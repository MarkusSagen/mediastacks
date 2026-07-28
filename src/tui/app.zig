//! Terminal UI for booktool.
//!
//! Four modes:
//!
//!   - LIST    Author / Series-grouped library with status + trust
//!             glyphs. Cursor navigates books only (group headers are
//!             non-selectable rows). `j`/`k` move 1; `J`/`K` move 10.
//!             `r` cycles read status, `i` enriches, `e` opens the
//!             detail popup, `/` enters FILTER, `Enter` reads.
//!
//!   - FILTER  An incremental search overlay anchored to the status
//!             bar. Updates the visible book set as the user types.
//!             Supports `author:foo`, `series:bar`, `format:epub`
//!             prefix tokens — same syntax as the web search bar.
//!             Esc returns to LIST without committing; Enter commits.
//!
//!   - DETAIL  A centered popup mirroring the web detail panel —
//!             hero (title/author/series-link), meta row
//!             (status · trust · format), facts (year/publisher/isbn
//!             /language/subjects), description preview, footer
//!             (path + sha + cover-override indicator). `e` toggles
//!             inline edit mode; `i` enriches; Esc/q returns.
//!
//!   - READER  Paginated EPUB text view (unchanged from the v1 TUI
//!             except for a progress bar at the bottom).
//!
//! Renders via libvaxis. Catalog mutations (read-status, edit, enrich)
//! flow through `catalog_mod.Catalog` directly; the same code paths
//! the web API uses. After any mutation we refetch the affected book
//! so the cursor row reflects the new state.

const std = @import("std");
const vaxis = @import("vaxis");
const catalog_mod = @import("../core/catalog.zig");
const epub_chapters = @import("../formats/epub_chapters.zig");
const meta = @import("../core/metadata.zig");
const reflow = @import("reflow.zig");
const groups = @import("groups.zig");
const cover_store = @import("../core/cover_store.zig");
const openlibrary = @import("../providers/openlibrary.zig");
const provider_iface = @import("../providers/provider.zig");
const path_meta = @import("../core/path_meta.zig");
const sources_mod = @import("../commands/sources.zig");
const http_mod = @import("../util/http.zig");

const View = enum { list, filter, detail, reader, help };

const SortOrder = enum {
    author,
    title,
    year_desc,
    year_asc,
    added_desc,

    pub fn label(self: SortOrder) []const u8 {
        return switch (self) {
            .author => "author",
            .title => "title",
            .year_desc => "year ↓",
            .year_asc => "year ↑",
            .added_desc => "added",
        };
    }

    pub fn next(self: SortOrder) SortOrder {
        return switch (self) {
            .author => .title,
            .title => .year_desc,
            .year_desc => .year_asc,
            .year_asc => .added_desc,
            .added_desc => .author,
        };
    }
};

pub const App = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cat: *catalog_mod.Catalog,

    all_books: []catalog_mod.Book,
    visible_books: []catalog_mod.Book = &.{},
    events_buf: []groups.Event = &.{},
    events: []const groups.Event = &.{},

    cursor: usize = 0,
    list_scroll: usize = 0,
    view: View = .list,
    status: ?[]const u8 = null,
    sort: SortOrder = .author,

    filter_input: std.ArrayList(u8) = .empty,
    filter_active: bool = false,

    detail_book_id: ?i64 = null,
    detail_editing: bool = false,
    detail_field_idx: usize = 0,
    detail_inputs: [5]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty, .empty },

    book_arena: ?std.heap.ArenaAllocator = null,
    reader_lines: []const []const u8 = &.{},
    reader_page: usize = 0,
    reader_book_title: []const u8 = "",
};

