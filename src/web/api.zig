//! JSON API endpoints. Hand-written serialisation gives us control over
//! the response shape without dragging structs/derives into the catalog
//! model.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");
const cover_mod = @import("../core/cover.zig");
const format_mod = @import("../formats/format.zig");
const setmeta = @import("../commands/setmeta.zig");
const setcover = @import("../commands/setcover.zig");
const convert_mod = @import("../convert/convert.zig");
const openlibrary = @import("../providers/openlibrary.zig");
const provider_iface = @import("../providers/provider.zig");

// ---- Read endpoints -----------------------------------------------------

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

/// Dispatch /api/books/:id and /api/books/:id/<action>. The `rest` slice
/// is everything after "/api/books/".
pub fn handleBookSubresource(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    rest: []const u8,
) !void {
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const id_str = rest[0..slash];
    const tail = if (slash < rest.len) rest[slash + 1 ..] else "";

    if (std.mem.eql(u8, id_str, "bulk")) {
        return handleBulk(arena, io, cat, request, tail);
    }

    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        try request.respond("bad id\n", .{ .status = .bad_request });
        return;
    };

    if (tail.len == 0) {
        switch (request.head.method) {
            .GET => {
                const book = (try cat.getBookById(arena, id)) orelse return notFound(request);
                var out: std.ArrayList(u8) = .empty;
                try writeBookJson(arena, &out, book);
                return respondJson(request, out.items);
            },
            .PATCH => return handlePatch(arena, cat, request, id),
            .DELETE => return handleDelete(arena, cat, request, id),
            else => return methodNotAllowed(request),
        }
    }

    if (std.mem.eql(u8, tail, "file")) {
        const book = (try cat.getBookById(arena, id)) orelse return notFound(request);
        return streamFile(arena, request, book);
    }
    if (std.mem.eql(u8, tail, "cover")) {
        if (request.head.method == .POST) {
            return handleCoverUpload(arena, cat, request, id);
        }
        const book = (try cat.getBookById(arena, id)) orelse return notFound(request);
        return streamCover(arena, io, request, book);
    }
    if (std.mem.eql(u8, tail, "enrich")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        return handleEnrich(arena, io, cat, request, id);
    }
    if (std.mem.eql(u8, tail, "convert")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        return handleConvert(arena, io, cat, request, id);
    }

    return notFound(request);
}

// ---- Write endpoints ----------------------------------------------------

/// PATCH /api/books/:id
/// Body: { "title"?, "author"?, "series"?, "series_index"?, "year"? }
/// All fields optional. The corresponding embedded metadata is rewritten
/// in place (EPUB OPF or MOBI mobimeta) AND the catalog row is updated.
fn handlePatch(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const body = try readBody(arena, request, 64 * 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        try request.respond("bad json\n", .{ .status = .bad_request });
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try request.respond("body must be a json object\n", .{ .status = .bad_request });
        return;
    }
    const obj = parsed.value.object;

    const book = (try cat.getBookById(arena, id)) orelse return notFound(request);

    var update: setmeta.Update = .{};
    if (obj.get("title")) |v| if (v == .string) { update.title = try arena.dupe(u8, v.string); };
    if (obj.get("author")) |v| if (v == .string) { update.author = try arena.dupe(u8, v.string); };
    if (obj.get("series")) |v| if (v == .string) { update.series = try arena.dupe(u8, v.string); };
    if (obj.get("series_index")) |v| if (v == .string) {
        update.series_index = try arena.dupe(u8, v.string);
    } else if (v == .integer) {
        update.series_index = try std.fmt.allocPrint(arena, "{d}", .{v.integer});
    };
    if (obj.get("year")) |v| if (v == .string) {
        update.year = try arena.dupe(u8, v.string);
    } else if (v == .integer) {
        update.year = try std.fmt.allocPrint(arena, "{d}", .{v.integer});
    };

    // Persist to the file (EPUB only — MOBI write would need mobimeta).
    if (book.format == .epub) {
        setmeta.applyToEpub(arena, book.path, update) catch |err| {
            return errorJson(arena, request, "set-meta failed", @errorName(err));
        };
    } else {
        // For non-EPUB we still update the catalog row (so the UI
        // reflects the user's edit), but warn that the file is
        // untouched.
    }

    // Rebuild a BookInput with the merged values and re-upsert.
    var md = book.metadata;
    if (update.title) |t| md.title = t;
    if (update.author) |a| {
        const author = try meta.Author.fromDisplay(arena, a);
        md.authors = try arena.dupe(meta.Author, &[_]meta.Author{author});
    }
    if (update.series) |s| md.series = s;
    if (update.series_index) |idx| md.series_index = std.fmt.parseFloat(f32, idx) catch null;
    if (update.year) |y| md.published_year = std.fmt.parseInt(u16, y, 10) catch null;
    md.source = .manual;
    md.confidence = 1.0;

    _ = try cat.upsertBook(arena, .{
        .path = book.path,
        .sha256 = book.sha256,
        .size = book.size,
        .format = book.format,
        .mtime = book.mtime,
        .metadata = md,
    });

    // Return the updated row.
    const fresh = (try cat.getBookById(arena, id)) orelse return notFound(request);
    var out: std.ArrayList(u8) = .empty;
    try writeBookJson(arena, &out, fresh);
    try respondJson(request, out.items);
}

