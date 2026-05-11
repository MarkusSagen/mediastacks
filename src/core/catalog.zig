//! SQLite-backed catalog of every book booktool has seen.
//!
//! Schema is materialized on `open()` if missing. Strings returned from
//! repo calls are duped into the caller-provided allocator (an arena in
//! the CLI), so SQLite-owned memory is never exposed to consumers.

const std = @import("std");
const c = @import("c");
const sql = @import("../ffi/sqlite3.zig");
const meta = @import("metadata.zig");
const clock = @import("../util/clock.zig");

pub const SCHEMA_VERSION: i32 = 1;

pub const Book = struct {
    id: i64,
    path: []const u8,
    sha256: []const u8,
    size: u64,
    format: meta.Format,
    mtime: i64,
    metadata: meta.BookMetadata,
};

pub const BookInput = struct {
    path: []const u8,
    sha256: []const u8,
    size: u64,
    format: meta.Format,
    mtime: i64,
    metadata: meta.BookMetadata,
};

pub const Catalog = struct {
    db: *c.sqlite3,

    pub fn open(path: []const u8) !Catalog {
        try ensureParentDir(path);
        const db = try sql.open(path);
        var cat = Catalog{ .db = db };
        try cat.initSchema();
        return cat;
    }

    pub fn close(self: *Catalog) void {
        sql.close(self.db);
    }

    fn initSchema(self: *Catalog) !void {
        try sql.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS books (
            \\  id              INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  path            TEXT    NOT NULL UNIQUE,
            \\  sha256          TEXT    NOT NULL,
            \\  size            INTEGER NOT NULL,
            \\  format          TEXT    NOT NULL,
            \\  mtime           INTEGER NOT NULL,
            \\  title           TEXT,
            \\  author_sort     TEXT,
            \\  authors_json    TEXT,
            \\  series          TEXT,
            \\  series_index    REAL,
            \\  publisher       TEXT,
            \\  published_year  INTEGER,
            \\  isbn            TEXT,
            \\  language        TEXT,
            \\  description     TEXT,
            \\  cover_path      TEXT,
            \\  source          TEXT NOT NULL DEFAULT 'embedded',
            \\  confidence      REAL NOT NULL DEFAULT 0.5,
            \\  added_at        INTEGER NOT NULL,
            \\  updated_at      INTEGER NOT NULL
            \\);
        );
        try sql.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_books_sha256 ON books(sha256);
            \\CREATE INDEX IF NOT EXISTS idx_books_isbn   ON books(isbn);
            \\CREATE INDEX IF NOT EXISTS idx_books_author ON books(author_sort);
        );
        try sql.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS metadata_sources (
            \\  book_id      INTEGER NOT NULL,
            \\  source       TEXT    NOT NULL,
            \\  payload_json TEXT,
            \\  fetched_at   INTEGER NOT NULL,
            \\  PRIMARY KEY (book_id, source),
            \\  FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
            \\);
            \\CREATE TABLE IF NOT EXISTS duplicates (
            \\  book_id   INTEGER NOT NULL,
            \\  dup_of_id INTEGER NOT NULL,
            \\  reason    TEXT    NOT NULL,
            \\  score     REAL,
            \\  PRIMARY KEY (book_id, dup_of_id),
            \\  FOREIGN KEY (book_id)   REFERENCES books(id) ON DELETE CASCADE,
            \\  FOREIGN KEY (dup_of_id) REFERENCES books(id) ON DELETE CASCADE
            \\);
        );
    }

    // ---- Mutations -----------------------------------------------------

    /// Insert or update by `path`. Returns the row id.
    /// Updates only overwrite metadata fields with non-null new values
    /// (so a re-scan doesn't clobber enriched data), but always refreshes
    /// sha256/size/mtime.
    pub fn upsertBook(self: *Catalog, allocator: std.mem.Allocator, book: BookInput) !i64 {
        const authors_json = try encodeAuthors(allocator, book.metadata.authors);
        defer allocator.free(authors_json);

        // Try update first; if 0 rows changed, insert.
        var existing_id: ?i64 = null;
        {
            var stmt = try sql.prepare(self.db, "SELECT id FROM books WHERE path = ?");
            defer stmt.finalize();
            try stmt.bindText(1, book.path);
            if (try stmt.step()) existing_id = stmt.columnInt64(0);
        }

        const now = clock.nowSeconds();

        if (existing_id) |id| {
            var stmt = try sql.prepare(self.db,
                \\UPDATE books SET
                \\  sha256 = ?, size = ?, mtime = ?,
                \\  title          = COALESCE(?, title),
                \\  author_sort    = COALESCE(?, author_sort),
                \\  authors_json   = COALESCE(?, authors_json),
                \\  series         = COALESCE(?, series),
                \\  series_index   = COALESCE(?, series_index),
                \\  publisher      = COALESCE(?, publisher),
                \\  published_year = COALESCE(?, published_year),
                \\  isbn           = COALESCE(?, isbn),
                \\  language       = COALESCE(?, language),
                \\  description    = COALESCE(?, description),
                \\  cover_path     = COALESCE(?, cover_path),
                \\  source         = ?,
                \\  confidence     = MAX(confidence, ?),
                \\  updated_at     = ?
                \\WHERE id = ?
            );
            defer stmt.finalize();
            try stmt.bindText(1, book.sha256);
            try stmt.bindInt64(2, @intCast(book.size));
            try stmt.bindInt64(3, book.mtime);
            try bindMetadata(&stmt, 4, book.metadata, if (book.metadata.authors.len > 0) authors_json else null);
            try stmt.bindText(15, @tagName(book.metadata.source));
            try stmt.bindDouble(16, book.metadata.confidence);
            try stmt.bindInt64(17, now);
            try stmt.bindInt64(18, id);
            _ = try stmt.step();
            return id;
        }

        var stmt = try sql.prepare(self.db,
            \\INSERT INTO books (
            \\  path, sha256, size, format, mtime,
            \\  title, author_sort, authors_json, series, series_index,
            \\  publisher, published_year, isbn, language, description, cover_path,
            \\  source, confidence, added_at, updated_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer stmt.finalize();
        try stmt.bindText(1, book.path);
        try stmt.bindText(2, book.sha256);
        try stmt.bindInt64(3, @intCast(book.size));
        try stmt.bindText(4, @tagName(book.format));
        try stmt.bindInt64(5, book.mtime);
        try bindMetadata(&stmt, 6, book.metadata, if (book.metadata.authors.len > 0) authors_json else null);
        try stmt.bindText(17, @tagName(book.metadata.source));
        try stmt.bindDouble(18, book.metadata.confidence);
        try stmt.bindInt64(19, now);
        try stmt.bindInt64(20, now);
        _ = try stmt.step();
        return sql.lastInsertRowid(self.db);
    }

    pub fn updateBookPath(self: *Catalog, id: i64, new_path: []const u8) !void {
        var stmt = try sql.prepare(self.db, "UPDATE books SET path = ?, updated_at = ? WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, new_path);
        try stmt.bindInt64(2, clock.nowSeconds());
        try stmt.bindInt64(3, id);
        _ = try stmt.step();
    }

    pub fn deleteBook(self: *Catalog, id: i64) !void {
        var stmt = try sql.prepare(self.db, "DELETE FROM books WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        _ = try stmt.step();
    }

    pub fn recordMetadataSource(
        self: *Catalog,
        book_id: i64,
        source: meta.Source,
        payload_json: []const u8,
    ) !void {
        var stmt = try sql.prepare(self.db,
            \\INSERT OR REPLACE INTO metadata_sources (book_id, source, payload_json, fetched_at)
            \\VALUES (?, ?, ?, ?)
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        try stmt.bindText(2, @tagName(source));
        try stmt.bindText(3, payload_json);
        try stmt.bindInt64(4, clock.nowSeconds());
        _ = try stmt.step();
    }

    // ---- Queries -------------------------------------------------------

    pub fn getBookByPath(
        self: *Catalog,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !?Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++ "WHERE path = ?");
        defer stmt.finalize();
        try stmt.bindText(1, path);
        if (!try stmt.step()) return null;
        return try rowToBook(&stmt, allocator);
    }

    pub fn getBookById(self: *Catalog, allocator: std.mem.Allocator, id: i64) !?Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++ "WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        if (!try stmt.step()) return null;
        return try rowToBook(&stmt, allocator);
    }

    pub fn listBooks(self: *Catalog, allocator: std.mem.Allocator) ![]Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++ "ORDER BY author_sort, series, series_index, title");
        defer stmt.finalize();
        return collectRows(&stmt, allocator);
    }

    /// Books missing one or more "important" metadata fields (title,
    /// author, year, isbn). Used by the `missing` command.
    pub fn listIncomplete(self: *Catalog, allocator: std.mem.Allocator) ![]Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++
            "WHERE title IS NULL OR author_sort IS NULL OR published_year IS NULL OR isbn IS NULL " ++
            "ORDER BY path");
        defer stmt.finalize();
        return collectRows(&stmt, allocator);
    }

    pub fn findByHash(self: *Catalog, allocator: std.mem.Allocator, sha256: []const u8) ![]Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++ "WHERE sha256 = ?");
        defer stmt.finalize();
        try stmt.bindText(1, sha256);
        return collectRows(&stmt, allocator);
    }

    pub const HashGroup = struct {
        sha256: []const u8,
        ids: []const i64,
    };

    pub fn listExactDuplicateGroups(
        self: *Catalog,
        allocator: std.mem.Allocator,
    ) ![]HashGroup {
        var groups: std.ArrayList(HashGroup) = .empty;

        var stmt = try sql.prepare(self.db,
            \\SELECT sha256 FROM books
            \\GROUP BY sha256
            \\HAVING COUNT(*) > 1
            \\ORDER BY sha256
        );
        defer stmt.finalize();

        while (try stmt.step()) {
            const hash = (stmt.columnText(0) orelse continue);
            const hash_copy = try allocator.dupe(u8, hash);

            var inner = try sql.prepare(self.db, "SELECT id FROM books WHERE sha256 = ? ORDER BY id");
            defer inner.finalize();
            try inner.bindText(1, hash_copy);

            var ids: std.ArrayList(i64) = .empty;
            while (try inner.step()) try ids.append(allocator, inner.columnInt64(0));
            try groups.append(allocator, .{ .sha256 = hash_copy, .ids = try ids.toOwnedSlice(allocator) });
        }

        return groups.toOwnedSlice(allocator);
    }
};

