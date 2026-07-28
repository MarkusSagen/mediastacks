//! EPUB chapter extraction for the TUI reader.
//!
//! Opens an EPUB, walks the OPF spine to get an ordered list of
//! content documents, extracts each one as plaintext (tag-stripped
//! and entity-decoded). The TUI then word-wraps and paginates.
//!
//! Returns a `Book` struct that owns all string memory through the
//! provided allocator.

const std = @import("std");
const zip = @import("../ffi/miniz.zig");
const xml = @import("../ffi/libxml2.zig");
const c = @import("c");

const OPF_NS = "http://www.idpf.org/2007/opf";
const DC_NS = "http://purl.org/dc/elements/1.1/";

pub const Chapter = struct {
    title: ?[]const u8,
    text: []const u8,
};

pub const Book = struct {
    title: ?[]const u8,
    author: ?[]const u8,
    chapters: []Chapter,
};

pub fn open(allocator: std.mem.Allocator, path: []const u8) !Book {
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
    const opf_dir = std.fs.path.dirname(opf_path) orelse "";

    const opf_bytes = try reader.readMember(allocator, opf_path);
    defer allocator.free(opf_bytes);
    var opf = try xml.Doc.parseMemory(opf_bytes);
    defer opf.deinit();

    const title = try opf.firstString(allocator, "dc", DC_NS, "//dc:title");
    const author = try opf.firstString(allocator, "dc", DC_NS, "//dc:creator");

    const itemrefs = try collectAttribute(opf, allocator, "p", OPF_NS, "//p:spine/p:itemref/@idref");
    defer freeStringList(allocator, itemrefs);

    var chapters: std.ArrayList(Chapter) = .empty;

    for (itemrefs) |idref| {
        var xpath_buf: [256]u8 = undefined;
        const xpath = std.fmt.bufPrint(&xpath_buf, "//p:item[@id='{s}']/@href", .{idref}) catch continue;
        const href = (try opf.firstString(allocator, "p", OPF_NS, xpath)) orelse continue;
        defer allocator.free(href);

        const member_path = if (opf_dir.len > 0)
            try std.fs.path.join(allocator, &.{ opf_dir, href })
        else
            try allocator.dupe(u8, href);
        defer allocator.free(member_path);

        const raw_bytes = reader.readMember(allocator, member_path) catch continue;
        defer allocator.free(raw_bytes);

        const plaintext = try htmlToText(allocator, raw_bytes);
        if (countNonWhitespace(plaintext) < 20) {
            allocator.free(plaintext);
            continue;
        }
        try chapters.append(allocator, .{ .title = null, .text = plaintext });
    }

    return .{
        .title = title,
        .author = author,
        .chapters = try chapters.toOwnedSlice(allocator),
    };
}

fn countNonWhitespace(s: []const u8) usize {
    var n: usize = 0;
    for (s) |ch| if (!std.ascii.isWhitespace(ch)) {
        n += 1;
    };
    return n;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

/// Collect every string-valued match from an XPath query (handles cases
/// where libxml2.firstString returns only the first). Uses raw libxml2
/// calls because our wrapper only exposes `firstString`.
fn collectAttribute(
    doc: xml.Doc,
    allocator: std.mem.Allocator,
    ns_prefix: []const u8,
    ns_uri: []const u8,
    xpath: []const u8,
) ![]const []const u8 {
    const ctx = c.xmlXPathNewContext(doc.ptr) orelse return error.XPathFailed;
    defer c.xmlXPathFreeContext(ctx);

    var p_z: [128]u8 = undefined;
    var u_z: [256]u8 = undefined;
    if (ns_prefix.len >= p_z.len or ns_uri.len >= u_z.len) return error.XPathFailed;
    @memcpy(p_z[0..ns_prefix.len], ns_prefix);
    p_z[ns_prefix.len] = 0;
    @memcpy(u_z[0..ns_uri.len], ns_uri);
    u_z[ns_uri.len] = 0;
    _ = c.xmlXPathRegisterNs(ctx, @ptrCast(&p_z), @ptrCast(&u_z));

    var xp_z: [1024]u8 = undefined;
    if (xpath.len >= xp_z.len) return error.XPathFailed;
    @memcpy(xp_z[0..xpath.len], xpath);
    xp_z[xpath.len] = 0;

    const result = c.xmlXPathEvalExpression(@ptrCast(&xp_z), ctx) orelse return error.XPathFailed;
    defer c.xmlXPathFreeObject(result);

    var list: std.ArrayList([]const u8) = .empty;
    const nodes = result.*.nodesetval;
    if (nodes == null) return list.toOwnedSlice(allocator);
    var i: c_int = 0;
    while (i < nodes.*.nodeNr) : (i += 1) {
        const node = nodes.*.nodeTab[@intCast(i)];
        const content = c.xmlNodeGetContent(node) orelse continue;
        defer c.xmlFree.?(content);
        const cstr: [*c]u8 = @ptrCast(content);
        const len = std.mem.len(cstr);
        if (len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, cstr[0..len]));
    }
    return list.toOwnedSlice(allocator);
}