const Color = struct {
    const accent: vaxis.Cell.Color = .{ .index = 214 };
    const dim: vaxis.Cell.Color = .{ .index = 244 };
    const mute: vaxis.Cell.Color = .{ .index = 240 };
    const ok: vaxis.Cell.Color = .{ .index = 71 };
    const warn: vaxis.Cell.Color = .{ .index = 215 };
    const danger: vaxis.Cell.Color = .{ .index = 167 };
    const rail: vaxis.Cell.Color = .{ .index = 236 };
    const rail_hot: vaxis.Cell.Color = .{ .index = 238 };
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cat: *catalog_mod.Catalog,
) !void {
    var app = App{
        .arena = allocator,
        .io = io,
        .env_map = env_map,
        .cat = cat,
        .all_books = &.{},
    };
    defer for (&app.detail_inputs) |*b| b.deinit(allocator);
    defer app.filter_input.deinit(allocator);

    try reloadCatalog(&app);
    if (app.all_books.len == 0) {
        std.log.err("catalog is empty — run `booktool scan DIR` first.", .{});
        return;
    }

    var tty_buf: [64 * 1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, allocator, env_map, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(vaxis.Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .{ .nanoseconds = std.time.ns_per_s });

    const initial_ws = try tty.getWinsize();
    try vx.resize(allocator, tty.writer(), initial_ws);

    {
        const win = vx.window();
        win.clear();
        render(&app, win);
        try vx.render(tty.writer());
    }

    while (true) {
        const event = try loop.nextEvent();
        if (event == .winsize) try vx.resize(allocator, tty.writer(), event.winsize);

        const quit = handleEvent(&app, event) catch |err| blk: {
            setStatus(&app, "{s}", .{@errorName(err)});
            break :blk false;
        };

        const win = vx.window();
        win.clear();
        render(&app, win);
        try vx.render(tty.writer());
        if (quit) break;
    }

    if (app.book_arena) |*a| a.deinit();
}

/// Re-read every book from the catalog and rebuild the visible subset
/// + event stream. Preserves the current cursor's book id when
/// possible.
fn reloadCatalog(app: *App) !void {
    const prev_book_id = currentBookId(app);

    app.all_books = try app.cat.listBooks(app.arena);
    sortInPlace(app.all_books, app.sort);
    try rebuildVisible(app);

    if (prev_book_id) |id| {
        moveCursorToBookId(app, id);
    }
}

/// Apply the current filter to `all_books` → `visible_books` and
/// rebuild the event stream. Called whenever the filter text or sort
/// changes, or after a mutation.
fn rebuildVisible(app: *App) !void {
    if (app.filter_active and app.filter_input.items.len > 0) {
        var keep: std.ArrayList(catalog_mod.Book) = .empty;
        const f = parseFilter(app.filter_input.items);
        for (app.all_books) |b| {
            if (matchesFilter(b, f)) try keep.append(app.arena, b);
        }
        app.visible_books = try keep.toOwnedSlice(app.arena);
    } else {
        app.visible_books = app.all_books;
    }

    const max_events = app.visible_books.len * 4 + 8;
    app.events_buf = try app.arena.alloc(groups.Event, max_events);
    const schema: groups.Schema = if (app.sort == .author) .author_series else .author_series;
    app.events = groups.build(app.visible_books, schema, app.events_buf);

    if (firstBookEventIndex(app.events)) |i| {
        app.cursor = i;
        app.list_scroll = 0;
    } else {
        app.cursor = 0;
        app.list_scroll = 0;
    }
}

fn currentBookId(app: *App) ?i64 {
    if (app.cursor >= app.events.len) return null;
    return switch (app.events[app.cursor]) {
        .book => |b| b.id,
        else => null,
    };
}

fn moveCursorToBookId(app: *App, id: i64) void {
    for (app.events, 0..) |e, i| {
        if (e == .book and e.book.id == id) {
            app.cursor = i;
            return;
        }
    }
}

fn firstBookEventIndex(events: []const groups.Event) ?usize {
    for (events, 0..) |e, i| if (e == .book) return i;
    return null;
}

fn sortInPlace(books: []catalog_mod.Book, order: SortOrder) void {
    const Ctx = struct {
        order: SortOrder,

        pub fn lessThan(ctx: @This(), a: catalog_mod.Book, b: catalog_mod.Book) bool {
            return switch (ctx.order) {
                .author => authorThen(a, b),
                .title => std.mem.lessThan(u8, titleOf(a), titleOf(b)),
                .year_desc => yearOf(b) < yearOf(a),
                .year_asc => yearOf(a) < yearOf(b),
                .added_desc => b.added_at < a.added_at,
            };
        }

        fn authorThen(a: catalog_mod.Book, b: catalog_mod.Book) bool {
            const cmp = std.mem.order(u8, authorSort(a), authorSort(b));
            if (cmp != .eq) return cmp == .lt;
            const sa = a.metadata.series orelse "";
            const sb = b.metadata.series orelse "";
            const sc = std.mem.order(u8, sa, sb);
            if (sc != .eq) return sc == .lt;
            const ia = a.metadata.series_index orelse std.math.floatMax(f32);
            const ib = b.metadata.series_index orelse std.math.floatMax(f32);
            if (ia != ib) return ia < ib;
            return std.mem.lessThan(u8, titleOf(a), titleOf(b));
        }

        fn authorSort(b: catalog_mod.Book) []const u8 {
            if (b.metadata.authors.len > 0) return b.metadata.authors[0].sort;
            return "~";
        }
        fn titleOf(b: catalog_mod.Book) []const u8 {
            return b.metadata.title orelse "";
        }
        fn yearOf(b: catalog_mod.Book) u16 {
            return b.metadata.published_year orelse 0;
        }
    };
    std.sort.block(catalog_mod.Book, books, Ctx{ .order = order }, Ctx.lessThan);
}

const ParsedFilter = struct {
    text: []const u8 = "",
    author: ?[]const u8 = null,
    series: ?[]const u8 = null,
    format: ?meta.Format = null,
};

/// Parse `freeform foo author:Hobb series:Farseer format:epub`. Splits
/// on whitespace; key:value tokens become typed filters, everything
/// else becomes the free-text needle. Quoting isn't supported (rare
/// for typed CLI input — author names with spaces stay matched via
/// substring against the free text).
fn parseFilter(input: []const u8) ParsedFilter {
    var f: ParsedFilter = .{};
    var text_start: usize = 0;
    var text_end: usize = input.len;
    var i: usize = 0;
    var last_text_end: usize = 0;
    while (i < input.len) {
        while (i < input.len and input[i] == ' ') i += 1;
        const tok_start = i;
        while (i < input.len and input[i] != ' ') i += 1;
        const tok = input[tok_start..i];
        if (tok.len == 0) break;

        if (std.mem.indexOfScalar(u8, tok, ':')) |colon| {
            const key = tok[0..colon];
            const val = tok[colon + 1 ..];
            if (std.mem.eql(u8, key, "author")) {
                f.author = val;
                continue;
            } else if (std.mem.eql(u8, key, "series")) {
                f.series = val;
                continue;
            } else if (std.mem.eql(u8, key, "format")) {
                f.format = meta.Format.fromExtension(val);
                if (f.format.? == .unknown) f.format = null;
                continue;
            }
        }
        if (last_text_end == 0) text_start = tok_start;
        last_text_end = i;
    }
    if (last_text_end > 0) text_end = last_text_end else text_start = 0;
    f.text = input[text_start..@min(text_end, input.len)];
    return f;
}

fn matchesFilter(b: catalog_mod.Book, f: ParsedFilter) bool {
    if (f.format) |fmt| if (b.format != fmt) return false;
    if (f.author) |a| {
        const sort = if (b.metadata.authors.len > 0) b.metadata.authors[0].sort else "";
        if (!containsCI(sort, a)) return false;
    }
    if (f.series) |s| {
        const series = b.metadata.series orelse "";
        if (!containsCI(series, s)) return false;
    }
    if (f.text.len > 0) {
        const title = b.metadata.title orelse "";
        const author = if (b.metadata.authors.len > 0) b.metadata.authors[0].sort else "";
        const series = b.metadata.series orelse "";
        if (!containsCI(title, f.text) and !containsCI(author, f.text) and !containsCI(series, f.text)) {
            return false;
        }
    }
    return true;
}

/// ASCII-only case-insensitive substring search. Good enough for the
/// filter UI — author/series strings are overwhelmingly ASCII; for
/// non-Latin titles we still do a case-sensitive substring as a
/// fallback (the lowercase comparison still works if the user types
/// the same bytes).
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, k| {
            if (std.ascii.toLower(c) != std.ascii.toLower(haystack[i + k])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn handleEvent(app: *App, event: vaxis.Event) !bool {
    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) return true;
            return switch (app.view) {
                .list => listKey(app, key),
                .filter => filterKey(app, key),
                .detail => detailKey(app, key),
                .reader => readerKey(app, key),
                .help => helpKey(app, key),
            };
        },
        else => return false,
    }
}

