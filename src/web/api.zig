//! JSON API endpoints. Hand-written serialisation gives us control over
//! the response shape without dragging structs/derives into the catalog
//! model.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");
const cover_mod = @import("../core/cover.zig");
const cover_store = @import("../core/cover_store.zig");
const handler_mod = @import("../formats/handler.zig");
const format_registry = @import("../formats/registry.zig");
const convert_mod = @import("../convert/convert.zig");
const openlibrary = @import("../providers/openlibrary.zig");
const provider_iface = @import("../providers/provider.zig");
const http = @import("../util/http.zig");
const path_meta = @import("../core/path_meta.zig");
const sources_mod = @import("../commands/sources.zig");
const enrich_job_mod = @import("enrich_job.zig");
const standardize_mod = @import("../core/standardize.zig");
const template_mod = @import("../core/template.zig");
const clock = @import("../util/clock.zig");
const comic_archive = @import("../formats/comic_archive.zig");
const exec = @import("../util/exec.zig");
const jobs_mod = @import("../core/jobs.zig");
const job_runner = @import("../core/job_runner.zig");

const enrich_log = std.log.scoped(.enrich);

/// Per-request context shared between web handlers. Defined here (not
/// in server.zig) so api.zig stays the single owner of its dependencies
/// and server.zig can simply reference `api.WebContext` without a
/// circular import.
pub const WebContext = struct {
    cat: *catalog_mod.Catalog,
    env: *std.process.Environ.Map,
    /// Absolute path to the catalog SQLite file. Needed by background
    /// scan threads so they can open their own connection without
    /// fighting the main HTTP handler over the same `*sqlite3*`.
    catalog_path: []const u8 = "",
    /// Long-lived allocator (the process-level arena/page allocator)
    /// usable by background workers. The per-request arena dies when
    /// the HTTP handler returns; threads outlive that.
    worker_allocator: ?std.mem.Allocator = null,
    /// Singleton batch-enrichment job. One at a time. Lives for the
    /// process; `state == .idle` until the user POSTs /api/enrich/batch.
    enrich_job: ?*enrich_job_mod.Job = null,
};

pub fn handleBooksList(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const q = try parseSearchQuery(arena, request.head.target);
    const books = try ctx.cat.searchBooks(arena, q);
    var out: std.ArrayList(u8) = .empty;
    try writeBookListJson(arena, &out, ctx, books);
    try respondJson(request, out.items);
}

/// GET /api/authors  (also /api/series, /api/genres, /api/formats)
/// Returns: [{ name: "...", count: N }, ...]
pub fn handleFacets(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    facet: enum { authors, series, genres, formats },
) !void {
    const items = switch (facet) {
        .authors => try ctx.cat.distinctAuthors(arena),
        .series => try ctx.cat.distinctSeries(arena),
        .genres => try ctx.cat.distinctGenres(arena),
        .formats => try ctx.cat.distinctFormats(arena),
    };
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (items, 0..) |f, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"name\":");
        try writeJsonString(arena, &out, f.name);
        try out.appendSlice(arena, ",\"count\":");
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{f.count}));
        try out.append(arena, '}');
    }
    try out.append(arena, ']');
    try respondJson(request, out.items);
}

/// Parse `?q=foo&author=Hobb&series=Farseer&year_from=2010&year_to=2020&format=epub&status=reading&order=year_desc&limit=50&has_isbn=1&missing=1`
fn parseSearchQuery(
    arena: std.mem.Allocator,
    target: []const u8,
) !catalog_mod.Catalog.SearchQuery {
    var q: catalog_mod.Catalog.SearchQuery = .{};
    const qstart = std.mem.indexOfScalar(u8, target, '?') orelse return q;
    const qs = target[qstart + 1 ..];

    var it = std.mem.splitScalar(u8, qs, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const raw_val = pair[eq + 1 ..];
        const val = try urlDecode(arena, raw_val);

        if (std.mem.eql(u8, key, "q")) q.text = val else if (std.mem.eql(u8, key, "author")) q.author = val else if (std.mem.eql(u8, key, "series")) q.series = val else if (std.mem.eql(u8, key, "genre")) q.genre = val else if (std.mem.eql(u8, key, "format")) {
            if (std.mem.indexOfScalar(u8, val, ',') != null) {
                var list: std.ArrayList(meta.Format) = .empty;
                var ft = std.mem.splitScalar(u8, val, ',');
                while (ft.next()) |part| {
                    const trimmed = std.mem.trim(u8, part, " ");
                    if (trimmed.len == 0) continue;
                    const f = meta.Format.fromExtension(trimmed);
                    if (f != .unknown) try list.append(arena, f);
                }
                if (list.items.len > 0) q.formats_in = try list.toOwnedSlice(arena);
            } else {
                const f = meta.Format.fromExtension(val);
                if (f != .unknown) q.format = f;
            }
        } else if (std.mem.eql(u8, key, "tag")) q.tag = val else if (std.mem.eql(u8, key, "year_from")) q.year_from = std.fmt.parseInt(u16, val, 10) catch null else if (std.mem.eql(u8, key, "year_to")) q.year_to = std.fmt.parseInt(u16, val, 10) catch null else if (std.mem.eql(u8, key, "status")) q.status = catalog_mod.ReadStatus.fromStr(val) else if (std.mem.eql(u8, key, "source")) q.source = std.meta.stringToEnum(meta.Source, val) else if (std.mem.eql(u8, key, "has_isbn")) q.has_isbn = boolFromStr(val) else if (std.mem.eql(u8, key, "has_cover")) q.has_cover = boolFromStr(val) else if (std.mem.eql(u8, key, "has_series")) q.has_series = boolFromStr(val) else if (std.mem.eql(u8, key, "missing")) q.missing_any = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") else if (std.mem.eql(u8, key, "order")) {
            q.order = std.meta.stringToEnum(catalog_mod.Catalog.Order, val) orelse .author;
        } else if (std.mem.eql(u8, key, "limit")) q.limit = std.fmt.parseInt(usize, val, 10) catch null;
    }
    return q;
}

fn boolFromStr(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "false")) return false;
    return null;
}

/// Percent-decode + replace '+' with space. Minimal — query values are
/// short and never contain Unicode that needs validation here.
fn urlDecode(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (ch == '+') {
            try out.append(arena, ' ');
        } else if (ch == '%' and i + 2 < src.len) {
            const h1 = std.fmt.charToDigit(src[i + 1], 16) catch {
                try out.append(arena, ch);
                continue;
            };
            const h2 = std.fmt.charToDigit(src[i + 2], 16) catch {
                try out.append(arena, ch);
                continue;
            };
            try out.append(arena, @intCast(h1 * 16 + h2));
            i += 2;
        } else {
            try out.append(arena, ch);
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn handleMissing(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const books = try ctx.cat.listIncomplete(arena);
    var out: std.ArrayList(u8) = .empty;
    try writeBookListJson(arena, &out, ctx, books);
    try respondJson(request, out.items);
}

pub fn handleUnverified(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const books = try ctx.cat.listUnverified(arena);
    var out: std.ArrayList(u8) = .empty;
    try writeBookListJson(arena, &out, ctx, books);
    try respondJson(request, out.items);
}

pub fn handleMissingFiles(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const books = try ctx.cat.listMissingFiles(arena);
    var out: std.ArrayList(u8) = .empty;
    try writeBookListJson(arena, &out, ctx, books);
    try respondJson(request, out.items);
}

/// GET /api/sevenzip-status — reports whether `7zz` / `7z` is reachable
/// on PATH. The frontend uses it to surface a one-time install hint when
/// the catalog contains CBR/CB7/CBT rows but no archive tool is present.
pub fn handleSevenzipStatus(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
) !void {
    claimEmptyBody(request);
    const binary: ?[]const u8 = blk: {
        if (exec.isExecutableInPath(arena, io, "7zz")) break :blk "7zz";
        if (exec.isExecutableInPath(arena, io, "7z")) break :blk "7z";
        break :blk null;
    };
    var out: std.ArrayList(u8) = .empty;
    if (binary) |name| {
        try out.appendSlice(arena, "{\"available\":true,\"binary\":");
        try writeJsonString(arena, &out, name);
        try out.append(arena, '}');
    } else {
        try out.appendSlice(arena, "{\"available\":false,\"binary\":null}");
    }
    try respondJson(request, out.items);
}

/// Format check used by the comic-reader endpoints.
/// GET /api/library-stats — rolled-up data for the Stats tab in one
/// JSON envelope so the frontend renders in a single fetch. Calls
/// six catalog helpers (statusCounts, finishedByMonth, …); each is
/// indexed in the books table and runs in single-digit ms even on a
/// catalog with tens of thousands of rows.
pub fn handleLibraryStats(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    claimEmptyBody(request);
    const status = try ctx.cat.statusCounts();
    const months = try ctx.cat.finishedByMonth(arena, 12);
    const currently = try ctx.cat.listCurrentlyReading(arena, 10);
    const recently = try ctx.cat.listRecentlyFinished(arena, 10);
    const formats = try ctx.cat.formatCounts(arena);
    const authors = try ctx.cat.topAuthors(arena, 10);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"status\":{");
    try appendFmt(arena, &out, "\"unread\":{d},\"reading\":{d},\"finished\":{d}", .{
        status.unread, status.reading, status.finished,
    });
    try out.appendSlice(arena, "},\"finished_by_month\":[");
    for (months, 0..) |m, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"ym\":");
        try writeJsonString(arena, &out, m.ym);
        try appendFmt(arena, &out, ",\"count\":{d}}}", .{m.count});
    }
    try out.appendSlice(arena, "],\"currently_reading\":");
    try writeBookListJson(arena, &out, ctx, currently);
    try out.appendSlice(arena, ",\"recently_finished\":");
    try writeBookListJson(arena, &out, ctx, recently);
    try out.appendSlice(arena, ",\"formats\":[");
    for (formats, 0..) |f, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"format\":");
        try writeJsonString(arena, &out, f.format);
        try appendFmt(arena, &out, ",\"count\":{d}}}", .{f.count});
    }
    try out.appendSlice(arena, "],\"top_authors\":[");
    for (authors, 0..) |a, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"name\":");
        try writeJsonString(arena, &out, a.name);
        try appendFmt(arena, &out, ",\"count\":{d}}}", .{a.count});
    }
    try out.appendSlice(arena, "]}");
    try respondJson(request, out.items);
}

fn isComicFormat(fmt: meta.Format) bool {
    return switch (fmt) {
        .cbz, .cbr, .cb7, .cbt => true,
        else => false,
    };
}

/// Open the right ArchiveReader for a comic-format book. CBZ uses
/// the in-process miniz adapter; CBR/CB7/CBT shell out to `7zz`.
/// Callers must `deinit`/`close` whichever adapter they hold —
/// returning a tagged union keeps the lifecycle explicit.
const ComicArchive = union(enum) {
    miniz: *comic_archive.MinizAdapter,
    sevenzip: *comic_archive.Sevenzip,

    fn reader(self: ComicArchive) comic_archive.ArchiveReader {
        return switch (self) {
            .miniz => |a| a.archiveReader(),
            .sevenzip => |a| a.reader(),
        };
    }
    fn close(self: ComicArchive) void {
        switch (self) {
            .miniz => |a| a.close(),
            .sevenzip => {},
        }
    }
};

fn openComicArchive(
    arena: std.mem.Allocator,
    io: std.Io,
    book: catalog_mod.Book,
) !ComicArchive {
    switch (book.format) {
        .cbz => {
            const a = try arena.create(comic_archive.MinizAdapter);
            try a.open(book.path);
            return .{ .miniz = a };
        },
        .cbr, .cb7, .cbt => {
            if (!comic_archive.Sevenzip.isAvailable(arena, io)) return error.ExecutableMissing;
            const a = try arena.create(comic_archive.Sevenzip);
            a.* = .{
                .allocator = arena,
                .io = io,
                .archive_path = book.path,
            };
            return .{ .sevenzip = a };
        },
        else => return error.NotComic,
    }
}

const ComicPageCache = struct {
    book_id: i64 = 0,
    mtime: i64 = 0,
    size: u64 = 0,
    pages: ?[]const []const u8 = null,
    /// Owns the page slices' memory. Re-initialised on each store.
    arena: ?std.heap.ArenaAllocator = null,
};
var comic_page_cache: ComicPageCache = .{};
/// Zig 0.16's stdlib doesn't ship `std.Thread.Mutex`. We need real
/// mutual exclusion (not just an atomic) because the cache update
/// frees the old arena and swaps the pages slice — a concurrent
/// reader would see torn state. `std.Io.Mutex.tryLock` is sync and
/// good enough: on contention we just skip the cache for this
/// request (one extra `7zz l` call, no correctness impact).
var comic_page_cache_mu: std.Io.Mutex = std.Io.Mutex.init;

