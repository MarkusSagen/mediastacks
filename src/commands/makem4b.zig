//! `medias makem4b DIR [--to LIB] [--out FILE] [--bitrate B]` — merge a folder
//! of chapter audio files into one chaptered `.m4b` audiobook (ffmpeg). Sources
//! are kept; the new file is journaled so `medias undo` removes it.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../core/config.zig");
const naming = @import("../core/naming.zig");
const plan = @import("../core/plan.zig");
const journal = @import("../core/journal.zig");
const standardize = @import("../core/standardize.zig");
const clock = @import("../util/clock.zig");
const music = @import("../kinds/music.zig");
const audiobook = @import("../kinds/audiobook.zig");

const AUDIO_EXT = [_][]const u8{ ".mp3", ".m4a", ".flac", ".aac", ".ogg", ".opus", ".wma" };

fn isAudio(ext: []const u8) bool {
    for (AUDIO_EXT) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn exists(path: []const u8) bool {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return false;
    const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return false;
    return std.c.access(p.ptr, 0) == 0;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var dir: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var out_flag: ?[]const u8 = null;
    var bitrate: []const u8 = "128k";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            to = args[i];
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            out_flag = args[i];
        } else if (std.mem.eql(u8, a, "--bitrate")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            bitrate = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return usage(ctx);
        } else if (dir == null) {
            dir = a;
        }
    }
    const dir_path = dir orelse return usage(ctx);

    // Collect audio chapter files (recursively), sorted by path.
    var files: std.ArrayList([]const u8) = .empty;
    {
        const cwd = std.Io.Dir.cwd();
        var d = cwd.openDir(ctx.io, dir_path, .{ .iterate = true }) catch |err| {
            try ctx.stderr.print("cannot open {s}: {s}\n", .{ dir_path, @errorName(err) });
            return 2;
        };
        defer d.close(ctx.io);
        var walker = try d.walk(ctx.arena);
        defer walker.deinit();
        while (try walker.next(ctx.io)) |entry| {
            if (entry.kind != .file) continue;
            const ext = std.fs.path.extension(entry.path);
            if (!isAudio(ext)) continue;
            try files.append(ctx.arena, try std.fs.path.join(ctx.arena, &.{ dir_path, entry.path }));
        }
    }
    if (files.items.len == 0) {
        try ctx.stderr.print("no audio chapter files found in {s}\n", .{dir_path});
        return 1;
    }
    std.mem.sort([]const u8, files.items, {}, lessStr);

    // Derive author/book from tags (consensus) and measure each chapter.
    var author: []const u8 = "Unknown Author";
    var book: ?[]const u8 = null;
    var chapters: std.ArrayList(audiobook.Chapter) = .empty;
    for (files.items) |abs| {
        const tr = music.parse(ctx.arena, ctx.io, abs) catch continue;
        if (std.mem.eql(u8, author, "Unknown Author")) {
            if (tr.album_artist) |aa| {
                if (aa.len > 0) author = aa;
            } else if (tr.artists.len > 0) author = tr.artists[0];
        }
        if (book == null) {
            if (tr.album) |al| if (al.len > 0) {
                book = al;
            };
        }
        const dur = audiobook.probeDurationMs(ctx.arena, ctx.io, abs) orelse {
            try ctx.stderr.print("cannot read duration of {s} (ffprobe required)\n", .{abs});
            return 2;
        };
        const title = tr.title orelse std.fs.path.basename(abs);
        try chapters.append(ctx.arena, .{ .path = abs, .title = title, .duration_ms = dur });
    }
    const book_title = book orelse std.fs.path.basename(dir_path);

    // Optional cover in the source folder.
    var cover: ?[]const u8 = null;
    for ([_][]const u8{ "cover.jpg", "folder.jpg", "cover.png", "folder.png" }) |name| {
        const p = try std.fs.path.join(ctx.arena, &.{ dir_path, name });
        if (exists(p)) {
            cover = p;
            break;
        }
    }

    // Destination: --out, else the audiobook library path for a single file.
    var cfg = try config.load(ctx.arena, ctx.env);
    if (to) |x| cfg.library_root = x;
    const out = out_flag orelse try naming.dstFor(ctx.arena, cfg, .audiobook, .{
        .album_artist = author,
        .album = book_title,
        .title = book_title,
        .ext = "m4b",
    });
    if (std.fs.path.dirname(out)) |parent| standardize.mkdirParents(parent) catch {};

    audiobook.makeM4b(ctx.arena, ctx.io, chapters.items, out, .{
        .book = book_title,
        .author = author,
        .cover_path = cover,
        .bitrate = bitrate,
    }) catch |err| switch (err) {
        error.FfmpegMissing => {
            try ctx.stderr.print("ffmpeg not found — install it to build .m4b files\n", .{});
            return 2;
        },
        else => {
            try ctx.stderr.print("m4b build failed: {s}\n", .{@errorName(err)});
            return 2;
        },
    };

    // Journal the created file so `medias undo` removes it (sources untouched).
    var entries = [_]journal.Entry{.{ .action = .create, .from = "", .to = out }};
    const j = journal.Journal{ .created = clock.nowSeconds(), .entries = entries[0..] };
    const jpath = journal.write(ctx.arena, ctx.env, j) catch "";

    try ctx.stdout.print(
        "created {s}\n  {d} chapters · {s} · author \"{s}\"\nundo with: medias undo   (journal: {s})\n",
        .{ out, chapters.items.len, book_title, author, jpath },
    );
    return 0;
}

fn usage(ctx: cli.Context) !u8 {
    try ctx.stderr.print("usage: medias makem4b DIR [--to LIB] [--out FILE.m4b] [--bitrate 128k]\n", .{});
    return 1;
}
