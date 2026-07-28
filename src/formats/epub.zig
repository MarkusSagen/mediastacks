//! EPUB reader — opens the ZIP container with miniz, locates the OPF,
//! pulls metadata via libxml2 XPath.

const std = @import("std");
const zip = @import("../ffi/miniz.zig");
const xml = @import("../ffi/libxml2.zig");
const meta = @import("../core/metadata.zig");
const handler_mod = @import("handler.zig");

const OPF_NS = "http://www.idpf.org/2007/opf";
const DC_NS = "http://purl.org/dc/elements/1.1/";

pub const CoverError = error{NoCover};

/// Registry-facing handler for `.epub`. Cover extraction lives in
/// `extractCover` below; `core/cover.zig::extract` calls into the
/// registry and ends up here, so the format module owns its dispatch.
pub const handler: handler_mod.FormatHandler = .{
    .format = .epub,
    .extensions = &.{"epub"},
    .capabilities = .{
        .embedded_metadata = true,
        .embedded_cover = true,
        .reader_inline = true,
    },
    .read_metadata_fn = readMetadataShim,
    .extract_cover_fn = extractCoverShim,
    .write_metadata_fn = writeMetadataShim,
    .write_cover_fn = writeCoverShim,
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

fn writeMetadataShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    update: handler_mod.MetadataUpdate,
) anyerror!void {
    _ = io;
    return writeMetadata(allocator, path, update);
}

fn writeCoverShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
) anyerror!void {
    _ = io;
    return writeCover(allocator, path, bytes);
}

/// Extract the cover image bytes from an EPUB. Walks the standard
/// container.xml → OPF → manifest dance: an EPUB3 file declares the
/// cover with `properties="cover-image"` on a manifest item; EPUB2
/// uses a `<meta name="cover" content="ID"/>` indirection. Returns
/// owned bytes or `error.NoCover` when neither resolution finds a
/// cover.
pub fn extractCover(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

    const container_bytes = try reader.readMember(allocator, "META-INF/container.xml");
    defer allocator.free(container_bytes);

    var container = try xml.Doc.parseMemory(container_bytes);
    defer container.deinit();
    const opf_path = (try container.firstString(
        allocator,
        "c",
        "urn:oasis:names:tc:opendocument:xmlns:container",
        "//c:rootfile/@full-path",
    )) orelse return CoverError.NoCover;
    defer allocator.free(opf_path);

    const opf_bytes = try reader.readMember(allocator, opf_path);
    defer allocator.free(opf_bytes);

    var opf = try xml.Doc.parseMemory(opf_bytes);
    defer opf.deinit();

    var cover_href = try opf.firstString(
        allocator,
        "p",
        OPF_NS,
        "//p:item[contains(@properties,'cover-image')]/@href",
    );
    if (cover_href == null) {
        const cover_id = try opf.firstString(
            allocator,
            "p",
            OPF_NS,
            "//p:meta[@name='cover']/@content",
        );
        if (cover_id) |id| {
            defer allocator.free(id);
            var xpath_buf: [256]u8 = undefined;
            const xpath = try std.fmt.bufPrint(&xpath_buf, "//p:item[@id='{s}']/@href", .{id});
            cover_href = try opf.firstString(allocator, "p", OPF_NS, xpath);
        }
    }
    const href = cover_href orelse return CoverError.NoCover;
    defer allocator.free(href);

    const opf_dir = std.fs.path.dirname(opf_path) orelse "";
    const member_path = if (opf_dir.len > 0)
        try std.fs.path.join(allocator, &.{ opf_dir, href })
    else
        try allocator.dupe(u8, href);
    defer allocator.free(member_path);

    return reader.readMember(allocator, member_path);
}

