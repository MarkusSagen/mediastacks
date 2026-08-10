//! Execute a `Plan`: move primaries/sidecars into the library, trash junk
//! (never hard-delete), and record every mutation in an undo `Journal`.
//! `undo` reverses a journal.

const std = @import("std");
const plan = @import("plan.zig");
const journal = @import("journal.zig");
const standardize = @import("standardize.zig");
const clock = @import("../util/clock.zig");
const music_tags = @import("../kinds/music_tags.zig");

pub const OnConflict = enum { skip, suffix, overwrite };

/// Opt-in tag write-back on apply. When `write`, music primaries get their tags
/// rewritten from `Plan.Fields` after the move — backed up to `backup_dir` and
/// journaled so `shelve undo` restores the original bytes.
pub const TagOpts = struct { write: bool = false, backup_dir: ?[]const u8 = null };

pub const Result = struct {
    moved: u32,
    trashed: u32,
    skipped: u32,
    journal_path: []const u8,
};

pub const Outcome = struct {
    journal: journal.Journal,
    moved: u32,
    trashed: u32,
    skipped: u32,
};

fn exists(path: []const u8) bool {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return false;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return false;
    return std.c.access(path_z.ptr, 0) == 0;
}

/// Move `from` → `to`, creating parent dirs; falls back to a cross-device
/// copy on EXDEV.
fn moveFile(from: []const u8, to: []const u8) !void {
    if (std.fs.path.dirname(to)) |parent| try standardize.mkdirParents(parent);
    var fz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    if (from.len >= fz.len or to.len >= tz.len) return error.PathTooLong;
    const from_z = try std.fmt.bufPrintZ(&fz, "{s}", .{from});
    const to_z = try std.fmt.bufPrintZ(&tz, "{s}", .{to});
    if (std.c.rename(from_z.ptr, to_z.ptr) != 0) {
        try standardize.copyAcrossDevices(from_z, to_z);
        _ = std.c.unlink(from_z.ptr);
    }
}

/// Resolve a destination against an existing file. Returns the final path
/// (owned by `alloc`), or null meaning "skip this item".
fn resolveConflict(alloc: std.mem.Allocator, dst: []const u8, on_conflict: OnConflict) !?[]u8 {
    if (!exists(dst)) return try alloc.dupe(u8, dst);
    switch (on_conflict) {
        .skip => return null,
        .overwrite => {
            var pz: [4096]u8 = undefined;
            if (dst.len < pz.len) {
                const dz = std.fmt.bufPrintZ(&pz, "{s}", .{dst}) catch return null;
                _ = std.c.unlink(dz.ptr);
            }
            return try alloc.dupe(u8, dst);
        },
        .suffix => {
            const ext = std.fs.path.extension(dst);
            const stem = dst[0 .. dst.len - ext.len];
            var n: u32 = 1;
            while (n < 1000) : (n += 1) {
                const cand = try std.fmt.allocPrint(alloc, "{s} ({d}){s}", .{ stem, n, ext });
                if (!exists(cand)) return cand;
                alloc.free(cand);
            }
            return null;
        },
    }
}

fn trashPath(alloc: std.mem.Allocator, root: []const u8, from: []const u8, created: i64) ![]u8 {
    const base = std.fs.path.basename(from);
    return std.fmt.allocPrint(alloc, "{s}/.stacks-trash/{d}/{s}", .{ root, created, base });
}

/// Perform the filesystem work and return the in-memory journal. All
/// journal strings are owned by `alloc`. Split out from `apply` so tests
/// don't touch the real XDG data dir.
pub fn applyInMemory(alloc: std.mem.Allocator, p: plan.Plan, on_conflict: OnConflict, tag_opts: TagOpts) !Outcome {
    const created = clock.nowSeconds();
    var entries: std.ArrayList(journal.Entry) = .empty;
    errdefer entries.deinit(alloc);

    var moved: u32 = 0;
    var trashed: u32 = 0;
    var skipped: u32 = 0;

    for (p.groups) |g| {
        for (g.items) |item| {
            switch (item.op) {
                .move, .copy => {
                    const dst0 = item.dst orelse {
                        skipped += 1;
                        continue;
                    };
                    const final = (try resolveConflict(alloc, dst0, on_conflict)) orelse {
                        skipped += 1;
                        continue;
                    };
                    try moveFile(item.src, final);
                    try entries.append(alloc, .{ .action = .move, .from = try alloc.dupe(u8, item.src), .to = final });
                    moved += 1;

                    if (tag_opts.write and g.kind == .music and item.role == .primary) {
                        try maybeWriteTags(alloc, &entries, tag_opts.backup_dir, final, item, created);
                    }
                },
                .trash => {
                    const tp = try trashPath(alloc, p.library_root, item.src, created);
                    try moveFile(item.src, tp);
                    try entries.append(alloc, .{ .action = .trash, .from = try alloc.dupe(u8, item.src), .to = tp });
                    trashed += 1;
                },
                .skip => skipped += 1,
            }
        }
    }

    return .{
        .journal = .{ .created = created, .entries = try entries.toOwnedSlice(alloc) },
        .moved = moved,
        .trashed = trashed,
        .skipped = skipped,
    };
}

