//! Terminal UI for booktool. Two views:
//!
//!   - LIST: scrollable library list from the catalog. j/k navigates,
//!     enter opens the book in the reader.
//!   - READER: paginated text view of an EPUB. space/right pages
//!     forward, b/left pages back, q returns to LIST.
//!
//! Renders via libvaxis. Non-EPUB books are listed but read-only — opening
//! a MOBI/AZW3/PDF prints "convert this to EPUB first".

const std = @import("std");
const vaxis = @import("vaxis");
const catalog_mod = @import("../core/catalog.zig");
const epub_chapters = @import("../formats/epub_chapters.zig");
const meta = @import("../core/metadata.zig");
const reflow = @import("reflow.zig");

const View = enum { list, reader };

pub const App = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cat: *catalog_mod.Catalog,

    books: []catalog_mod.Book,
    cursor: usize = 0,
    list_scroll: usize = 0,
    view: View = .list,
    status: ?[]const u8 = null,

    // Reader state. Allocated when entering reader view, freed on exit.
    book_arena: ?std.heap.ArenaAllocator = null,
    reader_lines: []const []const u8 = &.{},
    reader_page: usize = 0,
    reader_book_title: []const u8 = "",
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cat: *catalog_mod.Catalog,
) !void {
    const books = try cat.listBooks(allocator);
    if (books.len == 0) {
        std.log.err("catalog is empty — run `booktool scan DIR` first.", .{});
        return;
    }

    var app = App{
        .arena = allocator,
        .io = io,
        .env_map = env_map,
        .cat = cat,
        .books = books,
    };

    var tty_buf: [4 * 1024]u8 = undefined;
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

    while (true) {
        const event = try loop.nextEvent();
        const quit = try handleEvent(&app, event);

        const win = vx.window();
        win.clear();
        render(&app, win);

        try vx.render(tty.writer());
        if (quit) break;
    }

    if (app.book_arena) |*a| a.deinit();
}

// ---- Event handling -----------------------------------------------------

fn handleEvent(app: *App, event: vaxis.Event) !bool {
    switch (event) {
        .key_press => |key| {
            return switch (app.view) {
                .list => listKey(app, key),
                .reader => readerKey(app, key),
            };
        },
        .winsize => return false,
        else => return false,
    }
}

fn listKey(app: *App, key: vaxis.Key) !bool {
    if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) return true;
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (app.cursor + 1 < app.books.len) app.cursor += 1;
        return false;
    }
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (app.cursor > 0) app.cursor -= 1;
        return false;
    }
    if (key.matches('g', .{})) {
        app.cursor = 0;
        app.list_scroll = 0;
        return false;
    }
    if (key.matches('G', .{ .shift = true })) {
        app.cursor = app.books.len - 1;
        return false;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        try openSelected(app);
        return false;
    }
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
    const book = app.books[app.cursor];
    if (book.format != .epub) {
        app.status = try std.fmt.allocPrint(
            app.arena,
            "{s} is {s} — convert it to EPUB first (booktool convert)",
            .{ std.fs.path.basename(book.path), @tagName(book.format) },
        );
        return;
    }

    // Fresh arena for the loaded book so we can drop it cleanly on exit.
    if (app.book_arena) |*a| a.deinit();
    app.book_arena = std.heap.ArenaAllocator.init(app.arena);
    const arena = app.book_arena.?.allocator();

    const ebook = epub_chapters.open(arena, book.path) catch |err| {
        app.status = try std.fmt.allocPrint(
            app.arena,
            "failed to open {s}: {s}",
            .{ book.path, @errorName(err) },
        );
        app.book_arena.?.deinit();
        app.book_arena = null;
        return;
    };

    // Concatenate all chapter texts with double newlines between them.
    var body: std.ArrayList(u8) = .empty;
    for (ebook.chapters, 0..) |ch, i| {
        if (i > 0) try body.appendSlice(arena, "\n\n");
        try body.appendSlice(arena, ch.text);
    }

    // Wrap to a sensible reading width — narrower than the full terminal
    // is actually easier on the eyes.
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
    if (app.book_arena) |*a| { a.deinit(); app.book_arena = null; }
}

// ---- Rendering ----------------------------------------------------------

fn render(app: *App, win: vaxis.Window) void {
    switch (app.view) {
        .list => renderList(app, win),
        .reader => renderReader(app, win),
    }
}

const accent: vaxis.Cell.Color = .{ .index = 214 }; // amber
const dim: vaxis.Cell.Color = .{ .index = 244 };

fn renderList(app: *App, win: vaxis.Window) void {
    if (win.height < 4 or win.width < 20) return; // too small to draw anything legible

    // Title bar
    const title_seg = vaxis.Cell.Segment{
        .text = " booktool — j/k move · enter open · q quit ",
        .style = .{ .fg = .default, .bg = .{ .index = 236 } },
    };
    win.fill(.{ .style = .{ .bg = .{ .index = 236 } } });
    _ = win.printSegment(title_seg, .{ .row_offset = 0, .col_offset = 1 });

    const body = win.child(.{ .y_off = 2, .height = win.height - 3 });
    body.clear();

    // Keep cursor in view.
    const visible_rows: usize = if (body.height > 0) @intCast(body.height) else 1;
    if (app.cursor < app.list_scroll) app.list_scroll = app.cursor;
    if (app.cursor >= app.list_scroll + visible_rows) {
        app.list_scroll = app.cursor + 1 - visible_rows;
    }

    var row: u16 = 0;
    var i: usize = app.list_scroll;
    while (i < app.books.len and row < body.height) : ({ i += 1; row += 1; }) {
        drawRow(body, row, i == app.cursor, app.books[i]);
    }

    // Status bar
    if (win.height < 1) return;
    const status = win.child(.{ .y_off = win.height - 1, .height = 1 });
    status.fill(.{ .style = .{ .bg = .{ .index = 236 } } });
    if (app.status) |s| {
        _ = status.printSegment(.{
            .text = s,
            .style = .{ .fg = accent, .bg = .{ .index = 236 } },
        }, .{ .col_offset = 1 });
    } else {
        const total_text = std.fmt.bufPrint(&status_buf, "{d}/{d}", .{ app.cursor + 1, app.books.len }) catch return;
        _ = status.printSegment(.{
            .text = total_text,
            .style = .{ .fg = dim, .bg = .{ .index = 236 } },
        }, .{ .col_offset = 1 });
    }
}

