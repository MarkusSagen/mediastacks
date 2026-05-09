//! EPUB reader — opens the ZIP container with miniz, locates the OPF,
//! pulls metadata via libxml2 XPath.

const std = @import("std");
const zip = @import("../ffi/miniz.zig");
const xml = @import("../ffi/libxml2.zig");
const meta = @import("../core/metadata.zig");

const OPF_NS = "http://www.idpf.org/2007/opf";
const DC_NS = "http://purl.org/dc/elements/1.1/";

pub fn readMetadata(allocator: std.mem.Allocator, path: []const u8) !meta.BookMetadata {
    var reader = try zip.ZipReader.openFile(path);
    defer reader.close();

    // 1) container.xml -> OPF location
    const container_bytes = try reader.readMember(allocator, "META-INF/container.xml");
    defer allocator.free(container_bytes);

    var container = try xml.Doc.parseMemory(container_bytes);
    defer container.deinit();
    const opf_path = (try container.firstString(
        allocator,
        "c",
        "urn:oasis:names:tc:opendocument:xmlns:container",
        "//c:rootfile/@full-path",
    )) orelse return error.NoOpfPath;
    defer allocator.free(opf_path);

    // 2) Read and parse the OPF.
    const opf_bytes = try reader.readMember(allocator, opf_path);
    defer allocator.free(opf_bytes);
    var opf = try xml.Doc.parseMemory(opf_bytes);
    defer opf.deinit();

    const title = try opf.firstString(allocator, "dc", DC_NS, "//dc:title");
    const creator_raw = try opf.firstString(allocator, "dc", DC_NS, "//dc:creator");
    const publisher = try opf.firstString(allocator, "dc", DC_NS, "//dc:publisher");
    const language = try opf.firstString(allocator, "dc", DC_NS, "//dc:language");
    const description = try opf.firstString(allocator, "dc", DC_NS, "//dc:description");
    const date_raw = try opf.firstString(allocator, "dc", DC_NS, "//dc:date");
    const isbn_raw = try opf.firstString(
        allocator,
        "dc",
        DC_NS,
        "//dc:identifier[contains(translate(@*[local-name()='scheme'],'ISBN','isbn'),'isbn')]",
    );

    // dc:date is often "YYYY-MM-DD" or "YYYY"; pull leading year.
    var year: ?u16 = null;
    if (date_raw) |d| {
        defer allocator.free(d);
        if (d.len >= 4) year = std.fmt.parseInt(u16, d[0..4], 10) catch null;
    }

    var authors_buf: std.ArrayList(meta.Author) = .empty;
    if (creator_raw) |raw| {
        const a = try meta.Author.fromDisplay(allocator, raw);
        try authors_buf.append(allocator, a);
        allocator.free(raw);
    }

    return .{
        .title = title,
        .authors = try authors_buf.toOwnedSlice(allocator),
        .publisher = publisher,
        .language = language,
        .description = description,
        .isbn = isbn_raw,
        .published_year = year,
        .source = .embedded,
        .confidence = 0.9,
    };
}