pub fn readMetadata(allocator: std.mem.Allocator, path: []const u8) !meta.BookMetadata {
    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

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

    var subjects_buf: std.ArrayList([]const u8) = .empty;
    {
        const c = @import("c");
        const ctx = c.xmlXPathNewContext(opf.ptr);
        if (ctx) |xctx| {
            defer c.xmlXPathFreeContext(xctx);
            const ns_uri: [:0]const u8 = "http://purl.org/dc/elements/1.1/";
            _ = c.xmlXPathRegisterNs(xctx, "dc", ns_uri.ptr);
            if (c.xmlXPathEvalExpression("//dc:subject", xctx)) |result| {
                defer c.xmlXPathFreeObject(result);
                const nodes = result.*.nodesetval;
                if (nodes != null) {
                    var i: c_int = 0;
                    while (i < nodes.*.nodeNr) : (i += 1) {
                        const node = nodes.*.nodeTab[@intCast(i)];
                        const content = c.xmlNodeGetContent(node);
                        if (content == null) continue;
                        defer c.xmlFree.?(content);
                        const cstr: [*c]u8 = @ptrCast(content);
                        const len = std.mem.len(cstr);
                        if (len == 0) continue;
                        const trimmed = std.mem.trim(u8, cstr[0..len], " \t\r\n");
                        if (trimmed.len == 0) continue;
                        try subjects_buf.append(allocator, try allocator.dupe(u8, trimmed));
                    }
                }
            }
        }
    }

    return .{
        .title = title,
        .authors = try authors_buf.toOwnedSlice(allocator),
        .publisher = publisher,
        .language = language,
        .description = description,
        .isbn = isbn_raw,
        .published_year = year,
        .subjects = try subjects_buf.toOwnedSlice(allocator),
        .source = .embedded,
        .confidence = 0.9,
    };
}

/// Substitute the metadata fields in `update` into the EPUB's OPF
/// document and repack. Null fields are left alone. Series + index
/// land in Calibre-compatible `<meta name="calibre:series..."/>`.
pub fn writeMetadata(arena: std.mem.Allocator, path: []const u8, update: handler_mod.MetadataUpdate) !void {
    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

    const container = try reader.readMember(arena, "META-INF/container.xml");
    const opf_path = (try findOpfPath(arena, container)) orelse return error.NoOpf;
    const opf_bytes = try reader.readMember(arena, opf_path);
    const new_opf = try rewriteOpf(arena, opf_bytes, update);

    const tmp_path = try std.fmt.allocPrint(arena, "{s}.meta.tmp", .{path});
    var writer: zip.ZipWriter = .{};
    try writer.create(tmp_path);
    errdefer writer.abort();

    const Walk = struct {
        arena: std.mem.Allocator,
        reader: *zip.ZipReader,
        writer: *zip.ZipWriter,
        opf_path: []const u8,
        new_opf: []const u8,

        fn add(self: *@This(), _: u32, name: []const u8, _: u64) anyerror!void {
            const level: zip.ZipWriter.Compression =
                if (std.mem.eql(u8, name, "mimetype")) .none else .best;
            if (std.mem.eql(u8, name, self.opf_path)) {
                try self.writer.addBytes(name, self.new_opf, level);
            } else {
                const bytes = try self.reader.readMember(self.arena, name);
                defer self.arena.free(bytes);
                try self.writer.addBytes(name, bytes, level);
            }
        }
    };
    var walk_ctx = Walk{
        .arena = arena,
        .reader = &reader,
        .writer = &writer,
        .opf_path = opf_path,
        .new_opf = new_opf,
    };
    try reader.forEachMember(&walk_ctx, Walk.add);
    try writer.finalizeAndClose();

    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{tmp_path});
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{path});
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) return error.RenameFailed;
}