/// Returns the cached page list for this book if valid AND we can
/// grab the lock without waiting. Copies into the caller's
/// allocator while still holding the lock, so the caller's slice
/// stays valid even if a concurrent writer evicts the cache.
fn comicPagesGet(arena: std.mem.Allocator, io: std.Io, book: catalog_mod.Book) !?[]const []const u8 {
    if (!comic_page_cache_mu.tryLock()) return null;
    defer comic_page_cache_mu.unlock(io);
    const hit = comic_page_cache.pages orelse return null;
    if (comic_page_cache.book_id != book.id) return null;
    if (comic_page_cache.mtime != book.mtime) return null;
    if (comic_page_cache.size != book.size) return null;
    var copy = try arena.alloc([]const u8, hit.len);
    for (hit, 0..) |p, i| copy[i] = try arena.dupe(u8, p);
    return copy;
}

/// Best-effort cache write: tryLock and skip on contention. Stores
/// a deep copy of `pages` keyed by (book.id, mtime, size).
fn comicPagesPut(parent_allocator: std.mem.Allocator, io: std.Io, book: catalog_mod.Book, pages: []const []const u8) !void {
    if (!comic_page_cache_mu.tryLock()) return;
    defer comic_page_cache_mu.unlock(io);
    if (comic_page_cache.arena) |*old| old.deinit();
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    const a = arena.allocator();
    var copy = try a.alloc([]const u8, pages.len);
    for (pages, 0..) |p, i| copy[i] = try a.dupe(u8, p);
    comic_page_cache = .{
        .book_id = book.id,
        .mtime = book.mtime,
        .size = book.size,
        .pages = copy,
        .arena = arena,
    };
}

/// List the archive's image pages, hitting the cache when fresh.
fn listImagePagesCached(
    arena: std.mem.Allocator,
    io: std.Io,
    book: catalog_mod.Book,
) ![]const []const u8 {
    if (try comicPagesGet(arena, io, book)) |hit| return hit;
    var arch = try openComicArchive(arena, io, book);
    defer arch.close();
    const pages = try comic_archive.listImagePages(arch.reader(), arena);
    comicPagesPut(std.heap.page_allocator, io, book, pages) catch {};
    return pages;
}

/// GET /api/books/:id/comic-pages — list every image page in the
/// archive (CBZ/CBR/CB7/CBT). Response: `{count: N, format: "cbz"}`.
/// The frontend uses `count` to drive the page-N URLs.
fn handleComicPages(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
    if (!isComicFormat(book.format)) {
        return errorJson(arena, request, "not_comic", "endpoint only valid for cbz/cbr/cb7/cbt");
    }
    const pages = listImagePagesCached(arena, io, book) catch |err| switch (err) {
        error.ExecutableMissing => return errorJson(arena, request, "sevenzip_missing", "7zz not on PATH"),
        else => return errorJson(arena, request, "list_pages_failed", @errorName(err)),
    };

    var out: std.ArrayList(u8) = .empty;
    const body = try std.fmt.allocPrint(arena, "{{\"count\":{d},\"format\":\"{s}\"}}", .{
        pages.len, @tagName(book.format),
    });
    try out.appendSlice(arena, body);
    try respondJson(request, out.items);
}

/// GET /api/books/:id/comic-page/:n — stream the nth image (0-indexed)
/// out of the comic archive. Content-type is sniffed from the image
/// magic so the browser renders it directly.
fn handleComicPage(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
    n: usize,
) !void {
    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
    if (!isComicFormat(book.format)) {
        return errorJson(arena, request, "not_comic", "endpoint only valid for cbz/cbr/cb7/cbt");
    }
    const pages = listImagePagesCached(arena, io, book) catch |err| switch (err) {
        error.ExecutableMissing => return errorJson(arena, request, "sevenzip_missing", "7zz not on PATH"),
        else => return errorJson(arena, request, "list_pages_failed", @errorName(err)),
    };
    if (n >= pages.len) {
        try request.respond("page out of range\n", .{ .status = .not_found });
        return;
    }
    var arch = openComicArchive(arena, io, book) catch |err| switch (err) {
        error.ExecutableMissing => return errorJson(arena, request, "sevenzip_missing", "7zz not on PATH"),
        else => return errorJson(arena, request, "archive_open_failed", @errorName(err)),
    };
    defer arch.close();
    const bytes = arch.reader().read(arena, pages[n]) catch |err|
        return errorJson(arena, request, "read_page_failed", @errorName(err));
    const ct = sniffImageType(bytes);
    try request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = ct },
            .{ .name = "cache-control", .value = "public, max-age=31536000, immutable" },
        },
    });
}

fn sniffImageType(bytes: []const u8) []const u8 {
    if (bytes.len >= 4 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return "application/octet-stream";
}

/// GET /api/export?format=json|csv — download the entire catalog.
/// JSON returns the same shape used by `/api/books`; CSV is a flat
/// row-per-book layout convenient for spreadsheets. Both stream
/// straight off `listBooks` — no caching, always fresh.
pub fn handleExport(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const target = try arena.dupe(u8, request.head.target);
    claimEmptyBody(request);
    const is_csv = std.mem.indexOf(u8, target, "format=csv") != null;

    const books = try ctx.cat.listBooks(arena);
    var out: std.ArrayList(u8) = .empty;

    const datestamp = try formatDateUtc(arena);
    if (is_csv) {
        try writeCsvExport(arena, &out, books);
        const filename = try std.fmt.allocPrint(arena, "mediastacks-library-{s}.csv", .{datestamp});
        const disposition = try std.fmt.allocPrint(arena, "attachment; filename=\"{s}\"", .{filename});
        try request.respond(out.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/csv; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "content-disposition", .value = disposition },
            },
        });
    } else {
        try writeBookListJson(arena, &out, ctx, books);
        const filename = try std.fmt.allocPrint(arena, "mediastacks-library-{s}.json", .{datestamp});
        const disposition = try std.fmt.allocPrint(arena, "attachment; filename=\"{s}\"", .{filename});
        try request.respond(out.items, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
                .{ .name = "content-disposition", .value = disposition },
            },
        });
    }
}

/// POST /api/import — accept a JSON array of `{path, title?, author?,
/// series?, series_index?, year?, isbn?, publisher?, language?,
/// description?}` rows. Each row matches a catalogued book by exact
/// `path`; non-empty fields are merged into the existing metadata
/// (existing values are NOT overwritten with empty strings). Rows
/// whose path isn't in the catalog are skipped — use **Add books
/// from a folder** to ingest new files first.
///
/// Response: `{matched: int, updated: int, skipped: int, errors: [{...}]}`
pub fn handleImport(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const body = try readBody(arena, request, 32 * 1024 * 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        return errorJson(arena, request, "bad_json", "body must be a JSON array of book records");
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        return errorJson(arena, request, "bad_shape", "expected a JSON array at the top level");
    }
    const result = try applyImport(arena, ctx.cat, parsed.value.array.items);
    const body_str = try std.fmt.allocPrint(
        arena,
        "{{\"matched\":{d},\"updated\":{d},\"skipped\":{d},\"errors\":{s},\"error_count\":{d}}}",
        .{ result.matched, result.updated, result.skipped, result.errors_json, result.error_count },
    );
    try respondJson(request, body_str);
}

pub const ImportResult = struct {
    matched: usize,
    updated: usize,
    skipped: usize,
    error_count: usize,
    /// JSON array literal of per-row failures: `[{"path":"...","error":"..."}]`.
    errors_json: []const u8,
};

/// Pure flow extracted from `handleImport` so tests can exercise it
/// without spinning up an HTTP server. Walks the parsed JSON rows;
/// for each row with a `path` that matches a catalogued book, merges
/// non-empty fields and re-upserts. Returns counts + a JSON-encoded
/// errors list (which the handler embeds verbatim).
pub fn applyImport(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    rows: []const std.json.Value,
) !ImportResult {
    var matched: usize = 0;
    var updated: usize = 0;
    var skipped: usize = 0;
    var error_count: usize = 0;
    var errors: std.ArrayList(u8) = .empty;
    try errors.append(arena, '[');
    var first_err = true;

    for (rows) |row| {
        if (row != .object) {
            skipped += 1;
            continue;
        }
        const obj = row.object;
        const path_val = obj.get("path") orelse {
            skipped += 1;
            continue;
        };
        if (path_val != .string) {
            skipped += 1;
            continue;
        }
        const path = path_val.string;
        const book = (try cat.getBookByPath(arena, path)) orelse {
            skipped += 1;
            continue;
        };
        matched += 1;

        var md = book.metadata;
        var changed = false;

        if (jsonNonEmptyString(obj, "title")) |s| {
            md.title = s;
            changed = true;
        }
        if (jsonNonEmptyString(obj, "author")) |s| {
            const author = try meta.Author.fromDisplay(arena, s);
            md.authors = try arena.dupe(meta.Author, &[_]meta.Author{author});
            changed = true;
        }
        if (jsonNonEmptyString(obj, "series")) |s| {
            md.series = s;
            changed = true;
        }
        if (jsonNumberOrString(arena, obj, "series_index")) |s| {
            md.series_index = std.fmt.parseFloat(f32, s) catch md.series_index;
            changed = true;
        }
        if (jsonNumberOrString(arena, obj, "year")) |s| {
            md.published_year = std.fmt.parseInt(u16, s, 10) catch md.published_year;
            changed = true;
        }
        if (jsonNonEmptyString(obj, "isbn")) |s| {
            md.isbn = s;
            changed = true;
        }
        if (jsonNonEmptyString(obj, "publisher")) |s| {
            md.publisher = s;
            changed = true;
        }
        if (jsonNonEmptyString(obj, "language")) |s| {
            md.language = s;
            changed = true;
        }
        if (jsonNonEmptyString(obj, "description")) |s| {
            md.description = s;
            changed = true;
        }

        if (!changed) continue;
        md.source = .manual;
        md.confidence = @max(md.confidence, 0.99);
        _ = cat.upsertBook(arena, .{
            .path = book.path,
            .sha256 = book.sha256,
            .size = book.size,
            .format = book.format,
            .mtime = book.mtime,
            .metadata = md,
        }) catch |err| {
            error_count += 1;
            if (!first_err) try errors.append(arena, ',') else first_err = false;
            try errors.appendSlice(arena, "{\"path\":");
            try writeJsonString(arena, &errors, path);
            try errors.appendSlice(arena, ",\"error\":");
            try writeJsonString(arena, &errors, @errorName(err));
            try errors.append(arena, '}');
            continue;
        };
        updated += 1;
    }
    try errors.append(arena, ']');

    return .{
        .matched = matched,
        .updated = updated,
        .skipped = skipped,
        .error_count = error_count,
        .errors_json = errors.items,
    };
}

fn jsonNonEmptyString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    if (v.string.len == 0) return null;
    return v.string;
}

fn jsonNumberOrString(arena: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    switch (v) {
        .string => |s| return if (s.len == 0) null else s,
        .integer => |i| return std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
        .float => |f| return std.fmt.allocPrint(arena, "{d}", .{f}) catch null,
        else => return null,
    }
}

fn formatDateUtc(arena: std.mem.Allocator) ![]const u8 {
    const now = clock.nowSeconds();
    const epoch_day_seconds: i64 = @divFloor(now, 86400);
    const epoch_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_day_seconds) };
    const ymd = epoch_day.calculateYearDay();
    const md = ymd.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        ymd.year, md.month.numeric(), md.day_index + 1,
    });
}