/// Convert XHTML/HTML to plaintext: strip tags, decode the handful of
/// entities that matter for narrative text. Paragraph breaks (`</p>`,
/// `<br>`, headings) are normalised to `\n\n`. Whitespace inside text
/// runs is collapsed.
pub fn htmlToText(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    var in_tag = false;
    var in_script = false;
    var in_style = false;
    var prev_was_space = true;

    while (i < input.len) : (i += 1) {
        const ch = input[i];

        if (in_tag) {
            if (ch == '>') {
                const tag = lastTag(input, i);
                in_tag = false;
                if (isBlockTag(tag)) {
                    appendParagraphBreak(allocator, &out, &prev_was_space) catch {};
                }
                if (std.ascii.eqlIgnoreCase(tag, "script")) {
                    in_script = true;
                } else if (std.ascii.eqlIgnoreCase(tag, "/script")) {
                    in_script = false;
                } else if (std.ascii.eqlIgnoreCase(tag, "style")) {
                    in_style = true;
                } else if (std.ascii.eqlIgnoreCase(tag, "/style")) {
                    in_style = false;
                } else if (std.ascii.eqlIgnoreCase(tag, "br") or
                    std.ascii.eqlIgnoreCase(tag, "br/") or
                    std.ascii.eqlIgnoreCase(tag, "br /"))
                {
                    try out.append(allocator, '\n');
                    prev_was_space = true;
                }
            }
            continue;
        }

        if (ch == '<') {
            in_tag = true;
            continue;
        }

        if (in_script or in_style) continue;

        if (ch == '&') {
            if (decodeEntity(input[i..])) |dec| {
                try out.appendSlice(allocator, dec.text);
                i += dec.skip - 1;
                prev_was_space = false;
                continue;
            }
            try out.append(allocator, ch);
            prev_was_space = false;
            continue;
        }

        if (std.ascii.isWhitespace(ch)) {
            if (!prev_was_space) {
                try out.append(allocator, ' ');
                prev_was_space = true;
            }
            continue;
        }

        try out.append(allocator, ch);
        prev_was_space = false;
    }

    return collapseBlankLines(allocator, out.items);
}

fn appendParagraphBreak(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    prev_was_space: *bool,
) !void {
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or
        out.items[out.items.len - 1] == '\n'))
    {
        if (out.items[out.items.len - 1] == '\n' and out.items.len >= 2 and
            out.items[out.items.len - 2] == '\n')
        {
            break;
        }
        _ = out.pop();
    }
    if (out.items.len > 0) try out.appendSlice(allocator, "\n\n");
    prev_was_space.* = true;
}

fn collapseBlankLines(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var newline_run: u8 = 0;
    for (src) |ch| {
        if (ch == '\n') {
            newline_run += 1;
            if (newline_run <= 2) try out.append(allocator, ch);
            continue;
        }
        newline_run = 0;
        try out.append(allocator, ch);
    }
    var slice: []const u8 = out.items;
    while (slice.len > 0 and std.ascii.isWhitespace(slice[0])) slice = slice[1..];
    while (slice.len > 0 and std.ascii.isWhitespace(slice[slice.len - 1])) slice = slice[0 .. slice.len - 1];
    return allocator.dupe(u8, slice);
}

fn lastTag(input: []const u8, gt_index: usize) []const u8 {
    var lt: usize = gt_index;
    while (lt > 0) : (lt -= 1) {
        if (input[lt - 1] == '<') break;
    }
    if (lt == 0) return "";
    var tag = input[lt..gt_index];
    var end: usize = 0;
    while (end < tag.len) : (end += 1) {
        if (tag[end] == ' ' or tag[end] == '\t' or tag[end] == '/' and end > 0) break;
    }
    if (end > 0 and tag.len > 0 and tag[0] == '/') {
        return tag[0..end];
    }
    return tag[0..end];
}

