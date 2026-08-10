//! Undo journal: every apply records its moves and trashes so `shelve
//! undo` can reverse them. Stored as JSON under
//! `$XDG_DATA_HOME/stacks/undo/<timestamp>.json`, with a `latest`
//! pointer file naming the most recent journal.

const std = @import("std");
const standardize = @import("standardize.zig");

pub const Action = enum { move, trash, tagwrite, create };
pub const Entry = struct { action: Action, from: []const u8, to: []const u8 };
pub const Journal = struct { created: i64, entries: []Entry };

/// Resolve the undo directory path. Owned by `alloc`.
pub fn dir(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(alloc, &.{ xdg, "stacks", "undo" });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "stacks", "undo" });
}

fn writeFileZ(path: []const u8, bytes: []const u8) !void {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return error.PathTooLong;
    const path_z = try std.fmt.bufPrintZ(&pz, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (bytes.len == 0) return;
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) return error.WriteFailed;
}

fn readFileZ(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return null;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        try buf.appendSlice(alloc, chunk[0..n]);
    }
    return try buf.toOwnedSlice(alloc);
}

/// Write journal `j` under `dir_path`; also update the `latest` pointer.
/// Returns the journal file path (owned by `alloc`).
pub fn writeTo(alloc: std.mem.Allocator, dir_path: []const u8, j: Journal) ![]u8 {
    try standardize.mkdirParents(dir_path);

    const fname = try std.fmt.allocPrint(alloc, "{d}.json", .{j.created});
    defer alloc.free(fname);
    const jpath = try std.fs.path.join(alloc, &.{ dir_path, fname });

    const bytes = try std.json.Stringify.valueAlloc(alloc, j, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    try writeFileZ(jpath, bytes);

    const lp = try std.fs.path.join(alloc, &.{ dir_path, "latest" });
    defer alloc.free(lp);
    try writeFileZ(lp, jpath);

    return jpath;
}

/// Path of the most recent journal under `dir_path`, or null. Owned by `alloc`.
pub fn latestIn(alloc: std.mem.Allocator, dir_path: []const u8) !?[]u8 {
    const lp = try std.fs.path.join(alloc, &.{ dir_path, "latest" });
    defer alloc.free(lp);
    const contents = (try readFileZ(alloc, lp)) orelse return null;
    defer alloc.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \n\r\t");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

/// Convenience env-driven wrappers.
pub fn write(alloc: std.mem.Allocator, env: *std.process.Environ.Map, j: Journal) ![]u8 {
    const d = try dir(alloc, env);
    defer alloc.free(d);
    return writeTo(alloc, d, j);
}

pub fn latest(alloc: std.mem.Allocator, env: *std.process.Environ.Map) !?[]u8 {
    const d = try dir(alloc, env);
    defer alloc.free(d);
    return latestIn(alloc, d);
}

/// Load a journal from `path`. Uses `alloc` leakily — pass an arena, or
/// call `freeOwned` on the result.
pub fn load(alloc: std.mem.Allocator, path: []const u8) !Journal {
    const bytes = (try readFileZ(alloc, path)) orelse return error.FileNotFound;
    defer alloc.free(bytes);
    // `.alloc_always` so parsed strings own their memory and survive freeing
    // `bytes` (the default aliases the input buffer).
    return std.json.parseFromSliceLeaky(Journal, alloc, bytes, .{ .allocate = .alloc_always });
}

/// Free a Journal whose `from`/`to` strings and `entries` slice are all
/// owned by `alloc` (as produced by `apply.applyInMemory`).
pub fn freeOwned(alloc: std.mem.Allocator, j: Journal) void {
    for (j.entries) |e| {
        alloc.free(e.from);
        alloc.free(e.to);
    }
    alloc.free(j.entries);
}

const t = std.testing;

test "journal round-trips a tagwrite entry" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var db: [256]u8 = undefined;
    const d = try std.fmt.bufPrint(&db, "/tmp/stacks-jtw-{d}", .{pid});
    var entries = [_]Entry{.{ .action = .tagwrite, .from = "/lib/a.flac", .to = "/backup/1/a.flac" }};
    const j = Journal{ .created = 7, .entries = entries[0..] };
    const jpath = try writeTo(a, d, j);
    defer a.free(jpath);
    const loaded = try load(a, jpath);
    defer freeOwned(a, loaded);
    try t.expectEqual(Action.tagwrite, loaded.entries[0].action);
    try t.expectEqualStrings("/backup/1/a.flac", loaded.entries[0].to);
    var pz: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&pz, "{s}", .{jpath}) catch unreachable).ptr);
    _ = std.c.unlink((std.fmt.bufPrintZ(&pz, "{s}/latest", .{d}) catch unreachable).ptr);
    _ = std.c.rmdir((std.fmt.bufPrintZ(&pz, "{s}", .{d}) catch unreachable).ptr);
}

test "journal writeTo + latestIn + load round-trips" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var db: [256]u8 = undefined;
    const d = try std.fmt.bufPrint(&db, "/tmp/stacks-journal-{d}", .{pid});

    var entries = [_]Entry{
        .{ .action = .move, .from = "/x/a.mkv", .to = "/lib/a.mkv" },
        .{ .action = .trash, .from = "/x/.DS_Store", .to = "/lib/.trash/1/.DS_Store" },
    };
    const j = Journal{ .created = 1234, .entries = entries[0..] };

    const jpath = try writeTo(a, d, j);
    defer a.free(jpath);

    const latest_path = (try latestIn(a, d)).?;
    defer a.free(latest_path);
    try t.expectEqualStrings(jpath, latest_path);

    const loaded = try load(a, latest_path);
    defer freeOwned(a, loaded);
    try t.expectEqual(@as(i64, 1234), loaded.created);
    try t.expectEqual(@as(usize, 2), loaded.entries.len);
    try t.expectEqual(Action.trash, loaded.entries[1].action);
    try t.expectEqualStrings("/x/a.mkv", loaded.entries[0].from);

    // cleanup
    var pz: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&pz, "{s}", .{jpath}) catch unreachable).ptr);
    var lz: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&lz, "{s}/latest", .{d}) catch unreachable).ptr);
    var dz: [512]u8 = undefined;
    _ = std.c.rmdir((std.fmt.bufPrintZ(&dz, "{s}", .{d}) catch unreachable).ptr);
}