fn writeCsvExport(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    books: []const catalog_mod.Book,
) !void {
    try out.appendSlice(arena, "id,path,format,size,sha256,title,author_sort,year,isbn,series,series_index,language,publisher,read_status,added_at,updated_at\n");
    for (books) |b| {
        try appendFmt(arena, out, "{d},", .{b.id});
        try writeCsvField(arena, out, b.path);
        try out.append(arena, ',');
        try writeCsvField(arena, out, @tagName(b.format));
        try appendFmt(arena, out, ",{d},", .{b.size});
        try writeCsvField(arena, out, b.sha256);
        try out.append(arena, ',');
        try writeCsvField(arena, out, b.metadata.title orelse "");
        try out.append(arena, ',');
        try writeCsvField(arena, out, b.metadata.primaryAuthorSort());
        try out.append(arena, ',');
        if (b.metadata.published_year) |y| try appendFmt(arena, out, "{d}", .{y});
        try out.append(arena, ',');
        try writeCsvField(arena, out, b.metadata.isbn orelse "");
        try out.append(arena, ',');
        try writeCsvField(arena, out, b.metadata.series orelse "");
        try out.append(arena, ',');
        if (b.metadata.series_index) |idx| try appendFmt(arena, out, "{d}", .{idx});
        try out.append(arena, ',');
        try writeCsvField(arena, out, b.metadata.language orelse "");
        try out.append(arena, ',');
        try writeCsvField(arena, out, b.metadata.publisher orelse "");
        try out.append(arena, ',');
        try writeCsvField(arena, out, @tagName(b.read_status));
        try appendFmt(arena, out, ",{d},{d}\n", .{ b.added_at, b.updated_at });
    }
}

fn appendFmt(arena: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(arena, fmt, args);
    try out.appendSlice(arena, s);
}

fn writeCsvField(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const needs_quote = std.mem.indexOfAny(u8, value, ",\"\n\r") != null;
    if (!needs_quote) {
        try out.appendSlice(arena, value);
        return;
    }
    try out.append(arena, '"');
    for (value) |c| {
        if (c == '"') try out.append(arena, '"');
        try out.append(arena, c);
    }
    try out.append(arena, '"');
}

/// POST /api/pick-folder — pops a native folder picker. On macOS this
/// runs `osascript` and returns the absolute path; on other platforms
/// it returns 400 with a hint so the UI can fall back to the manual
/// path input. Designed for a local-only personal tool; not exposed
/// externally.
pub fn handlePickFolder(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
) !void {
    claimEmptyBody(request);

    if (@import("builtin").os.tag != .macos) {
        try respondJson(request, "{\"ok\":false,\"reason\":\"unsupported\"}");
        return;
    }

    const result = std.process.run(arena, io, .{
        .argv = &.{
            "osascript",
            "-e",
            "POSIX path of (choose folder with prompt \"Select a folder of ebooks\")",
        },
    }) catch {
        try respondJson(request, "{\"ok\":false,\"reason\":\"osascript_failed\"}");
        return;
    };

    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => 1,
    };
    if (code != 0) {
        try respondJson(request, "{\"ok\":false,\"reason\":\"cancelled\"}");
        return;
    }

    var trimmed: []const u8 = result.stdout;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) {
        try respondJson(request, "{\"ok\":false,\"reason\":\"empty\"}");
        return;
    }
    if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"ok\":true,\"path\":");
    try writeJsonString(arena, &out, trimmed);
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

pub fn handleSources(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    switch (request.head.method) {
        .GET => {
            const sources = try ctx.cat.listSources(arena);
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (sources, 0..) |s, i| {
                if (i > 0) try out.append(arena, ',');
                try writeSourceJson(arena, &out, s);
            }
            try out.append(arena, ']');
            try respondJson(request, out.items);
        },
        .POST => {
            const body = try readBody(arena, request, 64 * 1024);
            var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
                return errorJson(arena, request, "bad json", "");
            defer parsed.deinit();
            if (parsed.value != .object) return errorJson(arena, request, "body must be object", "");
            const path_v = parsed.value.object.get("path") orelse
                return errorJson(arena, request, "missing 'path'", "");
            if (path_v != .string) return errorJson(arena, request, "'path' must be a string", "");
            const name_v = parsed.value.object.get("name");
            const name: ?[]const u8 = if (name_v) |v| (if (v == .string) v.string else null) else null;

            const id = try ctx.cat.addSource(arena, path_v.string, name);

            const wa = ctx.worker_allocator orelse {
                const stats = sources_mod.scanSourceFromHttp(arena, io, ctx.cat, id, path_v.string) catch |err| {
                    var out: std.ArrayList(u8) = .empty;
                    try out.appendSlice(arena, try std.fmt.allocPrint(
                        arena,
                        "{{\"id\":{d},\"scanned\":false,\"error\":\"{s}\"}}",
                        .{ id, @errorName(err) },
                    ));
                    try respondJson(request, out.items);
                    return;
                };
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(arena, try std.fmt.allocPrint(
                    arena,
                    "{{\"id\":{d},\"scheduled\":false,\"scanned\":true,\"seen\":{d},\"added\":{d},\"updated\":{d}}}",
                    .{ id, stats.seen, stats.added, stats.updated },
                ));
                try respondJson(request, out.items);
                return;
            };

            ctx.cat.markSourceScanning(id, 0) catch {};

            sources_mod.spawnBackgroundScan(wa, io, ctx.catalog_path, id, path_v.string) catch |err| {
                std.log.warn("spawn scan worker: {s}", .{@errorName(err)});
                ctx.cat.markSourceError(id, @errorName(err)) catch {};
                const body_ = try std.fmt.allocPrint(
                    arena,
                    "{{\"id\":{d},\"scheduled\":false,\"error\":\"{s}\"}}",
                    .{ id, @errorName(err) },
                );
                try respondJson(request, body_);
                return;
            };

            const body_ = try std.fmt.allocPrint(
                arena,
                "{{\"id\":{d},\"scheduled\":true}}",
                .{id},
            );
            try respondJson(request, body_);
        },
        else => return methodNotAllowed(request),
    }
}

pub fn handleSourceRescan(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    claimEmptyBody(request);
    const src = (try ctx.cat.getSourceById(arena, id)) orelse return notFound(request);

    const wa = ctx.worker_allocator orelse {
        const stats = try sources_mod.scanSourceFromHttp(arena, io, ctx.cat, src.id, src.path);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"scheduled\":false,\"seen\":{d},\"added\":{d},\"updated\":{d},\"missing\":{d}}}",
            .{ stats.seen, stats.added, stats.updated, stats.missing },
        );
        try respondJson(request, body);
        return;
    };

    ctx.cat.markSourceScanning(id, 0) catch {};

    sources_mod.spawnBackgroundScan(wa, io, ctx.catalog_path, src.id, src.path) catch |err| {
        ctx.cat.markSourceError(id, @errorName(err)) catch {};
        const body = try std.fmt.allocPrint(arena, "{{\"scheduled\":false,\"error\":\"{s}\"}}", .{@errorName(err)});
        try respondJson(request, body);
        return;
    };

    try respondJson(request, "{\"scheduled\":true}");
}

pub fn handleSourceDelete(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    _ = arena;
    claimEmptyBody(request);
    try ctx.cat.removeSource(id);
    try respondJson(request, "{\"ok\":true}");
}

fn writeSourceJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: catalog_mod.Catalog.LibrarySource,
) !void {
    try out.append(arena, '{');
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\"id\":{d}", .{s.id}));
    try out.appendSlice(arena, ",\"path\":");
    try writeJsonString(arena, out, s.path);
    if (s.name) |n| {
        try out.appendSlice(arena, ",\"name\":");
        try writeJsonString(arena, out, n);
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        ",\"added_at\":{d},\"last_seen\":{d},\"last_added\":{d},\"last_missing\":{d}",
        .{ s.added_at, s.last_seen, s.last_added, s.last_missing },
    ));
    if (s.last_scanned_at) |t| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"last_scanned_at\":{d}", .{t}));
    }
    if (s.last_error) |e| {
        try out.appendSlice(arena, ",\"last_error\":");
        try writeJsonString(arena, out, e);
    }
    if (s.scanning) {
        try out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            ",\"scanning\":true,\"scan_seen\":{d},\"scan_total\":{d}",
            .{ s.scan_seen, s.scan_total },
        ));
    }
    try out.append(arena, '}');
}

/// POST /api/derive-paths
/// Walks every book, runs path_meta.fromPath on its path, and fills in
/// series + series_index when the row is missing them. The MOBI/EPUB
/// headers we read at scan time almost never populate series, so this
/// is a one-shot backfill that turns the catalog into something the
/// Series view can actually use.
pub fn handleDerivePaths(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    claimEmptyBody(request);
    const books = try ctx.cat.listBooks(arena);
    var scanned: u32 = 0;
    var updated: u32 = 0;
    for (books) |b| {
        scanned += 1;
        const d = path_meta.fromPath(arena, b.path) catch continue;
        if (d.series == null and d.series_index == null) continue;

        var md = b.metadata;
        var changed = false;
        if (md.series == null and d.series != null) {
            md.series = d.series;
            changed = true;
        }
        const series_matches = md.series != null and d.series != null and
            std.ascii.eqlIgnoreCase(md.series.?, d.series.?);
        if (md.series_index == null and d.series_index != null and series_matches) {
            md.series_index = d.series_index;
            changed = true;
        }
        if (!changed) continue;

        _ = ctx.cat.upsertBook(arena, .{
            .path = b.path,
            .sha256 = b.sha256,
            .size = b.size,
            .format = b.format,
            .mtime = b.mtime,
            .metadata = md,
        }) catch continue;
        updated += 1;
    }

    const body = try std.fmt.allocPrint(
        arena,
        "{{\"scanned\":{d},\"updated\":{d}}}",
        .{ scanned, updated },
    );
    try respondJson(request, body);
}

/// GET /api/standardize?preset=default|flat|series-dir
///   or ?template=<custom>
/// Returns a dry-run plan: every book in the catalog paired with the
/// canonical destination path under the chosen template. Books with
/// incomplete metadata come back with `unrenameable_reason` instead.
/// The frontend renders this as the "Rename preview" lens.
pub fn handleStandardizePreview(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const target = try arena.dupe(u8, request.head.target);
    claimEmptyBody(request);
    const template_str = try resolveTemplate(arena, target);

    const plans = try standardize_mod.planAll(arena, ctx.cat, template_str);
    const counts = standardize_mod.summarize(plans);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"counts\":{");
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "\"total\":{d},\"would_change\":{d},\"same\":{d},\"unrenameable\":{d}",
        .{ counts.total, counts.would_change, counts.same, counts.unrenameable },
    ));
    try out.appendSlice(arena, "},\"template\":");
    try writeJsonString(arena, &out, template_str);
    try out.appendSlice(arena, ",\"plans\":[");
    var first = true;
    for (plans) |p| {
        if (!first) try out.append(arena, ',');
        first = false;
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d}", .{p.id}));
        try out.appendSlice(arena, ",\"src\":");
        try writeJsonString(arena, &out, p.src);
        if (p.dst) |d| {
            try out.appendSlice(arena, ",\"dst\":");
            try writeJsonString(arena, &out, d);
            try out.appendSlice(arena, ",\"same\":");
            try out.appendSlice(arena, if (p.same) "true" else "false");
        } else if (p.unrenameable_reason) |r| {
            try out.appendSlice(arena, ",\"unrenameable_reason\":");
            try writeJsonString(arena, &out, r);
        }
        try out.append(arena, '}');
    }
    try out.appendSlice(arena, "]}");
    try respondJson(request, out.items);
}

/// POST /api/standardize/apply
/// Body: { "ids": [42, 17, ...], "template": "..." | "preset": "default" }
/// Applies the canonical rename for each listed id. Returns one result
/// per id so partial failures don't take down the whole batch.
pub fn handleStandardizeApply(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const body = try readBody(arena, request, 64 * 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "body must be an object", "");
    const obj = parsed.value.object;

    var template_str: []const u8 = template_mod.DEFAULT_TEMPLATE;
    if (obj.get("preset")) |v| if (v == .string) {
        template_str = standardize_mod.presetTemplate(v.string) catch
            return errorJson(arena, request, "unknown preset", v.string);
    };
    if (obj.get("template")) |v| if (v == .string) {
        template_str = try arena.dupe(u8, v.string);
    };

    const ids_v = obj.get("ids") orelse
        return errorJson(arena, request, "missing 'ids' array", "");
    if (ids_v != .array) return errorJson(arena, request, "'ids' must be an array", "");
    var want: std.AutoHashMap(i64, void) = .init(arena);
    defer want.deinit();
    for (ids_v.array.items) |idv| {
        if (idv != .integer) continue;
        try want.put(@intCast(idv.integer), {});
    }
    if (want.count() == 0) return errorJson(arena, request, "no valid ids in request", "");

    const plans = try standardize_mod.planAll(arena, ctx.cat, template_str);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"results\":[");
    var first = true;
    var ok_count: u32 = 0;
    var err_count: u32 = 0;
    for (plans) |p| {
        if (!want.contains(p.id)) continue;
        if (!first) try out.append(arena, ',');
        first = false;
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},", .{p.id}));
        if (p.dst == null) {
            try out.appendSlice(arena, "\"status\":\"skipped\",\"reason\":");
            try writeJsonString(arena, &out, p.unrenameable_reason orelse "no destination");
        } else if (p.same) {
            try out.appendSlice(arena, "\"status\":\"skipped\",\"reason\":\"already canonical\"");
        } else {
            standardize_mod.applyOne(ctx.cat, p) catch |err| {
                err_count += 1;
                try out.appendSlice(arena, "\"status\":\"error\",\"error\":");
                try writeJsonString(arena, &out, @errorName(err));
                try out.append(arena, '}');
                continue;
            };
            ok_count += 1;
            try out.appendSlice(arena, "\"status\":\"ok\",\"new_path\":");
            try writeJsonString(arena, &out, p.dst.?);
        }
        try out.append(arena, '}');
    }
    try out.appendSlice(arena, "],\"summary\":{");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\"ok\":{d},\"errors\":{d}", .{ ok_count, err_count }));
    try out.appendSlice(arena, "}}");
    try respondJson(request, out.items);
}

