//! CBR handler — RAR-of-images comic archive.
//!
//! RAR is proprietary; we shell out to `7zz` (sevenzip) for both
//! listing and per-member extraction. When `7zz` isn't on PATH, the
//! handler degrades to filename-only metadata and a no-cover stub —
//! the book still appears in the catalog with the right format chip,
//! the user just doesn't get rich metadata until they install
//! sevenzip (`brew install sevenzip` / `apt install p7zip-full`).

const std = @import("std");
const meta = @import("../core/metadata.zig");
const handler_mod = @import("handler.zig");
const archive = @import("comic_archive.zig");

pub const handler: handler_mod.FormatHandler = .{
    .format = .cbr,
    .extensions = &.{"cbr"},
    .capabilities = .{
        .embedded_metadata = true,
        .embedded_cover = true,
        .reader_inline = false,
    },
    .read_metadata_fn = readMetadataShim,
    .extract_cover_fn = extractCoverShim,
};

fn readMetadataShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) anyerror!meta.BookMetadata {
    if (!archive.Sevenzip.isAvailable(allocator, io)) {
        return derivedFromPath(allocator, path);
    }
    var sz: archive.Sevenzip = .{
        .allocator = allocator,
        .io = io,
        .archive_path = path,
    };
    return archive.readMetadata(sz.reader(), allocator, path);
}

fn extractCoverShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) anyerror![]u8 {
    var sz: archive.Sevenzip = .{
        .allocator = allocator,
        .io = io,
        .archive_path = path,
    };
    if (!archive.Sevenzip.isAvailable(allocator, io)) {
        return archive.Error.NoCover;
    }
    return archive.extractCover(sz.reader(), allocator);
}

fn derivedFromPath(allocator: std.mem.Allocator, path: []const u8) !meta.BookMetadata {
    const basename = std.fs.path.basename(path);
    const ext_dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = std.mem.trim(u8, basename[0..ext_dot], " ");
    return .{
        .title = if (stem.len > 0) try allocator.dupe(u8, stem) else null,
        .source = .derived,
        .confidence = 0.2,
    };
}
