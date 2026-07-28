//! CB7 handler — 7z-of-images comic archive. Less common than CBZ/CBR
//! but seen in size-optimised manga collections (7z gets ~20% better
//! compression than ZIP on flat image data).
//!
//! Same shell-out shape as CBR — see `cbr.zig` for the rationale.

const std = @import("std");
const meta = @import("../core/metadata.zig");
const handler_mod = @import("handler.zig");
const archive = @import("comic_archive.zig");

pub const handler: handler_mod.FormatHandler = .{
    .format = .cb7,
    .extensions = &.{"cb7"},
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
    if (!archive.Sevenzip.isAvailable(allocator, io)) return derivedFromPath(allocator, path);
    var sz: archive.Sevenzip = .{ .allocator = allocator, .io = io, .archive_path = path };
    return archive.readMetadata(sz.reader(), allocator, path);
}

fn extractCoverShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) anyerror![]u8 {
    if (!archive.Sevenzip.isAvailable(allocator, io)) return archive.Error.NoCover;
    var sz: archive.Sevenzip = .{ .allocator = allocator, .io = io, .archive_path = path };
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