/// DELETE /api/books/:id?file=1
/// Removes the catalog row. If ?file=1, also unlinks the file from disk.
fn handleDelete(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    // Snapshot request.head fields BEFORE claimEmptyBody, since
    // initializing a body reader invalidates the head's slices (they
    // alias the receive buffer that the body reader takes over).
    const remove_file = std.mem.indexOf(u8, request.head.target, "file=1") != null;
    claimEmptyBody(request);
    const book = (try cat.getBookById(arena, id)) orelse return notFound(request);

    if (remove_file) {
        var path_z: [4096]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&path_z, "{s}", .{book.path});
        _ = std.c.unlink(z.ptr);
    }
    try cat.deleteBook(book.id);
    try respondJson(request, "{\"ok\":true}");
}

/// POST /api/books/:id/enrich
/// Queries Open Library for this book (by ISBN if available, otherwise
/// title + author) and merges any new fields into the catalog row.
fn handleEnrich(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    claimEmptyBody(request);
    const book = (try cat.getBookById(arena, id)) orelse return notFound(request);

    var ol = openlibrary.OpenLibrary{};
    const provider = ol.provider();
    const q = provider_iface.Query{
        .isbn = book.metadata.isbn,
        .title = book.metadata.title,
        .author = if (book.metadata.authors.len > 0) book.metadata.authors[0].sort else null,
    };
    const remote = (try provider.lookup(arena, io, q)) orelse {
        try respondJson(request, "{\"enriched\":false,\"reason\":\"no match\"}");
        return;
    };

    const merged = try meta.BookMetadata.merge(arena, book.metadata, remote);
    _ = try cat.upsertBook(arena, .{
        .path = book.path,
        .sha256 = book.sha256,
        .size = book.size,
        .format = book.format,
        .mtime = book.mtime,
        .metadata = merged,
    });

    const fresh = (try cat.getBookById(arena, id)) orelse return notFound(request);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"enriched\":true,\"book\":");
    try writeBookJson(arena, &out, fresh);
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// POST /api/books/:id/convert
/// Body: { "to": "epub" | "mobi" | "azw3" | "pdf" }
fn handleConvert(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const body = try readBody(arena, request, 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "body must be object", "");
    const to_val = parsed.value.object.get("to") orelse return errorJson(arena, request, "missing 'to'", "");
    if (to_val != .string) return errorJson(arena, request, "'to' must be a string", "");
    const dst = meta.Format.fromExtension(to_val.string);
    if (dst == .unknown) return errorJson(arena, request, "unknown target format", to_val.string);

    const book = (try cat.getBookById(arena, id)) orelse return notFound(request);
    const out_dir = std.fs.path.dirname(book.path) orelse ".";
    const new_path = convert_mod.convert(arena, io, book.path, book.format, dst, out_dir) catch |err|
        return errorJson(arena, request, "convert failed", @errorName(err));

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"ok\":true,\"path\":");
    try writeJsonString(arena, &out, new_path);
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// POST /api/books/:id/cover
/// Body: { "data_base64": "...", "content_type"?: "image/jpeg" }
/// EPUB only — replaces the bytes of the existing cover-image manifest
/// entry and repacks the archive.
fn handleCoverUpload(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const book = (try cat.getBookById(arena, id)) orelse return notFound(request);
    if (book.format != .epub) return errorJson(arena, request, "cover upload supports EPUB only", "");

    // 16 MB cap on the body — covers larger than this almost always
    // mean someone uploaded a wrong file.
    const body = try readBody(arena, request, 16 * 1024 * 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "body must be object", "");

    const b64_val = parsed.value.object.get("data_base64") orelse
        return errorJson(arena, request, "missing data_base64", "");
    if (b64_val != .string) return errorJson(arena, request, "data_base64 must be a string", "");

    const dec = std.base64.standard.Decoder;
    const decoded_len = dec.calcSizeForSlice(b64_val.string) catch
        return errorJson(arena, request, "bad base64 length", "");
    const decoded = try arena.alloc(u8, decoded_len);
    dec.decode(decoded, b64_val.string) catch
        return errorJson(arena, request, "base64 decode failed", "");

    setcover.applyToEpub(arena, book.path, decoded) catch |err|
        return errorJson(arena, request, "set-cover failed", @errorName(err));

    try respondJson(request, "{\"ok\":true}");
}

// ---- Bulk endpoints -----------------------------------------------------

/// /api/books/bulk/<action>
fn handleBulk(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    action: []const u8,
) !void {
    if (request.head.method != .POST) return methodNotAllowed(request);
    const body = try readBody(arena, request, 64 * 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "body must be object", "");

    const ids_v = parsed.value.object.get("ids") orelse return errorJson(arena, request, "missing 'ids'", "");
    if (ids_v != .array) return errorJson(arena, request, "'ids' must be an array", "");

    if (std.mem.eql(u8, action, "enrich")) {
        return bulkEnrich(arena, io, cat, request, ids_v.array.items);
    }
    if (std.mem.eql(u8, action, "delete")) {
        const remove_files = if (parsed.value.object.get("remove_files")) |v| (v == .bool and v.bool) else false;
        return bulkDelete(arena, cat, request, ids_v.array.items, remove_files);
    }
    return errorJson(arena, request, "unknown bulk action", action);
}

