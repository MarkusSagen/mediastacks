//! `medias remux <file|dir> [--keep-langs en,ja] [--no-embed-subs] [--dry-run]`
//!
//! Losslessly repackages video into a clean `.mkv` (ffmpeg `-c copy`), drops
//! audio/subtitle tracks outside the keep-languages policy, and muxes matching
//! external subtitle sidecars into the container. Reversible: the original (and
//! any embedded sidecars) go to a trash dir and the run is recorded in the undo
//! journal, so `medias undo` restores everything.

const std = @import("std");
const cli = @import("../cli.zig");
const probe = @import("../core/probe.zig");
const remux = @import("../core/remux.zig");
const subtitles = @import("../core/subtitles.zig");
const journal = @import("../core/journal.zig");
const standardize = @import("../core/standardize.zig");
const exec = @import("../util/exec.zig");
const clock = @import("../util/clock.zig");

const video_exts = [_][]const u8{ ".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".webm", ".wmv" };

fn isVideo(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for (video_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    const arena = ctx.arena;
    const io = ctx.io;
    var path: ?[]const u8 = null;
    var dry_run = false;
    var embed_subs = true;
    var keep: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--no-embed-subs")) {
            embed_subs = false;
        } else if (std.mem.eql(u8, a, "--keep-langs")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            var it = std.mem.tokenizeScalar(u8, args[i], ',');
            while (it.next()) |tok| try keep.append(arena, tok);
        } else if (std.mem.startsWith(u8, a, "--")) {
            return usage(ctx);
        } else if (path == null) {
            path = a;
        } else return usage(ctx);
    }
    const target = path orelse return usage(ctx);

    if (!exec.isExecutableInPath(arena, io, "ffmpeg") or !probe.available(arena, io)) {
        try ctx.stderr.print("remux needs ffmpeg + ffprobe on PATH\n", .{});
        return 2;
    }

    // Collect video files: a single file, or every video under a directory.
    var videos: std.ArrayList([]const u8) = .empty;
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, target, .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(io);
        var w = try d.walk(arena);
        defer w.deinit();
        while (w.next(io) catch null) |ent| {
            if (ent.kind == .file and isVideo(ent.path))
                try videos.append(arena, try std.fs.path.join(arena, &.{ target, ent.path }));
        }
    } else |_| {
        if (isVideo(target)) try videos.append(arena, try arena.dupe(u8, target));
    }
    if (videos.items.len == 0) {
        try ctx.stderr.print("no video files found at {s}\n", .{target});
        return 1;
    }

    const created = clock.nowSeconds();
    var entries: std.ArrayList(journal.Entry) = .empty;
    var done: usize = 0;
    var skipped: usize = 0;

    for (videos.items) |video| {
        const pr = probe.run(arena, io, video) orelse {
            try ctx.stdout.print("  skip (unreadable): {s}\n", .{video});
            skipped += 1;
            continue;
        };
        const dir = std.fs.path.dirname(video) orelse ".";
        const stem = std.fs.path.stem(std.fs.path.basename(video));
        const ext_subs = if (embed_subs) try findSubs(arena, io, dir, stem) else &[_]remux.ExtSub{};

        const dst_final = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}.mkv", .{stem}) });
        const tmp = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, ".{s}.remux.{d}.mkv", .{ stem, clock.nowMs() }) });
        const r = try remux.buildArgs(arena, video, tmp, pr, ext_subs, keep.items);

        if (remux.isNoOp(video, r)) {
            skipped += 1;
            continue;
        }

        try ctx.stdout.print("  {s}\n    → {s}  (audio: keep {d} drop {d} · subs: keep {d} drop {d} embed {d})\n", .{
            std.fs.path.basename(video), std.fs.path.basename(dst_final),
            r.kept_audio, r.dropped_audio, r.kept_subs, r.dropped_subs, r.embedded_subs,
        });
        if (dry_run) {
            done += 1;
            continue;
        }

        const res = exec.runCaptureStdout(arena, io, r.argv, 1 << 20) catch {
            try ctx.stderr.print("  ffmpeg failed to spawn for {s}\n", .{video});
            continue;
        };
        if (res.exit_code != 0) {
            try ctx.stderr.print("  ffmpeg exited {d} for {s}\n", .{ res.exit_code, video });
            unlinkPath(arena, tmp);
            continue;
        }

        // Reversible swap: trash the original + embedded subs, move temp → final.
        try trashInto(arena, io, dir, video, created, &entries);
        for (ext_subs) |s| try trashInto(arena, io, dir, s.path, created, &entries);
        if (renamePath(arena, tmp, dst_final)) {
            try entries.append(arena, .{ .action = .create, .from = try arena.dupe(u8, ""), .to = try arena.dupe(u8, dst_final) });
            done += 1;
        } else {
            try ctx.stderr.print("  could not place {s}\n", .{dst_final});
        }
    }

    if (!dry_run and entries.items.len > 0)
        _ = journal.write(arena, ctx.env, .{ .created = created, .entries = entries.items }) catch {};

    try ctx.stdout.print("{s} {d} file(s){s}{d} skipped\n", .{
        if (dry_run) "would remux" else "remuxed",
        done,
        if (skipped > 0) ", " else " · ",
        skipped,
    });
    return 0;
}