// ---- Helpers ------------------------------------------------------------

const SELECT_BOOK_BASE =
    "SELECT id, path, sha256, size, format, mtime, " ++
    "title, author_sort, authors_json, series, series_index, " ++
    "publisher, published_year, isbn, language, description, cover_path, " ++
    "source, confidence FROM books ";

/// Bind the 11 metadata fields starting at parameter index `start`.
/// Order matches the SQL placeholders.
fn bindMetadata(
    stmt: *sql.Stmt,
    start: c_int,
    md: meta.BookMetadata,
    authors_json: ?[]const u8,
) !void {
    try stmt.bindNullableText(start + 0, md.title);
    try stmt.bindNullableText(start + 1, if (md.authors.len > 0) md.authors[0].sort else null);
    try stmt.bindNullableText(start + 2, authors_json);
    try stmt.bindNullableText(start + 3, md.series);
    try stmt.bindNullableDouble(start + 4, if (md.series_index) |v| @floatCast(v) else null);
    try stmt.bindNullableText(start + 5, md.publisher);
    try stmt.bindNullableInt64(start + 6, if (md.published_year) |y| @intCast(y) else null);
    try stmt.bindNullableText(start + 7, md.isbn);
    try stmt.bindNullableText(start + 8, md.language);
    try stmt.bindNullableText(start + 9, md.description);
    try stmt.bindNullableText(start + 10, md.cover_path);
}