/// Pull the active template string out of a `?preset=…&template=…`
/// query. `template` wins if both are present. Defaults to the
/// `default` preset when neither is set.
fn resolveTemplate(arena: std.mem.Allocator, target: []const u8) ![]const u8 {
    var preset: ?[]const u8 = null;
    var custom: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const k = pair[0..eq];
            const v_raw = pair[eq + 1 ..];
            const v = try urlDecode(arena, v_raw);
            if (std.mem.eql(u8, k, "preset")) preset = v;
            if (std.mem.eql(u8, k, "template")) custom = v;
        }
    }
    if (custom) |t| return t;
    if (preset) |p| return standardize_mod.presetTemplate(p) catch template_mod.DEFAULT_TEMPLATE;
    return template_mod.DEFAULT_TEMPLATE;
}

pub fn handleDuplicates(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const groups = try ctx.cat.listExactDuplicateGroups(arena);
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (groups, 0..) |group, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"sha256\":\"");
        try out.appendSlice(arena, group.sha256);
        try out.appendSlice(arena, "\",\"books\":[");
        for (group.ids, 0..) |id, j| {
            if (j > 0) try out.append(arena, ',');
            const b = (try ctx.cat.getBookById(arena, id)) orelse continue;
            try writeBookJson(arena, &out, ctx, b);
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
    ctx: *WebContext,
    request: *std.http.Server.Request,
    rest: []const u8,
) !void {
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const id_str = rest[0..slash];
    const tail = if (slash < rest.len) rest[slash + 1 ..] else "";

    if (std.mem.eql(u8, id_str, "bulk")) {
        return handleBulk(arena, io, ctx, request, tail);
    }

    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        try request.respond("bad id\n", .{ .status = .bad_request });
        return;
    };

    if (tail.len == 0) {
        switch (request.head.method) {
            .GET => {
                const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
                var out: std.ArrayList(u8) = .empty;
                try writeBookJson(arena, &out, ctx, book);
                return respondJson(request, out.items);
            },
            .PATCH => return handlePatch(arena, io, ctx, request, id),
            .DELETE => return handleDelete(arena, ctx, request, id),
            else => return methodNotAllowed(request),
        }
    }

    if (std.mem.eql(u8, tail, "file")) {
        const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
        return streamFile(arena, request, book);
    }
    if (std.mem.eql(u8, tail, "cover")) {
        if (request.head.method == .POST) {
            return handleCoverUpload(arena, io, ctx, request, id);
        }
        const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
        return streamCover(arena, io, ctx, request, book);
    }
    if (std.mem.eql(u8, tail, "covers")) {
        if (request.head.method != .GET) return methodNotAllowed(request);
        return handleMoreCovers(arena, io, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "reset")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        return handleReset(arena, io, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "enrich")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        return handleEnrich(arena, io, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "skip-triage")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        return handleSkipTriage(arena, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "convert")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        return handleConvert(arena, io, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "status")) {
        if (request.head.method != .PATCH and request.head.method != .POST) return methodNotAllowed(request);
        return handleSetStatus(arena, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "changes")) {
        if (request.head.method != .GET) return methodNotAllowed(request);
        return handleBookChanges(arena, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "stats")) {
        if (request.head.method != .GET) return methodNotAllowed(request);
        return handleBookStats(arena, ctx, request, id);
    }
    if (std.mem.eql(u8, tail, "tags")) {
        return handleBookTags(arena, ctx, request, id);
    }
    if (matchPrefixLocal(tail, "tags/")) |tag_rest| {
        const tag_id = std.fmt.parseInt(i64, tag_rest, 10) catch
            return errorJson(arena, request, "bad tag id", tag_rest);
        if (request.head.method != .DELETE) return methodNotAllowed(request);
        return handleBookTagDelete(arena, ctx, request, id, tag_id);
    }
    if (std.mem.eql(u8, tail, "comic-pages")) {
        if (request.head.method != .GET) return methodNotAllowed(request);
        return handleComicPages(arena, io, ctx, request, id);
    }
    if (matchPrefixLocal(tail, "comic-page/")) |n_str| {
        if (request.head.method != .GET) return methodNotAllowed(request);
        const n = std.fmt.parseInt(usize, n_str, 10) catch {
            try request.respond("bad page index\n", .{ .status = .bad_request });
            return;
        };
        return handleComicPage(arena, io, ctx, request, id, n);
    }
    if (std.mem.eql(u8, tail, "location")) {
        if (request.head.method == .GET) return handleGetLocation(arena, ctx, request, id);
        if (request.head.method == .PUT) return handleSetLocation(arena, ctx, request, id);
        if (request.head.method == .DELETE) return handleDeleteLocation(arena, ctx, request, id);
        return methodNotAllowed(request);
    }

    return notFound(request);
}

/// PATCH /api/books/:id/status
/// Body: { "status": "unread" | "reading" | "finished" }
fn handleSetStatus(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const body = try readBody(arena, request, 256);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "body must be object", "");
    const v = parsed.value.object.get("status") orelse return errorJson(arena, request, "missing 'status'", "");
    if (v != .string) return errorJson(arena, request, "'status' must be a string", "");

    const status = catalog_mod.ReadStatus.fromStr(v.string);
    try ctx.cat.setReadStatus(id, status);
    const fresh = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
    var out: std.ArrayList(u8) = .empty;
    try writeBookJson(arena, &out, ctx, fresh);
    try respondJson(request, out.items);
}

/// GET /api/books/:id/location → saved reading position, or null.
fn matchPrefixLocal(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, prefix)) return path[prefix.len..];
    return null;
}

/// GET /api/tags → [{id, name, count}, ...]
pub fn handleTagsList(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const tags = try ctx.cat.listTags(arena);
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (tags, 0..) |t, i| {
        if (i > 0) try out.append(arena, ',');
        try out.append(arena, '{');
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\"id\":{d},", .{t.id}));
        try out.appendSlice(arena, "\"name\":");
        try writeJsonString(arena, &out, t.name);
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"count\":{d}", .{t.count}));
        try out.append(arena, '}');
    }
    try out.append(arena, ']');
    try respondJson(request, out.items);
}

/// POST /api/tags  body: {"name": "to-read"}  → {id, name}
pub fn handleTagsCreate(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const body = try readBody(arena, request, 4096);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "bad shape", "");
    const name_v = parsed.value.object.get("name") orelse
        return errorJson(arena, request, "missing 'name'", "");
    if (name_v != .string) return errorJson(arena, request, "'name' must be string", "");
    const id = ctx.cat.upsertTag(arena, name_v.string) catch |err|
        return errorJson(arena, request, "create tag", @errorName(err));

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},\"name\":", .{id}));
    try writeJsonString(arena, &out, std.mem.trim(u8, name_v.string, " \t\n"));
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// DELETE /api/tags/:id
pub fn handleTagsDelete(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    _ = arena;
    claimEmptyBody(request);
    try ctx.cat.deleteTag(id);
    try respondJson(request, "{\"ok\":true}");
}

/// GET  /api/books/:id/tags → tags on this book
/// POST /api/books/:id/tags body {"name":"X"}|{"tag_id":N} → attach
fn handleBookTags(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    book_id: i64,
) !void {
    switch (request.head.method) {
        .GET => {
            claimEmptyBody(request);
            const tags = try ctx.cat.listBookTags(arena, book_id);
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '[');
            for (tags, 0..) |t, i| {
                if (i > 0) try out.append(arena, ',');
                try out.append(arena, '{');
                try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\"id\":{d},", .{t.id}));
                try out.appendSlice(arena, "\"name\":");
                try writeJsonString(arena, &out, t.name);
                try out.append(arena, '}');
            }
            try out.append(arena, ']');
            try respondJson(request, out.items);
        },
        .POST => {
            const body = try readBody(arena, request, 4096);
            var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
                return errorJson(arena, request, "bad json", "");
            defer parsed.deinit();
            if (parsed.value != .object) return errorJson(arena, request, "bad shape", "");
            var tag_id: i64 = 0;
            if (parsed.value.object.get("tag_id")) |tv| {
                if (tv == .integer) tag_id = tv.integer;
            }
            if (tag_id == 0) {
                const name_v = parsed.value.object.get("name") orelse
                    return errorJson(arena, request, "need 'tag_id' or 'name'", "");
                if (name_v != .string) return errorJson(arena, request, "'name' must be string", "");
                tag_id = ctx.cat.upsertTag(arena, name_v.string) catch |err|
                    return errorJson(arena, request, "tag upsert", @errorName(err));
            }
            try ctx.cat.addBookTag(book_id, tag_id);
            try respondJson(request, "{\"ok\":true}");
        },
        else => return methodNotAllowed(request),
    }
}

/// DELETE /api/books/:id/tags/:tag_id
fn handleBookTagDelete(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    book_id: i64,
    tag_id: i64,
) !void {
    _ = arena;
    claimEmptyBody(request);
    try ctx.cat.removeBookTag(book_id, tag_id);
    try respondJson(request, "{\"ok\":true}");
}

/// GET /api/books/:id/stats — reading time + sessions.
fn handleBookStats(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    claimEmptyBody(request);
    const s = ctx.cat.getReadingStats(id) catch
        catalog_mod.Catalog.ReadingStats{ .sessions = 0, .total_seconds = 0, .last_at = 0 };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "{{\"sessions\":{d},\"total_seconds\":{d},\"last_at\":{d}}}",
        .{ s.sessions, s.total_seconds, s.last_at },
    ));
    try respondJson(request, out.items);
}

/// GET /api/books/:id/changes — recent field-level audit log entries.
/// Response: [{field, old, new, source, at}, ...] sorted newest first.
fn handleBookChanges(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    claimEmptyBody(request);
    const rows = try ctx.cat.listBookChanges(arena, id, 50);
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (rows, 0..) |r, i| {
        if (i > 0) try out.append(arena, ',');
        try out.append(arena, '{');
        try out.appendSlice(arena, "\"field\":");
        try writeJsonString(arena, &out, r.field);
        try out.appendSlice(arena, ",\"old\":");
        if (r.old_value) |v| try writeJsonString(arena, &out, v) else try out.appendSlice(arena, "null");
        try out.appendSlice(arena, ",\"new\":");
        if (r.new_value) |v| try writeJsonString(arena, &out, v) else try out.appendSlice(arena, "null");
        try out.appendSlice(arena, ",\"source\":");
        try writeJsonString(arena, &out, r.source);
        try out.appendSlice(arena, ",\"at\":");
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{r.changed_at}));
        try out.append(arena, '}');
    }
    try out.append(arena, ']');
    try respondJson(request, out.items);
}

fn handleGetLocation(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    claimEmptyBody(request);
    const loc = try ctx.cat.getLocation(arena, id);
    if (loc == null) {
        try respondJson(request, "null");
        return;
    }
    const l = loc.?;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"location\":");
    try writeJsonString(arena, &out, l.location);
    try out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        ",\"updated_at\":{d}",
        .{l.updated_at},
    ));
    if (l.percent) |p| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"percent\":{d:.4}", .{p}));
    }
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// PUT /api/books/:id/location
/// Body: { "location": "<opaque cfi or page-no>", "percent"?: 0.42 }
fn handleSetLocation(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const body = try readBody(arena, request, 8 * 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "body must be object", "");
    const loc_v = parsed.value.object.get("location") orelse
        return errorJson(arena, request, "missing 'location'", "");
    if (loc_v != .string) return errorJson(arena, request, "'location' must be a string", "");

    var percent: ?f32 = null;
    if (parsed.value.object.get("percent")) |p| {
        if (p == .float) percent = @floatCast(p.float);
        if (p == .integer) percent = @floatFromInt(p.integer);
    }

    try ctx.cat.setLocation(id, loc_v.string, percent);
    try respondJson(request, "{\"ok\":true}");
}

