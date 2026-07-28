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

pub const SCHEMA_VERSION: i32 = 2;

pub const ReadStatus = enum {
    unread,
    reading,
    finished,

    pub fn fromStr(s: []const u8) ReadStatus {
        if (std.mem.eql(u8, s, "reading")) return .reading;
        if (std.mem.eql(u8, s, "finished")) return .finished;
        return .unread;
    }
};

pub const Book = struct {
    id: i64,
    path: []const u8,
    sha256: []const u8,
    size: u64,
    format: meta.Format,
    mtime: i64,
    metadata: meta.BookMetadata,
    read_status: ReadStatus = .unread,
    started_at: ?i64 = null,
    finished_at: ?i64 = null,
    added_at: i64 = 0,
    updated_at: i64 = 0,
    /// Library source this book was ingested from. Null when added
    /// directly via `booktool scan PATH` (no enrolled source).
    source_id: ?i64 = null,
    /// Set by rescan when the file at `path` no longer exists. Cleared
    /// if a later scan finds it again.
    missing_at: ?i64 = null,
    /// Last-read fraction (0.0 – 1.0) and timestamp, mirrored from
    /// `read_locations` so the gallery can render a "Resume (NN%)"
    /// affordance without a second request per card.
    read_percent: ?f32 = null,
    last_read_at: ?i64 = null,
    /// Path the file had when first added to the catalog. Preserved
    /// across `updateBookPath` (rename) so the user can always see
    /// where a book *came from* relative to where it sits now.
    original_path: ?[]const u8 = null,
};