/// External subtitle sidecars in `dir` whose name begins with the video stem.
fn findSubs(arena: std.mem.Allocator, io: std.Io, dir: []const u8, video_stem: []const u8) ![]remux.ExtSub {
    var out: std.ArrayList(remux.ExtSub) = .empty;
    const cwd = std.Io.Dir.cwd();
    var d = cwd.openDir(io, dir, .{ .iterate = true }) catch return out.toOwnedSlice(arena);
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .file) continue;
        const ext_dot = std.fs.path.extension(ent.name);
        if (ext_dot.len < 2 or !subtitles.isSubtitleExt(ext_dot[1..])) continue;
        const s_stem = std.fs.path.stem(ent.name);
        if (!std.mem.startsWith(u8, s_stem, video_stem)) continue;
        const info = subtitles.parse(s_stem);
        try out.append(arena, .{
            .path = try std.fs.path.join(arena, &.{ dir, try arena.dupe(u8, ent.name) }),
            .lang = info.lang,
            .forced = info.forced,
        });
    }
    return out.toOwnedSlice(arena);
}

fn trashInto(arena: std.mem.Allocator, io: std.Io, dir: []const u8, file: []const u8, created: i64, entries: *std.ArrayList(journal.Entry)) !void {
    _ = io;
    const base = std.fs.path.basename(file);
    const trash_dir = try std.fmt.allocPrint(arena, "{s}/.mediastacks-trash/{d}", .{ dir, created });
    standardize.mkdirParents(trash_dir) catch {};
    const to = try std.fs.path.join(arena, &.{ trash_dir, base });
    if (renamePath(arena, file, to))
        try entries.append(arena, .{ .action = .trash, .from = try arena.dupe(u8, file), .to = to });
}

fn zdup(arena: std.mem.Allocator, s: []const u8) ?[:0]u8 {
    const z = arena.allocSentinel(u8, s.len, 0) catch return null;
    @memcpy(z[0..s.len], s);
    return z;
}

fn renamePath(arena: std.mem.Allocator, from: []const u8, to: []const u8) bool {
    const fz = zdup(arena, from) orelse return false;
    const tz = zdup(arena, to) orelse return false;
    return std.c.rename(fz.ptr, tz.ptr) == 0;
}

fn unlinkPath(arena: std.mem.Allocator, p: []const u8) void {
    const z = zdup(arena, p) orelse return;
    _ = std.c.unlink(z.ptr);
}

fn usage(ctx: cli.Context) !u8 {
    try ctx.stderr.print("usage: medias remux <file|dir> [--keep-langs en,ja] [--no-embed-subs] [--dry-run]\n", .{});
    return 1;
}