fn bulkEnrich(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    ids: []const std.json.Value,
) !void {
    var ol = openlibrary.OpenLibrary{};
    const provider = ol.provider();
    var ok: u32 = 0;
    var miss: u32 = 0;
    var err: u32 = 0;
    for (ids) |id_v| {
        if (id_v != .integer) continue;
        const id = id_v.integer;
        const book = (try cat.getBookById(arena, id)) orelse {
            err += 1;
            continue;
        };
        const q = provider_iface.Query{
            .isbn = book.metadata.isbn,
            .title = book.metadata.title,
            .author = if (book.metadata.authors.len > 0) book.metadata.authors[0].sort else null,
        };
        const remote_opt = provider.lookup(arena, io, q) catch |e| {
            std.log.warn("bulk enrich {d}: {s}", .{ id, @errorName(e) });
            err += 1;
            continue;
        };
        const remote = remote_opt orelse {
            miss += 1;
            continue;
        };
        const merged = try meta.BookMetadata.merge(arena, book.metadata, remote);
        _ = cat.upsertBook(arena, .{
            .path = book.path,
            .sha256 = book.sha256,
            .size = book.size,
            .format = book.format,
            .mtime = book.mtime,
            .metadata = merged,
        }) catch {
            err += 1;
            continue;
        };
        ok += 1;
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "{{\"enriched\":{d},\"no_match\":{d},\"errors\":{d}}}",
        .{ ok, miss, err },
    ));
    try respondJson(request, out.items);
}

fn bulkDelete(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    request: *std.http.Server.Request,
    ids: []const std.json.Value,
    remove_files: bool,
) !void {
    var deleted: u32 = 0;
    for (ids) |id_v| {
        if (id_v != .integer) continue;
        const id = id_v.integer;
        if (remove_files) {
            if (try cat.getBookById(arena, id)) |b| {
                var path_z: [4096]u8 = undefined;
                const z = std.fmt.bufPrintZ(&path_z, "{s}", .{b.path}) catch continue;
                _ = std.c.unlink(z.ptr);
            }
        }
        cat.deleteBook(id) catch continue;
        deleted += 1;
    }
    const body = try std.fmt.allocPrint(arena, "{{\"deleted\":{d}}}", .{deleted});
    try respondJson(request, body);
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
    const ct: []const u8 = blk: {
        if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) break :blk "image/jpeg";
        if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) break :blk "image/png";
        break :blk "image/jpeg";
    };
    try request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = ct },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

// ---- Helpers ------------------------------------------------------------

fn readBody(
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    max: usize,
) ![]u8 {
    if (request.head.content_length) |len| {
        if (len > max) return error.BodyTooLarge;
        // Large body buffer because cover uploads can be a few MB. The
        // buffer holds the streaming window; readAlloc pulls into the
        // arena.
        var body_buf: [64 * 1024]u8 = undefined;
        const reader = try claimReader(request, &body_buf);
        return try reader.readAlloc(arena, @intCast(len));
    }
    var body_buf: [16]u8 = undefined;
    _ = try claimReader(request, &body_buf);
    return arena.alloc(u8, 0);
}

/// Some POST endpoints (enrich, bulk actions without payload) don't
/// expect a body. We still need to mark the body as "consumed" on the
/// server reader before responding — otherwise std.http.Server's
/// discardBody fires an assertion on POST/PATCH without a length.
fn claimEmptyBody(request: *std.http.Server.Request) void {
    var body_buf: [16]u8 = undefined;
    _ = claimReader(request, &body_buf) catch return;
}

/// Picks the right reader-init based on whether the client sent an
/// `Expect: 100-continue` header. `readerExpectNone` asserts there's
/// no expect header; `readerExpectContinue` sends the 100 response
/// and then reads.
fn claimReader(
    request: *std.http.Server.Request,
    buffer: []u8,
) !*std.Io.Reader {
    if (request.head.expect != null) {
        return try request.readerExpectContinue(buffer);
    }
    return request.readerExpectNone(buffer);
}

fn notFound(request: *std.http.Server.Request) !void {
    try request.respond("not found\n", .{ .status = .not_found });
}

fn methodNotAllowed(request: *std.http.Server.Request) !void {
    try request.respond("method not allowed\n", .{ .status = .method_not_allowed });
}

fn errorJson(
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    message: []const u8,
    detail: []const u8,
) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"error\":");
    try writeJsonString(arena, &out, message);
    if (detail.len > 0) {
        try out.appendSlice(arena, ",\"detail\":");
        try writeJsonString(arena, &out, detail);
    }
    try out.append(arena, '}');
    try request.respond(out.items, .{
        .status = .bad_request,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
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