/// DELETE /api/books/:id/location → drop saved reading position.
fn handleDeleteLocation(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    _ = arena;
    claimEmptyBody(request);
    try ctx.cat.deleteLocation(id);
    try respondJson(request, "{\"ok\":true}");
}

/// Apply a parsed JSON object (the body of PATCH /api/books/:id) to
/// the on-disk file via the FormatHandler vtable AND to the catalog
/// row. Extracted from handlePatch so the bulk endpoint can reuse
/// the same per-book logic. Mutates the file in place when the
/// format supports it (EPUB OPF rewrite, MOBI/AZW3 via mobimeta);
/// silently degrades to catalog-only update for formats whose
/// handler returns `error.NotSupported`.
///
/// `append_subjects`: when true, the parsed subjects are APPENDED to
/// the existing list (dedup case-insensitively) rather than
/// replacing it. The bulk endpoint sets this to avoid surprising
/// users who tag 80 books at once.
pub fn applyPatchToBook(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    book: catalog_mod.Book,
    obj: std.json.ObjectMap,
    append_subjects: bool,
) !void {
    var update: handler_mod.MetadataUpdate = .{};
    if (obj.get("title")) |v| if (v == .string) {
        update.title = try arena.dupe(u8, v.string);
    };
    if (obj.get("author")) |v| if (v == .string) {
        update.author = try arena.dupe(u8, v.string);
    };
    if (obj.get("series")) |v| if (v == .string) {
        update.series = try arena.dupe(u8, v.string);
    };
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
    if (obj.get("publisher")) |v| if (v == .string) {
        update.publisher = try arena.dupe(u8, v.string);
    };
    if (obj.get("language")) |v| if (v == .string) {
        update.language = try arena.dupe(u8, v.string);
    };
    if (obj.get("isbn")) |v| if (v == .string) {
        update.isbn = try arena.dupe(u8, v.string);
    };
    if (obj.get("description")) |v| if (v == .string) {
        update.description = try arena.dupe(u8, v.string);
    };

    var new_subjects: ?[]const []const u8 = null;
    if (obj.get("subjects")) |v| if (v == .string) {
        var list: std.ArrayList([]const u8) = .empty;
        if (append_subjects) {
            for (book.metadata.subjects) |s| {
                try list.append(arena, try arena.dupe(u8, s));
            }
        }
        var it = std.mem.splitScalar(u8, v.string, ',');
        while (it.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) continue;
            var seen = false;
            for (list.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, trimmed)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try list.append(arena, try arena.dupe(u8, trimmed));
        }
        new_subjects = try list.toOwnedSlice(arena);
        update.subjects = new_subjects;
    };

    if (format_registry.forFormat(book.format)) |h| {
        h.writeMetadata(arena, io, book.path, update) catch |err| switch (err) {
            error.NotSupported => {},
            else => return err,
        };
    }

    var md = book.metadata;
    if (update.title) |t| md.title = t;
    if (update.author) |a| {
        const author = try meta.Author.fromDisplay(arena, a);
        md.authors = try arena.dupe(meta.Author, &[_]meta.Author{author});
    }
    if (update.series) |s| md.series = s;
    if (update.series_index) |idx| md.series_index = std.fmt.parseFloat(f32, idx) catch null;
    if (update.year) |y| md.published_year = std.fmt.parseInt(u16, y, 10) catch null;
    if (update.publisher) |p| md.publisher = p;
    if (update.language) |l| md.language = l;
    if (update.isbn) |i| md.isbn = i;
    if (update.description) |d| md.description = d;
    if (new_subjects) |s| md.subjects = s;
    md.source = .manual;
    md.confidence = 1.0;

    _ = try ctx.cat.upsertBook(arena, .{
        .path = book.path,
        .sha256 = book.sha256,
        .size = book.size,
        .format = book.format,
        .mtime = book.mtime,
        .metadata = md,
    });
}

/// PATCH /api/books/:id
/// Body: { "title"?, "author"?, "series"?, "series_index"?, "year"? }
/// All fields optional. The corresponding embedded metadata is rewritten
/// in place (EPUB OPF or MOBI mobimeta) AND the catalog row is updated.
fn handlePatch(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
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
    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
    applyPatchToBook(arena, io, ctx, book, parsed.value.object, false) catch |err|
        return errorJson(arena, request, "set-meta failed", @errorName(err));
    const fresh = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
    var out: std.ArrayList(u8) = .empty;
    try writeBookJson(arena, &out, ctx, fresh);
    try respondJson(request, out.items);
}

/// DELETE /api/books/:id?file=1
/// Removes the catalog row. If ?file=1, also unlinks the file from disk.
fn handleDelete(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const remove_file = std.mem.indexOf(u8, request.head.target, "file=1") != null;
    claimEmptyBody(request);
    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);

    if (remove_file) {
        var path_z: [4096]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&path_z, "{s}", .{book.path});
        _ = std.c.unlink(z.ptr);
    }
    cover_store.unlink(arena, ctx.env, book.id) catch {};
    cover_store.unlinkThumb(arena, ctx.env, book.id) catch {};
    try ctx.cat.deleteBook(book.id);
    try respondJson(request, "{\"ok\":true}");
}

/// GET /api/books/:id/covers?work_key=&offset=&limit=&seen=
/// Pages through OpenLibrary editions for additional cover URLs when
/// the 3 covers returned by enrich aren't enough. Cancellable
/// client-side via fetch AbortController.
fn handleMoreCovers(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    _ = id;
    const target = try arena.dupe(u8, request.head.target);
    claimEmptyBody(request);

    var work_key: ?[]const u8 = null;
    var offset: usize = 3;
    var limit: usize = 6;
    var seen_csv: ?[]const u8 = null;

    if (std.mem.indexOfScalar(u8, target, '?')) |qstart| {
        var it = std.mem.splitScalar(u8, target[qstart + 1 ..], '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = try urlDecode(arena, pair[eq + 1 ..]);
            if (std.mem.eql(u8, key, "work_key")) work_key = val else if (std.mem.eql(u8, key, "offset")) offset = std.fmt.parseInt(usize, val, 10) catch offset else if (std.mem.eql(u8, key, "limit")) limit = std.fmt.parseInt(usize, val, 10) catch limit else if (std.mem.eql(u8, key, "seen")) seen_csv = val;
        }
    }

    const wk = work_key orelse
        return errorJson(arena, request, "missing 'work_key' query parameter", "");
    if (wk.len == 0)
        return errorJson(arena, request, "empty work_key", "");
    if (!std.mem.startsWith(u8, wk, "/works/") and !std.mem.startsWith(u8, wk, "OL"))
        return errorJson(arena, request, "bad work_key shape", wk);
    if (limit == 0) limit = 6;
    if (limit > 20) limit = 20;

    var seen_list: std.ArrayList([]const u8) = .empty;
    if (seen_csv) |s| {
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len == 0) continue;
            try seen_list.append(arena, trimmed);
        }
    }

    var real_http = http.RealHttpClient{ .io = io };
    var ol = openlibrary.OpenLibrary{ .http_client = real_http.client() };
    const result = ol.lookupMoreCovers(arena, io, wk, offset, limit, seen_list.items) catch |err|
        return errorJson(arena, request, "more-covers fetch failed", @errorName(err));

    _ = ctx;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"urls\":[");
    for (result.urls, 0..) |u, i| {
        if (i > 0) try out.append(arena, ',');
        try writeJsonString(arena, &out, u);
    }
    try out.appendSlice(arena, "],\"next_offset\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{result.next_offset}));
    try out.appendSlice(arena, ",\"exhausted\":");
    try out.appendSlice(arena, if (result.exhausted) "true" else "false");
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// POST /api/books/:id/enrich
/// Queries Open Library for this book (by ISBN if available, otherwise
/// title + author) and merges any new fields into the catalog row.
/// Q3: POST /api/books/:id/skip-triage — marks the book as no_match so
/// it disappears from the triage queue and the batch worker skips it
/// on the next run. The user can clear the status from the detail
/// panel later if they want to retry. Reuses the same enum value the
/// "no Open Library match" path sets, so triage skips and provider
/// no-match are indistinguishable downstream (which is correct: both
/// mean "we've already tried and decided not to act on this").
fn handleSkipTriage(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    claimEmptyBody(request);
    ctx.cat.setEnrichStatus(id, .no_match) catch |err|
        return errorJson(arena, request, "set status failed", @errorName(err));
    try respondJson(request, "{\"ok\":true}");
}

const ENRICH_CACHE_TTL_SECONDS: i64 = 30 * 24 * 60 * 60;

fn handleEnrich(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const target_snapshot = try arena.dupe(u8, request.head.target);
    claimEmptyBody(request);
    const force_refresh = std.mem.indexOf(u8, target_snapshot, "refresh=1") != null;

    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);

    const derived = path_meta.fromPath(arena, book.path) catch path_meta.Derived{};

    if (!force_refresh) {
        if (try ctx.cat.getMetadataSource(arena, id, .openlibrary)) |cached| {
            const age = clock.nowSeconds() - cached.fetched_at;
            if (age < ENRICH_CACHE_TTL_SECONDS) {
                enrich_log.debug(
                    "book {d} → cache hit (age={d}s, ttl={d}s)",
                    .{ id, age, ENRICH_CACHE_TTL_SECONDS },
                );
                try respondCachedEnrich(arena, ctx, request, book, cached);
                return;
            }
            enrich_log.debug("book {d} cache expired (age={d}s); refetching", .{ id, age });
        }
    }

    const title_for_query = book.metadata.title orelse derived.title;
    const title_from_catalog = book.metadata.title != null;
    const author_from_catalog = book.metadata.authors.len > 0;
    const author_for_query: ?[]const u8 = if (author_from_catalog)
        book.metadata.authors[0].sort
    else
        derived.author;
    const q = provider_iface.Query{
        .isbn = book.metadata.isbn,
        .title = title_for_query,
        .author = author_for_query,
    };
    enrich_log.debug(
        "book {d} query: isbn={?s} title={?s} (from {s}) author={?s} (from {s})",
        .{
            id,
            q.isbn,
            q.title,
            if (title_from_catalog) @as([]const u8, "catalog") else @as([]const u8, "filename"),
            q.author,
            if (author_from_catalog) @as([]const u8, "catalog") else @as([]const u8, "filename"),
        },
    );

    var real_http = http.RealHttpClient{ .io = io };
    var ol = openlibrary.OpenLibrary{ .http_client = real_http.client() };
    const diag = try ol.lookupRichDiag(arena, io, q);
    const rich = diag.result orelse {
        ctx.cat.setEnrichStatus(id, .no_match) catch {};
        enrich_log.info(
            "book {d} → no_match (tried {d} variants)",
            .{ id, diag.attempts.len },
        );
        try respondNoMatchDiag(arena, request, q, diag.attempts);
        return;
    };

    ctx.cat.setEnrichStatus(id, .ok) catch {};

    var ol_payload: std.ArrayList(u8) = .empty;
    try writeOlPayloadJson(arena, &ol_payload, rich, derived);
    ctx.cat.recordMetadataSource(id, .openlibrary, ol_payload.items) catch |err|
        enrich_log.warn("book {d}: cache write failed: {s}", .{ id, @errorName(err) });

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"enriched\":true,\"book\":");
    try writeBookJson(arena, &out, ctx, book);
    try out.appendSlice(arena, ",\"current\":");
    try writeMetadataJson(arena, &out, book.metadata);
    if (ol_payload.items.len > 2) {
        try out.append(arena, ',');
        try out.appendSlice(arena, ol_payload.items[1 .. ol_payload.items.len - 1]);
    }
    if (diag.attempts.len > 0) {
        try out.appendSlice(arena, ",\"tried\":");
        try writeAttemptsJson(arena, &out, diag.attempts);
    }
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// Serialize the cacheable portion of a lookupRichDiag result: every
/// field that doesn't depend on the live book row. We persist this
/// blob to `metadata_sources.payload_json` so a subsequent Fetch info
/// on the same book can replay the same suggestion without burning an
/// OL roundtrip. `tried` is deliberately excluded — it's a per-call
/// diagnostic, not data the user cares about on re-open.
fn writeOlPayloadJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rich: openlibrary.EnrichResult,
    derived: path_meta.Derived,
) !void {
    try out.append(arena, '{');
    try out.appendSlice(arena, "\"suggested\":");
    try writeMetadataJson(arena, out, rich.metadata);
    if (derived.series) |s| {
        try out.appendSlice(arena, ",\"derived_series\":");
        try writeJsonString(arena, out, s);
        if (derived.series_index) |idx| {
            try out.appendSlice(arena, ",\"derived_series_index\":");
            const buf = try std.fmt.allocPrint(arena, "{d}", .{idx});
            try out.appendSlice(arena, buf);
        }
    }
    if (rich.work_key) |wk| {
        try out.appendSlice(arena, ",\"work_key\":");
        try writeJsonString(arena, out, wk);
    }
    try out.appendSlice(arena, ",\"alt_covers\":[");
    for (rich.alt_cover_urls, 0..) |u, i| {
        if (i > 0) try out.append(arena, ',');
        try writeJsonString(arena, out, u);
    }
    try out.appendSlice(arena, "],\"editions\":[");
    for (rich.editions, 0..) |e, i| {
        if (i > 0) try out.append(arena, ',');
        try writeEditionJson(arena, out, e);
    }
    try out.appendSlice(arena, "],\"candidates\":[");
    for (rich.candidates, 0..) |c, i| {
        if (i > 0) try out.append(arena, ',');
        try writeCandidateJson(arena, out, c);
    }
    try out.appendSlice(arena, "]}");
}

