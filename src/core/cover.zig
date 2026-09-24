//! Cover image extraction — dispatch shim.
//!
//! The actual cover-extraction logic now lives in each per-format
//! module (`formats/epub.zig::extractCover`, `formats/mobi.zig::
//! extractCover`). This file's `extract` looks up the handler via
//! the registry and delegates. Callers don't need to change — the
//! signature is identical to the previous switch-based dispatcher.

const std = @import("std");
const meta = @import("metadata.zig");
const registry = @import("../formats/registry.zig");

pub const Error = error{
    NoCover,
    ExtractFailed,
};

/// Extract the cover image bytes from a book. Returns owned bytes
/// on success, `error.NoCover` when the handler is missing or
/// doesn't support cover extraction.
pub fn extract(allocator: std.mem.Allocator, io: std.Io, path: []const u8, fmt: meta.Format) ![]u8 {
    const h = registry.forFormat(fmt) orelse return Error.NoCover;
    return h.extractCover(allocator, io, path);
}

/// Write `bytes` to a tmp file and return its path (caller frees).
pub fn writeTmp(allocator: std.mem.Allocator, bytes: []const u8, extension: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/mediastacks-cover-{d}.{s}",
        .{ std.c.getpid(), extension },
    );
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return Error.ExtractFailed;
    defer _ = std.c.fclose(fp);
    const n = std.c.fwrite(bytes.ptr, 1, bytes.len, fp);
    if (n != bytes.len) return Error.ExtractFailed;
    return path;
}
