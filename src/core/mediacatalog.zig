const std = @import("std");
const c = @import("c");
const sql = @import("../ffi/sqlite3.zig");
const clock = @import("../util/clock.zig");
const standardize = @import("standardize.zig");

pub const Item = struct {
    id: i64 = 0,
    kind: []const u8,
    path: []const u8,
    title: []const u8,
    sort_title: []const u8,
    year: ?i64 = null,
    subtitle: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    provider_id: ?[]const u8 = null,
    cover_path: ?[]const u8 = null,
    primary_path: ?[]const u8 = null,
    container: ?[]const u8 = null,
    playable_inline: bool = false,
    file_count: i64 = 0,
    total_bytes: i64 = 0,
    has_metadata: bool = false,
    has_cover: bool = false,
    is_duplicate: bool = false,
    mtime: i64 = 0,
    indexed_at: i64 = 0,
    extra: ?[]const u8 = null,

    /// Free strings owned by rows returned from getByPath/search (which dupe
    /// into the caller's allocator). Do NOT call on literal-built Items.
    pub fn deinit(self: *Item, alloc: std.mem.Allocator) void {
        alloc.free(self.kind);
        alloc.free(self.path);
        alloc.free(self.title);
        alloc.free(self.sort_title);
        if (self.subtitle) |v| alloc.free(v);
        if (self.provider) |v| alloc.free(v);
        if (self.provider_id) |v| alloc.free(v);
        if (self.cover_path) |v| alloc.free(v);
        if (self.primary_path) |v| alloc.free(v);
        if (self.container) |v| alloc.free(v);
        if (self.extra) |v| alloc.free(v);
    }
};

const SELECT_COLS =
    "id,kind,path,title,sort_title,year,subtitle,provider,provider_id," ++
    "cover_path,primary_path,container,playable_inline,file_count,total_bytes," ++
    "has_metadata,has_cover,is_duplicate,mtime,indexed_at,extra";

