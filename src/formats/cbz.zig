//! CBZ handler — ZIP-of-images comic/manga archive.
//!
//! Metadata comes from an optional `ComicInfo.xml` at the root of the
//! archive (Calibre / ComicRack v2.0 schema). Cover is the first image
//! entry sorted lexicographically — virtually every CBZ in the wild
//! follows the `001.jpg`, `002.jpg`, ... naming convention which makes
//! this trivially correct.
//!
//! The archive itself is opened via the existing miniz wrapper (same
//! one EPUB uses), so this handler adds zero new C deps.

const std = @import("std");
const zip = @import("../ffi/miniz.zig");
const xml = @import("../ffi/libxml2.zig");
const meta = @import("../core/metadata.zig");
const handler_mod = @import("handler.zig");

pub const Error = error{
    NoCover,
    ExtractFailed,
};

pub const handler: handler_mod.FormatHandler = .{
    .format = .cbz,
    .extensions = &.{"cbz"},
    .capabilities = .{
        .embedded_metadata = true,
        .embedded_cover = true,
        .reader_inline = true,
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
    _ = io;
    return readMetadata(allocator, path);
}

fn extractCoverShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) anyerror![]u8 {
    _ = io;
    return extractCover(allocator, path);
}

/// Read metadata from a CBZ. If `ComicInfo.xml` is present, parses it
/// for title/series/number/year/writer/publisher/language/genre/summary.
/// Otherwise returns a low-confidence `Derived` stub keyed on the
/// basename — the filename + path_meta will fill in the gaps later.
pub fn readMetadata(allocator: std.mem.Allocator, path: []const u8) !meta.BookMetadata {
    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

    const info_bytes = blk: {
        if (reader.readMember(allocator, "ComicInfo.xml")) |b| break :blk b else |_| {}
        const found = try findComicInfoMember(&reader, allocator);
        if (found) |name| {
            defer allocator.free(name);
            break :blk reader.readMember(allocator, name) catch null;
        }
        break :blk null;
    };

    if (info_bytes) |bytes| {
        defer allocator.free(bytes);
        return parseComicInfo(allocator, bytes);
    }
    return derivedFromPath(allocator, path);
}

/// Extract the cover image — first archive entry whose name (just
/// the basename, after stripping any directory prefix) has an image
/// extension, in lexicographic order. macOS resource-fork garbage
/// (`__MACOSX/`, `.DS_Store`) is skipped.
pub fn extractCover(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

    var collector: ImageCollector = .{ .allocator = allocator };
    defer collector.deinit();
    try reader.forEachMember(&collector, ImageCollector.add);

    if (collector.entries.items.len == 0) return Error.NoCover;
    std.mem.sort([]const u8, collector.entries.items, {}, lessThan);

    return reader.readMember(allocator, collector.entries.items[0]);
}

const ImageCollector = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ImageCollector) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
    }

    fn add(self: *ImageCollector, idx: u32, name: []const u8, uncomp: u64) anyerror!void {
        _ = idx;
        _ = uncomp;
        if (!isImageMember(name)) return;
        try self.entries.append(self.allocator, try self.allocator.dupe(u8, name));
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Public alias for `comic_archive.zig` to reuse the image filter
/// without duplicating the extension list.
pub fn isImageMemberPub(name: []const u8) bool {
    return isImageMember(name);
}

/// Filter for the cover-pick walk. Accepts JPEG/PNG/WebP/GIF; rejects
/// macOS resource forks, hidden files, and ComicInfo.xml.
fn isImageMember(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "__MACOSX/")) return false;
    const basename = std.fs.path.basename(name);
    if (basename.len == 0 or basename[0] == '.') return false;
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    var lower: [8]u8 = undefined;
    if (ext.len - 1 > lower.len) return false;
    for (ext[1..], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const e = lower[0 .. ext.len - 1];
    return std.mem.eql(u8, e, "jpg") or
        std.mem.eql(u8, e, "jpeg") or
        std.mem.eql(u8, e, "png") or
        std.mem.eql(u8, e, "webp") or
        std.mem.eql(u8, e, "gif");
}

/// Case-insensitive scan for a `ComicInfo.xml` entry. Some producers
/// (e.g. older Mylar exports) use lowercase or nested paths like
/// `info/ComicInfo.xml`. Returns an owned name slice or null.
fn findComicInfoMember(reader: *zip.ZipReader, allocator: std.mem.Allocator) !?[]u8 {
    var finder: ComicInfoFinder = .{ .allocator = allocator };
    try reader.forEachMember(&finder, ComicInfoFinder.match);
    return finder.found;
}

const ComicInfoFinder = struct {
    allocator: std.mem.Allocator,
    found: ?[]u8 = null,

    fn match(self: *ComicInfoFinder, idx: u32, name: []const u8, uncomp: u64) anyerror!void {
        _ = idx;
        _ = uncomp;
        if (self.found != null) return;
        const basename = std.fs.path.basename(name);
        if (std.ascii.eqlIgnoreCase(basename, "ComicInfo.xml")) {
            self.found = try self.allocator.dupe(u8, name);
        }
    }
};

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