threadlocal var status_buf: [128]u8 = undefined;

fn drawRow(win: vaxis.Window, row: u16, selected: bool, book: catalog_mod.Book) void {
    const bg: vaxis.Cell.Color = if (selected) .{ .index = 237 } else .default;
    const fg: vaxis.Cell.Color = if (selected) accent else .default;
    const author = if (book.metadata.authors.len > 0)
        book.metadata.authors[0].sort
    else
        "(unknown)";
    const title = book.metadata.title orelse std.fs.path.basename(book.path);

    // Marker column
    const marker = if (selected) "▶ " else "  ";
    _ = win.printSegment(.{
        .text = marker,
        .style = .{ .fg = fg, .bg = bg },
    }, .{ .row_offset = row, .col_offset = 0 });

    // Author (fixed width)
    var author_buf: [256]u8 = undefined;
    const author_clip = clipString(&author_buf, author, 24);
    _ = win.printSegment(.{
        .text = author_clip,
        .style = .{ .fg = dim, .bg = bg },
    }, .{ .row_offset = row, .col_offset = 2 });

    // Title (rest of line)
    var title_buf: [512]u8 = undefined;
    const max_title = if (win.width > 30) @as(usize, @intCast(win.width)) - 30 else 20;
    const title_clip = clipString(&title_buf, title, max_title);
    _ = win.printSegment(.{
        .text = title_clip,
        .style = .{ .fg = fg, .bg = bg },
    }, .{ .row_offset = row, .col_offset = 28 });

    // Format badge on the right
    const fmt = @tagName(book.format);
    _ = win.printSegment(.{
        .text = fmt,
        .style = .{ .fg = dim, .bg = bg },
    }, .{ .row_offset = row, .col_offset = if (win.width > 8) win.width - 6 else 0 });
}

fn clipString(buf: []u8, src: []const u8, max: usize) []const u8 {
    if (src.len <= max) return src;
    if (max < 4) return src[0..@min(src.len, max)];
    // Reserve 3 bytes for the trailing "..." (ASCII — saves UTF-8 dance).
    const cut = max - 3;
    if (cut + 3 > buf.len) return src[0..@min(src.len, max)];
    @memcpy(buf[0..cut], src[0..cut]);
    buf[cut] = '.'; buf[cut + 1] = '.'; buf[cut + 2] = '.';
    return buf[0 .. cut + 3];
}

fn renderReader(app: *App, win: vaxis.Window) void {
    if (win.height < 4 or win.width < 20) return;

    // Title bar
    win.fill(.{ .style = .{ .bg = .{ .index = 236 } } });
    var title_buf: [256]u8 = undefined;
    const title_text = std.fmt.bufPrint(
        &title_buf,
        " {s} — space/← → page · q back ",
        .{app.reader_book_title},
    ) catch app.reader_book_title;
    _ = win.printSegment(.{
        .text = title_text,
        .style = .{ .fg = accent, .bg = .{ .index = 236 } },
    }, .{ .row_offset = 0, .col_offset = 1 });

    const body = win.child(.{ .y_off = 2, .height = win.height - 3 });
    body.clear();

    if (app.reader_lines.len == 0) {
        _ = body.printSegment(.{ .text = "(empty book)", .style = .{ .fg = dim } }, .{ .row_offset = 0 });
        return;
    }

    const page_height: usize = @intCast(body.height);
    const total_pages = reflow.paginate(app.reader_lines, page_height);
    if (app.reader_page >= total_pages) app.reader_page = total_pages - 1;

    const start = app.reader_page * page_height;
    const end = @min(start + page_height, app.reader_lines.len);

    // Horizontal centering: pad text to the left to give a column-style read.
    const text_col_width: u16 = 76;
    const left_pad: u16 = if (body.width > text_col_width) (body.width - text_col_width) / 2 else 0;

    var row: u16 = 0;
    var i = start;
    while (i < end) : ({ i += 1; row += 1; }) {
        _ = body.printSegment(.{
            .text = app.reader_lines[i],
            .style = .{ .fg = .default },
        }, .{ .row_offset = row, .col_offset = left_pad });
    }

    // Status bar — page n/m
    const status = win.child(.{ .y_off = win.height - 1, .height = 1 });
    status.fill(.{ .style = .{ .bg = .{ .index = 236 } } });
    var stat_buf: [64]u8 = undefined;
    const stat_text = std.fmt.bufPrint(&stat_buf, "page {d}/{d}", .{ app.reader_page + 1, total_pages }) catch "";
    _ = status.printSegment(.{
        .text = stat_text,
        .style = .{ .fg = dim, .bg = .{ .index = 236 } },
    }, .{ .col_offset = 1 });
}
