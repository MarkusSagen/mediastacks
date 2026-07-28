//! `FormatHandler` — VTable for per-format file operations.
//!
//! Mirrors the `Provider` pattern in `src/providers/provider.zig`:
//! opaque context pointer + function pointers for the operations every
//! format must (or may) support. Each format module exports a handler
//! constant; the registry in `registry.zig` owns the table and
//! dispatches by `Format` enum value.
//!
//! Operations: `readMetadata` (required), `extractCover`,
//! `writeMetadata`, `writeCover` (all optional — null means the
//! format doesn't support it, callers get `error.NotSupported`).

const std = @import("std");
const meta = @import("../core/metadata.zig");

/// Describes a metadata write. Each field is optional; null means
/// "don't touch this field". Field semantics match the corresponding
/// CLI flags (`--title`, `--author`, …) and the web layer's PATCH
/// shape. Lives here (rather than in `commands/setmeta.zig`) so
/// format handlers can reference it without a cyclic import.
pub const MetadataUpdate = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    series: ?[]const u8 = null,
    series_index: ?[]const u8 = null,
    year: ?[]const u8 = null,
    publisher: ?[]const u8 = null,
    language: ?[]const u8 = null,
    isbn: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Subjects/tags as a list. EPUB writes one `<dc:subject>` per
    /// entry; MOBI/AZW3 don't carry subjects via mobimeta and
    /// silently skip the field.
    subjects: ?[]const []const u8 = null,
};

/// What a format handler can do, surfaced separately so the UI and
/// command layer can ask "does this format support X?" without
/// invoking the function pointer (which is allowed to be null).
pub const Capabilities = struct {
    /// True when `readMetadata` returns confidence > derived. False for
    /// formats like PDF where the catalog has nothing to read.
    embedded_metadata: bool = false,
    /// True when `extractCover` is wired AND the format typically has
    /// a cover. Cover-cache layer uses this to decide whether to even
    /// bother trying on first scan.
    embedded_cover: bool = false,
    /// True when the format opens directly in foliate-js (no
    /// server-side rendering needed). EPUB/MOBI/AZW3/CBZ today. CBR/
    /// CB7/CBT are false — they need an external app or a future
    /// custom comic-reader page.
    reader_inline: bool = true,
};

pub const FormatHandler = struct {
    /// The `meta.Format` enum value this handler claims. Used for
    /// reverse-lookup by tag.
    format: meta.Format,
    /// File extensions this handler accepts, lowercase, no leading
    /// dot. Multiple extensions are common (`.mobi` and `.prc` both
    /// dispatch to the same MOBI handler).
    extensions: []const []const u8,
    capabilities: Capabilities,
    /// Opaque context. Most handlers don't need state and pass an
    /// empty `&{}` here; comic handlers use this to thread an
    /// `ArchiveReader` impl through. The shim functions cast it back.
    ctx: *const anyopaque = undefined,

    /// Required. Returns embedded metadata, or a low-confidence
    /// "derived from filename" stub when the format has nothing to
    /// surface (PDF today). `io` is threaded for handlers that shell
    /// out (CBR/CB7/CBT via `7zz`); in-process handlers like EPUB
    /// ignore it.
    read_metadata_fn: *const fn (
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) anyerror!meta.BookMetadata,

    /// Optional. When null, the caller treats it as `error.NoCover`.
    /// `io` is threaded so handlers that shell out (MOBI's mobitool,
    /// the planned `7zz` comic handler) can use `std.process.run`.
    extract_cover_fn: ?*const fn (
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) anyerror![]u8 = null,

    /// Optional. Apply a metadata patch to the file in place. EPUB
    /// rewrites the OPF + repacks the ZIP; MOBI/AZW3 shell out to
    /// `mobimeta`; comic + PDF handlers leave this null (the catalog
    /// row is updated separately for those, with no file-level write).
    write_metadata_fn: ?*const fn (
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        update: MetadataUpdate,
    ) anyerror!void = null,

    /// Optional. Replace the embedded cover image with `bytes`. EPUB
    /// is the only format we can write a cover INTO today (libmobi
    /// has no cover-write API); MOBI/AZW3 + comic + PDF use a
    /// library-side override file instead, written by the cover_store
    /// module rather than going through the handler.
    write_cover_fn: ?*const fn (
        ctx: *const anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        bytes: []const u8,
    ) anyerror!void = null,

    pub fn readMetadata(
        self: FormatHandler,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !meta.BookMetadata {
        return self.read_metadata_fn(self.ctx, allocator, io, path);
    }

    /// Returns `error.NoCover` when the handler doesn't support
    /// extraction, so callers don't have to null-check before
    /// dispatching.
    pub fn extractCover(
        self: FormatHandler,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) ![]u8 {
        const fnp = self.extract_cover_fn orelse return error.NoCover;
        return fnp(self.ctx, allocator, io, path);
    }

    /// Returns `error.NotSupported` when the format doesn't allow
    /// in-file metadata writes.
    pub fn writeMetadata(
        self: FormatHandler,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        update: MetadataUpdate,
    ) !void {
        const fnp = self.write_metadata_fn orelse return error.NotSupported;
        return fnp(self.ctx, allocator, io, path, update);
    }

    /// Returns `error.NotSupported` when the format doesn't allow
    /// in-file cover writes.
    pub fn writeCover(
        self: FormatHandler,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        bytes: []const u8,
    ) !void {
        const fnp = self.write_cover_fn orelse return error.NotSupported;
        return fnp(self.ctx, allocator, io, path, bytes);
    }
};
