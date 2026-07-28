//! On-disk library-side cover overrides.
//!
//! For MOBI/AZW3 we can't write covers back into the file (libmobi
//! exposes no cover-write API and mobimeta's named-key list does not
//! include cover/thumbnail), and even for EPUB it's useful to keep an
//! out-of-file copy so the catalog can serve the user's chosen cover
//! without re-extracting from the archive on every request.
//!
//! Layout: `$XDG_DATA_HOME/booktool/covers/<id>.<ext>`. Same parent dir
//! as the catalog DB. Extension is sniffed from the image magic bytes
//! so the file is self-describing on disk.

const std = @import("std");
const cover_resize = @import("../ffi/cover_resize.zig");

/// Gallery thumbnail dimension (CSS-pixel width). The card is ~180px
/// wide @1x, ~360px @2x. 320px is the sweet spot: visually crisp
/// on most displays while keeping the encoded payload and the
/// decoded bitmap small (~10-30 KB encoded, ~400 KB decoded).
pub const THUMB_MAX_WIDTH: u32 = 320;
pub const THUMB_JPEG_QUALITY: u32 = 82;

pub const Ext = enum {
    jpg,
    png,

    pub fn asString(self: Ext) []const u8 {
        return switch (self) {
            .jpg => "jpg",
            .png => "png",
        };
    }

    pub fn contentType(self: Ext) []const u8 {
        return switch (self) {
            .jpg => "image/jpeg",
            .png => "image/png",
        };
    }
};

/// Sniff a cover image's extension/content-type from its first few
/// bytes. Defaults to `.jpg` when the magic doesn't match — JPEG is by
/// far the more common cover format and OpenLibrary always returns it.
pub fn sniff(bytes: []const u8) Ext {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpg;
    return .jpg;
}

/// Returns `$XDG_DATA_HOME/booktool/covers/` (with a trailing path
/// separator), creating the directory if it does not exist.
pub fn dirPath(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
) ![]const u8 {
    const dir = if (env.get("XDG_DATA_HOME")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "booktool", "covers" })
    else blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "booktool", "covers" });
    };
    ensureDir(dir);
    return dir;
}

/// Sibling of `dirPath` for the auto-extracted thumb cache. Same disk
/// layout (`<id>.<ext>`), but unlike `covers/` these files are not
/// "user-chosen" — they're just a memo of `cover.extract` output so we
/// don't re-parse the EPUB/spawn `mobitool` on every gallery request.
pub fn thumbDirPath(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
) ![]const u8 {
    const dir = if (env.get("XDG_DATA_HOME")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "booktool", "thumbs" })
    else blk: {
        const home = env.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "booktool", "thumbs" });
    };
    ensureDir(dir);
    return dir;
}

fn thumbPathFor(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
    ext: Ext,
) ![]const u8 {
    const dir = try thumbDirPath(allocator, env);
    return try std.fmt.allocPrint(allocator, "{s}/{d}.{s}", .{ dir, id, ext.asString() });
}

/// Returns the on-disk path of an existing thumb file for `id`, or
/// null if none cached. Probes both `.jpg` and `.png` since the
/// extraction picks whichever the source file had.
pub fn existingThumbPath(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
) !?[]const u8 {
    for ([_]Ext{ .jpg, .png }) |ext| {
        const p = try thumbPathFor(allocator, env, id, ext);
        if (pathExists(p)) return p;
    }
    return null;
}

/// Read a cached thumb for `id`, or null when none has been written yet.
pub fn readThumb(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
) !?ReadResult {
    const path = (try existingThumbPath(allocator, env, id)) orelse return null;
    const bytes = try readWhole(allocator, path);
    const ext: Ext = if (std.mem.endsWith(u8, path, ".png")) .png else .jpg;
    return .{ .bytes = bytes, .ext = ext };
}

/// Write `bytes` as the cached thumb for `id`. Resizes to
/// `THUMB_MAX_WIDTH` so the gallery's decoded-bitmap memory footprint
/// stays bounded. On resize failure (corrupt source, unsupported
/// format like CMYK), falls back to writing the original bytes
/// unchanged — the gallery still works, just heavier.
pub fn writeThumb(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
    bytes: []const u8,
) !void {
    try unlinkThumb(allocator, env, id);

    const resized = cover_resize.resize(
        allocator,
        bytes,
        THUMB_MAX_WIDTH,
        THUMB_JPEG_QUALITY,
    ) catch null;
    defer if (resized) |r| allocator.free(r);

    const to_write = if (resized) |r| r else bytes;
    const ext: Ext = if (resized != null) .jpg else sniff(bytes);
    const path = try thumbPathFor(allocator, env, id, ext);
    try writeAll(path, to_write);
}

/// Clear the cached thumb for `id`. Called when the user uploads a
/// cover override (so the override is what's served next time) and on
/// row delete.
pub fn unlinkThumb(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
) !void {
    for ([_]Ext{ .jpg, .png }) |ext| {
        const path = try thumbPathFor(allocator, env, id, ext);
        var z: [4096]u8 = undefined;
        if (path.len >= z.len) continue;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = std.c.unlink(@ptrCast(&z));
    }
}