fn isBlockTag(tag: []const u8) bool {
    const blocks = [_][]const u8{
        "p",   "/p",         "div",         "/div",    "br",       "h1",      "h2",       "h3",
        "h4",  "h5",         "h6",          "/h1",     "/h2",      "/h3",     "/h4",      "/h5",
        "/h6", "li",         "/li",         "tr",      "/tr",      "ul",      "/ul",      "ol",
        "/ol", "blockquote", "/blockquote", "section", "/section", "article", "/article", "hr",
    };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(tag, b)) return true;
    return false;
}

const EntityHit = struct { text: []const u8, skip: usize };

fn decodeEntity(src: []const u8) ?EntityHit {
    const map = [_]struct { name: []const u8, val: []const u8 }{
        .{ .name = "&amp;", .val = "&" },
        .{ .name = "&lt;", .val = "<" },
        .{ .name = "&gt;", .val = ">" },
        .{ .name = "&quot;", .val = "\"" },
        .{ .name = "&apos;", .val = "'" },
        .{ .name = "&#39;", .val = "'" },
        .{ .name = "&nbsp;", .val = " " },
        .{ .name = "&mdash;", .val = "—" },
        .{ .name = "&ndash;", .val = "–" },
        .{ .name = "&hellip;", .val = "…" },
        .{ .name = "&lsquo;", .val = "‘" },
        .{ .name = "&rsquo;", .val = "’" },
        .{ .name = "&ldquo;", .val = "“" },
        .{ .name = "&rdquo;", .val = "”" },
    };
    for (map) |e| {
        if (src.len >= e.name.len and std.ascii.eqlIgnoreCase(src[0..e.name.len], e.name)) {
            return .{ .text = e.val, .skip = e.name.len };
        }
    }
    if (src.len > 3 and src[1] == '#') {
        var idx: usize = 2;
        var hex = false;
        if (src[idx] == 'x' or src[idx] == 'X') {
            hex = true;
            idx += 1;
        }
        var codepoint: u21 = 0;
        var digits: usize = 0;
        while (idx < src.len and digits < 6) : ({
            idx += 1;
            digits += 1;
        }) {
            const ch = src[idx];
            if (ch == ';') break;
            if (hex) {
                if (std.ascii.isDigit(ch)) {
                    codepoint = codepoint * 16 + (ch - '0');
                } else if (ch >= 'a' and ch <= 'f') {
                    codepoint = codepoint * 16 + (ch - 'a' + 10);
                } else if (ch >= 'A' and ch <= 'F') {
                    codepoint = codepoint * 16 + (ch - 'A' + 10);
                } else return null;
            } else {
                if (!std.ascii.isDigit(ch)) return null;
                codepoint = codepoint * 10 + (ch - '0');
            }
        }
        if (idx >= src.len or src[idx] != ';') return null;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(codepoint, &buf) catch return null;
        return .{ .text = staticUtf8(buf[0..n]), .skip = idx + 1 };
    }
    return null;
}

threadlocal var entity_buf: [4]u8 = undefined;
fn staticUtf8(bytes: []const u8) []const u8 {
    @memcpy(entity_buf[0..bytes.len], bytes);
    return entity_buf[0..bytes.len];
}

test "htmlToText strips tags and decodes basic entities" {
    const alloc = std.testing.allocator;
    const out = try htmlToText(alloc,
        \\<html><body><p>Hello &amp; world</p><p>Goodbye &mdash; cruel world.</p></body></html>
    );
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Hello & world\n\nGoodbye — cruel world.", out);
}

test "htmlToText drops script and style content" {
    const alloc = std.testing.allocator;
    const out = try htmlToText(alloc,
        \\<style>p{color:red}</style><script>alert(1)</script><p>Visible.</p>
    );
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Visible.", out);
}

test "htmlToText collapses whitespace inside paragraphs" {
    const alloc = std.testing.allocator;
    const out = try htmlToText(alloc, "<p>foo\n   bar    baz</p>");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("foo bar baz", out);
}

test "htmlToText handles numeric entities" {
    const alloc = std.testing.allocator;
    const out = try htmlToText(alloc, "<p>caf&#233; au lait</p>");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("café au lait", out);
}