fn listKey(app: *App, key: vaxis.Key) !bool {
    if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
        if (app.filter_active) {
            app.filter_active = false;
            app.filter_input.clearRetainingCapacity();
            try rebuildVisible(app);
            return false;
        }
        return true;
    }
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        cursorMove(app, 1);
        return false;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        cursorMove(app, -1);
        return false;
    }
    if (key.matches('J', .{ .shift = true })) {
        cursorMove(app, 10);
        return false;
    }
    if (key.matches('K', .{ .shift = true })) {
        cursorMove(app, -10);
        return false;
    }
    if (key.matches('g', .{})) {
        cursorToFirst(app);
        return false;
    }
    if (key.matches('G', .{ .shift = true })) {
        cursorToLast(app);
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        try openSelected(app);
        return false;
    }
    if (key.matches('/', .{})) {
        app.view = .filter;
        if (!app.filter_active) app.filter_input.clearRetainingCapacity();
        return false;
    }
    if (key.matches('e', .{})) {
        try openDetail(app);
        return false;
    }
    if (key.matches('r', .{})) {
        try toggleReadStatus(app);
        return false;
    }
    if (key.matches('i', .{})) {
        try enrichSelected(app);
        return false;
    }
    if (key.matches('s', .{})) {
        try cycleSort(app);
        return false;
    }
    if (key.matches('B', .{ .shift = true })) {
        try backfillPaths(app);
        return false;
    }
    if (key.matches('R', .{ .shift = true })) {
        try rescanAllSources(app);
        return false;
    }
    if (key.matches('?', .{ .shift = true })) {
        app.view = .help;
        return false;
    }
    return false;
}

fn cursorMove(app: *App, delta: isize) void {
    if (app.events.len == 0) return;
    var i: isize = @intCast(app.cursor);
    const step: isize = if (delta > 0) 1 else -1;
    var remaining: isize = if (delta > 0) delta else -delta;
    while (remaining > 0) {
        i += step;
        if (i < 0 or i >= @as(isize, @intCast(app.events.len))) break;
        if (app.events[@intCast(i)] == .book) {
            app.cursor = @intCast(i);
            remaining -= 1;
        }
    }
}

fn cursorToFirst(app: *App) void {
    if (firstBookEventIndex(app.events)) |i| {
        app.cursor = i;
        app.list_scroll = 0;
    }
}

fn cursorToLast(app: *App) void {
    var i: usize = app.events.len;
    while (i > 0) {
        i -= 1;
        if (app.events[i] == .book) {
            app.cursor = i;
            return;
        }
    }
}

fn cycleSort(app: *App) !void {
    app.sort = app.sort.next();
    setStatus(app, "sort: {s}", .{app.sort.label()});
    try reloadCatalog(app);
}

fn toggleReadStatus(app: *App) !void {
    const id = currentBookId(app) orelse return;
    const book = (try app.cat.getBookById(app.arena, id)) orelse return;
    const next: catalog_mod.ReadStatus = switch (book.read_status) {
        .unread => .reading,
        .reading => .finished,
        .finished => .unread,
    };
    try app.cat.setReadStatus(id, next);
    setStatus(app, "marked {s} as {s}", .{ titlePreview(book), @tagName(next) });
    try reloadCatalog(app);
}

fn enrichSelected(app: *App) !void {
    const id = currentBookId(app) orelse return;
    const book = (try app.cat.getBookById(app.arena, id)) orelse return;

    setStatus(app, "fetching info for {s}…", .{titlePreview(book)});

    const derived = path_meta.fromPath(app.arena, book.path) catch path_meta.Derived{};

    var real_http = http_mod.RealHttpClient{ .io = app.io };
    var ol = openlibrary.OpenLibrary{ .http_client = real_http.client() };
    const q = provider_iface.Query{
        .isbn = book.metadata.isbn,
        .title = book.metadata.title orelse derived.title,
        .author = if (book.metadata.authors.len > 0)
            book.metadata.authors[0].sort
        else
            derived.author,
    };
    const rich = (ol.lookupRich(app.arena, app.io, q) catch null) orelse {
        setStatus(app, "no match on Open Library", .{});
        return;
    };

    var merged = try meta.BookMetadata.merge(app.arena, book.metadata, rich.metadata);
    if (derived.series) |s| {
        merged.series = s;
        if (derived.series_index) |idx| merged.series_index = idx;
    }
    _ = try app.cat.upsertBook(app.arena, .{
        .path = book.path,
        .sha256 = book.sha256,
        .size = book.size,
        .format = book.format,
        .mtime = book.mtime,
        .metadata = merged,
    });
    setStatus(app, "enriched: {d} editions, {d} alt covers", .{ rich.editions.len, rich.alt_cover_urls.len });
    try reloadCatalog(app);
}

/// Walk every library source on disk and update the catalog: ingest
/// new files, flag missing ones. Bound to `R` in the TUI.
fn rescanAllSources(app: *App) !void {
    const sources = try app.cat.listSources(app.arena);
    if (sources.len == 0) {
        setStatus(app, "no sources — add one with `booktool sources add PATH`", .{});
        return;
    }
    var total_added: u32 = 0;
    var total_missing: u32 = 0;
    for (sources) |s| {
        setStatus(app, "scanning {s}…", .{s.path});
        const stats = sources_mod.scanSourceFromHttp(app.arena, app.io, app.cat, s.id, s.path) catch |err| {
            setStatus(app, "scan {s}: {s}", .{ s.path, @errorName(err) });
            continue;
        };
        total_added += stats.added;
        total_missing += stats.missing;
    }
    setStatus(app, "rescan: +{d} new, {d} missing across {d} source(s)", .{
        total_added, total_missing, sources.len,
    });
    try reloadCatalog(app);
}

fn backfillPaths(app: *App) !void {
    var updated: u32 = 0;
    for (app.all_books) |b| {
        const d = path_meta.fromPath(app.arena, b.path) catch continue;
        if (d.series == null and d.series_index == null) continue;
        var md = b.metadata;
        var changed = false;
        if (md.series == null and d.series != null) {
            md.series = d.series;
            changed = true;
        }
        const matches = md.series != null and d.series != null and
            std.ascii.eqlIgnoreCase(md.series.?, d.series.?);
        if (md.series_index == null and d.series_index != null and matches) {
            md.series_index = d.series_index;
            changed = true;
        }
        if (!changed) continue;
        _ = app.cat.upsertBook(app.arena, .{
            .path = b.path,
            .sha256 = b.sha256,
            .size = b.size,
            .format = b.format,
            .mtime = b.mtime,
            .metadata = md,
        }) catch continue;
        updated += 1;
    }
    setStatus(app, "backfilled series on {d} book(s)", .{updated});
    try reloadCatalog(app);
}