pub const ReadLocation = struct {
    book_id: i64,
    /// Opaque string interpreted by the frontend based on book.format
    /// (EPUB CFI for foliate; decimal page number for pdf.js).
    location: []const u8,
    percent: ?f32,
    updated_at: i64,
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
            \\  updated_at      INTEGER NOT NULL,
            \\  subjects_json   TEXT,
            \\  read_status     TEXT NOT NULL DEFAULT 'unread',
            \\  started_at      INTEGER,
            \\  finished_at     INTEGER
            \\);
        );
        try addColumnIfMissing(self.db, "subjects_json", "TEXT");
        try addColumnIfMissing(self.db, "read_status", "TEXT NOT NULL DEFAULT 'unread'");
        try addColumnIfMissing(self.db, "started_at", "INTEGER");
        try addColumnIfMissing(self.db, "finished_at", "INTEGER");
        try addColumnIfMissing(self.db, "source_id", "INTEGER REFERENCES library_sources(id) ON DELETE SET NULL");
        try addColumnIfMissing(self.db, "missing_at", "INTEGER");
        try addColumnIfMissing(self.db, "enrich_status", "TEXT");
        try addColumnIfMissing(self.db, "enrich_attempted_at", "INTEGER");
        try addColumnIfMissing(self.db, "original_path", "TEXT");
        try sql.exec(self.db, "UPDATE books SET original_path = path WHERE original_path IS NULL");
        try sql.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS tags (
            \\  id         INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name       TEXT    NOT NULL UNIQUE COLLATE NOCASE,
            \\  created_at INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS book_tags (
            \\  book_id   INTEGER NOT NULL,
            \\  tag_id    INTEGER NOT NULL,
            \\  added_at  INTEGER NOT NULL,
            \\  PRIMARY KEY (book_id, tag_id),
            \\  FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE,
            \\  FOREIGN KEY (tag_id)  REFERENCES tags(id)  ON DELETE CASCADE
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_book_tags_book ON book_tags(book_id);
            \\CREATE INDEX IF NOT EXISTS idx_book_tags_tag  ON book_tags(tag_id);
        );

        try sql.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS catalog_changes (
            \\  id         INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  book_id    INTEGER NOT NULL,
            \\  field      TEXT    NOT NULL,
            \\  old_value  TEXT,
            \\  new_value  TEXT,
            \\  source     TEXT    NOT NULL, -- 'embedded' | 'openlibrary' | 'manual' | 'derived'
            \\  changed_at INTEGER NOT NULL,
            \\  FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_changes_book_id ON catalog_changes(book_id);
            \\CREATE INDEX IF NOT EXISTS idx_changes_at ON catalog_changes(changed_at DESC);
        );
        try sql.exec(self.db,
            \\CREATE INDEX IF NOT EXISTS idx_books_sha256 ON books(sha256);
            \\CREATE INDEX IF NOT EXISTS idx_books_isbn   ON books(isbn);
            \\CREATE INDEX IF NOT EXISTS idx_books_author ON books(author_sort);
            \\CREATE INDEX IF NOT EXISTS idx_books_year   ON books(published_year);
            \\CREATE INDEX IF NOT EXISTS idx_books_series ON books(series);
            \\CREATE INDEX IF NOT EXISTS idx_books_status ON books(read_status);
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
            \\CREATE TABLE IF NOT EXISTS library_sources (
            \\  id              INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  path            TEXT    NOT NULL UNIQUE,
            \\  name            TEXT,
            \\  added_at        INTEGER NOT NULL,
            \\  last_scanned_at INTEGER,
            \\  last_seen       INTEGER NOT NULL DEFAULT 0,
            \\  last_added      INTEGER NOT NULL DEFAULT 0,
            \\  last_missing    INTEGER NOT NULL DEFAULT 0,
            \\  last_error      TEXT,
            \\  scanning        INTEGER NOT NULL DEFAULT 0,
            \\  scan_seen       INTEGER NOT NULL DEFAULT 0,
            \\  scan_total      INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_books_source  ON books(source_id);
            \\CREATE INDEX IF NOT EXISTS idx_books_missing ON books(missing_at);
            \\CREATE TABLE IF NOT EXISTS read_locations (
            \\  book_id    INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
            \\  location   TEXT    NOT NULL,
            \\  percent    REAL,
            \\  updated_at INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS reading_sessions (
            \\  id         INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  book_id    INTEGER NOT NULL,
            \\  started_at INTEGER NOT NULL,
            \\  ended_at   INTEGER NOT NULL,
            \\  start_pct  REAL,
            \\  end_pct    REAL,
            \\  FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_sessions_book ON reading_sessions(book_id, started_at);
        );
        try addColumnIfMissingOn(self.db, "library_sources", "last_error", "TEXT");
        try addColumnIfMissingOn(self.db, "library_sources", "scanning", "INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissingOn(self.db, "library_sources", "scan_seen", "INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissingOn(self.db, "library_sources", "scan_total", "INTEGER NOT NULL DEFAULT 0");
        try sql.exec(self.db, "UPDATE library_sources SET scanning = 0 WHERE scanning = 1");

        try sql.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS scheduled_jobs (
            \\  id                INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name              TEXT    NOT NULL,
            \\  spec              TEXT    NOT NULL,
            \\  job_type          TEXT    NOT NULL,
            \\  params_json       TEXT,
            \\  enabled           INTEGER NOT NULL DEFAULT 1,
            \\  created_at        INTEGER NOT NULL,
            \\  updated_at        INTEGER NOT NULL,
            \\  last_run_at       INTEGER,
            \\  last_run_status   TEXT,
            \\  last_run_summary  TEXT,
            \\  next_run_at       INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_jobs_next_run ON scheduled_jobs(next_run_at) WHERE enabled = 1;
        );
        try sql.exec(self.db, "UPDATE scheduled_jobs SET last_run_status = 'error' WHERE last_run_status = 'running'");
    }

    /// Insert or update by `path`. Returns the row id.
    /// Updates only overwrite metadata fields with non-null new values
    /// (so a re-scan doesn't clobber enriched data), but always refreshes
    /// sha256/size/mtime.
    pub fn upsertBook(self: *Catalog, allocator: std.mem.Allocator, book: BookInput) !i64 {
        const authors_json = try encodeAuthors(allocator, book.metadata.authors);
        defer allocator.free(authors_json);
        const subjects_json: ?[]const u8 = if (book.metadata.subjects.len > 0)
            try encodeStringArray(allocator, book.metadata.subjects)
        else
            null;
        defer if (subjects_json) |s| allocator.free(s);

        var existing_id: ?i64 = null;
        {
            var stmt = try sql.prepare(self.db, "SELECT id FROM books WHERE path = ?");
            defer stmt.finalize();
            try stmt.bindText(1, book.path);
            if (try stmt.step()) existing_id = stmt.columnInt64(0);
        }

        const now = clock.nowSeconds();

        if (existing_id) |id| {
            const old_snapshot = self.fetchAuditSnapshot(allocator, id) catch null;
            defer if (old_snapshot) |s| s.free(allocator);

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
                \\  subjects_json  = COALESCE(?, subjects_json),
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
            try stmt.bindNullableText(15, subjects_json);
            try stmt.bindText(16, @tagName(book.metadata.source));
            try stmt.bindDouble(17, book.metadata.confidence);
            try stmt.bindInt64(18, now);
            try stmt.bindInt64(19, id);
            _ = try stmt.step();

            if (old_snapshot) |old| {
                self.logFieldChanges(allocator, id, old, book.metadata) catch |err| {
                    std.log.warn("audit: logFieldChanges failed for book {d}: {s}", .{ id, @errorName(err) });
                };
            }
            return id;
        }

        var stmt = try sql.prepare(self.db,
            \\INSERT INTO books (
            \\  path, sha256, size, format, mtime,
            \\  title, author_sort, authors_json, series, series_index,
            \\  publisher, published_year, isbn, language, description, cover_path,
            \\  subjects_json, source, confidence, added_at, updated_at, original_path
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer stmt.finalize();
        try stmt.bindText(1, book.path);
        try stmt.bindText(2, book.sha256);
        try stmt.bindInt64(3, @intCast(book.size));
        try stmt.bindText(4, @tagName(book.format));
        try stmt.bindInt64(5, book.mtime);
        try bindMetadata(&stmt, 6, book.metadata, if (book.metadata.authors.len > 0) authors_json else null);
        try stmt.bindNullableText(17, subjects_json);
        try stmt.bindText(18, @tagName(book.metadata.source));
        try stmt.bindDouble(19, book.metadata.confidence);
        try stmt.bindInt64(20, now);
        try stmt.bindInt64(21, now);
        try stmt.bindText(22, book.path);
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

    /// Update the on-row format tag after a format-converting move.
    /// Companion to `updateBookPath` — they're typically called together
    /// (handleConvert moves both at once). Touches `format` only, leaves
    /// metadata + provenance alone.
    pub fn updateBookFormat(self: *Catalog, id: i64, fmt: meta.Format) !void {
        var stmt = try sql.prepare(self.db, "UPDATE books SET format = ?, updated_at = ? WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, @tagName(fmt));
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

    pub const CachedMetadataSource = struct {
        payload_json: []const u8,
        fetched_at: i64,
    };

    /// Fetch the cached provider response for a (book, source) pair.
    /// Returns null when there's no entry. Used by the enrich path to
    /// short-circuit repeat OL lookups within a freshness window.
    pub fn getMetadataSource(
        self: *Catalog,
        allocator: std.mem.Allocator,
        book_id: i64,
        source: meta.Source,
    ) !?CachedMetadataSource {
        var stmt = try sql.prepare(self.db,
            \\SELECT payload_json, fetched_at
            \\FROM metadata_sources
            \\WHERE book_id = ? AND source = ?
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        try stmt.bindText(2, @tagName(source));
        if (!try stmt.step()) return null;
        const payload = stmt.columnText(0) orelse return null;
        return .{
            .payload_json = try allocator.dupe(u8, payload),
            .fetched_at = stmt.columnInt64(1),
        };
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

    /// Books whose metadata is still untrusted: the file's own embedded
    /// header is the only source, and either there's no ISBN to verify
    /// against or the parser's confidence is low. Sorted with the least
    /// trustworthy rows first so the user can fix them top-down.
    pub fn listUnverified(self: *Catalog, allocator: std.mem.Allocator) ![]Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++
            "WHERE source = 'embedded' AND (isbn IS NULL OR confidence < 0.6) " ++
            "ORDER BY confidence ASC, path");
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

    /// One axis to sort matches by.
    pub const Order = enum {
        title,
        author,
        year_asc,
        year_desc,
        added_desc,
        updated_desc,
        series,
        size_desc,
    };

    /// All filter knobs the API and CLI expose. Any field left null is
    /// "no filter". `text` is a substring match against title or author.
    pub const SearchQuery = struct {
        text: ?[]const u8 = null,
        author: ?[]const u8 = null,
        series: ?[]const u8 = null,
        genre: ?[]const u8 = null,
        format: ?meta.Format = null,
        formats_in: ?[]const meta.Format = null,
        tag: ?[]const u8 = null,
        year_from: ?u16 = null,
        year_to: ?u16 = null,
        status: ?ReadStatus = null,
        has_isbn: ?bool = null,
        has_cover: ?bool = null,
        has_series: ?bool = null,
        missing_any: bool = false,
        source: ?meta.Source = null,
        order: Order = .author,
        limit: ?usize = null,
    };

    /// Run a parametrised search against the books table.
    pub fn searchBooks(
        self: *Catalog,
        allocator: std.mem.Allocator,
        q: SearchQuery,
    ) ![]Book {
        var where: std.ArrayList(u8) = .empty;
        defer where.deinit(allocator);
        var binds: std.ArrayList([]const u8) = .empty;
        defer binds.deinit(allocator);
        var int_binds: std.ArrayList(i64) = .empty;
        defer int_binds.deinit(allocator);

        try where.appendSlice(allocator, "WHERE 1=1 ");

        if (q.text) |t| {
            try where.appendSlice(allocator, "AND (title LIKE ? OR author_sort LIKE ?) ");
            const wrapped = try std.fmt.allocPrint(allocator, "%{s}%", .{t});
            try binds.append(allocator, wrapped);
            try binds.append(allocator, wrapped);
        }
        if (q.author) |a| {
            try where.appendSlice(allocator, "AND author_sort = ? ");
            try binds.append(allocator, a);
        }
        if (q.series) |s| {
            try where.appendSlice(allocator, "AND series = ? ");
            try binds.append(allocator, s);
        }
        if (q.genre) |g| {
            try where.appendSlice(allocator, "AND subjects_json LIKE ? ");
            try binds.append(allocator, try std.fmt.allocPrint(allocator, "%\"{s}\"%", .{g}));
        }
        if (q.formats_in) |fmts| {
            if (fmts.len > 0) {
                try where.appendSlice(allocator, "AND format IN (");
                for (fmts, 0..) |fmt, i| {
                    if (i > 0) try where.append(allocator, ',');
                    try where.append(allocator, '?');
                    try binds.append(allocator, @tagName(fmt));
                }
                try where.appendSlice(allocator, ") ");
            }
        } else if (q.format) |fmt| {
            try where.appendSlice(allocator, "AND format = ? ");
            try binds.append(allocator, @tagName(fmt));
        }
        if (q.year_from) |y| {
            try where.appendSlice(allocator, "AND published_year >= ? ");
            try int_binds.append(allocator, @intCast(y));
        }
        if (q.year_to) |y| {
            try where.appendSlice(allocator, "AND published_year <= ? ");
            try int_binds.append(allocator, @intCast(y));
        }
        if (q.status) |s| {
            try where.appendSlice(allocator, "AND read_status = ? ");
            try binds.append(allocator, @tagName(s));
        }
        if (q.source) |s| {
            try where.appendSlice(allocator, "AND source = ? ");
            try binds.append(allocator, @tagName(s));
        }
        if (q.tag) |t| {
            try where.appendSlice(
                allocator,
                "AND id IN (SELECT bt.book_id FROM book_tags bt " ++
                    "JOIN tags tg ON tg.id = bt.tag_id WHERE tg.name = ? COLLATE NOCASE) ",
            );
            try binds.append(allocator, t);
        }
        if (q.has_isbn) |has| {
            try where.appendSlice(allocator, if (has)
                "AND isbn IS NOT NULL "
            else
                "AND isbn IS NULL ");
        }
        if (q.has_cover) |has| {
            try where.appendSlice(allocator, if (has)
                "AND cover_path IS NOT NULL "
            else
                "AND cover_path IS NULL ");
        }
        if (q.has_series) |has| {
            try where.appendSlice(allocator, if (has)
                "AND series IS NOT NULL "
            else
                "AND series IS NULL ");
        }
        if (q.missing_any) {
            try where.appendSlice(
                allocator,
                "AND (title IS NULL OR author_sort IS NULL OR published_year IS NULL OR isbn IS NULL) ",
            );
        }

        const order_clause = switch (q.order) {
            .title => "ORDER BY title COLLATE NOCASE ",
            .author => "ORDER BY author_sort COLLATE NOCASE, series, series_index, title ",
            .year_asc => "ORDER BY published_year ASC, author_sort ",
            .year_desc => "ORDER BY published_year DESC, author_sort ",
            .added_desc => "ORDER BY added_at DESC ",
            .updated_desc => "ORDER BY updated_at DESC ",
            .series => "ORDER BY series COLLATE NOCASE, series_index ASC, title ",
            .size_desc => "ORDER BY size DESC ",
        };

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.appendSlice(allocator, SELECT_BOOK_BASE);
        try sql_buf.appendSlice(allocator, where.items);
        try sql_buf.appendSlice(allocator, order_clause);
        if (q.limit) |n| {
            const lim = try std.fmt.allocPrint(allocator, "LIMIT {d} ", .{n});
            try sql_buf.appendSlice(allocator, lim);
        }

        var stmt = try sql.prepare(self.db, sql_buf.items);
        defer stmt.finalize();
        var idx: c_int = 1;
        for (binds.items) |b| {
            try stmt.bindText(idx, b);
            idx += 1;
        }
        for (int_binds.items) |i| {
            try stmt.bindInt64(idx, i);
            idx += 1;
        }
        return collectRows(&stmt, allocator);
    }

    pub const Facet = struct {
        name: []const u8,
        count: usize,
    };

    fn distinctValues(
        self: *Catalog,
        allocator: std.mem.Allocator,
        comptime sql_text: []const u8,
    ) ![]Facet {
        var out: std.ArrayList(Facet) = .empty;
        var stmt = try sql.prepare(self.db, sql_text);
        defer stmt.finalize();
        while (try stmt.step()) {
            const name = stmt.columnText(0) orelse continue;
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .count = @intCast(stmt.columnInt64(1)),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn distinctAuthors(self: *Catalog, allocator: std.mem.Allocator) ![]Facet {
        return self.distinctValues(
            allocator,
            "SELECT author_sort, COUNT(*) FROM books " ++
                "WHERE author_sort IS NOT NULL " ++
                "GROUP BY author_sort COLLATE NOCASE " ++
                "ORDER BY COUNT(*) DESC, author_sort COLLATE NOCASE",
        );
    }

    pub fn distinctSeries(self: *Catalog, allocator: std.mem.Allocator) ![]Facet {
        return self.distinctValues(
            allocator,
            "SELECT series, COUNT(*) FROM books " ++
                "WHERE series IS NOT NULL " ++
                "GROUP BY series COLLATE NOCASE " ++
                "ORDER BY COUNT(*) DESC, series COLLATE NOCASE",
        );
    }

    pub fn distinctFormats(self: *Catalog, allocator: std.mem.Allocator) ![]Facet {
        return self.distinctValues(
            allocator,
            "SELECT format, COUNT(*) FROM books " ++
                "WHERE format IS NOT NULL " ++
                "GROUP BY format " ++
                "ORDER BY COUNT(*) DESC, format",
        );
    }

    /// Genres are stored as a JSON array per row; we expand them in-app.
    /// At catalog sizes <100k books this is fine; if it ever isn't,
    /// promote subjects to a join table.
    pub fn distinctGenres(self: *Catalog, allocator: std.mem.Allocator) ![]Facet {
        var counts: std.StringHashMap(usize) = .init(allocator);
        defer counts.deinit();

        var stmt = try sql.prepare(
            self.db,
            "SELECT subjects_json FROM books WHERE subjects_json IS NOT NULL",
        );
        defer stmt.finalize();
        while (try stmt.step()) {
            const json_text = stmt.columnText(0) orelse continue;
            const items = decodeStringArray(allocator, json_text) catch continue;
            for (items) |g| {
                const gop = try counts.getOrPut(g);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
            allocator.free(items);
        }

        var out: std.ArrayList(Facet) = .empty;
        var it = counts.iterator();
        while (it.next()) |entry| {
            try out.append(allocator, .{ .name = entry.key_ptr.*, .count = entry.value_ptr.* });
        }
        std.mem.sort(Facet, out.items, {}, struct {
            fn lt(_: void, a: Facet, b: Facet) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lt);
        return out.toOwnedSlice(allocator);
    }

    pub fn setReadStatus(
        self: *Catalog,
        id: i64,
        status: ReadStatus,
    ) !void {
        const now = clock.nowSeconds();
        const set_started: ?i64 = if (status == .reading) now else null;
        const set_finished: ?i64 = if (status == .finished) now else null;

        var stmt = try sql.prepare(self.db,
            \\UPDATE books SET
            \\  read_status = ?1,
            \\  started_at  = COALESCE(started_at, ?2),
            \\  finished_at = CASE WHEN ?1 = 'finished' THEN ?3
            \\                     WHEN ?1 = 'unread'   THEN NULL
            \\                     ELSE finished_at END,
            \\  updated_at  = ?4
            \\WHERE id = ?5
        );
        defer stmt.finalize();
        try stmt.bindText(1, @tagName(status));
        try stmt.bindNullableInt64(2, set_started);
        try stmt.bindNullableInt64(3, set_finished);
        try stmt.bindInt64(4, now);
        try stmt.bindInt64(5, id);
        _ = try stmt.step();
    }

    pub const EnrichStatus = enum {
        ok,
        no_match,
        @"error",
    };

    /// Snapshot of the fields we audit. Owned strings so we can
    /// read the old row safely before the UPDATE clobbers it. Caller
    /// is responsible for calling `free()` once done.
    pub const AuditSnapshot = struct {
        title: ?[]const u8 = null,
        author_sort: ?[]const u8 = null,
        series: ?[]const u8 = null,
        published_year: ?u16 = null,
        isbn: ?[]const u8 = null,
        publisher: ?[]const u8 = null,
        description: ?[]const u8 = null,

        pub fn free(self: AuditSnapshot, allocator: std.mem.Allocator) void {
            if (self.title) |s| allocator.free(s);
            if (self.author_sort) |s| allocator.free(s);
            if (self.series) |s| allocator.free(s);
            if (self.isbn) |s| allocator.free(s);
            if (self.publisher) |s| allocator.free(s);
            if (self.description) |s| allocator.free(s);
        }
    };

    fn fetchAuditSnapshot(self: *Catalog, allocator: std.mem.Allocator, id: i64) !?AuditSnapshot {
        var stmt = try sql.prepare(
            self.db,
            "SELECT title, author_sort, series, published_year, isbn, publisher, description " ++
                "FROM books WHERE id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        if (!try stmt.step()) return null;

        return AuditSnapshot{
            .title = if (stmt.columnText(0)) |s| try allocator.dupe(u8, s) else null,
            .author_sort = if (stmt.columnText(1)) |s| try allocator.dupe(u8, s) else null,
            .series = if (stmt.columnText(2)) |s| try allocator.dupe(u8, s) else null,
            .published_year = if (stmt.columnIsNull(3)) null else @intCast(stmt.columnInt64(3)),
            .isbn = if (stmt.columnText(4)) |s| try allocator.dupe(u8, s) else null,
            .publisher = if (stmt.columnText(5)) |s| try allocator.dupe(u8, s) else null,
            .description = if (stmt.columnText(6)) |s| try allocator.dupe(u8, s) else null,
        };
    }

    fn logFieldChanges(
        self: *Catalog,
        allocator: std.mem.Allocator,
        id: i64,
        old: AuditSnapshot,
        new_md: meta.BookMetadata,
    ) !void {
        const src = @tagName(new_md.source);
        try self.maybeLogChange(allocator, id, "title", old.title, new_md.title, src);
        const new_author: ?[]const u8 = if (new_md.authors.len > 0) new_md.authors[0].sort else null;
        try self.maybeLogChange(allocator, id, "author", old.author_sort, new_author, src);
        try self.maybeLogChange(allocator, id, "series", old.series, new_md.series, src);
        try self.maybeLogChange(allocator, id, "isbn", old.isbn, new_md.isbn, src);
        try self.maybeLogChange(allocator, id, "publisher", old.publisher, new_md.publisher, src);
        if (new_md.published_year) |new_y| {
            if (old.published_year == null or old.published_year.? != new_y) {
                var old_buf: [16]u8 = undefined;
                var new_buf: [16]u8 = undefined;
                const old_str = if (old.published_year) |y|
                    std.fmt.bufPrint(&old_buf, "{d}", .{y}) catch null
                else
                    null;
                const new_str = std.fmt.bufPrint(&new_buf, "{d}", .{new_y}) catch null;
                try self.maybeLogChange(allocator, id, "year", old_str, new_str, src);
            }
        }
    }

    fn maybeLogChange(
        self: *Catalog,
        allocator: std.mem.Allocator,
        id: i64,
        field: []const u8,
        old: ?[]const u8,
        new: ?[]const u8,
        source: []const u8,
    ) !void {
        _ = allocator;
        if (new == null) return;
        if (old != null and new != null and std.mem.eql(u8, old.?, new.?)) return;
        var stmt = try sql.prepare(
            self.db,
            "INSERT INTO catalog_changes (book_id, field, old_value, new_value, source, changed_at) " ++
                "VALUES (?, ?, ?, ?, ?, ?)",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        try stmt.bindText(2, field);
        try stmt.bindNullableText(3, old);
        try stmt.bindNullableText(4, new);
        try stmt.bindText(5, source);
        try stmt.bindInt64(6, clock.nowSeconds());
        _ = try stmt.step();
    }

    pub const ChangeRow = struct {
        id: i64,
        book_id: i64,
        field: []const u8,
        old_value: ?[]const u8,
        new_value: ?[]const u8,
        source: []const u8,
        changed_at: i64,
    };

    /// Return the recent change log for a book, newest first.
    pub fn listBookChanges(
        self: *Catalog,
        allocator: std.mem.Allocator,
        book_id: i64,
        limit: usize,
    ) ![]ChangeRow {
        var stmt = try sql.prepare(
            self.db,
            "SELECT id, book_id, field, old_value, new_value, source, changed_at " ++
                "FROM catalog_changes WHERE book_id = ? ORDER BY changed_at DESC, id DESC LIMIT ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        try stmt.bindInt64(2, @intCast(limit));

        var out: std.ArrayList(ChangeRow) = .empty;
        while (try stmt.step()) {
            try out.append(allocator, .{
                .id = stmt.columnInt64(0),
                .book_id = stmt.columnInt64(1),
                .field = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
                .old_value = if (stmt.columnText(3)) |s| try allocator.dupe(u8, s) else null,
                .new_value = if (stmt.columnText(4)) |s| try allocator.dupe(u8, s) else null,
                .source = try allocator.dupe(u8, stmt.columnText(5) orelse ""),
                .changed_at = stmt.columnInt64(6),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    pub const Tag = struct {
        id: i64,
        name: []const u8,
        count: u64,
    };

    /// Get-or-create a tag by name. Names are NOCASE-unique and
    /// trimmed of surrounding whitespace.
    pub fn upsertTag(self: *Catalog, allocator: std.mem.Allocator, name: []const u8) !i64 {
        const trimmed = std.mem.trim(u8, name, " \t\n");
        if (trimmed.len == 0) return error.EmptyTagName;

        var ins = try sql.prepare(
            self.db,
            "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)",
        );
        defer ins.finalize();
        try ins.bindText(1, trimmed);
        try ins.bindInt64(2, clock.nowSeconds());
        _ = try ins.step();

        var sel = try sql.prepare(self.db, "SELECT id FROM tags WHERE name = ? COLLATE NOCASE");
        defer sel.finalize();
        try sel.bindText(1, trimmed);
        if (try sel.step()) return sel.columnInt64(0);
        _ = allocator;
        return error.TagNotFound;
    }

    pub fn deleteTag(self: *Catalog, id: i64) !void {
        var stmt = try sql.prepare(self.db, "DELETE FROM tags WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        _ = try stmt.step();
    }

    /// All tags with their book counts, ordered by count desc, name asc.
    pub fn listTags(self: *Catalog, allocator: std.mem.Allocator) ![]Tag {
        var stmt = try sql.prepare(
            self.db,
            "SELECT t.id, t.name, COUNT(bt.book_id) " ++
                "FROM tags t LEFT JOIN book_tags bt ON bt.tag_id = t.id " ++
                "GROUP BY t.id ORDER BY COUNT(bt.book_id) DESC, t.name COLLATE NOCASE ASC",
        );
        defer stmt.finalize();
        var out: std.ArrayList(Tag) = .empty;
        while (try stmt.step()) {
            try out.append(allocator, .{
                .id = stmt.columnInt64(0),
                .name = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
                .count = @intCast(stmt.columnInt64(2)),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// Add a tag to a book. Idempotent — re-adding a tag is a no-op.
    pub fn addBookTag(self: *Catalog, book_id: i64, tag_id: i64) !void {
        var stmt = try sql.prepare(
            self.db,
            "INSERT OR IGNORE INTO book_tags (book_id, tag_id, added_at) VALUES (?, ?, ?)",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        try stmt.bindInt64(2, tag_id);
        try stmt.bindInt64(3, clock.nowSeconds());
        _ = try stmt.step();
    }

    pub fn removeBookTag(self: *Catalog, book_id: i64, tag_id: i64) !void {
        var stmt = try sql.prepare(
            self.db,
            "DELETE FROM book_tags WHERE book_id = ? AND tag_id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        try stmt.bindInt64(2, tag_id);
        _ = try stmt.step();
    }

    /// Tags assigned to a single book.
    pub fn listBookTags(self: *Catalog, allocator: std.mem.Allocator, book_id: i64) ![]Tag {
        var stmt = try sql.prepare(
            self.db,
            "SELECT t.id, t.name FROM tags t " ++
                "JOIN book_tags bt ON bt.tag_id = t.id " ++
                "WHERE bt.book_id = ? ORDER BY t.name COLLATE NOCASE ASC",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        var out: std.ArrayList(Tag) = .empty;
        while (try stmt.step()) {
            try out.append(allocator, .{
                .id = stmt.columnInt64(0),
                .name = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
                .count = 0,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// Persist the outcome of an enrichment attempt for `id`. Called
    /// from the batch worker after every book it touches (and from
    /// the per-book /api/.../enrich handler, so manual enrichment also
    /// flips the row out of "never attempted").
    pub fn setEnrichStatus(
        self: *Catalog,
        id: i64,
        status: EnrichStatus,
    ) !void {
        const now = clock.nowSeconds();
        var stmt = try sql.prepare(
            self.db,
            "UPDATE books SET enrich_status = ?, enrich_attempted_at = ? WHERE id = ?",
        );
        defer stmt.finalize();
        try stmt.bindText(1, @tagName(status));
        try stmt.bindInt64(2, now);
        try stmt.bindInt64(3, id);
        _ = try stmt.step();
    }

    /// Books eligible for the batch enrichment pass — never attempted
    /// or last attempt errored (transient failure worth retrying). 'ok'
    /// and 'no_match' rows are skipped so re-running the batch is
    /// idempotent. Order is `added_at` ascending so the user sees a
    /// stable, predictable progression in the UI.
    pub fn listForEnrichment(self: *Catalog, allocator: std.mem.Allocator) ![]Book {
        var stmt = try sql.prepare(
            self.db,
            SELECT_BOOK_BASE ++
                "WHERE missing_at IS NULL " ++
                "AND (enrich_status IS NULL OR enrich_status = 'error') " ++
                "ORDER BY added_at ASC, id ASC",
        );
        defer stmt.finalize();
        return collectRows(&stmt, allocator);
    }

    /// Counts for the batch progress UI: how many books are unenriched
    /// vs already done, vs failed-permanent. One round-trip rather
    /// than three.
    pub const EnrichCounts = struct {
        total: u64,
        eligible: u64,
        ok: u64,
        no_match: u64,
        errored: u64,
    };
    pub fn countEnrichmentBuckets(self: *Catalog) !EnrichCounts {
        var stmt = try sql.prepare(self.db,
            \\SELECT
            \\  COUNT(*),
            \\  SUM(CASE WHEN missing_at IS NULL AND
            \\           (enrich_status IS NULL OR enrich_status = 'error')
            \\           THEN 1 ELSE 0 END),
            \\  SUM(CASE WHEN enrich_status = 'ok'       THEN 1 ELSE 0 END),
            \\  SUM(CASE WHEN enrich_status = 'no_match' THEN 1 ELSE 0 END),
            \\  SUM(CASE WHEN enrich_status = 'error'    THEN 1 ELSE 0 END)
            \\FROM books
        );
        defer stmt.finalize();
        if (!try stmt.step()) return error.NoRow;
        return .{
            .total = @intCast(stmt.columnInt64(0)),
            .eligible = @intCast(stmt.columnInt64(1)),
            .ok = @intCast(stmt.columnInt64(2)),
            .no_match = @intCast(stmt.columnInt64(3)),
            .errored = @intCast(stmt.columnInt64(4)),
        };
    }

    pub const ReadStatusCounts = struct {
        unread: u32,
        reading: u32,
        finished: u32,
    };

    /// Aggregate counts of every book by read_status. One round-trip.
    pub fn statusCounts(self: *Catalog) !ReadStatusCounts {
        var stmt = try sql.prepare(
            self.db,
            "SELECT " ++
                "SUM(CASE WHEN read_status = 'unread' OR read_status IS NULL THEN 1 ELSE 0 END), " ++
                "SUM(CASE WHEN read_status = 'reading' THEN 1 ELSE 0 END), " ++
                "SUM(CASE WHEN read_status = 'finished' THEN 1 ELSE 0 END) " ++
                "FROM books",
        );
        defer stmt.finalize();
        if (!try stmt.step()) return error.NoRow;
        return .{
            .unread = @intCast(stmt.columnInt64(0)),
            .reading = @intCast(stmt.columnInt64(1)),
            .finished = @intCast(stmt.columnInt64(2)),
        };
    }

    pub const MonthCount = struct {
        /// Year-month string in ISO 8601 partial form, e.g. "2026-06".
        ym: []const u8,
        count: u32,
    };

    /// Books finished per month, oldest → newest, for the last `months`
    /// months ending with the current month. Zero-fills months with no
    /// finishes so the chart's x-axis stays consistent.
    pub fn finishedByMonth(
        self: *Catalog,
        allocator: std.mem.Allocator,
        months: u8,
    ) ![]MonthCount {
        var stmt = try sql.prepare(
            self.db,
            "SELECT strftime('%Y-%m', finished_at, 'unixepoch') AS ym, COUNT(*) " ++
                "FROM books " ++
                "WHERE finished_at IS NOT NULL " ++
                "GROUP BY ym " ++
                "ORDER BY ym ASC",
        );
        defer stmt.finalize();
        var raw: std.StringHashMap(u32) = .init(allocator);
        defer raw.deinit();
        while (try stmt.step()) {
            const ym = stmt.columnText(0) orelse continue;
            try raw.put(try allocator.dupe(u8, ym), @intCast(stmt.columnInt64(1)));
        }
        const now = clock.nowSeconds();
        const today_epoch_day: i64 = @divFloor(now, 86400);
        const today_ymd = (std.time.epoch.EpochDay{ .day = @intCast(today_epoch_day) }).calculateYearDay();
        const today_md = today_ymd.calculateMonthDay();
        var year: i32 = @intCast(today_ymd.year);
        var month: i32 = @intCast(today_md.month.numeric());
        var out: std.ArrayList(MonthCount) = .empty;
        var buf: std.ArrayList(MonthCount) = .empty;
        var i: u8 = 0;
        while (i < months) : (i += 1) {
            const ym_str = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}", .{
                @as(u16, @intCast(year)), @as(u4, @intCast(month)),
            });
            const count = raw.get(ym_str) orelse 0;
            try buf.append(allocator, .{ .ym = ym_str, .count = count });
            month -= 1;
            if (month < 1) {
                month = 12;
                year -= 1;
            }
        }
        var j: usize = buf.items.len;
        while (j > 0) : (j -= 1) try out.append(allocator, buf.items[j - 1]);
        return out.toOwnedSlice(allocator);
    }

    /// Books with read_status = 'reading', sorted by last-read time
    /// desc (most-recently-touched first) with a fallback to
    /// `started_at`. `last_read_at` is a correlated-subquery column
    /// at the SELECT level (see SELECT_BOOK_BASE) — not a `books`
    /// column — so we inline the same subquery in the ORDER BY
    /// rather than referencing the alias.
    pub fn listCurrentlyReading(
        self: *Catalog,
        allocator: std.mem.Allocator,
        limit: u32,
    ) ![]Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++
            "WHERE read_status = 'reading' " ++
            "ORDER BY COALESCE(" ++
            "(SELECT updated_at FROM read_locations WHERE book_id = books.id), " ++
            "started_at, 0" ++
            ") DESC " ++
            "LIMIT ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, limit);
        return collectRows(&stmt, allocator);
    }

    pub fn listRecentlyFinished(
        self: *Catalog,
        allocator: std.mem.Allocator,
        limit: u32,
    ) ![]Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++
            "WHERE read_status = 'finished' AND finished_at IS NOT NULL " ++
            "ORDER BY finished_at DESC " ++
            "LIMIT ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, limit);
        return collectRows(&stmt, allocator);
    }

    pub const FormatCount = struct {
        format: []const u8,
        count: u32,
    };

    pub fn formatCounts(self: *Catalog, allocator: std.mem.Allocator) ![]FormatCount {
        var stmt = try sql.prepare(
            self.db,
            "SELECT format, COUNT(*) FROM books " ++
                "GROUP BY format ORDER BY COUNT(*) DESC",
        );
        defer stmt.finalize();
        var out: std.ArrayList(FormatCount) = .empty;
        while (try stmt.step()) {
            const fmt = stmt.columnText(0) orelse continue;
            try out.append(allocator, .{
                .format = try allocator.dupe(u8, fmt),
                .count = @intCast(stmt.columnInt64(1)),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    pub const AuthorCount = struct {
        name: []const u8,
        count: u32,
    };

    /// Top N authors by book count. Uses `author_sort` (the indexed
    /// canonical form) so multi-author cases bucket consistently.
    pub fn topAuthors(self: *Catalog, allocator: std.mem.Allocator, limit: u32) ![]AuthorCount {
        var stmt = try sql.prepare(
            self.db,
            "SELECT author_sort, COUNT(*) FROM books " ++
                "WHERE author_sort IS NOT NULL AND author_sort != '' " ++
                "GROUP BY author_sort " ++
                "ORDER BY COUNT(*) DESC, author_sort COLLATE NOCASE " ++
                "LIMIT ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, limit);
        var out: std.ArrayList(AuthorCount) = .empty;
        while (try stmt.step()) {
            const name = stmt.columnText(0) orelse continue;
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .count = @intCast(stmt.columnInt64(1)),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// Fetch the saved reading location for a book, or null if none.
    /// The `location` string is opaque and interpreted by the frontend
    /// based on book format (EPUB CFI for foliate; decimal page number
    /// for pdf.js).
    pub fn getLocation(
        self: *Catalog,
        allocator: std.mem.Allocator,
        book_id: i64,
    ) !?ReadLocation {
        var stmt = try sql.prepare(
            self.db,
            "SELECT book_id, location, percent, updated_at FROM read_locations WHERE book_id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        if (!try stmt.step()) return null;
        return .{
            .book_id = stmt.columnInt64(0),
            .location = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
            .percent = if (stmt.columnIsNull(2)) null else @floatCast(stmt.columnDouble(2)),
            .updated_at = stmt.columnInt64(3),
        };
    }

    /// Upsert the reading location for a book. Called every ~800ms
    /// from the browser as the user pages through.
    pub fn setLocation(
        self: *Catalog,
        book_id: i64,
        location: []const u8,
        percent: ?f32,
    ) !void {
        const now = clock.nowSeconds();
        var stmt = try sql.prepare(self.db,
            \\INSERT INTO read_locations (book_id, location, percent, updated_at)
            \\VALUES (?, ?, ?, ?)
            \\ON CONFLICT(book_id) DO UPDATE SET
            \\  location = excluded.location,
            \\  percent  = excluded.percent,
            \\  updated_at = excluded.updated_at
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        try stmt.bindText(2, location);
        try stmt.bindNullableDouble(3, if (percent) |p| @floatCast(p) else null);
        try stmt.bindInt64(4, now);
        _ = try stmt.step();

        try self.recordReadingTick(book_id, now, percent);
    }

    fn recordReadingTick(self: *Catalog, book_id: i64, now: i64, percent: ?f32) !void {
        const session_gap_seconds: i64 = 5 * 60;
        var sel = try sql.prepare(
            self.db,
            "SELECT id, started_at, ended_at, start_pct FROM reading_sessions " ++
                "WHERE book_id = ? ORDER BY started_at DESC LIMIT 1",
        );
        defer sel.finalize();
        try sel.bindInt64(1, book_id);

        const new_pct: ?f64 = if (percent) |p| @floatCast(p) else null;
        if (try sel.step()) {
            const sid = sel.columnInt64(0);
            const ended_at = sel.columnInt64(2);
            if (now - ended_at < session_gap_seconds) {
                var upd = try sql.prepare(
                    self.db,
                    "UPDATE reading_sessions SET ended_at = ?, end_pct = ? WHERE id = ?",
                );
                defer upd.finalize();
                try upd.bindInt64(1, now);
                try upd.bindNullableDouble(2, new_pct);
                try upd.bindInt64(3, sid);
                _ = try upd.step();
                return;
            }
        }
        var ins = try sql.prepare(
            self.db,
            "INSERT INTO reading_sessions (book_id, started_at, ended_at, start_pct, end_pct) " ++
                "VALUES (?, ?, ?, ?, ?)",
        );
        defer ins.finalize();
        try ins.bindInt64(1, book_id);
        try ins.bindInt64(2, now);
        try ins.bindInt64(3, now);
        try ins.bindNullableDouble(4, new_pct);
        try ins.bindNullableDouble(5, new_pct);
        _ = try ins.step();
    }

    pub const ReadingStats = struct {
        sessions: u64,
        total_seconds: i64,
        last_at: i64,
    };

    /// Aggregate reading stats for one book. Used by the detail panel
    /// to show "X minutes across N sessions, last read Y ago".
    pub fn getReadingStats(self: *Catalog, book_id: i64) !ReadingStats {
        var stmt = try sql.prepare(
            self.db,
            "SELECT COUNT(*), COALESCE(SUM(ended_at - started_at), 0), COALESCE(MAX(ended_at), 0) " ++
                "FROM reading_sessions WHERE book_id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        if (!try stmt.step()) return .{ .sessions = 0, .total_seconds = 0, .last_at = 0 };
        return .{
            .sessions = @intCast(stmt.columnInt64(0)),
            .total_seconds = stmt.columnInt64(1),
            .last_at = stmt.columnInt64(2),
        };
    }

    /// Drop a saved location. Used by the "Start over" overflow item.
    pub fn deleteLocation(self: *Catalog, book_id: i64) !void {
        var stmt = try sql.prepare(self.db, "DELETE FROM read_locations WHERE book_id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        _ = try stmt.step();
    }

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

    pub const LibrarySource = struct {
        id: i64,
        path: []const u8,
        name: ?[]const u8,
        added_at: i64,
        last_scanned_at: ?i64,
        last_seen: u32,
        last_added: u32,
        last_missing: u32,
        /// Set by rescan when the folder can't be read (path doesn't
        /// exist, permission denied, etc). Cleared on a successful
        /// scan. Used by the UI to render an "unreachable" state.
        last_error: ?[]const u8 = null,
        /// Live scan state. `scanning=true` means a worker thread is
        /// currently walking this source; the UI uses scan_seen /
        /// scan_total to render a progress bar without blocking the
        /// HTTP request that triggered the scan.
        scanning: bool = false,
        scan_seen: u32 = 0,
        scan_total: u32 = 0,
    };

    /// Add a new source. Returns the existing source's id if the path
    /// is already registered (idempotent).
    pub fn addSource(
        self: *Catalog,
        allocator: std.mem.Allocator,
        path: []const u8,
        name: ?[]const u8,
    ) !i64 {
        if (try self.getSourceByPath(allocator, path)) |s| return s.id;

        var stmt = try sql.prepare(self.db,
            \\INSERT INTO library_sources (path, name, added_at)
            \\VALUES (?, ?, ?)
        );
        defer stmt.finalize();
        try stmt.bindText(1, path);
        try stmt.bindNullableText(2, name);
        try stmt.bindInt64(3, clock.nowSeconds());
        _ = try stmt.step();
        return sql.lastInsertRowid(self.db);
    }

    pub fn removeSource(self: *Catalog, id: i64) !void {
        var stmt = try sql.prepare(self.db, "DELETE FROM library_sources WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        _ = try stmt.step();
    }

    pub fn getSourceById(
        self: *Catalog,
        allocator: std.mem.Allocator,
        id: i64,
    ) !?LibrarySource {
        var stmt = try sql.prepare(
            self.db,
            "SELECT id, path, name, added_at, last_scanned_at, last_seen, last_added, last_missing, last_error, scanning, scan_seen, scan_total FROM library_sources WHERE id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        if (!try stmt.step()) return null;
        return try rowToSource(&stmt, allocator);
    }

    pub fn getSourceByPath(
        self: *Catalog,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !?LibrarySource {
        var stmt = try sql.prepare(
            self.db,
            "SELECT id, path, name, added_at, last_scanned_at, last_seen, last_added, last_missing, last_error, scanning, scan_seen, scan_total FROM library_sources WHERE path = ?",
        );
        defer stmt.finalize();
        try stmt.bindText(1, path);
        if (!try stmt.step()) return null;
        return try rowToSource(&stmt, allocator);
    }

    pub fn listSources(self: *Catalog, allocator: std.mem.Allocator) ![]LibrarySource {
        var stmt = try sql.prepare(
            self.db,
            "SELECT id, path, name, added_at, last_scanned_at, last_seen, last_added, last_missing, last_error, scanning, scan_seen, scan_total FROM library_sources ORDER BY added_at ASC",
        );
        defer stmt.finalize();
        var out: std.ArrayList(LibrarySource) = .empty;
        while (try stmt.step()) try out.append(allocator, try rowToSource(&stmt, allocator));
        return out.toOwnedSlice(allocator);
    }

    pub fn updateSourceScanStats(
        self: *Catalog,
        id: i64,
        seen: u32,
        added: u32,
        missing: u32,
    ) !void {
        var stmt = try sql.prepare(self.db,
            \\UPDATE library_sources SET
            \\  last_scanned_at = ?, last_seen = ?, last_added = ?, last_missing = ?,
            \\  last_error = NULL
            \\WHERE id = ?
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, clock.nowSeconds());
        try stmt.bindInt64(2, @intCast(seen));
        try stmt.bindInt64(3, @intCast(added));
        try stmt.bindInt64(4, @intCast(missing));
        try stmt.bindInt64(5, id);
        _ = try stmt.step();
    }

    /// Record a scan failure on a source row. The UI uses `last_error`
    /// to render an "unreachable" state with the error message. Also
    /// clears the live `scanning` flag so a failed scan doesn't leave
    /// the row stuck "in progress".
    pub fn markSourceError(self: *Catalog, id: i64, err_msg: []const u8) !void {
        var stmt = try sql.prepare(self.db,
            \\UPDATE library_sources SET
            \\  last_scanned_at = ?, last_error = ?, scanning = 0
            \\WHERE id = ?
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, clock.nowSeconds());
        try stmt.bindText(2, err_msg);
        try stmt.bindInt64(3, id);
        _ = try stmt.step();
    }

    /// Mark a scan as starting. `total` is the file count from the
    /// first pass (0 means "unknown — still counting").
    pub fn markSourceScanning(self: *Catalog, id: i64, total: u32) !void {
        var stmt = try sql.prepare(self.db,
            \\UPDATE library_sources SET
            \\  scanning = 1, scan_seen = 0, scan_total = ?, last_error = NULL
            \\WHERE id = ?
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, @intCast(total));
        try stmt.bindInt64(2, id);
        _ = try stmt.step();
    }

    /// Update the live progress counter. Called from the worker thread
    /// every N files so the UI poll picks up steady movement.
    pub fn updateSourceScanProgress(self: *Catalog, id: i64, seen: u32) !void {
        var stmt = try sql.prepare(
            self.db,
            "UPDATE library_sources SET scan_seen = ? WHERE id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, @intCast(seen));
        try stmt.bindInt64(2, id);
        _ = try stmt.step();
    }

    /// Clear the scanning flag. Called after the worker finishes —
    /// whether it completed successfully or aborted on an error.
    pub fn clearSourceScanning(self: *Catalog, id: i64) !void {
        var stmt = try sql.prepare(self.db, "UPDATE library_sources SET scanning = 0 WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        _ = try stmt.step();
    }

    /// Set `source_id` on a book (link a book to a library source).
    pub fn setBookSource(self: *Catalog, book_id: i64, source_id: i64) !void {
        var stmt = try sql.prepare(self.db, "UPDATE books SET source_id = ? WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, source_id);
        try stmt.bindInt64(2, book_id);
        _ = try stmt.step();
    }

    /// Mark / unmark a book whose file is missing on disk.
    pub fn markBookMissing(self: *Catalog, book_id: i64) !void {
        var stmt = try sql.prepare(
            self.db,
            "UPDATE books SET missing_at = ? WHERE id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, clock.nowSeconds());
        try stmt.bindInt64(2, book_id);
        _ = try stmt.step();
    }

    pub fn clearBookMissing(self: *Catalog, book_id: i64) !void {
        var stmt = try sql.prepare(
            self.db,
            "UPDATE books SET missing_at = NULL WHERE id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, book_id);
        _ = try stmt.step();
    }

    /// Return every book whose `source_id` matches. Used by rescan to
    /// build the "previously known" set so it can flag vanished files.
    pub fn listBooksUnderSource(
        self: *Catalog,
        allocator: std.mem.Allocator,
        source_id: i64,
    ) ![]Book {
        var stmt = try sql.prepare(self.db, SELECT_BOOK_BASE ++ "WHERE source_id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, source_id);
        return collectRows(&stmt, allocator);
    }

    /// Books currently flagged as missing on disk.
    pub fn listMissingFiles(self: *Catalog, allocator: std.mem.Allocator) ![]Book {
        var stmt = try sql.prepare(
            self.db,
            SELECT_BOOK_BASE ++ "WHERE missing_at IS NOT NULL ORDER BY missing_at DESC",
        );
        defer stmt.finalize();
        return collectRows(&stmt, allocator);
    }
};

/// Helper: build a LibrarySource from the current statement row. Used
/// by every read path that returns sources so we don't repeat the
/// 8-column unpacking each time.
fn rowToSource(stmt: *sql.Stmt, allocator: std.mem.Allocator) !Catalog.LibrarySource {
    return .{
        .id = stmt.columnInt64(0),
        .path = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
        .name = if (stmt.columnIsNull(2)) null else try allocator.dupe(u8, stmt.columnText(2) orelse ""),
        .added_at = stmt.columnInt64(3),
        .last_scanned_at = if (stmt.columnIsNull(4)) null else stmt.columnInt64(4),
        .last_seen = @intCast(stmt.columnInt64(5)),
        .last_added = @intCast(stmt.columnInt64(6)),
        .last_missing = @intCast(stmt.columnInt64(7)),
        .last_error = if (stmt.columnIsNull(8)) null else try allocator.dupe(u8, stmt.columnText(8) orelse ""),
        .scanning = stmt.columnInt64(9) != 0,
        .scan_seen = @intCast(stmt.columnInt64(10)),
        .scan_total = @intCast(stmt.columnInt64(11)),
    };
}

const SELECT_BOOK_BASE =
    "SELECT id, path, sha256, size, format, mtime, " ++
    "title, author_sort, authors_json, series, series_index, " ++
    "publisher, published_year, isbn, language, description, cover_path, " ++
    "source, confidence, " ++
    "subjects_json, read_status, started_at, finished_at, added_at, updated_at, " ++
    "source_id, missing_at, " ++
    "(SELECT percent    FROM read_locations WHERE book_id = books.id), " ++
    "(SELECT updated_at FROM read_locations WHERE book_id = books.id), " ++
    "original_path " ++
    "FROM books ";

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

    md.subjects = if (stmt.columnText(19)) |sj|
        try decodeStringArray(allocator, sj)
    else
        &.{};
    const status = ReadStatus.fromStr(stmt.columnText(20) orelse "unread");
    const started: ?i64 = if (stmt.columnIsNull(21)) null else stmt.columnInt64(21);
    const finished: ?i64 = if (stmt.columnIsNull(22)) null else stmt.columnInt64(22);
    const added_at = stmt.columnInt64(23);
    const updated_at = stmt.columnInt64(24);
    const source_id: ?i64 = if (stmt.columnIsNull(25)) null else stmt.columnInt64(25);
    const missing_at: ?i64 = if (stmt.columnIsNull(26)) null else stmt.columnInt64(26);
    const read_percent: ?f32 = if (stmt.columnIsNull(27)) null else @floatCast(stmt.columnDouble(27));
    const last_read_at: ?i64 = if (stmt.columnIsNull(28)) null else stmt.columnInt64(28);
    const original_path = try dup.run(allocator, stmt.columnText(29));

    return .{
        .id = id,
        .path = path,
        .sha256 = sha,
        .size = size,
        .format = fmt,
        .mtime = mtime,
        .metadata = md,
        .read_status = status,
        .started_at = started,
        .finished_at = finished,
        .added_at = added_at,
        .updated_at = updated_at,
        .source_id = source_id,
        .missing_at = missing_at,
        .read_percent = read_percent,
        .last_read_at = last_read_at,
        .original_path = original_path,
    };
}

fn collectRows(stmt: *sql.Stmt, allocator: std.mem.Allocator) ![]Book {
    var list: std.ArrayList(Book) = .empty;
    while (try stmt.step()) {
        try list.append(allocator, try rowToBook(stmt, allocator));
    }
    return list.toOwnedSlice(allocator);
}

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
    return s;
}

/// Encode a list of strings as a JSON array. Used for the `subjects_json`
/// column (and is general enough that other multi-value columns can reuse
/// it later).
pub fn encodeStringArray(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    if (items.len == 0) return allocator.dupe(u8, "[]");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (items, 0..) |s, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        for (s) |ch| switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, ch),
        };
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

pub fn decodeStringArray(allocator: std.mem.Allocator, json_text: []const u8) ![]const []const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch
        return allocator.dupe([]const u8, &.{});
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.dupe([]const u8, &.{});
    var out: std.ArrayList([]const u8) = .empty;
    for (parsed.value.array.items) |item| {
        if (item != .string) continue;
        try out.append(allocator, try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice(allocator);
}

/// Checks PRAGMA table_info(books) for `name`; runs ALTER TABLE only when
/// absent. Robust against both fresh and pre-existing databases without
/// relying on swallowing ExecFailed on every call.
fn addColumnIfMissing(db: *c.sqlite3, name: []const u8, decl: []const u8) !void {
    return addColumnIfMissingOn(db, "books", name, decl);
}

fn addColumnIfMissingOn(db: *c.sqlite3, table: []const u8, name: []const u8, decl: []const u8) !void {
    var pragma_buf: [128]u8 = undefined;
    const pragma = try std.fmt.bufPrint(&pragma_buf, "PRAGMA table_info({s})", .{table});
    var stmt = try sql.prepare(db, pragma);
    defer stmt.finalize();
    while (try stmt.step()) {
        const existing = stmt.columnText(1) orelse continue;
        if (std.mem.eql(u8, existing, name)) return;
    }
    var buf: [256]u8 = undefined;
    const alter = try std.fmt.bufPrint(&buf, "ALTER TABLE {s} ADD COLUMN {s} {s};", .{ table, name, decl });
    try sql.exec(db, alter);
}

fn ensureParentDir(file_path: []const u8) !void {
    const dir_path = std.fs.path.dirname(file_path) orelse return;
    var buf: [4096]u8 = undefined;
    if (dir_path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..dir_path.len], dir_path);
    buf[dir_path.len] = 0;
    _ = std.c.mkdir(@ptrCast(&buf), 0o755);
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
    try std.testing.expect(fetched.original_path != null);
    try std.testing.expectEqualStrings("/tmp/test.epub", fetched.original_path.?);
}

test "migration backfills original_path on next open" {
    const alloc = std.testing.allocator;
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "/tmp/booktool-test-origpath-migration-{d}-{d}.db",
        .{ pid, stamp },
    );
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{name});
    defer _ = std.c.unlink(path_z.ptr);

    {
        var cat = try Catalog.open(name);
        defer cat.close();
        const author = meta.Author{ .last = "Le Guin", .first = "Ursula", .sort = "Le Guin, Ursula" };
        _ = try cat.upsertBook(alloc, .{
            .path = "/lib/dispossessed.epub",
            .sha256 = "feedface",
            .size = 4096,
            .format = .epub,
            .mtime = 0,
            .metadata = .{
                .title = "The Dispossessed",
                .authors = &[_]meta.Author{author},
                .source = .embedded,
                .confidence = 0.9,
            },
        });

        try sql.exec(cat.db, "UPDATE books SET original_path = NULL");

        const pre = (try cat.getBookByPath(alloc, "/lib/dispossessed.epub")) orelse return error.MissingRow;
        defer freeBook(alloc, pre);
        try std.testing.expect(pre.original_path == null);
    }

    {
        var cat = try Catalog.open(name);
        defer cat.close();
        const post = (try cat.getBookByPath(alloc, "/lib/dispossessed.epub")) orelse return error.MissingRow;
        defer freeBook(alloc, post);
        try std.testing.expect(post.original_path != null);
        try std.testing.expectEqualStrings("/lib/dispossessed.epub", post.original_path.?);
        try std.testing.expectEqualStrings("/lib/dispossessed.epub", post.path);
    }
}

test "updateBookPath preserves original_path" {
    const alloc = std.testing.allocator;
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "/tmp/booktool-test-origpath-{d}-{d}.db",
        .{ pid, stamp },
    );
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{name});
    defer _ = std.c.unlink(path_z.ptr);

    var cat = try Catalog.open(name);
    defer cat.close();

    const author = meta.Author{ .last = "Asimov", .first = "Isaac", .sort = "Asimov, Isaac" };
    const id = try cat.upsertBook(alloc, .{
        .path = "/lib/old.azw3",
        .sha256 = "abc",
        .size = 100,
        .format = .azw3,
        .mtime = 0,
        .metadata = .{ .title = "Foundation", .authors = &[_]meta.Author{author} },
    });
    try cat.updateBookPath(id, "/lib/new.epub");

    const fetched = (try cat.getBookById(alloc, id)) orelse return error.MissingRow;
    defer freeBook(alloc, fetched);
    try std.testing.expectEqualStrings("/lib/new.epub", fetched.path);
    try std.testing.expectEqualStrings("/lib/old.azw3", fetched.original_path.?);
}

test "ReadLocation: null when unset" {
    const alloc = std.testing.allocator;
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "/tmp/booktool-test-loc-null-{d}-{d}.db",
        .{ pid, stamp },
    );
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{name});
    defer _ = std.c.unlink(path_z.ptr);

    var cat = try Catalog.open(name);
    defer cat.close();
    try std.testing.expectEqual(@as(?ReadLocation, null), try cat.getLocation(alloc, 999));
}

test "ReadLocation: set then get round-trips location + percent" {
    const alloc = std.testing.allocator;
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buf,
        "/tmp/booktool-test-loc-rt-{d}-{d}.db",
        .{ pid, stamp },
    );
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{name});
    defer _ = std.c.unlink(path_z.ptr);

    var cat = try Catalog.open(name);
    defer cat.close();

    const id = try cat.upsertBook(alloc, .{
        .path = "/tmp/loc-test.epub",
        .sha256 = "deadbeef",
        .size = 1024,
        .format = .epub,
        .mtime = 0,
        .metadata = .{ .title = "Test", .source = .embedded, .confidence = 0.5 },
    });

    try cat.setLocation(id, "epubcfi(/6/4!/4)", 0.42);
    const got = (try cat.getLocation(alloc, id)) orelse return error.MissingRow;
    defer alloc.free(got.location);

    try std.testing.expectEqualStrings("epubcfi(/6/4!/4)", got.location);
    try std.testing.expect(got.percent.? > 0.41 and got.percent.? < 0.43);

    try cat.setLocation(id, "epubcfi(/6/8)", 0.84);
    const got2 = (try cat.getLocation(alloc, id)) orelse return error.MissingRow;
    defer alloc.free(got2.location);
    try std.testing.expectEqualStrings("epubcfi(/6/8)", got2.location);

    try cat.deleteLocation(id);
    try std.testing.expectEqual(@as(?ReadLocation, null), try cat.getLocation(alloc, id));
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
    if (b.original_path) |s| alloc.free(s);
}
