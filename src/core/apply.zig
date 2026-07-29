//! Execute a `Plan`: move primaries/sidecars into the library, trash junk
//! (never hard-delete), and record every mutation in an undo `Journal`.
//! `undo` reverses a journal.

const std = @import("std");
const plan = @import("plan.zig");
const journal = @import("journal.zig");
const standardize = @import("standardize.zig");
const clock = @import("../util/clock.zig");

pub const OnConflict = enum { skip, suffix, overwrite };

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
pub fn applyInMemory(alloc: std.mem.Allocator, p: plan.Plan, on_conflict: OnConflict) !Outcome {
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
pub fn apply(alloc: std.mem.Allocator, p: plan.Plan, on_conflict: OnConflict, env: *std.process.Environ.Map) !Result {
    const out = try applyInMemory(alloc, p, on_conflict);
    const jpath = try journal.write(alloc, env, out.journal);
    return .{ .moved = out.moved, .trashed = out.trashed, .skipped = out.skipped, .journal_path = jpath };
}

/// Reverse a journal, last entry first.
pub fn undo(alloc: std.mem.Allocator, j: journal.Journal) !void {
    _ = alloc;
    var i = j.entries.len;
    while (i > 0) {
        i -= 1;
        const e = j.entries[i];
        moveFile(e.to, e.from) catch {};
    }
}

const t = std.testing;

fn writeFile(path_z: [:0]const u8, contents: []const u8) void {
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    _ = std.c.fwrite(contents.ptr, 1, contents.len, fp);
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

    const out = try applyInMemory(a, p, .skip);
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