fn writeCandidateJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    c: openlibrary.Candidate,
) !void {
    try out.append(arena, '{');
    try out.appendSlice(arena, "\"title\":");
    if (c.title) |t| try writeJsonString(arena, out, t) else try out.appendSlice(arena, "null");
    try out.appendSlice(arena, ",\"author\":");
    if (c.author) |a| try writeJsonString(arena, out, a) else try out.appendSlice(arena, "null");
    if (c.work_key) |w| {
        try out.appendSlice(arena, ",\"work_key\":");
        try writeJsonString(arena, out, w);
    }
    if (c.year) |y| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"year\":{d}", .{y}));
    }
    if (c.isbn) |i| {
        try out.appendSlice(arena, ",\"isbn\":");
        try writeJsonString(arena, out, i);
    }
    if (c.cover_url) |u| {
        try out.appendSlice(arena, ",\"cover_url\":");
        try writeJsonString(arena, out, u);
    }
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"score\":{d}", .{c.score}));
    try out.appendSlice(arena, ",\"metadata\":");
    try writeMetadataJson(arena, out, c.metadata);
    try out.append(arena, '}');
}

/// Q1: respond to Fetch info from a cached OL payload. Live `book` +
/// `current` (the catalog's CURRENT metadata) are spliced in fresh so
/// the user always sees their latest edits; the rest comes straight
/// from `cached.payload_json`. `from_cache: true` + `cached_at` let
/// the UI render a "cached" hint badge.
fn respondCachedEnrich(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    book: catalog_mod.Book,
    cached: catalog_mod.Catalog.CachedMetadataSource,
) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"enriched\":true,\"book\":");
    try writeBookJson(arena, &out, ctx, book);
    try out.appendSlice(arena, ",\"current\":");
    try writeMetadataJson(arena, &out, book.metadata);
    if (cached.payload_json.len > 2) {
        try out.append(arena, ',');
        try out.appendSlice(arena, cached.payload_json[1 .. cached.payload_json.len - 1]);
    }
    try out.appendSlice(arena, ",\"from_cache\":true,\"cached_at\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{cached.fetched_at}));
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// Serialise a BookMetadata as a flat JSON object suitable for the
/// diff editor. Only the fields the editor cares about — title, author
/// (display + sort), series + series_index, year, publisher, language,
/// isbn, description, subjects. Cover URL is excluded (covers have
/// their own picker UI).
fn writeMetadataJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    md: meta.BookMetadata,
) !void {
    try out.append(arena, '{');
    var first = true;
    if (md.title) |v| {
        try writeJsonKv(arena, out, &first, "title", v);
    }
    if (md.authors.len > 0) {
        if (!first) try out.append(arena, ',');
        first = false;
        try out.appendSlice(arena, "\"author\":");
        try writeJsonString(arena, out, md.authors[0].sort);
    }
    if (md.series) |v| {
        try writeJsonKv(arena, out, &first, "series", v);
    }
    if (md.series_index) |idx| {
        if (!first) try out.append(arena, ',');
        first = false;
        const buf = try std.fmt.allocPrint(arena, "\"series_index\":{d}", .{idx});
        try out.appendSlice(arena, buf);
    }
    if (md.published_year) |y| {
        if (!first) try out.append(arena, ',');
        first = false;
        const buf = try std.fmt.allocPrint(arena, "\"year\":{d}", .{y});
        try out.appendSlice(arena, buf);
    }
    if (md.publisher) |v| {
        try writeJsonKv(arena, out, &first, "publisher", v);
    }
    if (md.language) |v| {
        try writeJsonKv(arena, out, &first, "language", v);
    }
    if (md.isbn) |v| {
        try writeJsonKv(arena, out, &first, "isbn", v);
    }
    if (md.description) |v| {
        try writeJsonKv(arena, out, &first, "description", v);
    }
    if (md.subjects.len > 0) {
        if (!first) try out.append(arena, ',');
        first = false;
        try out.appendSlice(arena, "\"subjects\":[");
        for (md.subjects, 0..) |s, i| {
            if (i > 0) try out.append(arena, ',');
            try writeJsonString(arena, out, s);
        }
        try out.append(arena, ']');
    }
    try out.append(arena, '}');
}

fn writeJsonKv(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try out.append(arena, ',');
    first.* = false;
    try out.append(arena, '"');
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, "\":");
    try writeJsonString(arena, out, value);
}

/// Diagnostic body for the no-match path. The frontend uses this to
/// render a short "Tried N variants — best had 0 docs / no surname
/// match" trailer in the toast or detail panel, so the user can see
/// the failure mode without cracking open the server log.
fn respondNoMatchDiag(
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    q: provider_iface.Query,
    attempts: []const openlibrary.SearchAttempt,
) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"enriched\":false,\"reason\":\"no_match\",\"query\":{");
    try out.appendSlice(arena, "\"isbn\":");
    if (q.isbn) |s| try writeJsonString(arena, &out, s) else try out.appendSlice(arena, "null");
    try out.appendSlice(arena, ",\"title\":");
    if (q.title) |s| try writeJsonString(arena, &out, s) else try out.appendSlice(arena, "null");
    try out.appendSlice(arena, ",\"author\":");
    if (q.author) |s| try writeJsonString(arena, &out, s) else try out.appendSlice(arena, "null");
    try out.appendSlice(arena, "},\"tried\":");
    try writeAttemptsJson(arena, &out, attempts);
    try out.appendSlice(arena, "}");
    try respondJson(request, out.items);
}

fn writeAttemptsJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    attempts: []const openlibrary.SearchAttempt,
) !void {
    try out.append(arena, '[');
    for (attempts, 0..) |a, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"title\":");
        try writeJsonString(arena, out, a.title);
        try out.appendSlice(arena, ",\"author\":");
        try writeJsonString(arena, out, a.author);
        try out.appendSlice(arena, ",\"num_docs\":");
        const nd = try std.fmt.allocPrint(arena, "{d}", .{a.num_docs});
        try out.appendSlice(arena, nd);
        try out.appendSlice(arena, ",\"score\":");
        const sc = try std.fmt.allocPrint(arena, "{d}", .{a.score});
        try out.appendSlice(arena, sc);
        if (a.chosen_title) |t| {
            try out.appendSlice(arena, ",\"chosen_title\":");
            try writeJsonString(arena, out, t);
        }
        if (a.chosen_key) |k| {
            try out.appendSlice(arena, ",\"chosen_key\":");
            try writeJsonString(arena, out, k);
        }
        try out.append(arena, '}');
    }
    try out.append(arena, ']');
}

/// POST /api/enrich/batch — kick off a run. 409 if one is already
/// running; otherwise the worker thread is spawned and we return the
/// initial snapshot so the UI can render the modal immediately.
pub fn handleEnrichBatchStart(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    claimEmptyBody(request);
    const job = ctx.enrich_job orelse
        return errorJson(arena, request, "enrich job state not initialised", "");
    if (job.isRunning()) {
        try request.respond(
            "{\"error\":\"already running\"}\n",
            .{
                .status = .conflict,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            },
        );
        return;
    }
    const worker_alloc = ctx.worker_allocator orelse
        return errorJson(arena, request, "worker allocator unavailable", "");

    const counts = ctx.cat.countEnrichmentBuckets() catch null;
    if (counts) |c| job.total.store(c.eligible, .monotonic);

    enrich_job_mod.spawn(worker_alloc, io, ctx.catalog_path, job) catch |err|
        return errorJson(arena, request, "failed to spawn worker", @errorName(err));

    return handleEnrichBatchStatus(arena, ctx, request);
}