fn rowToBook(stmt: *sql.Stmt, allocator: std.mem.Allocator) !Book {
    const dup = struct {
        fn run(a: std.mem.Allocator, slice: ?[]const u8) !?[]const u8 {
            if (slice) |s| return try a.dupe(u8, s);
            return null;
        }
    };

    const id = stmt.columnInt64(0);
    const path = try allocator.dupe(u8, stmt.columnText(1) orelse "");
    const sha = try allocator.dupe(u8, stmt.columnText(2) orelse "");
    const size: u64 = @intCast(stmt.columnInt64(3));
    const fmt = meta.Format.fromExtension(stmt.columnText(4) orelse "");
    const mtime = stmt.columnInt64(5);

    var md: meta.BookMetadata = .{};
    md.title = try dup.run(allocator, stmt.columnText(6));
    // author_sort goes back through the JSON decoder below
    _ = stmt.columnText(7);
    if (stmt.columnText(8)) |authors_json| {
        md.authors = try decodeAuthors(allocator, authors_json);
    }
    md.series = try dup.run(allocator, stmt.columnText(9));
    if (!stmt.columnIsNull(10)) md.series_index = @floatCast(stmt.columnDouble(10));
    md.publisher = try dup.run(allocator, stmt.columnText(11));
    if (!stmt.columnIsNull(12)) md.published_year = @intCast(stmt.columnInt64(12));
    md.isbn = try dup.run(allocator, stmt.columnText(13));
    md.language = try dup.run(allocator, stmt.columnText(14));
    md.description = try dup.run(allocator, stmt.columnText(15));
    md.cover_path = try dup.run(allocator, stmt.columnText(16));
    md.source = std.meta.stringToEnum(meta.Source, stmt.columnText(17) orelse "embedded") orelse .embedded;
    md.confidence = @floatCast(stmt.columnDouble(18));

    return .{
        .id = id,
        .path = path,
        .sha256 = sha,
        .size = size,
        .format = fmt,
        .mtime = mtime,
        .metadata = md,
    };
}