fn filterKey(app: *App, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.escape, .{})) {
        app.view = .list;
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        app.filter_active = app.filter_input.items.len > 0;
        app.view = .list;
        try rebuildVisible(app);
        return false;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (app.filter_input.items.len > 0) {
            _ = app.filter_input.pop();
            try rebuildVisible(app);
        }
        return false;
    }
    if (key.text) |t| {
        try app.filter_input.appendSlice(app.arena, t);
        try rebuildVisible(app);
    }
    return false;
}

fn openDetail(app: *App) !void {
    const id = currentBookId(app) orelse return;
    app.detail_book_id = id;
    app.detail_editing = false;
    app.view = .detail;
}

fn detailKey(app: *App, key: vaxis.Key) !bool {
    if (app.detail_editing) return detailEditKey(app, key);
    if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
        app.view = .list;
        return false;
    }
    if (key.matches('e', .{})) {
        try enterEditMode(app);
        return false;
    }
    if (key.matches('i', .{})) {
        try enrichSelected(app);
        return false;
    }
    if (key.matches('r', .{})) {
        try toggleReadStatus(app);
        return false;
    }
    return false;
}

const edit_field_keys = [_][]const u8{ "title", "author", "series", "series_index", "year" };

fn enterEditMode(app: *App) !void {
    const id = app.detail_book_id orelse return;
    const book = (try app.cat.getBookById(app.arena, id)) orelse return;
    app.detail_editing = true;
    app.detail_field_idx = 0;

    inline for (.{
        .{ 0, book.metadata.title },
        .{ 2, book.metadata.series },
    }) |pair| {
        const idx: usize = pair[0];
        app.detail_inputs[idx].clearRetainingCapacity();
        if (pair[1]) |s| try app.detail_inputs[idx].appendSlice(app.arena, s);
    }
    app.detail_inputs[1].clearRetainingCapacity();
    if (book.metadata.authors.len > 0) {
        try app.detail_inputs[1].appendSlice(app.arena, book.metadata.authors[0].sort);
    }
    app.detail_inputs[3].clearRetainingCapacity();
    if (book.metadata.series_index) |idx| {
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{idx});
        try app.detail_inputs[3].appendSlice(app.arena, s);
    }
    app.detail_inputs[4].clearRetainingCapacity();
    if (book.metadata.published_year) |y| {
        var buf: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{y});
        try app.detail_inputs[4].appendSlice(app.arena, s);
    }
}

fn detailEditKey(app: *App, key: vaxis.Key) !bool {
    if (key.matches(vaxis.Key.escape, .{})) {
        app.detail_editing = false;
        return false;
    }
    if (key.matches(vaxis.Key.tab, .{})) {
        app.detail_field_idx = (app.detail_field_idx + 1) % edit_field_keys.len;
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        try commitEdit(app);
        return false;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        const buf = &app.detail_inputs[app.detail_field_idx];
        if (buf.items.len > 0) _ = buf.pop();
        return false;
    }
    if (key.text) |t| {
        try app.detail_inputs[app.detail_field_idx].appendSlice(app.arena, t);
    }
    return false;
}

fn commitEdit(app: *App) !void {
    const id = app.detail_book_id orelse return;
    const book = (try app.cat.getBookById(app.arena, id)) orelse return;
    var md = book.metadata;

    if (app.detail_inputs[0].items.len > 0) md.title = try app.arena.dupe(u8, app.detail_inputs[0].items);
    if (app.detail_inputs[1].items.len > 0) {
        const a = try meta.Author.fromDisplay(app.arena, app.detail_inputs[1].items);
        md.authors = try app.arena.dupe(meta.Author, &[_]meta.Author{a});
    }
    if (app.detail_inputs[2].items.len > 0) md.series = try app.arena.dupe(u8, app.detail_inputs[2].items);
    if (app.detail_inputs[3].items.len > 0) md.series_index = std.fmt.parseFloat(f32, app.detail_inputs[3].items) catch null;
    if (app.detail_inputs[4].items.len > 0) md.published_year = std.fmt.parseInt(u16, app.detail_inputs[4].items, 10) catch null;

    md.source = .manual;
    md.confidence = 1.0;

    _ = try app.cat.upsertBook(app.arena, .{
        .path = book.path,
        .sha256 = book.sha256,
        .size = book.size,
        .format = book.format,
        .mtime = book.mtime,
        .metadata = md,
    });

    app.detail_editing = false;
    setStatus(app, "saved", .{});
    try reloadCatalog(app);
}

fn helpKey(app: *App, key: vaxis.Key) !bool {
    _ = key;
    app.view = .list;
    return false;
}

fn readerKey(app: *App, key: vaxis.Key) !bool {
    if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
        closeReader(app);
        return false;
    }
    if (key.matches(' ', .{}) or
        key.matches('l', .{}) or
        key.matches(vaxis.Key.right, .{}) or
        key.matches(vaxis.Key.page_down, .{}))
    {
        app.reader_page += 1;
        return false;
    }
    if (key.matches('b', .{}) or
        key.matches('h', .{}) or
        key.matches(vaxis.Key.left, .{}) or
        key.matches(vaxis.Key.page_up, .{}))
    {
        if (app.reader_page > 0) app.reader_page -= 1;
        return false;
    }
    return false;
}

fn openSelected(app: *App) !void {
    const id = currentBookId(app) orelse return;
    const book = (try app.cat.getBookById(app.arena, id)) orelse return;
    if (book.format != .epub) {
        setStatus(app, "{s} is {s} — convert it to EPUB first", .{
            std.fs.path.basename(book.path), @tagName(book.format),
        });
        return;
    }

    if (app.book_arena) |*a| a.deinit();
    app.book_arena = std.heap.ArenaAllocator.init(app.arena);
    const arena = app.book_arena.?.allocator();

    const ebook = epub_chapters.open(arena, book.path) catch |err| {
        setStatus(app, "failed to open {s}: {s}", .{ book.path, @errorName(err) });
        app.book_arena.?.deinit();
        app.book_arena = null;
        return;
    };

    var body: std.ArrayList(u8) = .empty;
    for (ebook.chapters, 0..) |ch, i| {
        if (i > 0) try body.appendSlice(arena, "\n\n");
        try body.appendSlice(arena, ch.text);
    }
    const text_width: usize = 76;
    app.reader_lines = try reflow.wrap(arena, body.items, text_width);
    app.reader_page = 0;
    app.reader_book_title = ebook.title orelse book.metadata.title orelse std.fs.path.basename(book.path);
    app.view = .reader;
    app.status = null;
}

