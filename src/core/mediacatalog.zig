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

pub const Status = enum { all, missing_cover, missing_metadata, duplicates };
pub const Sort = enum { kind_title, title, year };
pub const SearchQuery = struct {
    text: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    status: Status = .all,
    sort: Sort = .kind_title,
};

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

    pub fn getById(self: *Catalog, alloc: std.mem.Allocator, id: i64) !?Item {
        var stmt = try sql.prepare(self.db, "SELECT " ++ SELECT_COLS ++ " FROM items WHERE id = ?");
        defer stmt.finalize();
        try stmt.bindInt64(1, id);
        if (!try stmt.step()) return null;
        return try rowToItem(alloc, &stmt);
    }

    pub fn search(self: *Catalog, alloc: std.mem.Allocator, q: SearchQuery) ![]Item {
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(alloc);
        try text_buf.appendSlice(alloc, "SELECT " ++ SELECT_COLS ++ " FROM items WHERE 1=1");
        if (q.kind != null) try text_buf.appendSlice(alloc, " AND kind = ?1");
        if (q.text != null) try text_buf.appendSlice(alloc, " AND (title LIKE ?2 ESCAPE '\\' OR subtitle LIKE ?2 ESCAPE '\\')");
        switch (q.status) {
            .all => {},
            .missing_cover => try text_buf.appendSlice(alloc, " AND has_cover = 0"),
            .missing_metadata => try text_buf.appendSlice(alloc, " AND has_metadata = 0"),
            .duplicates => try text_buf.appendSlice(alloc, " AND is_duplicate = 1"),
        }
        const order = switch (q.sort) {
            .kind_title => " ORDER BY kind, sort_title",
            .title => " ORDER BY sort_title",
            .year => " ORDER BY year DESC, sort_title",
        };
        try text_buf.appendSlice(alloc, order);

        var stmt = try sql.prepare(self.db, text_buf.items);
        defer stmt.finalize();
        if (q.kind) |k| try stmt.bindText(1, k);
        if (q.text) |t| {
            var esc: std.ArrayList(u8) = .empty;
            defer esc.deinit(alloc);
            try esc.append(alloc, '%');
            for (t) |ch| {
                if (ch == '%' or ch == '_' or ch == '\\') try esc.append(alloc, '\\');
                try esc.append(alloc, ch);
            }
            try esc.append(alloc, '%');
            try stmt.bindText(2, esc.items);
        }

        var out: std.ArrayList(Item) = .empty;
        errdefer {
            for (out.items) |*it| it.deinit(alloc);
            out.deinit(alloc);
        }
        while (try stmt.step()) {
            try out.append(alloc, try rowToItem(alloc, &stmt));
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn count(self: *Catalog) !i64 {
        var stmt = try sql.prepare(self.db, "SELECT COUNT(*) FROM items");
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt64(0);
    }

    pub fn clear(self: *Catalog) !void {
        try sql.exec(self.db, "DELETE FROM items;");
    }

    pub fn deleteUnderPath(self: *Catalog, prefix: []const u8) !usize {
        var stmt = try sql.prepare(self.db, "DELETE FROM items WHERE path = ?1 OR path LIKE ?2 ESCAPE '\\'");
        defer stmt.finalize();
        // ?2 matches children: prefix ++ "/%", with LIKE metacharacters in prefix escaped.
        var esc: std.ArrayList(u8) = .empty;
        defer esc.deinit(std.heap.page_allocator);
        for (prefix) |ch| {
            if (ch == '%' or ch == '_' or ch == '\\') try esc.append(std.heap.page_allocator, '\\');
            try esc.append(std.heap.page_allocator, ch);
        }
        try esc.appendSlice(std.heap.page_allocator, "/%");
        try stmt.bindText(1, prefix);
        try stmt.bindText(2, esc.items);
        _ = try stmt.step();
        const n = sql.changes(self.db);
        return if (n < 0) 0 else @intCast(n);
    }

    pub fn allPaths(self: *Catalog, alloc: std.mem.Allocator) ![][]const u8 {
        var stmt = try sql.prepare(self.db, "SELECT path FROM items ORDER BY path");
        defer stmt.finalize();
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |p| alloc.free(p);
            out.deinit(alloc);
        }
        while (try stmt.step()) {
            try out.append(alloc, try alloc.dupe(u8, stmt.columnText(0) orelse ""));
        }
        return out.toOwnedSlice(alloc);
    }
};

pub fn defaultPath(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(alloc, &.{ xdg, "mediastacks", "media.db" });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "mediastacks", "media.db" });
}

test "upsertItem inserts then updates by path" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/mediastacks-mc-{d}.db", .{clock.nowSeconds()});
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

fn freeItems(a: std.mem.Allocator, items: []Item) void {
    for (items) |*it| it.deinit(a);
    a.free(items);
}