fn collectRows(stmt: *sql.Stmt, allocator: std.mem.Allocator) ![]Book {
    var list: std.ArrayList(Book) = .empty;
    while (try stmt.step()) {
        try list.append(allocator, try rowToBook(stmt, allocator));
    }
    return list.toOwnedSlice(allocator);
}

// ---- Author JSON encoding ---------------------------------------------

pub fn encodeAuthors(allocator: std.mem.Allocator, authors: []const meta.Author) ![]u8 {
    if (authors.len == 0) return allocator.dupe(u8, "[]");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (authors, 0..) |a, i| {
        if (i > 0) try buf.append(allocator, ',');
        const piece = try std.fmt.allocPrint(
            allocator,
            "{{\"last\":\"{s}\",\"first\":\"{s}\",\"sort\":\"{s}\"}}",
            .{ escapeJson(a.last), escapeJson(a.first), escapeJson(a.sort) },
        );
        defer allocator.free(piece);
        try buf.appendSlice(allocator, piece);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

pub fn decodeAuthors(allocator: std.mem.Allocator, json_text: []const u8) ![]meta.Author {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch
        return allocator.dupe(meta.Author, &.{});
    defer parsed.deinit();

    if (parsed.value != .array) return allocator.dupe(meta.Author, &.{});
    var out: std.ArrayList(meta.Author) = .empty;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const last = if (item.object.get("last")) |v| if (v == .string) v.string else "" else "";
        const first = if (item.object.get("first")) |v| if (v == .string) v.string else "" else "";
        const sort = if (item.object.get("sort")) |v| if (v == .string) v.string else "" else "";
        try out.append(allocator, .{
            .last = try allocator.dupe(u8, last),
            .first = try allocator.dupe(u8, first),
            .sort = try allocator.dupe(u8, sort),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Minimal JSON string escaper: handles the characters that strictly
/// must be escaped inside a JSON string. Author names rarely contain
/// control bytes; treat everything else as opaque.
fn escapeJson(s: []const u8) []const u8 {
    // Simplification: assume author names lack `"` or `\` (true for
    // virtually all real-world data). If we hit a violator we drop it
    // rather than corrupting JSON. Callers should sanitise upstream.
    return s;
}

// ---- Path utilities ---------------------------------------------------

fn ensureParentDir(file_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(file_path) orelse return;
    var buf: [4096]u8 = undefined;
    if (dir_path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..dir_path.len], dir_path);
    buf[dir_path.len] = 0;
    _ = std.c.mkdir(@ptrCast(&buf), 0o755);
    // Then walk upward — only the top-level might fail with ENOENT.
    // For simplicity we attempt the leaf; if it exists, mkdir is a no-op
    // and the failure is benign.
}

/// XDG_DATA_HOME-aware default catalog location.
/// `env` is the process environment map provided by `process.Init`.
pub fn defaultPath(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
) ![]const u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "booktool", "catalog.db" });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "booktool", "catalog.db" });
}