fn closeReader(app: *App) void {
    app.view = .list;
    app.reader_page = 0;
    app.reader_lines = &.{};
    if (app.book_arena) |*a| {
        a.deinit();
        app.book_arena = null;
    }
}

fn render(app: *App, win: vaxis.Window) void {
    switch (app.view) {
        .list, .filter => renderList(app, win),
        .reader => renderReader(app, win),
        .detail => {
            renderList(app, win);
            renderDetailPopup(app, win);
        },
        .help => {
            renderList(app, win);
            renderHelpOverlay(app, win);
        },
    }
}

threadlocal var status_buf: [256]u8 = undefined;

fn renderList(app: *App, win: vaxis.Window) void {
    if (win.height < 4 or win.width < 30) return;

    drawTitleBar(app, win);

    const body = win.child(.{ .y_off = 2, .height = win.height - 3 });
    body.clear();

    keepCursorVisible(app, body.height);

    var row: u16 = 0;
    var i: usize = app.list_scroll;
    while (i < app.events.len and row < body.height) : (i += 1) {
        const ev = app.events[i];
        drawEvent(app, body, row, i == app.cursor, ev);
        row += 1;
    }

    drawStatusBar(app, win);
}

fn drawTitleBar(app: *App, win: vaxis.Window) void {
    const bar = win.child(.{ .y_off = 0, .height = 1 });
    bar.fill(.{ .style = .{ .bg = Color.rail } });
    const text = std.fmt.bufPrint(
        &title_buf,
        " booktool — / search · e detail · r read · i info · R rescan · ? help · q quit  ─  {d} books · sort {s}{s} ",
        .{
            app.visible_books.len,
            app.sort.label(),
            if (app.filter_active) " · filtered" else "",
        },
    ) catch " booktool ";
    _ = bar.printSegment(.{
        .text = text,
        .style = .{ .fg = .default, .bg = Color.rail },
    }, .{ .col_offset = 1 });
}
threadlocal var title_buf: [512]u8 = undefined;

fn keepCursorVisible(app: *App, height: u16) void {
    const visible: usize = if (height > 0) @intCast(height) else 1;
    if (app.cursor < app.list_scroll) app.list_scroll = app.cursor;
    if (app.cursor >= app.list_scroll + visible) {
        app.list_scroll = app.cursor + 1 - visible;
    }
}

fn drawEvent(app: *App, win: vaxis.Window, row: u16, selected: bool, ev: groups.Event) void {
    switch (ev) {
        .section_start => |s| drawSectionHeader(win, row, s),
        .section_end => {},
        .book => |b| drawBookRow(app, win, row, selected, b),
    }
}

fn drawSectionHeader(win: vaxis.Window, row: u16, info: groups.SectionInfo) void {
    const w = win.width;
    if (info.depth == 1) {
        const label = std.fmt.bufPrint(
            &header_buf,
            "━━ {s} · {d} ━━",
            .{ info.name, info.count },
        ) catch info.name;
        _ = win.printSegment(.{
            .text = label,
            .style = .{ .fg = Color.accent },
        }, .{ .row_offset = row, .col_offset = 0 });
        if (label.len < w) {
            var pad_buf: [256]u8 = undefined;
            const pad_n = @min(@as(usize, w) - label.len, pad_buf.len);
            @memset(pad_buf[0..pad_n], '-');
            const fill = "━";
            var col: u16 = @intCast(label.len);
            var k: usize = 0;
            while (k < pad_n and col < w) : ({
                k += 1;
                col += 1;
            }) {
                _ = win.printSegment(.{
                    .text = fill,
                    .style = .{ .fg = Color.accent },
                }, .{ .row_offset = row, .col_offset = col });
            }
        }
        return;
    }
    const glyph = if (info.standalone) "·" else "└";
    const label = std.fmt.bufPrint(
        &header_buf,
        "  {s} {s} · {d}",
        .{ glyph, info.name, info.count },
    ) catch info.name;
    const fg = if (info.standalone) Color.mute else Color.dim;
    _ = win.printSegment(.{
        .text = label,
        .style = .{ .fg = fg },
    }, .{ .row_offset = row, .col_offset = 0 });
}
threadlocal var header_buf: [512]u8 = undefined;

fn drawBookRow(app: *App, win: vaxis.Window, row: u16, selected: bool, book: catalog_mod.Book) void {
    _ = app;
    const bg: vaxis.Cell.Color = if (selected) Color.rail_hot else .default;
    const fg: vaxis.Cell.Color = if (selected) Color.accent else .default;

    const status_glyph: []const u8 = switch (book.read_status) {
        .unread => " ",
        .reading => "▸",
        .finished => "✓",
    };
    const status_fg: vaxis.Cell.Color = switch (book.read_status) {
        .unread => fg,
        .reading => Color.accent,
        .finished => Color.ok,
    };
    _ = win.printSegment(.{
        .text = status_glyph,
        .style = .{ .fg = status_fg, .bg = bg },
    }, .{ .row_offset = row, .col_offset = 4 });

    var idx_buf: [16]u8 = undefined;
    var col: u16 = 6;
    if (book.metadata.series_index) |idx| {
        const idx_text = std.fmt.bufPrint(&idx_buf, "#{d} ", .{@as(u32, @intFromFloat(idx))}) catch "";
        _ = win.printSegment(.{
            .text = idx_text,
            .style = .{ .fg = Color.dim, .bg = bg },
        }, .{ .row_offset = row, .col_offset = col });
        col += @intCast(idx_text.len);
    }

    const title = book.metadata.title orelse std.fs.path.basename(book.path);
    var title_buf2: [512]u8 = undefined;
    const right_reserved: u16 = 12;
    const max_title: usize = if (win.width > col + right_reserved)
        @as(usize, @intCast(win.width - col - right_reserved))
    else
        20;
    const title_clip = clipString(&title_buf2, title, max_title);
    _ = win.printSegment(.{
        .text = title_clip,
        .style = .{ .fg = fg, .bg = bg },
    }, .{ .row_offset = row, .col_offset = col });

    const fmt = @tagName(book.format);
    const trust = trustGlyph(book);
    var right_buf: [32]u8 = undefined;
    const right = std.fmt.bufPrint(&right_buf, "{s} {s}", .{ fmt, trust }) catch fmt;
    if (win.width > right.len + 1) {
        _ = win.printSegment(.{
            .text = right,
            .style = .{ .fg = Color.dim, .bg = bg },
        }, .{ .row_offset = row, .col_offset = @intCast(win.width - right.len - 1) });
    }
}