/// Apply `p` and persist the journal under the env's XDG data dir.
pub fn apply(alloc: std.mem.Allocator, p: plan.Plan, on_conflict: OnConflict, env: *std.process.Environ.Map, tag_opts: TagOpts) !Result {
    var opts = tag_opts;
    if (opts.write and opts.backup_dir == null) {
        // Backups live beside the undo journals.
        const d = try journal.dir(alloc, env); // $XDG_DATA_HOME/stacks/undo
        defer alloc.free(d);
        const parent = std.fs.path.dirname(d) orelse d; // $XDG_DATA_HOME/stacks
        opts.backup_dir = try std.fs.path.join(alloc, &.{ parent, "backup" });
    }
    const out = try applyInMemory(alloc, p, on_conflict, opts);
    const jpath = try journal.write(alloc, env, out.journal);
    return .{ .moved = out.moved, .trashed = out.trashed, .skipped = out.skipped, .journal_path = jpath };
}

fn tagSetFromFields(f: plan.Fields) music_tags.TagSet {
    return .{
        .title = f.title,
        .artists = f.artists,
        .album_artist = f.album_artist,
        .album = f.album,
        .track = f.track,
        .disc = f.disc,
        .year = f.year,
        .release_mbid = f.release_mbid,
        .recording_mbid = f.recording_mbid,
    };
}

/// Back up `target` then write tags into it, journaling a `.tagwrite` entry
/// (from=target, to=backup). Skips silently (no mutation) on any
/// unsupported/failed step — never writes without a restorable backup.
fn maybeWriteTags(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(journal.Entry),
    backup_dir: ?[]const u8,
    target: []const u8,
    item: plan.Item,
    created: i64,
) !void {
    const fields = item.fields orelse return;
    const ext = std.fs.path.extension(target);
    if (!std.ascii.eqlIgnoreCase(ext, ".flac") and !std.ascii.eqlIgnoreCase(ext, ".mp3")) return;

    const bdir = backup_dir orelse return;
    const base = std.fs.path.basename(target);
    const backup = try std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{ bdir, created, base });
    if (std.fs.path.dirname(backup)) |bp| standardize.mkdirParents(bp) catch return;

    var fz: [4096]u8 = undefined;
    var bz: [4096]u8 = undefined;
    if (target.len >= fz.len or backup.len >= bz.len) return;
    const fzp = std.fmt.bufPrintZ(&fz, "{s}", .{target}) catch return;
    const bzp = std.fmt.bufPrintZ(&bz, "{s}", .{backup}) catch return;
    standardize.copyAcrossDevices(fzp, bzp) catch return; // no backup → no write

    music_tags.writeTags(alloc, target, tagSetFromFields(fields)) catch return;
    try entries.append(alloc, .{ .action = .tagwrite, .from = try alloc.dupe(u8, target), .to = backup });
}

/// Reverse a journal, last entry first. `.tagwrite` restores the pre-tag bytes
/// (copy backup over target); `.move`/`.trash` move the file back.
pub fn undo(alloc: std.mem.Allocator, j: journal.Journal) !void {
    _ = alloc;
    var i = j.entries.len;
    while (i > 0) {
        i -= 1;
        const e = j.entries[i];
        switch (e.action) {
            .tagwrite => {
                var fz: [4096]u8 = undefined;
                var bz: [4096]u8 = undefined;
                if (e.from.len < fz.len and e.to.len < bz.len) {
                    const fzp = std.fmt.bufPrintZ(&fz, "{s}", .{e.from}) catch continue;
                    const bzp = std.fmt.bufPrintZ(&bz, "{s}", .{e.to}) catch continue;
                    // copyAcrossDevices is O_EXCL — remove the tagged target first
                    // so the backup can be restored over it.
                    _ = std.c.unlink(fzp.ptr);
                    standardize.copyAcrossDevices(bzp, fzp) catch {};
                }
            },
            .move, .trash => moveFile(e.to, e.from) catch {},
        }
    }
}