/// Parse a ComicInfo.xml blob into a BookMetadata. Maps the
/// Calibre/ComicRack v2.0 schema; unknown fields are ignored. Returns
/// embedded-confidence (0.9) since publishers/scanners produce these
/// deliberately — they're not heuristic.
pub fn parseComicInfo(allocator: std.mem.Allocator, bytes: []const u8) !meta.BookMetadata {
    var doc = try xml.Doc.parseMemory(bytes);
    defer doc.deinit();

    var md: meta.BookMetadata = .{ .source = .embedded, .confidence = 0.9 };

    md.title = try doc.firstString(allocator, null, null, "//Title");
    md.series = try doc.firstString(allocator, null, null, "//Series");
    md.publisher = try doc.firstString(allocator, null, null, "//Publisher");
    md.language = try doc.firstString(allocator, null, null, "//LanguageISO");
    md.description = try doc.firstString(allocator, null, null, "//Summary");

    if (try doc.firstString(allocator, null, null, "//Number")) |n| {
        defer allocator.free(n);
        const trimmed = std.mem.trim(u8, n, " \t\r\n");
        if (std.fmt.parseFloat(f32, trimmed)) |v| {
            md.series_index = v;
        } else |_| {}
    }

    if (try doc.firstString(allocator, null, null, "//Year")) |y| {
        defer allocator.free(y);
        const trimmed = std.mem.trim(u8, y, " \t\r\n");
        if (std.fmt.parseInt(u16, trimmed, 10)) |v| {
            if (v >= 1000 and v < 3000) md.published_year = v;
        } else |_| {}
    }

    var authors_buf: std.ArrayList(meta.Author) = .empty;
    if (try doc.firstString(allocator, null, null, "//Writer")) |w| {
        defer allocator.free(w);
        const trimmed = std.mem.trim(u8, w, " \t\r\n");
        if (trimmed.len > 0) {
            try authors_buf.append(allocator, try meta.Author.fromDisplay(allocator, trimmed));
        }
    }
    if (try doc.firstString(allocator, null, null, "//Penciller")) |p| {
        defer allocator.free(p);
        const trimmed = std.mem.trim(u8, p, " \t\r\n");
        if (trimmed.len > 0) {
            try authors_buf.append(allocator, try meta.Author.fromDisplay(allocator, trimmed));
        }
    }
    md.authors = try authors_buf.toOwnedSlice(allocator);

    if (try doc.firstString(allocator, null, null, "//Genre")) |g| {
        defer allocator.free(g);
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, g, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            try out.append(allocator, try allocator.dupe(u8, trimmed));
            if (out.items.len >= 16) break;
        }
        md.subjects = try out.toOwnedSlice(allocator);
    }

    return md;
}

test "parseComicInfo extracts title + series + writer" {
    const fixture =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ComicInfo>
        \\  <Title>The Boys vs. The Seven</Title>
        \\  <Series>The Boys</Series>
        \\  <Number>1</Number>
        \\  <Year>2024</Year>
        \\  <Writer>Garth Ennis</Writer>
        \\  <Penciller>Darick Robertson</Penciller>
        \\  <Publisher>Dynamite</Publisher>
        \\  <LanguageISO>en</LanguageISO>
        \\  <Genre>Action, Superhero</Genre>
        \\  <Summary>Hughie joins a CIA-backed team that polices supers.</Summary>
        \\</ComicInfo>
    ;
    const a = std.testing.allocator;
    const md = try parseComicInfo(a, fixture);
    defer {
        if (md.title) |t| a.free(t);
        if (md.series) |s| a.free(s);
        if (md.publisher) |p| a.free(p);
        if (md.language) |l| a.free(l);
        if (md.description) |d| a.free(d);
        for (md.authors) |au| {
            a.free(au.last);
            a.free(au.first);
            a.free(au.sort);
        }
        a.free(md.authors);
        for (md.subjects) |s| a.free(s);
        a.free(md.subjects);
    }
    try std.testing.expectEqualStrings("The Boys vs. The Seven", md.title.?);
    try std.testing.expectEqualStrings("The Boys", md.series.?);
    try std.testing.expectEqual(@as(f32, 1), md.series_index.?);
    try std.testing.expectEqual(@as(u16, 2024), md.published_year.?);
    try std.testing.expectEqualStrings("Dynamite", md.publisher.?);
    try std.testing.expectEqualStrings("en", md.language.?);
    try std.testing.expect(std.mem.startsWith(u8, md.description.?, "Hughie"));
    try std.testing.expectEqual(@as(usize, 2), md.authors.len);
    try std.testing.expectEqual(@as(usize, 2), md.subjects.len);
}

test "parseComicInfo: minimal input" {
    const a = std.testing.allocator;
    const md = try parseComicInfo(a, "<ComicInfo><Title>Just A Title</Title></ComicInfo>");
    defer {
        if (md.title) |t| a.free(t);
        a.free(md.authors);
        a.free(md.subjects);
    }
    try std.testing.expectEqualStrings("Just A Title", md.title.?);
    try std.testing.expect(md.series == null);
    try std.testing.expect(md.published_year == null);
    try std.testing.expectEqual(@as(usize, 0), md.authors.len);
}

test "isImageMember filters known types" {
    try std.testing.expect(isImageMember("001.jpg"));
    try std.testing.expect(isImageMember("Page 02.JPEG"));
    try std.testing.expect(isImageMember("scans/03.png"));
    try std.testing.expect(isImageMember("004.webp"));
    try std.testing.expect(!isImageMember("ComicInfo.xml"));
    try std.testing.expect(!isImageMember("__MACOSX/._001.jpg"));
    try std.testing.expect(!isImageMember(".DS_Store"));
    try std.testing.expect(!isImageMember("Thumbs.db"));
}
