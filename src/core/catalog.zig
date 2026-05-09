//! SQLite-backed catalog of every book booktool has seen.
//!
//! Single file at `~/.local/share/booktool/catalog.db`. Schema is created
//! on open if missing.

const std = @import("std");
const c = @import("c");
const ffi = @import("../ffi/sqlite3.zig");
const meta = @import("metadata.zig");

pub const SCHEMA_VERSION: i32 = 1;

pub const Catalog = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Catalog {
        const db = try ffi.open(path);
        var cat = Catalog{ .db = db, .allocator = allocator };
        try cat.initSchema();
        return cat;
    }

    pub fn close(self: *Catalog) void {
        ffi.close(self.db);
    }

    fn initSchema(self: *Catalog) !void {
        try ffi.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS schema_version (
            \\  version INTEGER NOT NULL
            \\);
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
            \\CREATE INDEX IF NOT EXISTS idx_books_sha256  ON books(sha256);
            \\CREATE INDEX IF NOT EXISTS idx_books_isbn    ON books(isbn);
            \\CREATE INDEX IF NOT EXISTS idx_books_author  ON books(author_sort);
            \\CREATE TABLE IF NOT EXISTS metadata_sources (
            \\  book_id     INTEGER NOT NULL,
            \\  source      TEXT    NOT NULL,
            \\  payload_json TEXT,
            \\  fetched_at  INTEGER NOT NULL,
            \\  PRIMARY KEY (book_id, source),
            \\  FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
            \\);
            \\CREATE TABLE IF NOT EXISTS duplicates (
            \\  book_id     INTEGER NOT NULL,
            \\  dup_of_id   INTEGER NOT NULL,
            \\  reason      TEXT NOT NULL,
            \\  score       REAL,
            \\  PRIMARY KEY (book_id, dup_of_id),
            \\  FOREIGN KEY (book_id)   REFERENCES books(id) ON DELETE CASCADE,
            \\  FOREIGN KEY (dup_of_id) REFERENCES books(id) ON DELETE CASCADE
            \\);
        );
        // Stamp schema version row if empty.
        try ffi.exec(self.db, "INSERT OR IGNORE INTO schema_version (rowid, version) VALUES (1, 1);");
    }

    /// Default catalog path under XDG_DATA_HOME or ~/.local/share/booktool.
    pub fn defaultPath(allocator: std.mem.Allocator, env: *const std.process.EnvMap) ![]const u8 {
        if (env.get("XDG_DATA_HOME")) |xdg| {
            return std.fs.path.join(allocator, &.{ xdg, "booktool", "catalog.db" });
        }
        const home = env.get("HOME") orelse return error.NoHome;
        return std.fs.path.join(allocator, &.{ home, ".local", "share", "booktool", "catalog.db" });
    }
};

test "schema version constant exists" {
    try std.testing.expectEqual(@as(i32, 1), SCHEMA_VERSION);
}