pub const Catalog = struct {
    db: *c.sqlite3,

    pub fn open(path: []const u8) !Catalog {
        if (std.fs.path.dirname(path)) |d| standardize.mkdirParents(d) catch {};
        const db = try sql.open(path);
        var cat = Catalog{ .db = db };
        try cat.ensureSchema();
        return cat;
    }

    pub fn close(self: *Catalog) void {
        sql.close(self.db);
    }

    fn ensureSchema(self: *Catalog) !void {
        try sql.exec(self.db,
            \\CREATE TABLE IF NOT EXISTS items (
            \\  id              INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  kind            TEXT    NOT NULL,
            \\  path            TEXT    NOT NULL UNIQUE,
            \\  title           TEXT    NOT NULL,
            \\  sort_title      TEXT    NOT NULL,
            \\  year            INTEGER,
            \\  subtitle        TEXT,
            \\  provider        TEXT,
            \\  provider_id     TEXT,
            \\  cover_path      TEXT,
            \\  primary_path    TEXT,
            \\  container       TEXT,
            \\  playable_inline INTEGER NOT NULL DEFAULT 0,
            \\  file_count      INTEGER NOT NULL DEFAULT 0,
            \\  total_bytes     INTEGER NOT NULL DEFAULT 0,
            \\  has_metadata    INTEGER NOT NULL DEFAULT 0,
            \\  has_cover       INTEGER NOT NULL DEFAULT 0,
            \\  is_duplicate    INTEGER NOT NULL DEFAULT 0,
            \\  mtime           INTEGER NOT NULL DEFAULT 0,
            \\  indexed_at      INTEGER NOT NULL DEFAULT 0,
            \\  extra           TEXT
            \\);
        );
        try sql.exec(self.db, "CREATE INDEX IF NOT EXISTS items_kind ON items(kind);");
        try sql.exec(self.db, "CREATE INDEX IF NOT EXISTS items_sort ON items(kind, sort_title);");
    }

    fn b01(x: bool) i64 {
        return if (x) 1 else 0;
    }

    pub fn upsertItem(self: *Catalog, it: Item) !void {
        var stmt = try sql.prepare(self.db,
            \\INSERT INTO items
            \\ (kind,path,title,sort_title,year,subtitle,provider,provider_id,
            \\  cover_path,primary_path,container,playable_inline,file_count,total_bytes,
            \\  has_metadata,has_cover,is_duplicate,mtime,indexed_at,extra)
            \\ VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            \\ ON CONFLICT(path) DO UPDATE SET
            \\  kind=excluded.kind, title=excluded.title, sort_title=excluded.sort_title,
            \\  year=excluded.year, subtitle=excluded.subtitle, provider=excluded.provider,
            \\  provider_id=excluded.provider_id, cover_path=excluded.cover_path,
            \\  primary_path=excluded.primary_path, container=excluded.container,
            \\  playable_inline=excluded.playable_inline, file_count=excluded.file_count,
            \\  total_bytes=excluded.total_bytes, has_metadata=excluded.has_metadata,
            \\  has_cover=excluded.has_cover, is_duplicate=excluded.is_duplicate,
            \\  mtime=excluded.mtime, indexed_at=excluded.indexed_at, extra=excluded.extra;
        );
        defer stmt.finalize();
        try stmt.bindText(1, it.kind);
        try stmt.bindText(2, it.path);
        try stmt.bindText(3, it.title);
        try stmt.bindText(4, it.sort_title);
        try stmt.bindNullableInt64(5, it.year);
        try stmt.bindNullableText(6, it.subtitle);
        try stmt.bindNullableText(7, it.provider);
        try stmt.bindNullableText(8, it.provider_id);
        try stmt.bindNullableText(9, it.cover_path);
        try stmt.bindNullableText(10, it.primary_path);
        try stmt.bindNullableText(11, it.container);
        try stmt.bindInt64(12, b01(it.playable_inline));
        try stmt.bindInt64(13, it.file_count);
        try stmt.bindInt64(14, it.total_bytes);
        try stmt.bindInt64(15, b01(it.has_metadata));
        try stmt.bindInt64(16, b01(it.has_cover));
        try stmt.bindInt64(17, b01(it.is_duplicate));
        try stmt.bindInt64(18, it.mtime);
        try stmt.bindInt64(19, it.indexed_at);
        try stmt.bindNullableText(20, it.extra);
        _ = try stmt.step();
    }

    fn dupOpt(alloc: std.mem.Allocator, v: ?[]const u8) !?[]const u8 {
        return if (v) |s| try alloc.dupe(u8, s) else null;
    }

    /// Read the current row of `stmt` (columns in SELECT_COLS order) into an
    /// Item whose strings are owned by `alloc`.
    fn rowToItem(alloc: std.mem.Allocator, stmt: *sql.Stmt) !Item {
        return .{
            .id = stmt.columnInt64(0),
            .kind = try alloc.dupe(u8, stmt.columnText(1) orelse ""),
            .path = try alloc.dupe(u8, stmt.columnText(2) orelse ""),
            .title = try alloc.dupe(u8, stmt.columnText(3) orelse ""),
            .sort_title = try alloc.dupe(u8, stmt.columnText(4) orelse ""),
            .year = if (stmt.columnIsNull(5)) null else stmt.columnInt64(5),
            .subtitle = try dupOpt(alloc, stmt.columnText(6)),
            .provider = try dupOpt(alloc, stmt.columnText(7)),
            .provider_id = try dupOpt(alloc, stmt.columnText(8)),
            .cover_path = try dupOpt(alloc, stmt.columnText(9)),
            .primary_path = try dupOpt(alloc, stmt.columnText(10)),
            .container = try dupOpt(alloc, stmt.columnText(11)),
            .playable_inline = stmt.columnInt64(12) != 0,
            .file_count = stmt.columnInt64(13),
            .total_bytes = stmt.columnInt64(14),
            .has_metadata = stmt.columnInt64(15) != 0,
            .has_cover = stmt.columnInt64(16) != 0,
            .is_duplicate = stmt.columnInt64(17) != 0,
            .mtime = stmt.columnInt64(18),
            .indexed_at = stmt.columnInt64(19),
            .extra = try dupOpt(alloc, stmt.columnText(20)),
        };
    }

    pub fn getByPath(self: *Catalog, alloc: std.mem.Allocator, path: []const u8) !?Item {
        var stmt = try sql.prepare(self.db, "SELECT " ++ SELECT_COLS ++ " FROM items WHERE path = ?");
        defer stmt.finalize();
        try stmt.bindText(1, path);
        if (!try stmt.step()) return null;
        return try rowToItem(alloc, &stmt);
    }

    pub fn count(self: *Catalog) !i64 {
        var stmt = try sql.prepare(self.db, "SELECT COUNT(*) FROM items");
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt64(0);
    }
};

test "upsertItem inserts then updates by path" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/stacks-mc-{d}.db", .{clock.nowSeconds()});
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = std.c.unlink(path_z.ptr);

    var cat = try Catalog.open(path);
    defer cat.close();

    try cat.upsertItem(.{
        .kind = "movie", .path = "Movies/Dune (2021)", .title = "Dune",
        .sort_title = "dune", .year = 2021, .provider = "tmdb", .provider_id = "438631",
        .container = "mkv", .playable_inline = false, .file_count = 1, .has_metadata = true,
    });
    var got = (try cat.getByPath(a, "Movies/Dune (2021)")).?;
    defer got.deinit(a);
    try std.testing.expectEqualStrings("Dune", got.title);
    try std.testing.expectEqual(@as(?i64, 2021), got.year);
    try std.testing.expect(got.has_metadata);

    // Same path again → update, not a second row.
    try cat.upsertItem(.{
        .kind = "movie", .path = "Movies/Dune (2021)", .title = "Dune: Part One",
        .sort_title = "dune part one", .year = 2021, .file_count = 2,
    });
    var got2 = (try cat.getByPath(a, "Movies/Dune (2021)")).?;
    defer got2.deinit(a);
    try std.testing.expectEqualStrings("Dune: Part One", got2.title);
    try std.testing.expectEqual(@as(i64, 2), got2.file_count);
    try std.testing.expectEqual(@as(i64, 1), try cat.count());
}
