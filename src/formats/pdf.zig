//! PDF stub handler.
//!
//! PDFs have an embedded Info dictionary (Title/Author/Producer/etc.)
//! and a first-page rendering for the cover, but we don't yet parse
//! either. v1 just registers the format so PDFs aren't `unknown`
//! during scan; the catalog row gets a `Derived` confidence with the
//! filename as title so the user sees them in the library.
//!
//! Reader side: pdf.js handles it in the web UI (see `openPdfReader`
//! in app.js). Cover extraction can come later — pdfium or a pure-Zig
//! parser would land here as `extractCover`.

const std = @import("std");
const meta = @import("../core/metadata.zig");
const handler_mod = @import("handler.zig");

pub const handler: handler_mod.FormatHandler = .{
    .format = .pdf,
    .extensions = &.{"pdf"},
    .capabilities = .{
        .embedded_metadata = false,
        .embedded_cover = false,
        .reader_inline = true,
    },
    .read_metadata_fn = readMetadataShim,
    .extract_cover_fn = null,
};

fn readMetadataShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) anyerror!meta.BookMetadata {
    _ = io;
    const basename = std.fs.path.basename(path);
    const ext_dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = std.mem.trim(u8, basename[0..ext_dot], " ");
    return .{
        .title = if (stem.len > 0) try allocator.dupe(u8, stem) else null,
        .source = .derived,
        .confidence = 0.1,
    };
}