const t = std.testing;

fn writeFile(path_z: [:0]const u8, contents: []const u8) void {
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    _ = std.c.fwrite(contents.ptr, 1, contents.len, fp);
}

fn readBytes(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pz: [4096]u8 = undefined;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
    const fp = std.c.fopen(pzp.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch return null;
    }
    return buf.toOwnedSlice(alloc) catch null;
}

test "apply writes tags with backup and undo restores original bytes" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pid = std.c.getpid();
    const mt = @import("../kinds/music_tags.zig");

    var srcb: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&srcb, "/tmp/stacks-tw-{d}-src.flac", .{pid});
    var outdirb: [256]u8 = undefined;
    const outdir = try std.fmt.bufPrint(&outdirb, "/tmp/stacks-tw-{d}-out", .{pid});
    var dstb: [320]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dstb, "{s}/Album/01 - T.flac", .{outdir});
    var bkb: [256]u8 = undefined;
    const backup_dir = try std.fmt.bufPrint(&bkb, "/tmp/stacks-tw-{d}-bak", .{pid});

    const orig = try mt.buildFlac(a, try mt.synthFlacForTest(a), .{ .artists = &.{"Solo"}, .album = "Old" });
    defer a.free(orig);
    var sz: [256]u8 = undefined;
    writeFile(try std.fmt.bufPrintZ(&sz, "{s}", .{src}), orig);

    var items = [_]plan.Item{.{
        .src = src, .role = .primary, .op = .move, .dst = dst, .reason = "",
        .fields = .{ .album_artist = "A", .album = "Album", .title = "T", .track = 1, .artists = &.{ "A", "B" }, .ext = "flac" },
    }};
    var groups = [_]plan.Group{.{ .kind = .music, .title = "Album", .items = items[0..] }};
    const p = plan.Plan{ .library_root = "/tmp", .source = "/tmp", .groups = groups[0..] };

    const out = try applyInMemory(a, p, .skip, .{ .write = true, .backup_dir = backup_dir });
    defer journal.freeOwned(a, out.journal);
    try t.expect(exists(dst));
    const back = readBytes(a, dst).?;
    defer a.free(back);
    const artists = (try mt.readVorbisValues(a, back, "ARTIST")).?;
    try t.expectEqual(@as(usize, 2), artists.len); // wrote two artists

    try undo(a, out.journal);
    try t.expect(exists(src));
    const restored = readBytes(a, src).?;
    defer a.free(restored);
    try t.expectEqualSlices(u8, orig, restored); // byte-identical original

    // cleanup (best-effort)
    var z: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&z, "{s}", .{src}) catch unreachable).ptr);
    _ = std.c.unlink((std.fmt.bufPrintZ(&z, "{s}", .{dst}) catch unreachable).ptr);
}

test "apply moves a primary and undo restores it" {
    const a = t.allocator;
    const pid = std.c.getpid();

    var srcb: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&srcb, "/tmp/stacks-apply-{d}-src.mkv", .{pid});
    var outdirb: [256]u8 = undefined;
    const outdir = try std.fmt.bufPrint(&outdirb, "/tmp/stacks-apply-{d}-out", .{pid});
    var dstb: [320]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dstb, "{s}/Show - S01E01.mkv", .{outdir});

    var srcz: [256]u8 = undefined;
    writeFile(try std.fmt.bufPrintZ(&srcz, "{s}", .{src}), "video-bytes");

    var items = [_]plan.Item{.{ .src = src, .role = .primary, .op = .move, .dst = dst, .reason = "" }};
    var groups = [_]plan.Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const p = plan.Plan{ .library_root = "/tmp", .source = "/tmp", .groups = groups[0..] };

    const out = try applyInMemory(a, p, .skip, .{});
    defer journal.freeOwned(a, out.journal);
    try t.expectEqual(@as(u32, 1), out.moved);
    try t.expect(exists(dst));
    try t.expect(!exists(src));

    try undo(a, out.journal);
    try t.expect(exists(src));
    try t.expect(!exists(dst));

    // cleanup
    var z: [320]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&z, "{s}", .{src}) catch unreachable).ptr);
    _ = std.c.rmdir((std.fmt.bufPrintZ(&z, "{s}", .{outdir}) catch unreachable).ptr);
}