/// Replace the bytes of the EPUB's declared cover image with
/// `image_bytes`. The OPF must already designate one (EPUB3
/// `properties="cover-image"` on a manifest item, or EPUB2
/// `<meta name="cover">` indirection); booktool refuses to fabricate
/// a cover-image entry from scratch (use Sigil/Calibre to add one
/// initially).
pub fn writeCover(arena: std.mem.Allocator, book_path: []const u8, image_bytes: []const u8) !void {
    var reader: zip.ZipReader = .{};
    try reader.open(book_path);
    defer reader.close();

    const container_bytes = try reader.readMember(arena, "META-INF/container.xml");
    var container = try xml.Doc.parseMemory(container_bytes);
    defer container.deinit();
    const opf_path = (try container.firstString(
        arena,
        "c",
        "urn:oasis:names:tc:opendocument:xmlns:container",
        "//c:rootfile/@full-path",
    )) orelse return error.NoOpf;
    const opf_dir = std.fs.path.dirname(opf_path) orelse "";

    const opf_bytes = try reader.readMember(arena, opf_path);
    var opf = try xml.Doc.parseMemory(opf_bytes);
    defer opf.deinit();

    var cover_href = try opf.firstString(
        arena,
        "p",
        OPF_NS,
        "//p:item[contains(@properties,'cover-image')]/@href",
    );
    if (cover_href == null) {
        const cover_id = try opf.firstString(arena, "p", OPF_NS, "//p:meta[@name='cover']/@content");
        if (cover_id) |id| {
            var xp: [256]u8 = undefined;
            const xpath = try std.fmt.bufPrint(&xp, "//p:item[@id='{s}']/@href", .{id});
            cover_href = try opf.firstString(arena, "p", OPF_NS, xpath);
        }
    }
    const href = cover_href orelse return error.NoCoverItem;

    const cover_member_path = if (opf_dir.len > 0)
        try std.fs.path.join(arena, &.{ opf_dir, href })
    else
        try arena.dupe(u8, href);

    const tmp_path = try std.fmt.allocPrint(arena, "{s}.cover.tmp", .{book_path});
    var writer: zip.ZipWriter = .{};
    try writer.create(tmp_path);
    errdefer writer.abort();

    const Walk = struct {
        arena: std.mem.Allocator,
        reader: *zip.ZipReader,
        writer: *zip.ZipWriter,
        cover_path: []const u8,
        new_image: []const u8,
        replaced: bool = false,

        fn add(self: *@This(), _: u32, name: []const u8, _: u64) anyerror!void {
            const level: zip.ZipWriter.Compression =
                if (std.mem.eql(u8, name, "mimetype")) .none else .best;
            if (std.mem.eql(u8, name, self.cover_path)) {
                try self.writer.addBytes(name, self.new_image, level);
                self.replaced = true;
            } else {
                const bytes = try self.reader.readMember(self.arena, name);
                defer self.arena.free(bytes);
                try self.writer.addBytes(name, bytes, level);
            }
        }
    };
    var walk_ctx = Walk{
        .arena = arena,
        .reader = &reader,
        .writer = &writer,
        .cover_path = cover_member_path,
        .new_image = image_bytes,
    };
    try reader.forEachMember(&walk_ctx, Walk.add);
    if (!walk_ctx.replaced) {
        writer.abort();
        unlinkPath(tmp_path);
        return error.CoverMemberMissing;
    }
    try writer.finalizeAndClose();

    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{tmp_path});
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{book_path});
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) {
        unlinkPath(tmp_path);
        return error.RenameFailed;
    }
}

fn unlinkPath(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(z.ptr);
}

fn findOpfPath(arena: std.mem.Allocator, container: []const u8) !?[]const u8 {
    const tag = "full-path=\"";
    const start = std.mem.indexOf(u8, container, tag) orelse return null;
    const after = start + tag.len;
    const end = std.mem.indexOfScalarPos(u8, container, after, '"') orelse return null;
    return try arena.dupe(u8, container[after..end]);
}