/// One-glyph trust hint matching the web's cover-trust dot. `?` for
/// med/low; nothing for high.
fn trustGlyph(b: catalog_mod.Book) []const u8 {
    const md = b.metadata;
    if (md.source == .manual) return " ";
    if (md.source != .embedded and md.source != .derived) {
        return if (md.confidence >= 0.7) " " else "?";
    }
    if (md.isbn != null and md.confidence >= 0.6) return "?";
    return "?";
}

fn drawStatusBar(app: *App, win: vaxis.Window) void {
    if (win.height < 1) return;
    const status = win.child(.{ .y_off = win.height - 1, .height = 1 });
    status.fill(.{ .style = .{ .bg = Color.rail } });

    if (app.view == .filter) {
        const prompt = std.fmt.bufPrint(
            &status_buf,
            " filter: {s}_ ",
            .{app.filter_input.items},
        ) catch " filter: ";
        _ = status.printSegment(.{
            .text = prompt,
            .style = .{ .fg = Color.accent, .bg = Color.rail },
        }, .{ .col_offset = 1 });
        return;
    }
    if (app.status) |s| {
        _ = status.printSegment(.{
            .text = s,
            .style = .{ .fg = Color.accent, .bg = Color.rail },
        }, .{ .col_offset = 1 });
        return;
    }

    var book_n: usize = 0;
    var book_total: usize = 0;
    for (app.events, 0..) |e, i| {
        if (e == .book) {
            book_total += 1;
            if (i <= app.cursor) book_n += 1;
        }
    }
    const total_text = std.fmt.bufPrint(
        &status_buf,
        " {d}/{d}{s}",
        .{
            book_n,
            book_total,
            if (app.filter_active) "  ·  filtered" else "",
        },
    ) catch return;
    _ = status.printSegment(.{
        .text = total_text,
        .style = .{ .fg = Color.dim, .bg = Color.rail },
    }, .{ .col_offset = 1 });
}

fn setStatus(app: *App, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(app.arena, fmt, args) catch return;
    app.status = msg;
}