/// Returns the on-disk path for a book's override file, given an
/// explicit extension. Does not check whether the file exists.
pub fn pathFor(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
    ext: Ext,
) ![]const u8 {
    const dir = try dirPath(allocator, env);
    return try std.fmt.allocPrint(allocator, "{s}/{d}.{s}", .{ dir, id, ext.asString() });
}

/// Returns the on-disk path of an existing override file for `id`, or
/// null if none exists. Probes both `.jpg` and `.png`.
pub fn existingPath(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
) !?[]const u8 {
    for ([_]Ext{ .jpg, .png }) |ext| {
        const p = try pathFor(allocator, env, id, ext);
        if (pathExists(p)) return p;
    }
    return null;
}

/// True if an override file (either extension) exists for `id`.
pub fn exists(
    env: *std.process.Environ.Map,
    id: i64,
) bool {
    var buf: [4096]u8 = undefined;
    const dir = dirPathRaw(env, &buf) catch return false;
    var path_buf: [4096]u8 = undefined;
    for ([_]Ext{ .jpg, .png }) |ext| {
        const path = std.fmt.bufPrint(
            &path_buf,
            "{s}/{d}.{s}",
            .{ dir, id, ext.asString() },
        ) catch continue;
        var z: [4096]u8 = undefined;
        if (path.len >= z.len) continue;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        if (std.c.access(@ptrCast(&z), 0) == 0) return true;
    }
    return false;
}

/// Write `bytes` as the override for `id`. The extension is picked from
/// the magic bytes. Any pre-existing override file (regardless of
/// extension) is removed first so we never end up with both .jpg and
/// .png for the same id.
pub fn write(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
    bytes: []const u8,
) !void {
    try unlink(allocator, env, id);
    const ext = sniff(bytes);
    const path = try pathFor(allocator, env, id, ext);
    try writeAll(path, bytes);
}

/// Read the override bytes for `id`, or return null if none exists.
pub fn read(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
) !?ReadResult {
    const path = (try existingPath(allocator, env, id)) orelse return null;
    const bytes = try readWhole(allocator, path);
    const ext: Ext = if (std.mem.endsWith(u8, path, ".png")) .png else .jpg;
    return .{ .bytes = bytes, .ext = ext };
}

pub const ReadResult = struct {
    bytes: []u8,
    ext: Ext,
};

/// Delete the override file for `id`. No-op if missing.
pub fn unlink(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    id: i64,
) !void {
    for ([_]Ext{ .jpg, .png }) |ext| {
        const path = try pathFor(allocator, env, id, ext);
        var z: [4096]u8 = undefined;
        if (path.len >= z.len) continue;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = std.c.unlink(@ptrCast(&z));
    }
}

fn dirPathRaw(env: *std.process.Environ.Map, buf: []u8) ![]const u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return try std.fmt.bufPrint(buf, "{s}/booktool/covers", .{xdg});
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return try std.fmt.bufPrint(buf, "{s}/.local/share/booktool/covers", .{home});
}

fn ensureDir(dir_path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (dir_path.len >= buf.len) return;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, dir_path, i + 1, '/')) |slash| {
        if (slash == 0) {
            i = slash;
            continue;
        }
        @memcpy(buf[0..slash], dir_path[0..slash]);
        buf[slash] = 0;
        _ = std.c.mkdir(@ptrCast(&buf), 0o755);
        i = slash;
    }
    @memcpy(buf[0..dir_path.len], dir_path);
    buf[dir_path.len] = 0;
    _ = std.c.mkdir(@ptrCast(&buf), 0o755);
}

fn pathExists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    return std.c.access(@ptrCast(&z), 0) == 0;
}

fn writeAll(path: []const u8, bytes: []const u8) !void {
    var z: [4096]u8 = undefined;
    if (path.len >= z.len) return error.PathTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fp = std.c.fopen(@ptrCast(&z), "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (bytes.len == 0) return;
    const wrote = std.c.fwrite(bytes.ptr, 1, bytes.len, fp);
    if (wrote != bytes.len) return error.WriteFailed;
}

fn readWhole(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var z: [4096]u8 = undefined;
    if (path.len >= z.len) return error.PathTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fp = std.c.fopen(@ptrCast(&z), "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (fseek(fp, 0, 2) != 0) return error.SeekFailed;
    const sz = ftell(fp);
    if (sz < 0) return error.SeekFailed;
    _ = fseek(fp, 0, 0);
    const buf = try allocator.alloc(u8, @intCast(sz));
    if (std.c.fread(buf.ptr, 1, buf.len, fp) != buf.len) return error.ReadFailed;
    return buf;
}

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

test "sniff identifies jpg vs png magic" {
    const jpg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 0 };
    const png = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    try std.testing.expect(sniff(&jpg) == .jpg);
    try std.testing.expect(sniff(&png) == .png);
    try std.testing.expect(sniff("nope") == .jpg);
}

test "write/read/unlink round-trip via XDG_DATA_HOME" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [4096]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", tmp_path);

    const png = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3 };
    try write(alloc, &env, 42, &png);
    try std.testing.expect(exists(&env, 42));

    const got = (try read(alloc, &env, 42)) orelse return error.MissingCover;
    defer alloc.free(got.bytes);
    try std.testing.expect(got.ext == .png);
    try std.testing.expectEqualSlices(u8, &png, got.bytes);

    try unlink(alloc, &env, 42);
    try std.testing.expect(!exists(&env, 42));
    try unlink(alloc, &env, 42);
}