fn rewriteOpf(arena: std.mem.Allocator, opf: []const u8, u: handler_mod.MetadataUpdate) ![]u8 {
    var current = try arena.dupe(u8, opf);
    if (u.title) |t| current = try replaceElementText(arena, current, "dc:title", t);
    if (u.author) |a| current = try replaceElementText(arena, current, "dc:creator", a);
    if (u.year) |y| current = try replaceElementText(arena, current, "dc:date", y);
    if (u.publisher) |p| current = try replaceElementText(arena, current, "dc:publisher", p);
    if (u.language) |l| current = try replaceElementText(arena, current, "dc:language", l);
    if (u.description) |d| current = try replaceElementText(arena, current, "dc:description", d);
    if (u.isbn) |i| current = try replaceElementText(arena, current, "dc:identifier", i);
    if (u.series) |s| current = try upsertMeta(arena, current, "calibre:series", s);
    if (u.series_index) |idx| current = try upsertMeta(arena, current, "calibre:series_index", idx);
    if (u.subjects) |s| current = try replaceSubjects(arena, current, s);
    return current;
}

/// Drop every existing `<dc:subject>...</dc:subject>` element, then
/// append one per supplied subject before `</metadata>`. We do a full
/// replace (not a merge) because the input is the user's canonical
/// list — anything not in it should disappear.
fn replaceSubjects(arena: std.mem.Allocator, src: []const u8, subjects: []const []const u8) ![]u8 {
    var current = src;
    while (std.mem.indexOf(u8, current, "<dc:subject")) |open_pos| {
        const gt = std.mem.indexOfScalarPos(u8, current, open_pos, '>') orelse break;
        const before_gt = current[gt -| 1];
        const end_after = if (before_gt == '/') gt + 1 else blk: {
            const close_pos = std.mem.indexOfPos(u8, current, gt + 1, "</dc:subject>") orelse break;
            break :blk close_pos + "</dc:subject>".len;
        };
        current = try std.fmt.allocPrint(arena, "{s}{s}", .{ current[0..open_pos], current[end_after..] });
    }
    for (subjects) |s| {
        if (s.len == 0) continue;
        current = try appendInMetadata(arena, current, "dc:subject", s);
    }
    return arena.dupe(u8, current);
}

fn replaceElementText(arena: std.mem.Allocator, src: []const u8, tag: []const u8, value: []const u8) ![]u8 {
    const open_search = try std.fmt.allocPrint(arena, "<{s}", .{tag});
    defer arena.free(open_search);
    if (std.mem.indexOf(u8, src, open_search)) |open_pos| {
        const gt = std.mem.indexOfScalarPos(u8, src, open_pos, '>') orelse return arena.dupe(u8, src);
        const close = try std.fmt.allocPrint(arena, "</{s}>", .{tag});
        defer arena.free(close);
        const close_pos = std.mem.indexOfPos(u8, src, gt + 1, close) orelse return arena.dupe(u8, src);
        const escaped = try xmlEscape(arena, value);
        defer arena.free(escaped);
        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ src[0 .. gt + 1], escaped, src[close_pos..] });
    }
    return appendInMetadata(arena, src, tag, value);
}

fn upsertMeta(arena: std.mem.Allocator, src: []const u8, name: []const u8, value: []const u8) ![]u8 {
    const needle = try std.fmt.allocPrint(arena, "name=\"{s}\"", .{name});
    defer arena.free(needle);
    if (std.mem.indexOf(u8, src, needle)) |npos| {
        const after = std.mem.indexOfPos(u8, src, npos, "content=\"") orelse
            return appendMetaInline(arena, src, name, value);
        const after_q = after + "content=\"".len;
        const end_q = std.mem.indexOfScalarPos(u8, src, after_q, '"') orelse
            return appendMetaInline(arena, src, name, value);
        const escaped = try xmlEscape(arena, value);
        defer arena.free(escaped);
        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ src[0..after_q], escaped, src[end_q..] });
    }
    return appendMetaInline(arena, src, name, value);
}