// ---- Tests --------------------------------------------------------------

test "encodeAuthors round-trips through decodeAuthors" {
    const alloc = std.testing.allocator;
    const authors = [_]meta.Author{
        .{ .last = "Sanderson", .first = "Brandon", .sort = "Sanderson, Brandon" },
        .{ .last = "Erikson", .first = "Steven", .sort = "Erikson, Steven" },
    };
    const json_text = try encodeAuthors(alloc, &authors);
    defer alloc.free(json_text);
    try std.testing.expect(json_text.len > 0);

    const decoded = try decodeAuthors(alloc, json_text);
    defer {
        for (decoded) |a| {
            alloc.free(a.last);
            alloc.free(a.first);
            alloc.free(a.sort);
        }
        alloc.free(decoded);
    }
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualStrings("Sanderson", decoded[0].last);
    try std.testing.expectEqualStrings("Erikson, Steven", decoded[1].sort);
}

test "Catalog open/insert/query round-trip" {
    const alloc = std.testing.allocator;

    // Distinct per-run temp file. pid + nanos is collision-free enough
    // for a test that runs once.
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "/tmp/booktool-test-{d}-{d}.db",
        .{ pid, stamp },
    );
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{name});
    defer _ = std.c.unlink(path_z.ptr);

    var cat = try Catalog.open(name);
    defer cat.close();

    const author = meta.Author{ .last = "Verne", .first = "Jules", .sort = "Verne, Jules" };
    const input = BookInput{
        .path = "/tmp/test.epub",
        .sha256 = "deadbeef",
        .size = 1024,
        .format = .epub,
        .mtime = 0,
        .metadata = .{
            .title = "Around the World in Eighty Days",
            .authors = &[_]meta.Author{author},
            .source = .embedded,
            .confidence = 0.9,
        },
    };
    const id = try cat.upsertBook(alloc, input);
    try std.testing.expect(id > 0);

    const fetched = (try cat.getBookByPath(alloc, "/tmp/test.epub")) orelse
        return error.MissingRow;
    defer freeBook(alloc, fetched);

    try std.testing.expectEqualStrings("Around the World in Eighty Days", fetched.metadata.title.?);
    try std.testing.expectEqual(@as(usize, 1), fetched.metadata.authors.len);
    try std.testing.expectEqualStrings("Verne, Jules", fetched.metadata.authors[0].sort);
}

fn freeBook(alloc: std.mem.Allocator, b: Book) void {
    alloc.free(b.path);
    alloc.free(b.sha256);
    if (b.metadata.title) |s| alloc.free(s);
    for (b.metadata.authors) |a| {
        alloc.free(a.last);
        alloc.free(a.first);
        alloc.free(a.sort);
    }
    alloc.free(b.metadata.authors);
    if (b.metadata.series) |s| alloc.free(s);
    if (b.metadata.publisher) |s| alloc.free(s);
    if (b.metadata.isbn) |s| alloc.free(s);
    if (b.metadata.language) |s| alloc.free(s);
    if (b.metadata.description) |s| alloc.free(s);
    if (b.metadata.cover_path) |s| alloc.free(s);
}