fn renderDetailPopup(app: *App, win: vaxis.Window) void {
    const id = app.detail_book_id orelse return;
    const book_opt = app.cat.getBookById(app.arena, id) catch return;
    const book = book_opt orelse return;

    const popup_w: u16 = @min(@as(u16, 90), if (win.width > 6) win.width - 6 else win.width);
    const popup_h: u16 = @min(@as(u16, 30), if (win.height > 4) win.height - 4 else win.height);
    const x: i17 = @intCast((@as(i17, @intCast(win.width)) - @as(i17, @intCast(popup_w))) >> 1);
    const y: i17 = @intCast((@as(i17, @intCast(win.height)) - @as(i17, @intCast(popup_h))) >> 1);

    const popup = win.child(.{
        .x_off = @intCast(@max(0, x)),
        .y_off = @intCast(@max(0, y)),
        .width = popup_w,
        .height = popup_h,
    });
    popup.fill(.{ .style = .{ .bg = Color.rail } });

    drawBorder(popup);

    var row: u16 = 1;
    const title = book.metadata.title orelse std.fs.path.basename(book.path);
    _ = popup.printSegment(.{
        .text = title,
        .style = .{ .fg = .default, .bg = Color.rail, .bold = true },
    }, .{ .row_offset = row, .col_offset = 2 });
    row += 1;

    if (book.metadata.authors.len > 0) {
        _ = popup.printSegment(.{
            .text = book.metadata.authors[0].sort,
            .style = .{ .fg = Color.dim, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }

    if (book.metadata.series) |s| {
        var sbuf: [256]u8 = undefined;
        const idx = book.metadata.series_index;
        const sline = if (idx) |i|
            std.fmt.bufPrint(&sbuf, "{s} #{d}", .{ s, @as(u32, @intFromFloat(i)) }) catch s
        else
            s;
        _ = popup.printSegment(.{
            .text = sline,
            .style = .{ .fg = Color.accent, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }
    row += 1;

    var meta_buf: [256]u8 = undefined;
    const status_txt: []const u8 = switch (book.read_status) {
        .unread => "unread",
        .reading => "▸ reading",
        .finished => "✓ finished",
    };
    const trust_level: []const u8 = blk: {
        if (book.metadata.source == .manual) break :blk "verified";
        if (book.metadata.source != .embedded and book.metadata.source != .derived)
            break :blk if (book.metadata.confidence >= 0.7) "verified" else "partial";
        if (book.metadata.isbn != null and book.metadata.confidence >= 0.6) break :blk "partial";
        break :blk "unverified";
    };
    const meta_line = std.fmt.bufPrint(
        &meta_buf,
        "[{s}]  [{s} · {s}]  [{s}]",
        .{ status_txt, trust_level, @tagName(book.metadata.source), @tagName(book.format) },
    ) catch "";
    _ = popup.printSegment(.{
        .text = meta_line,
        .style = .{ .fg = Color.dim, .bg = Color.rail },
    }, .{ .row_offset = row, .col_offset = 2 });
    row += 2;

    if (app.detail_editing) {
        row = drawEditForm(app, popup, row);
    } else {
        row = drawFacts(book, popup, row, app.env_map);
    }

    const hint = if (app.detail_editing)
        " Tab: next field · Enter: save · Esc: cancel "
    else
        " e: edit · i: fetch info · r: cycle status · Esc/q: close ";
    if (popup.height >= 2) {
        _ = popup.printSegment(.{
            .text = hint,
            .style = .{ .fg = Color.mute, .bg = Color.rail },
        }, .{ .row_offset = popup.height - 2, .col_offset = 2 });
    }
}

fn drawFacts(book: catalog_mod.Book, win: vaxis.Window, start_row: u16, env: *std.process.Environ.Map) u16 {
    var row = start_row;
    const bottom: u16 = if (win.height > 2) win.height - 2 else 0;
    const pairs = [_]struct { label: []const u8, value: ?[]const u8, color: vaxis.Cell.Color }{
        .{ .label = "Year", .value = yearStr(book), .color = .default },
        .{ .label = "Publisher", .value = book.metadata.publisher, .color = .default },
        .{ .label = "Language", .value = book.metadata.language, .color = .default },
        .{ .label = "ISBN", .value = book.metadata.isbn, .color = .default },
    };
    for (pairs) |p| {
        const v = p.value orelse continue;
        if (row + 1 >= bottom) return row;
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{s}:", .{p.label}) catch p.label;
        _ = win.printSegment(.{
            .text = label,
            .style = .{ .fg = Color.mute, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 2 });
        _ = win.printSegment(.{
            .text = v,
            .style = .{ .fg = p.color, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 14 });
        row += 1;
    }

    if (book.metadata.subjects.len > 0 and row + 2 < bottom) {
        _ = win.printSegment(.{
            .text = "Subjects:",
            .style = .{ .fg = Color.mute, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 2 });
        const max = @min(book.metadata.subjects.len, 6);
        var subj_buf: [256]u8 = undefined;
        var w_idx: usize = 0;
        for (book.metadata.subjects[0..max], 0..) |s, i| {
            if (i > 0) {
                const sep = " · ";
                const fit = @min(sep.len, subj_buf.len - w_idx);
                @memcpy(subj_buf[w_idx .. w_idx + fit], sep[0..fit]);
                w_idx += fit;
            }
            const fit = @min(s.len, subj_buf.len - w_idx);
            if (fit == 0) break;
            @memcpy(subj_buf[w_idx .. w_idx + fit], s[0..fit]);
            w_idx += fit;
            if (w_idx >= subj_buf.len) break;
        }
        _ = win.printSegment(.{
            .text = subj_buf[0..w_idx],
            .style = .{ .fg = .default, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 14 });
        row += 1;
    }

    if (cover_store.exists(env, book.id) and row + 1 < bottom) {
        _ = win.printSegment(.{
            .text = " cover override active ",
            .style = .{ .fg = Color.warn, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }

    if (book.metadata.description) |d| {
        if (row + 2 < bottom) {
            _ = win.printSegment(.{
                .text = "Description:",
                .style = .{ .fg = Color.mute, .bg = Color.rail },
            }, .{ .row_offset = row, .col_offset = 2 });
            row += 1;
            const width: usize = if (win.width > 6) @intCast(win.width - 6) else 40;
            var preview_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer preview_arena.deinit();
            const lines = reflow.wrap(preview_arena.allocator(), d, width) catch {
                return row;
            };
            const max_lines: usize = if (win.height >= row + 4)
                @intCast(win.height - row - 4)
            else
                0;
            for (lines[0..@min(lines.len, max_lines)]) |ln| {
                _ = win.printSegment(.{
                    .text = ln,
                    .style = .{ .fg = Color.dim, .bg = Color.rail },
                }, .{ .row_offset = row, .col_offset = 2 });
                row += 1;
            }
        }
    }
    return row;
}

fn drawEditForm(app: *App, win: vaxis.Window, start_row: u16) u16 {
    var row = start_row;
    const bottom: u16 = if (win.height > 2) win.height - 2 else 0;
    const labels = [_][]const u8{ "Title:", "Author:", "Series:", "Series #:", "Year:" };
    for (labels, 0..) |label, i| {
        if (row + 1 >= bottom) return row;
        const focused = i == app.detail_field_idx;
        const label_color: vaxis.Cell.Color = if (focused) Color.accent else Color.mute;
        _ = win.printSegment(.{
            .text = label,
            .style = .{ .fg = label_color, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 2 });

        const value = app.detail_inputs[i].items;
        var disp_buf: [256]u8 = undefined;
        const cursor_glyph: []const u8 = if (focused) "_" else "";
        const disp = std.fmt.bufPrint(&disp_buf, "{s}{s}", .{ value, cursor_glyph }) catch value;
        _ = win.printSegment(.{
            .text = disp,
            .style = .{ .fg = if (focused) Color.accent else .default, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 14 });
        row += 1;
    }
    return row;
}

fn drawBorder(win: vaxis.Window) void {
    if (win.width < 2 or win.height < 2) return;
    const w = win.width;
    const h = win.height;
    var x: u16 = 1;
    while (x + 1 < w) : (x += 1) {
        _ = win.printSegment(.{
            .text = "─",
            .style = .{ .fg = Color.dim, .bg = Color.rail },
        }, .{ .row_offset = 0, .col_offset = x });
        _ = win.printSegment(.{
            .text = "─",
            .style = .{ .fg = Color.dim, .bg = Color.rail },
        }, .{ .row_offset = h - 1, .col_offset = x });
    }
    var y: u16 = 1;
    while (y + 1 < h) : (y += 1) {
        _ = win.printSegment(.{
            .text = "│",
            .style = .{ .fg = Color.dim, .bg = Color.rail },
        }, .{ .row_offset = y, .col_offset = 0 });
        _ = win.printSegment(.{
            .text = "│",
            .style = .{ .fg = Color.dim, .bg = Color.rail },
        }, .{ .row_offset = y, .col_offset = w - 1 });
    }
    _ = win.printSegment(.{
        .text = "┌",
        .style = .{ .fg = Color.dim, .bg = Color.rail },
    }, .{ .row_offset = 0, .col_offset = 0 });
    _ = win.printSegment(.{
        .text = "┐",
        .style = .{ .fg = Color.dim, .bg = Color.rail },
    }, .{ .row_offset = 0, .col_offset = w - 1 });
    _ = win.printSegment(.{
        .text = "└",
        .style = .{ .fg = Color.dim, .bg = Color.rail },
    }, .{ .row_offset = h - 1, .col_offset = 0 });
    _ = win.printSegment(.{
        .text = "┘",
        .style = .{ .fg = Color.dim, .bg = Color.rail },
    }, .{ .row_offset = h - 1, .col_offset = w - 1 });
}

fn yearStr(b: catalog_mod.Book) ?[]const u8 {
    const y = b.metadata.published_year orelse return null;
    var buf: [16]u8 = undefined;
    return std.fmt.bufPrint(&buf, "{d}", .{y}) catch null;
}

fn renderHelpOverlay(app: *App, win: vaxis.Window) void {
    _ = app;
    const help_w: u16 = @min(@as(u16, 60), if (win.width > 6) win.width - 6 else win.width);
    const help_h: u16 = @min(@as(u16, 24), if (win.height > 4) win.height - 4 else win.height);
    const x: i17 = @intCast((@as(i17, @intCast(win.width)) - @as(i17, @intCast(help_w))) >> 1);
    const y: i17 = @intCast((@as(i17, @intCast(win.height)) - @as(i17, @intCast(help_h))) >> 1);

    const popup = win.child(.{
        .x_off = @intCast(@max(0, x)),
        .y_off = @intCast(@max(0, y)),
        .width = help_w,
        .height = help_h,
    });
    popup.fill(.{ .style = .{ .bg = Color.rail } });
    drawBorder(popup);

    const rows = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "j / k  ↓↑", .desc = "move cursor (header rows skipped)" },
        .{ .key = "J / K", .desc = "move cursor by 10" },
        .{ .key = "g / G", .desc = "first / last book" },
        .{ .key = "Enter", .desc = "open reader (EPUB only)" },
        .{ .key = "e", .desc = "open detail popup" },
        .{ .key = "/", .desc = "filter (author: series: format: prefixes)" },
        .{ .key = "r", .desc = "cycle read status (unread→reading→finished)" },
        .{ .key = "i", .desc = "fetch info from Open Library" },
        .{ .key = "s", .desc = "cycle sort order" },
        .{ .key = "B", .desc = "backfill series from filenames" },
        .{ .key = "R", .desc = "rescan all library source folders" },
        .{ .key = "?", .desc = "this help" },
        .{ .key = "q / Esc", .desc = "close overlay or quit" },
    };
    var row: u16 = 2;
    _ = popup.printSegment(.{
        .text = "Keys",
        .style = .{ .fg = Color.accent, .bg = Color.rail, .bold = true },
    }, .{ .row_offset = 1, .col_offset = 2 });
    for (rows) |r| {
        if (row + 1 >= popup.height) break;
        _ = popup.printSegment(.{
            .text = r.key,
            .style = .{ .fg = Color.accent, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 2 });
        _ = popup.printSegment(.{
            .text = r.desc,
            .style = .{ .fg = Color.dim, .bg = Color.rail },
        }, .{ .row_offset = row, .col_offset = 18 });
        row += 1;
    }
}

fn renderReader(app: *App, win: vaxis.Window) void {
    if (win.height < 4 or win.width < 20) return;

    win.fill(.{ .style = .{ .bg = Color.rail } });
    var title_buf3: [256]u8 = undefined;
    const title_text = std.fmt.bufPrint(
        &title_buf3,
        " {s} — space/← → page · q back ",
        .{app.reader_book_title},
    ) catch app.reader_book_title;
    _ = win.printSegment(.{
        .text = title_text,
        .style = .{ .fg = Color.accent, .bg = Color.rail },
    }, .{ .row_offset = 0, .col_offset = 1 });

    const body = win.child(.{ .y_off = 2, .height = win.height - 3 });
    body.clear();

    if (app.reader_lines.len == 0) {
        _ = body.printSegment(.{
            .text = "(empty book)",
            .style = .{ .fg = Color.dim },
        }, .{ .row_offset = 0 });
        return;
    }

    const page_height: usize = @intCast(body.height);
    const total_pages = reflow.paginate(app.reader_lines, page_height);
    if (app.reader_page >= total_pages) app.reader_page = total_pages - 1;

    const start = app.reader_page * page_height;
    const end = @min(start + page_height, app.reader_lines.len);

    const text_col_width: u16 = 76;
    const left_pad: u16 = if (body.width > text_col_width) (body.width - text_col_width) / 2 else 0;

    var row: u16 = 0;
    var i = start;
    while (i < end) : ({
        i += 1;
        row += 1;
    }) {
        _ = body.printSegment(.{
            .text = app.reader_lines[i],
            .style = .{ .fg = .default },
        }, .{ .row_offset = row, .col_offset = left_pad });
    }

    const status = win.child(.{ .y_off = win.height - 1, .height = 1 });
    status.fill(.{ .style = .{ .bg = Color.rail } });

    const percent = if (total_pages > 0)
        @as(u8, @intCast((app.reader_page + 1) * 100 / total_pages))
    else
        0;
    var stat_buf: [128]u8 = undefined;
    const stat_text = std.fmt.bufPrint(
        &stat_buf,
        "page {d}/{d} · {d}%  ",
        .{ app.reader_page + 1, total_pages, percent },
    ) catch "";
    _ = status.printSegment(.{
        .text = stat_text,
        .style = .{ .fg = Color.dim, .bg = Color.rail },
    }, .{ .col_offset = 1 });

    const rail_start: u16 = @intCast(@min(stat_text.len + 2, win.width - 1));
    const rail_cells: u16 = if (win.width > rail_start + 24) 20 else 0;
    if (rail_cells > 0) {
        const filled: u16 = @intCast((@as(usize, percent) * rail_cells) / 100);
        var k: u16 = 0;
        while (k < rail_cells) : (k += 1) {
            const ch: []const u8 = if (k < filled) "▰" else "▱";
            const fg: vaxis.Cell.Color = if (k < filled) Color.accent else Color.mute;
            _ = status.printSegment(.{
                .text = ch,
                .style = .{ .fg = fg, .bg = Color.rail },
            }, .{ .col_offset = rail_start + k });
        }
    }
}

fn titlePreview(b: catalog_mod.Book) []const u8 {
    return b.metadata.title orelse std.fs.path.basename(b.path);
}

fn clipString(buf: []u8, src: []const u8, max: usize) []const u8 {
    if (src.len <= max) return src;
    if (max < 4) return src[0..@min(src.len, max)];
    const cut = max - 1;
    if (cut + 1 > buf.len) return src[0..@min(src.len, max)];
    @memcpy(buf[0..cut], src[0..cut]);
    buf[cut] = '~';
    return buf[0 .. cut + 1];
}