test "search filters by kind, text and status" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/mediastacks-mc-search-{d}.db", .{clock.nowSeconds()});
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = std.c.unlink(path_z.ptr);
    var cat = try Catalog.open(path);
    defer cat.close();

    try cat.upsertItem(.{ .kind = "movie", .path = "Movies/Dune (2021)", .title = "Dune",
        .sort_title = "dune", .has_cover = true, .has_metadata = true });
    try cat.upsertItem(.{ .kind = "movie", .path = "Movies/Blade Runner (1982)", .title = "Blade Runner",
        .sort_title = "blade runner", .has_cover = false, .has_metadata = true });
    try cat.upsertItem(.{ .kind = "tv", .path = "Shows/Severance", .title = "Severance",
        .sort_title = "severance", .has_cover = true, .has_metadata = false });

    const all = try cat.search(a, .{});
    defer freeItems(a, all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const movies = try cat.search(a, .{ .kind = "movie" });
    defer freeItems(a, movies);
    try std.testing.expectEqual(@as(usize, 2), movies.len);
    // kind_title sort → "blade runner" before "dune"
    try std.testing.expectEqualStrings("Blade Runner", movies[0].title);

    const text = try cat.search(a, .{ .text = "sever" });
    defer freeItems(a, text);
    try std.testing.expectEqual(@as(usize, 1), text.len);
    try std.testing.expectEqualStrings("Severance", text[0].title);

    const no_cover = try cat.search(a, .{ .status = .missing_cover });
    defer freeItems(a, no_cover);
    try std.testing.expectEqual(@as(usize, 1), no_cover.len);
    try std.testing.expectEqualStrings("Blade Runner", no_cover[0].title);
}

test "deleteUnderPath, clear, allPaths, defaultPath" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/mediastacks-mc-del-{d}.db", .{clock.nowSeconds()});
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    defer _ = std.c.unlink(path_z.ptr);
    var cat = try Catalog.open(path);
    defer cat.close();

    try cat.upsertItem(.{ .kind = "tv", .path = "Shows/Severance", .title = "S", .sort_title = "s" });
    try cat.upsertItem(.{ .kind = "tv", .path = "Shows/Severance Special", .title = "SS", .sort_title = "ss" });
    try cat.upsertItem(.{ .kind = "movie", .path = "Movies/Dune (2021)", .title = "D", .sort_title = "d" });

    // Only the exact folder + its children go — the sibling "Severance Special" stays.
    const removed = try cat.deleteUnderPath("Shows/Severance");
    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expectEqual(@as(i64, 2), try cat.count());

    const paths = try cat.allPaths(a);
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 2), paths.len);

    try cat.clear();
    try std.testing.expectEqual(@as(i64, 0), try cat.count());

    // defaultPath honours XDG_DATA_HOME.
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/data");
    const dp = try defaultPath(a, &env);
    defer a.free(dp);
    try std.testing.expectEqualStrings("/data/mediastacks/media.db", dp);
}

test "search treats % and _ in query as literal" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/mediastacks-mc-like-{d}.db", .{clock.nowSeconds()});
    var pz: [96]u8 = undefined;
    const pz2 = try std.fmt.bufPrintZ(&pz, "{s}", .{path});
    defer _ = std.c.unlink(pz2.ptr);
    var cat = try Catalog.open(path);
    defer cat.close();
    try cat.upsertItem(.{ .kind = "movie", .path = "Movies/50% Off", .title = "50% Off", .sort_title = "50% off" });
    try cat.upsertItem(.{ .kind = "movie", .path = "Movies/5000 Reasons", .title = "5000 Reasons", .sort_title = "5000 reasons" });

    // "50%" must match "50% Off" literally, NOT "5000 Reasons" (which it would
    // if % were a wildcard).
    const hits = try cat.search(a, .{ .text = "50%" });
    defer { for (hits) |*it| it.deinit(a); a.free(hits); }
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqualStrings("50% Off", hits[0].title);
}

test "getById returns the row or null" {
    const a = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/mediastacks-mc-byid-{d}.db", .{clock.nowSeconds()});
    var pz: [96]u8 = undefined;
    const pathz = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch unreachable;
    defer _ = std.c.unlink(pathz.ptr);

    var cat = try Catalog.open(path);
    defer cat.close();
    try cat.upsertItem(.{ .kind = "movie", .path = "Movies/Dune (2021)", .title = "Dune", .sort_title = "dune", .year = 2021 });

    // Look up the row's id via getByPath, then fetch it by id.
    var byPath = (try cat.getByPath(a, "Movies/Dune (2021)")).?;
    const id = byPath.id;
    byPath.deinit(a);

    var got = (try cat.getById(a, id)).?;
    defer got.deinit(a);
    try std.testing.expectEqualStrings("Dune", got.title);
    try std.testing.expectEqual(id, got.id);

    try std.testing.expectEqual(@as(?Item, null), try cat.getById(a, 99999));
}

test "deleteUnderPath escapes LIKE metacharacters in the prefix" {
    var buf: [80]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/mediastacks-mc-delesc-{d}.db", .{clock.nowSeconds()});
    var pz: [112]u8 = undefined;
    const pz2 = try std.fmt.bufPrintZ(&pz, "{s}", .{path});
    defer _ = std.c.unlink(pz2.ptr);
    var cat = try Catalog.open(path);
    defer cat.close();
    // Prefix "Music/AC_DC" — the '_' must be literal, so a sibling "Music/ACxDC"
    // (which '_' would match as a wildcard) must survive.
    try cat.upsertItem(.{ .kind = "music", .path = "Music/AC_DC", .title = "t", .sort_title = "t" });
    try cat.upsertItem(.{ .kind = "music", .path = "Music/AC_DC/Album", .title = "t", .sort_title = "t" });
    try cat.upsertItem(.{ .kind = "music", .path = "Music/ACxDC", .title = "t", .sort_title = "t" });

    const removed = try cat.deleteUnderPath("Music/AC_DC");
    try std.testing.expectEqual(@as(usize, 2), removed); // AC_DC + AC_DC/Album
    try std.testing.expectEqual(@as(i64, 1), try cat.count()); // ACxDC survives
}