/// GET /api/enrich/batch — current progress. Returned shape:
///   { state, total, processed, ok, no_match, errored,
///     current_id, current_title, started_at, finished_at,
///     buckets: { total, eligible, ok, no_match, errored } }
pub fn handleEnrichBatchStatus(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    const job = ctx.enrich_job orelse
        return errorJson(arena, request, "enrich job state not initialised", "");
    const snap = try job.snapshot(arena);
    const counts = ctx.cat.countEnrichmentBuckets() catch
        catalog_mod.Catalog.EnrichCounts{ .total = 0, .eligible = 0, .ok = 0, .no_match = 0, .errored = 0 };

    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    try out.appendSlice(arena, "\"state\":\"");
    try out.appendSlice(arena, @tagName(snap.state));
    try out.appendSlice(arena, "\",\"total\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.total}));
    try out.appendSlice(arena, ",\"processed\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.processed}));
    try out.appendSlice(arena, ",\"ok\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.ok}));
    try out.appendSlice(arena, ",\"no_match\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.no_match}));
    try out.appendSlice(arena, ",\"errored\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.errored}));
    try out.appendSlice(arena, ",\"current_id\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.current_id}));
    try out.appendSlice(arena, ",\"current_title\":");
    try writeJsonString(arena, &out, snap.current_title);
    try out.appendSlice(arena, ",\"started_at\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.started_at}));
    try out.appendSlice(arena, ",\"finished_at\":");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{snap.finished_at}));
    try out.appendSlice(arena, ",\"buckets\":{");
    try out.appendSlice(arena, try std.fmt.allocPrint(arena, "\"total\":{d},\"eligible\":{d},\"ok\":{d},\"no_match\":{d},\"errored\":{d}", .{
        counts.total, counts.eligible, counts.ok, counts.no_match, counts.errored,
    }));
    try out.appendSlice(arena, "}}");
    try respondJson(request, out.items);
}

/// DELETE /api/enrich/batch — request cancellation. The worker checks
/// the flag between books, so the actual stop lags by up to one
/// in-flight request. Returns the snapshot for the UI to render the
/// "cancelling…" → "canceled" transition.
pub fn handleEnrichBatchCancel(
    arena: std.mem.Allocator,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    claimEmptyBody(request);
    const job = ctx.enrich_job orelse
        return errorJson(arena, request, "enrich job state not initialised", "");
    if (job.isRunning()) job.requestCancel();
    return handleEnrichBatchStatus(arena, ctx, request);
}

fn writeEditionJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    e: openlibrary.Edition,
) !void {
    try out.append(arena, '{');
    var first = true;
    if (e.ol_key) |k| try writeFieldString(arena, out, "ol_key", k, &first);
    if (e.isbn) |v| try writeFieldString(arena, out, "isbn", v, &first);
    if (e.publisher) |v| try writeFieldString(arena, out, "publisher", v, &first);
    if (e.published_year) |y| {
        if (!first) try out.append(arena, ',');
        first = false;
        try out.appendSlice(arena, "\"year\":");
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{y}));
    }
    if (e.language) |v| try writeFieldString(arena, out, "language", v, &first);
    if (e.pages) |p| {
        if (!first) try out.append(arena, ',');
        first = false;
        try out.appendSlice(arena, "\"pages\":");
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{d}", .{p}));
    }
    if (e.cover_url) |v| try writeFieldString(arena, out, "cover_url", v, &first);
    try out.append(arena, '}');
}

fn writeFieldString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    first: *bool,
) !void {
    if (!first.*) try out.append(arena, ',');
    first.* = false;
    try out.append(arena, '"');
    try out.appendSlice(arena, key);
    try out.appendSlice(arena, "\":");
    try writeJsonString(arena, out, value);
}

/// POST /api/books/:id/convert
/// Body: { "to": "epub" | "mobi" | "azw3" | "pdf" }
fn handleConvert(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
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

    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);
    const out_dir = std.fs.path.dirname(book.path) orelse ".";
    const new_path = convert_mod.convert(arena, io, book.path, book.format, dst, out_dir) catch |err|
        return errorJson(arena, request, "convert failed", @errorName(err));

    ctx.cat.updateBookPath(book.id, new_path) catch |err| {
        std.log.warn("convert: updateBookPath({d}, {s}): {s}", .{ book.id, new_path, @errorName(err) });
    };
    ctx.cat.updateBookFormat(book.id, dst) catch |err| {
        std.log.warn("convert: updateBookFormat({d}): {s}", .{ book.id, @errorName(err) });
    };

    if (try cover_store.read(arena, ctx.env, book.id)) |ov| {
        defer arena.free(ov.bytes);
        if (format_registry.forFormat(dst)) |h| {
            h.writeCover(arena, io, new_path, ov.bytes) catch |err| switch (err) {
                error.NotSupported => {},
                else => std.log.warn("convert: writeCover({s}): {s}", .{ new_path, @errorName(err) }),
            };
        }
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"ok\":true,\"path\":");
    try writeJsonString(arena, &out, new_path);
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// POST /api/books/:id/cover
/// Body (one of):
///   { "data_base64": "..." }   inline image bytes
///   { "url": "https://..." }   fetch the image server-side (used for
///                              Open Library "alternative covers")
///
/// Always writes a library-side override file under
/// `$XDG_DATA_HOME/mediastacks/covers/<id>.<ext>` so the chosen cover is
/// served everywhere a `/cover` URL is used. For EPUB we *also* repack
/// the book file so the chosen cover is embedded in the ebook itself;
/// for MOBI/AZW3/PDF the source file is left untouched (libmobi has no
/// cover-write API). The response includes `file_updated: bool` so the
/// frontend can show an "override · file unchanged" affordance.
fn handleCoverUpload(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);

    const body = try readBody(arena, request, 16 * 1024 * 1024);
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return errorJson(arena, request, "bad json", "");
    defer parsed.deinit();
    if (parsed.value != .object) return errorJson(arena, request, "body must be object", "");
    const obj = parsed.value.object;

    var image_bytes: []u8 = &.{};
    if (obj.get("url")) |u| {
        if (u != .string) return errorJson(arena, request, "url must be a string", "");
        var resp = http.get(arena, io, u.string, .{}) catch |err|
            return errorJson(arena, request, "cover fetch failed", @errorName(err));
        defer resp.deinit(arena);
        if (resp.status != 200) {
            return errorJson(arena, request, "cover fetch non-200", try std.fmt.allocPrint(arena, "{d}", .{resp.status}));
        }
        image_bytes = try arena.dupe(u8, resp.body);
    } else if (obj.get("data_base64")) |b64| {
        if (b64 != .string) return errorJson(arena, request, "data_base64 must be a string", "");
        const dec = std.base64.standard.Decoder;
        const decoded_len = dec.calcSizeForSlice(b64.string) catch
            return errorJson(arena, request, "bad base64 length", "");
        image_bytes = try arena.alloc(u8, decoded_len);
        dec.decode(image_bytes, b64.string) catch
            return errorJson(arena, request, "base64 decode failed", "");
    } else {
        return errorJson(arena, request, "need data_base64 or url", "");
    }

    cover_store.write(arena, ctx.env, book.id, image_bytes) catch |err|
        return errorJson(arena, request, "cover override write failed", @errorName(err));
    cover_store.unlinkThumb(arena, ctx.env, book.id) catch {};

    var file_updated = false;
    if (format_registry.forFormat(book.format)) |h| {
        if (h.writeCover(arena, io, book.path, image_bytes)) {
            file_updated = true;
        } else |err| switch (err) {
            error.NotSupported => {},
            else => std.log.warn("cover: writeCover({s}): {s}", .{ book.path, @errorName(err) }),
        }
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"ok\":true,\"override\":true,\"file_updated\":");
    try out.appendSlice(arena, if (file_updated) "true" else "false");
    try out.append(arena, '}');
    try respondJson(request, out.items);
}

/// POST /api/books/:id/reset
/// Discards any manual edits and enriched fields by re-reading the file's
/// embedded metadata. Useful when an enrichment merged the wrong data,
/// or after a user accidentally overwrote a field they wanted to keep.
fn handleReset(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    id: i64,
) !void {
    claimEmptyBody(request);
    _ = io;
    const book = (try ctx.cat.getBookById(arena, id)) orelse return notFound(request);

    const epub_reader = @import("../formats/epub.zig");
    const mobi_reader = @import("../formats/mobi.zig");

    const fresh_md = switch (book.format) {
        .epub => epub_reader.readMetadata(arena, book.path) catch |err|
            return errorJson(arena, request, "re-read failed", @errorName(err)),
        .mobi, .azw3 => mobi_reader.readMetadata(arena, book.path) catch |err|
            return errorJson(arena, request, "re-read failed", @errorName(err)),
        else => return errorJson(arena, request, "reset not supported for this format", @tagName(book.format)),
    };

    cover_store.unlink(arena, ctx.env, book.id) catch {};
    cover_store.unlinkThumb(arena, ctx.env, book.id) catch {};

    try ctx.cat.deleteBook(book.id);
    _ = try ctx.cat.upsertBook(arena, .{
        .path = book.path,
        .sha256 = book.sha256,
        .size = book.size,
        .format = book.format,
        .mtime = book.mtime,
        .metadata = fresh_md,
    });

    const reloaded = (try ctx.cat.getBookByPath(arena, book.path)) orelse return notFound(request);
    var out: std.ArrayList(u8) = .empty;
    try writeBookJson(arena, &out, ctx, reloaded);
    try respondJson(request, out.items);
}

/// /api/books/bulk/<action>
fn handleBulk(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
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
        return bulkEnrich(arena, io, ctx, request, ids_v.array.items);
    }
    if (std.mem.eql(u8, action, "delete")) {
        const remove_files = if (parsed.value.object.get("remove_files")) |v| (v == .bool and v.bool) else false;
        return bulkDelete(arena, ctx, request, ids_v.array.items, remove_files);
    }
    if (std.mem.eql(u8, action, "patch")) {
        const update_v = parsed.value.object.get("update") orelse
            return errorJson(arena, request, "missing 'update'", "");
        if (update_v != .object)
            return errorJson(arena, request, "'update' must be an object", "");
        const append_subjects = if (parsed.value.object.get("append_subjects")) |v| (v == .bool and v.bool) else true;
        return bulkPatch(arena, io, ctx, request, ids_v.array.items, update_v.object, append_subjects);
    }
    return errorJson(arena, request, "unknown bulk action", action);
}

fn bulkPatch(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    ids: []const std.json.Value,
    update: std.json.ObjectMap,
    append_subjects: bool,
) !void {
    var updated: u32 = 0;
    var skipped: u32 = 0;
    var errors: std.ArrayList(u8) = .empty;
    try errors.append(arena, '[');
    var first_err = true;
    for (ids) |id_v| {
        if (id_v != .integer) {
            skipped += 1;
            continue;
        }
        const id = id_v.integer;
        const book = (try ctx.cat.getBookById(arena, id)) orelse {
            skipped += 1;
            continue;
        };
        applyPatchToBook(arena, io, ctx, book, update, append_subjects) catch |e| {
            if (!first_err) try errors.append(arena, ',') else first_err = false;
            try appendFmt(arena, &errors, "{{\"id\":{d},\"error\":", .{id});
            try writeJsonString(arena, &errors, @errorName(e));
            try errors.append(arena, '}');
            continue;
        };
        updated += 1;
    }
    try errors.append(arena, ']');
    const body_str = try std.fmt.allocPrint(
        arena,
        "{{\"updated\":{d},\"skipped\":{d},\"errors\":{s}}}",
        .{ updated, skipped, errors.items },
    );
    try respondJson(request, body_str);
}

fn bulkEnrich(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    ids: []const std.json.Value,
) !void {
    var real_http = http.RealHttpClient{ .io = io };
    var ol = openlibrary.OpenLibrary{ .http_client = real_http.client() };
    const provider = ol.provider();
    var ok: u32 = 0;
    var miss: u32 = 0;
    var err: u32 = 0;
    for (ids) |id_v| {
        if (id_v != .integer) continue;
        const id = id_v.integer;
        const book = (try ctx.cat.getBookById(arena, id)) orelse {
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
        _ = ctx.cat.upsertBook(arena, .{
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
    ctx: *WebContext,
    request: *std.http.Server.Request,
    ids: []const std.json.Value,
    remove_files: bool,
) !void {
    var deleted: u32 = 0;
    for (ids) |id_v| {
        if (id_v != .integer) continue;
        const id = id_v.integer;
        if (remove_files) {
            if (try ctx.cat.getBookById(arena, id)) |b| {
                var path_z: [4096]u8 = undefined;
                const z = std.fmt.bufPrintZ(&path_z, "{s}", .{b.path}) catch continue;
                _ = std.c.unlink(z.ptr);
            }
        }
        cover_store.unlink(arena, ctx.env, id) catch {};
        cover_store.unlinkThumb(arena, ctx.env, id) catch {};
        ctx.cat.deleteBook(id) catch continue;
        deleted += 1;
    }
    const body = try std.fmt.allocPrint(arena, "{{\"deleted\":{d}}}", .{deleted});
    try respondJson(request, body);
}

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
    ctx: *WebContext,
    request: *std.http.Server.Request,
    book: catalog_mod.Book,
) !void {
    const cache_header = std.http.Header{
        .name = "cache-control",
        .value = "public, max-age=31536000, immutable",
    };

    if (cover_store.read(arena, ctx.env, book.id) catch null) |ov| {
        try request.respond(ov.bytes, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = ov.ext.contentType() },
                cache_header,
            },
        });
        return;
    }

    if (cover_store.readThumb(arena, ctx.env, book.id) catch null) |cached| {
        try request.respond(cached.bytes, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = cached.ext.contentType() },
                cache_header,
            },
        });
        return;
    }

    const bytes = cover_mod.extract(arena, io, book.path, book.format) catch {
        try request.respond("no cover\n", .{ .status = .not_found });
        return;
    };
    cover_store.writeThumb(arena, ctx.env, book.id, bytes) catch {};
    const ct: []const u8 = blk: {
        if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) break :blk "image/jpeg";
        if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) break :blk "image/png";
        break :blk "image/jpeg";
    };
    try request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = ct },
            cache_header,
        },
    });
}

fn readBody(
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    max: usize,
) ![]u8 {
    if (request.head.content_length) |len| {
        if (len > max) return error.BodyTooLarge;
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

fn writeBookListJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ctx: *WebContext,
    books: []const catalog_mod.Book,
) !void {
    try out.append(arena, '[');
    for (books, 0..) |b, i| {
        if (i > 0) try out.append(arena, ',');
        try writeBookJson(arena, out, ctx, b);
    }
    try out.append(arena, ']');
}

fn writeBookJson(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ctx: *WebContext,
    b: catalog_mod.Book,
) !void {
    try out.append(arena, '{');
    try writeNumber(arena, out, "id", b.id, true);
    try writeString(arena, out, "path", b.path, false);
    if (b.original_path) |op| {
        if (!std.mem.eql(u8, op, b.path)) {
            try writeString(arena, out, "original_path", op, false);
        }
    }
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

    if (md.subjects.len > 0) {
        try out.appendSlice(arena, ",\"subjects\":[");
        for (md.subjects, 0..) |s, i| {
            if (i > 0) try out.append(arena, ',');
            try writeJsonString(arena, out, s);
        }
        try out.append(arena, ']');
    }

    try out.appendSlice(arena, ",\"read_status\":\"");
    try out.appendSlice(arena, @tagName(b.read_status));
    try out.append(arena, '"');
    if (b.started_at) |t| try writeNumber(arena, out, "started_at", t, false);
    if (b.finished_at) |t| try writeNumber(arena, out, "finished_at", t, false);
    try writeNumber(arena, out, "added_at", b.added_at, false);
    try writeNumber(arena, out, "updated_at", b.updated_at, false);
    if (b.read_percent) |p| {
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"read_percent\":{d:.4}", .{p}));
    }
    if (b.last_read_at) |t| try writeNumber(arena, out, "last_read_at", t, false);

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

    if (cover_store.exists(ctx.env, b.id)) {
        try out.appendSlice(arena, ",\"has_cover_override\":true");
    }

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

