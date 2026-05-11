//! JSON API endpoints. Hand-written serialisation gives us control over
//! the response shape without dragging structs/derives into the catalog
//! model.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");
const cover_mod = @import("../core/cover.zig");
const format_mod = @import("../formats/format.zig");

pub fn handleBooksList(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
) !void {
    const books = try cat.listBooks(arena);
    var out: std.ArrayList(u8) = .empty;
    try writeBookListJson(arena, &out, books);
    try respondJson(request, out.items);
}

pub fn handleMissing(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
) !void {
    const books = try cat.listIncomplete(arena);
    var out: std.ArrayList(u8) = .empty;
    try writeBookListJson(arena, &out, books);
    try respondJson(request, out.items);
}

pub fn handleDuplicates(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
) !void {
    const groups = try cat.listExactDuplicateGroups(arena);
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (groups, 0..) |group, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"sha256\":\"");
        try out.appendSlice(arena, group.sha256);
        try out.appendSlice(arena, "\",\"books\":[");
        for (group.ids, 0..) |id, j| {
            if (j > 0) try out.append(arena, ',');
            const b = (try cat.getBookById(arena, id)) orelse continue;
            try writeBookJson(arena, &out, b);
        }
        try out.appendSlice(arena, "]}");
    }
    try out.append(arena, ']');
    try respondJson(request, out.items);
}

/// Subresources under /api/books/:id/...
pub fn handleBookSubresource(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    rest: []const u8, // everything after "/api/books/"
) !void {
    // Split id and trailing path.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const id_str = rest[0..slash];
    const tail = if (slash < rest.len) rest[slash + 1 ..] else "";

    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        try request.respond("bad id\n", .{ .status = .bad_request });
        return;
    };
    const book = (try cat.getBookById(arena, id)) orelse {
        try request.respond("not found\n", .{ .status = .not_found });
        return;
    };

    if (tail.len == 0) {
        var out: std.ArrayList(u8) = .empty;
        try writeBookJson(arena, &out, book);
        return respondJson(request, out.items);
    }
    if (std.mem.eql(u8, tail, "file")) {
        return streamFile(arena, request, book);
    }
    if (std.mem.eql(u8, tail, "cover")) {
        return streamCover(arena, io, request, book);
    }

    try request.respond("not found\n", .{ .status = .not_found });
}

// ---- Streaming ----------------------------------------------------------

fn streamFile(
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    book: catalog_mod.Book,
) !void {
    const bytes = try readWhole(arena, book.path);
    const ct = switch (book.format) {
        .epub => "application/epub+zip",
        .mobi => "application/x-mobipocket-ebook",
        .azw3 => "application/vnd.amazon.ebook",
        .pdf => "application/pdf",
        else => "application/octet-stream",
    };
    try request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = ct },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

fn streamCover(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    book: catalog_mod.Book,
) !void {
    const bytes = cover_mod.extract(arena, io, book.path, book.format) catch {
        try request.respond("no cover\n", .{ .status = .not_found });
        return;
    };
    // Sniff JPEG vs PNG by magic.
    const ct: []const u8 = blk: {
        if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) break :blk "image/jpeg";
        if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) break :blk "image/png";
        break :blk "image/jpeg";
    };
    try request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = ct },
            .{ .name = "cache-control", .value = "max-age=3600" },
        },
    });
}

fn readWhole(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (fseek(fp, 0, 2) != 0) return error.SeekFailed;
    const size = ftell(fp);
    if (size < 0) return error.SeekFailed;
    _ = fseek(fp, 0, 0);
    const buf = try arena.alloc(u8, @intCast(size));
    if (std.c.fread(buf.ptr, 1, buf.len, fp) != buf.len) return error.ReadFailed;
    return buf;
}

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

// ---- JSON encoding ------------------------------------------------------

fn writeBookListJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    books: []const catalog_mod.Book,
) !void {
    try out.append(arena, '[');
    for (books, 0..) |b, i| {
        if (i > 0) try out.append(arena, ',');
        try writeBookJson(arena, out, b);
    }
    try out.append(arena, ']');
}

fn writeBookJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    b: catalog_mod.Book,
) !void {
    try out.append(arena, '{');
    try writeNumber(arena, out, "id", b.id, true);
    try writeString(arena, out, "path", b.path, false);
    try writeString(arena, out, "sha256", b.sha256, false);
    try writeString(arena, out, "format", @tagName(b.format), false);
    try writeNumber(arena, out, "size", @intCast(b.size), false);

    const md = b.metadata;
    if (md.title) |v| try writeString(arena, out, "title", v, false);
    if (md.series) |v| try writeString(arena, out, "series", v, false);
    if (md.series_index) |v| try writeFloat(arena, out, "series_index", v, false);
    if (md.publisher) |v| try writeString(arena, out, "publisher", v, false);
    if (md.published_year) |v| try writeNumber(arena, out, "year", @intCast(v), false);
    if (md.isbn) |v| try writeString(arena, out, "isbn", v, false);
    if (md.language) |v| try writeString(arena, out, "language", v, false);
    if (md.description) |v| try writeString(arena, out, "description", v, false);
    if (md.cover_path) |v| try writeString(arena, out, "cover_url_external", v, false);

    if (md.authors.len > 0) {
        try out.appendSlice(arena, ",\"author_sort\":");
        try writeJsonString(arena, out, md.authors[0].sort);
        try out.appendSlice(arena, ",\"authors\":[");
        for (md.authors, 0..) |a, i| {
            if (i > 0) try out.append(arena, ',');
            try writeJsonString(arena, out, a.sort);
        }
        try out.append(arena, ']');
    }

    try out.appendSlice(arena, ",\"confidence\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d:.2}", .{md.confidence}));
    try out.appendSlice(arena, ",\"source\":\"");
    try out.appendSlice(arena, @tagName(md.source));
    try out.append(arena, '"');

    try out.append(arena, '}');
}

fn writeString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    first: bool,
) !void {
    if (!first) try out.append(arena, ',');
    try out.append(arena, '"');
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, "\":");
    try writeJsonString(arena, out, value);
}

fn writeNumber(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: i64,
    first: bool,
) !void {
    if (!first) try out.append(arena, ',');
    try out.append(arena, '"');
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, "\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{value}));
}

fn writeFloat(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: f32,
    first: bool,
) !void {
    if (!first) try out.append(arena, ',');
    try out.append(arena, '"');
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, "\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{value}));
}

fn writeJsonString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) !void {
    try out.append(arena, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
            const hex = try std.fmt.allocPrint(arena, "\\u{x:0>4}", .{ch});
            try out.appendSlice(arena, hex);
        },
        else => try out.append(arena, ch),
    };
    try out.append(arena, '"');
}

fn respondJson(
    request: *std.http.Server.Request,
    body: []const u8,
) !void {
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}