fn appendMetaInline(arena: std.mem.Allocator, src: []const u8, name: []const u8, value: []const u8) ![]u8 {
    const escaped = try xmlEscape(arena, value);
    defer arena.free(escaped);
    const tag = try std.fmt.allocPrint(arena, "<meta name=\"{s}\" content=\"{s}\"/>", .{ name, escaped });
    defer arena.free(tag);
    return insertBeforeCloseMetadata(arena, src, tag);
}

fn appendInMetadata(arena: std.mem.Allocator, src: []const u8, tag_name: []const u8, value: []const u8) ![]u8 {
    const escaped = try xmlEscape(arena, value);
    defer arena.free(escaped);
    const piece = try std.fmt.allocPrint(arena, "<{s}>{s}</{s}>", .{ tag_name, escaped, tag_name });
    defer arena.free(piece);
    return insertBeforeCloseMetadata(arena, src, piece);
}

fn insertBeforeCloseMetadata(arena: std.mem.Allocator, src: []const u8, fragment: []const u8) ![]u8 {
    const pos = std.mem.indexOf(u8, src, "</metadata>") orelse return arena.dupe(u8, src);
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ src[0..pos], fragment, src[pos..] });
}

fn xmlEscape(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    for (s) |ch| switch (ch) {
        '&' => try buf.appendSlice(arena, "&amp;"),
        '<' => try buf.appendSlice(arena, "&lt;"),
        '>' => try buf.appendSlice(arena, "&gt;"),
        '"' => try buf.appendSlice(arena, "&quot;"),
        '\'' => try buf.appendSlice(arena, "&apos;"),
        else => try buf.append(arena, ch),
    };
    return buf.toOwnedSlice(arena);
}

test "replaceElementText overwrites existing text" {
    const alloc = std.testing.allocator;
    const src =
        "<package><metadata><dc:title>Old</dc:title><dc:creator>X</dc:creator></metadata></package>";
    const out = try replaceElementText(alloc, src, "dc:title", "New");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:title>New</dc:title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Old") == null);
}

test "replaceElementText appends when missing" {
    const alloc = std.testing.allocator;
    const src = "<package><metadata></metadata></package>";
    const out = try replaceElementText(alloc, src, "dc:title", "Brand New");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:title>Brand New</dc:title></metadata>") != null);
}

test "upsertMeta updates existing meta content attribute" {
    const alloc = std.testing.allocator;
    const src = "<metadata><meta name=\"calibre:series\" content=\"Old\"/></metadata>";
    const out = try upsertMeta(alloc, src, "calibre:series", "Stormlight");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "content=\"Stormlight\"") != null);
}

test "xmlEscape handles special chars" {
    const alloc = std.testing.allocator;
    const out = try xmlEscape(alloc, "Tolkien & Sons <Press>");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Tolkien &amp; Sons &lt;Press&gt;", out);
}

test "replaceSubjects strips old elements and appends the new list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "<package><metadata>" ++
        "<dc:title>X</dc:title>" ++
        "<dc:subject>Old1</dc:subject>" ++
        "<dc:subject>Old2</dc:subject>" ++
        "</metadata></package>";
    const subs = [_][]const u8{ "Fantasy", "Adventure", "Magic" };
    const out = try replaceSubjects(arena, src, &subs);

    try std.testing.expect(std.mem.indexOf(u8, out, "Old1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Old2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:subject>Fantasy</dc:subject>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:subject>Adventure</dc:subject>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:subject>Magic</dc:subject>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:title>X</dc:title>") != null);
}

test "replaceSubjects handles self-closing dc:subject elements" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "<metadata><dc:subject/></metadata>";
    const subs = [_][]const u8{"NewTag"};
    const out = try replaceSubjects(arena, src, &subs);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:subject/>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:subject>NewTag</dc:subject>") != null);
}

test "replaceSubjects with empty list just strips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "<metadata><dc:subject>One</dc:subject></metadata>";
    const empty: []const []const u8 = &.{};
    const out = try replaceSubjects(arena, src, empty);
    try std.testing.expect(std.mem.indexOf(u8, out, "One") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:subject") == null);
}