pub fn handleJobs(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
) !void {
    switch (request.head.method) {
        .GET => {
            claimEmptyBody(request);
            const list = try jobs_mod.listAll(ctx.cat.db, arena);
            var out: std.ArrayList(u8) = .empty;
            try writeJobsList(arena, &out, list);
            try respondJson(request, out.items);
        },
        .POST => {
            const body = try readBody(arena, request, 16 * 1024);
            var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
                return errorJson(arena, request, "bad_json", "body must be a JSON object");
            defer parsed.deinit();
            if (parsed.value != .object)
                return errorJson(arena, request, "bad_shape", "expected an object");
            const obj = parsed.value.object;
            const name = jsonNonEmptyString(obj, "name") orelse
                return errorJson(arena, request, "missing_field", "name");
            const spec = jsonNonEmptyString(obj, "spec") orelse
                return errorJson(arena, request, "missing_field", "spec");
            const type_str = jsonNonEmptyString(obj, "job_type") orelse
                return errorJson(arena, request, "missing_field", "job_type");
            const jt = jobs_mod.JobType.fromString(type_str) orelse
                return errorJson(arena, request, "bad_job_type", type_str);
            _ = jobs_mod.nextRunAt(spec, 0, clock.nowSeconds()) catch
                return errorJson(arena, request, "bad_spec", spec);
            const enabled = if (obj.get("enabled")) |v| (v == .bool and v.bool) else true;
            const id = jobs_mod.create(ctx.cat.db, arena, .{
                .name = name,
                .spec = spec,
                .job_type = jt,
                .enabled = enabled,
            }) catch |err| return errorJson(arena, request, "create_failed", @errorName(err));
            const job = (try jobs_mod.get(ctx.cat.db, arena, id)) orelse unreachable;
            var out: std.ArrayList(u8) = .empty;
            try writeJobJson(arena, &out, job);
            try respondJson(request, out.items);
        },
        else => return methodNotAllowed(request),
    }
    _ = io;
}

pub fn handleJobSubresource(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *WebContext,
    request: *std.http.Server.Request,
    rest: []const u8,
) !void {
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const id_str = rest[0..slash];
    const tail = if (slash < rest.len) rest[slash + 1 ..] else "";
    const id = std.fmt.parseInt(i64, id_str, 10) catch {
        try request.respond("bad id\n", .{ .status = .bad_request });
        return;
    };

    if (tail.len == 0) {
        switch (request.head.method) {
            .DELETE => {
                claimEmptyBody(request);
                try jobs_mod.delete(ctx.cat.db, id);
                try respondJson(request, "{\"ok\":true}");
                return;
            },
            .PATCH => {
                const body = try readBody(arena, request, 1024);
                var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
                    return errorJson(arena, request, "bad_json", "");
                defer parsed.deinit();
                if (parsed.value != .object)
                    return errorJson(arena, request, "bad_shape", "");
                if (parsed.value.object.get("enabled")) |v| {
                    if (v != .bool) return errorJson(arena, request, "bad_enabled", "must be bool");
                    try jobs_mod.setEnabled(ctx.cat.db, id, v.bool);
                }
                const job = (try jobs_mod.get(ctx.cat.db, arena, id)) orelse return notFound(request);
                var out: std.ArrayList(u8) = .empty;
                try writeJobJson(arena, &out, job);
                try respondJson(request, out.items);
                return;
            },
            else => return methodNotAllowed(request),
        }
    }

    if (std.mem.eql(u8, tail, "run")) {
        if (request.head.method != .POST) return methodNotAllowed(request);
        claimEmptyBody(request);
        const job = (try jobs_mod.get(ctx.cat.db, arena, id)) orelse return notFound(request);
        const ran = job_runner.runJob(arena, io, ctx.cat, job) catch |err|
            return errorJson(arena, request, "run_failed", @errorName(err));
        if (!ran) {
            try respondJson(request, "{\"ok\":false,\"reason\":\"another job is already running\"}");
            return;
        }
        const refreshed = (try jobs_mod.get(ctx.cat.db, arena, id)) orelse unreachable;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "{\"ok\":true,\"job\":");
        try writeJobJson(arena, &out, refreshed);
        try out.append(arena, '}');
        try respondJson(request, out.items);
        return;
    }

    try request.respond("not found\n", .{ .status = .not_found });
}

fn writeJobsList(arena: std.mem.Allocator, out: *std.ArrayList(u8), list: []jobs_mod.Job) !void {
    try out.append(arena, '[');
    for (list, 0..) |j, i| {
        if (i > 0) try out.append(arena, ',');
        try writeJobJson(arena, out, j);
    }
    try out.append(arena, ']');
}

fn writeJobJson(arena: std.mem.Allocator, out: *std.ArrayList(u8), j: jobs_mod.Job) !void {
    try out.append(arena, '{');
    try writeNumber(arena, out, "id", j.id, true);
    try writeString(arena, out, "name", j.name, false);
    try writeString(arena, out, "spec", j.spec, false);
    try writeString(arena, out, "job_type", j.job_type.toString(), false);
    try out.appendSlice(arena, ",\"enabled\":");
    try out.appendSlice(arena, if (j.enabled) "true" else "false");
    try writeNumber(arena, out, "created_at", j.created_at, false);
    try writeNumber(arena, out, "updated_at", j.updated_at, false);
    if (j.last_run_at) |t| try writeNumber(arena, out, "last_run_at", t, false);
    if (j.last_run_status) |s| try writeString(arena, out, "last_run_status", s, false);
    if (j.last_run_summary) |s| try writeString(arena, out, "last_run_summary", s, false);
    try writeNumber(arena, out, "next_run_at", j.next_run_at, false);
    try out.append(arena, '}');
}

fn testTempCatalogPath(buf: []u8, suffix: []const u8) ![]u8 {
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();
    return std.fmt.bufPrint(buf, "/tmp/mediastacks-web-{s}-{d}-{d}.db", .{ suffix, pid, stamp });
}

fn testSeedBook(
    cat: *catalog_mod.Catalog,
    alloc: std.mem.Allocator,
    path: []const u8,
    title: []const u8,
    author_sort: []const u8,
) !i64 {
    const last_idx = std.mem.lastIndexOfScalar(u8, author_sort, ',') orelse author_sort.len;
    const author = meta.Author{
        .last = author_sort[0..last_idx],
        .first = if (last_idx < author_sort.len) std.mem.trim(u8, author_sort[last_idx + 1 ..], " ") else "",
        .sort = author_sort,
    };
    return cat.upsertBook(alloc, .{
        .path = path,
        .sha256 = "abcdef",
        .size = 1024,
        .format = .epub,
        .mtime = 0,
        .metadata = .{
            .title = title,
            .authors = &[_]meta.Author{author},
            .source = .embedded,
            .confidence = 0.9,
        },
    });
}

test "applyImport: matches a row by path and updates non-empty fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var name_buf: [128]u8 = undefined;
    const db_path = try testTempCatalogPath(&name_buf, "import-match");
    var path_z: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&path_z, "{s}", .{db_path});
    defer _ = std.c.unlink(z.ptr);

    var cat = try catalog_mod.Catalog.open(db_path);
    defer cat.close();
    _ = try testSeedBook(&cat, arena, "/lib/foo.epub", "Original Title", "Doe, Jane");

    const payload =
        \\[{"path":"/lib/foo.epub","title":"Updated Title","year":2024,"isbn":"9780000000001"}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{});
    defer parsed.deinit();

    const result = try applyImport(arena, &cat, parsed.value.array.items);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
    try std.testing.expectEqual(@as(usize, 1), result.updated);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.error_count);

    const fetched = (try cat.getBookByPath(arena, "/lib/foo.epub")) orelse return error.MissingRow;
    try std.testing.expectEqualStrings("Updated Title", fetched.metadata.title.?);
    try std.testing.expectEqual(@as(u16, 2024), fetched.metadata.published_year.?);
    try std.testing.expectEqualStrings("9780000000001", fetched.metadata.isbn.?);
}

test "applyImport: rows with unknown path are skipped, not errored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var name_buf: [128]u8 = undefined;
    const db_path = try testTempCatalogPath(&name_buf, "import-skip");
    var path_z: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&path_z, "{s}", .{db_path});
    defer _ = std.c.unlink(z.ptr);

    var cat = try catalog_mod.Catalog.open(db_path);
    defer cat.close();

    const payload =
        \\[
        \\  {"path":"/does/not/exist","title":"Ghost"},
        \\  {"no_path_key":"oops"},
        \\  {"path":123},
        \\  "not_even_an_object"
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{});
    defer parsed.deinit();

    const result = try applyImport(arena, &cat, parsed.value.array.items);
    try std.testing.expectEqual(@as(usize, 0), result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.updated);
    try std.testing.expectEqual(@as(usize, 4), result.skipped);
    try std.testing.expectEqual(@as(usize, 0), result.error_count);
    try std.testing.expectEqualStrings("[]", result.errors_json);
}

test "applyImport: empty-string fields don't overwrite existing values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var name_buf: [128]u8 = undefined;
    const db_path = try testTempCatalogPath(&name_buf, "import-empty");
    var path_z: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&path_z, "{s}", .{db_path});
    defer _ = std.c.unlink(z.ptr);

    var cat = try catalog_mod.Catalog.open(db_path);
    defer cat.close();
    _ = try testSeedBook(&cat, arena, "/lib/bar.epub", "Keep Me", "Smith, John");

    const payload =
        \\[{"path":"/lib/bar.epub","title":"","author":"","isbn":""}]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, payload, .{});
    defer parsed.deinit();

    const result = try applyImport(arena, &cat, parsed.value.array.items);
    try std.testing.expectEqual(@as(usize, 1), result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.updated);
    const fetched = (try cat.getBookByPath(arena, "/lib/bar.epub")) orelse return error.MissingRow;
    try std.testing.expectEqualStrings("Keep Me", fetched.metadata.title.?);
}

test "writeCsvExport: header line plus one row per book" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const author = meta.Author{ .last = "Verne", .first = "Jules", .sort = "Verne, Jules" };
    const books = [_]catalog_mod.Book{.{
        .id = 7,
        .path = "/lib/around-the-world.epub",
        .sha256 = "deadbeef",
        .size = 12345,
        .format = .epub,
        .mtime = 0,
        .metadata = .{
            .title = "Around the World",
            .authors = @constCast(&[_]meta.Author{author}),
            .published_year = 1873,
            .isbn = "9780000000002",
            .source = .embedded,
            .confidence = 0.9,
        },
        .added_at = 100,
        .updated_at = 200,
    }};

    var out: std.ArrayList(u8) = .empty;
    try writeCsvExport(arena, &out, &books);

    try std.testing.expect(std.mem.startsWith(u8, out.items, "id,path,format,size,sha256,title,author_sort,year,isbn,series,series_index,language,publisher,read_status,added_at,updated_at\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "7,/lib/around-the-world.epub,epub,12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Around the World") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, ",1873,") != null);
}

test "writeCsvField: quotes values containing commas and newlines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeCsvField(arena, &out, "hello, world");
    try std.testing.expectEqualStrings("\"hello, world\"", out.items);

    out = .empty;
    try writeCsvField(arena, &out, "she said \"hi\"");
    try std.testing.expectEqualStrings("\"she said \"\"hi\"\"\"", out.items);

    out = .empty;
    try writeCsvField(arena, &out, "no-special-chars");
    try std.testing.expectEqualStrings("no-special-chars", out.items);
}

test "catalog: countEnrichmentBuckets matches seeded state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var name_buf: [128]u8 = undefined;
    const db_path = try testTempCatalogPath(&name_buf, "buckets");
    var path_z: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&path_z, "{s}", .{db_path});
    defer _ = std.c.unlink(z.ptr);

    var cat = try catalog_mod.Catalog.open(db_path);
    defer cat.close();
    const id_a = try testSeedBook(&cat, arena, "/lib/a.epub", "A", "X, Y");
    const id_b = try testSeedBook(&cat, arena, "/lib/b.epub", "B", "X, Y");
    _ = try testSeedBook(&cat, arena, "/lib/c.epub", "C", "X, Y");

    try cat.setEnrichStatus(id_a, .ok);
    try cat.setEnrichStatus(id_b, .no_match);

    const counts = try cat.countEnrichmentBuckets();
    try std.testing.expectEqual(@as(u32, 3), counts.total);
    try std.testing.expectEqual(@as(u32, 1), counts.ok);
    try std.testing.expectEqual(@as(u32, 1), counts.no_match);
}
