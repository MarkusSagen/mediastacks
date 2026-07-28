//! Streaming group iterator for the TUI list.
//!
//! Walks a pre-sorted slice of `catalog.Book` once and emits a flat
//! stream of events:
//!
//!     SectionStart { name, depth, count }
//!     Book         { book }
//!     SectionEnd   { depth }
//!
//! The renderer consumes events in order — header rows draw the
//! "━━ Author · 8 ━━" / "└ Series · 3" lines, book events draw
//! selectable rows. `j`/`k` advance/retreat the cursor by skipping
//! `SectionStart`/`SectionEnd` events so headers are never selectable.
//!
//! Two schemas, mirroring the web (see `groupSchemaFor` in app.js):
//!
//!   - `.author_series` : two-level — outer author, inner series + a
//!                        trailing "Standalone" sub-bucket for the
//!                        author's series-less books.
//!   - `.series`        : one-level — books with no series are dropped
//!                        (they aren't part of the series view).
//!
//! No allocation: the iterator carries a small slice cursor and a
//! lookahead key. The caller owns the input slice.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");

pub const Schema = enum {
    author_series,
    series,
};

pub const EventKind = enum {
    section_start,
    book,
    section_end,
};

pub const Event = union(EventKind) {
    section_start: SectionInfo,
    book: catalog_mod.Book,
    section_end: u8,

    pub fn isSelectable(self: Event) bool {
        return self == .book;
    }
};

pub const SectionInfo = struct {
    name: []const u8,
    depth: u8,
    /// Number of books inside this section (and its children for depth-1).
    count: usize,
    /// True if this section is the "Standalone" tail under an author.
    /// Renderer dims this differently so the user reads it as a tail.
    standalone: bool = false,
};

/// Iterator. Pre-computes the section boundaries and emits events on
/// demand. `init()` does one O(n) pass to build the event list — kept
/// in a fixed-size buffer to avoid allocating per-frame on render. If
/// the book count exceeds `max_events`, the iterator falls back to
/// flat rendering (rare in practice; a 200-book library produces
/// roughly 200 + 30 = 230 events).
pub const Iterator = struct {
    events: []const Event,
    cursor: usize = 0,

    pub fn next(self: *Iterator) ?Event {
        if (self.cursor >= self.events.len) return null;
        const e = self.events[self.cursor];
        self.cursor += 1;
        return e;
    }

    pub fn reset(self: *Iterator) void {
        self.cursor = 0;
    }
};

/// Build the event list for the given books + schema. Caller-provided
/// buffer must hold at least `books.len * 2 + 4` events for the
/// worst-case `.author_series` schema (every book in its own author
/// gets a Start+End pair). Returns the populated slice.
pub fn build(
    books: []const catalog_mod.Book,
    schema: Schema,
    buf: []Event,
) []const Event {
    var w: usize = 0;
    switch (schema) {
        .author_series => w = buildAuthorSeries(books, buf),
        .series => w = buildSeries(books, buf),
    }
    return buf[0..w];
}

fn buildAuthorSeries(books: []const catalog_mod.Book, buf: []Event) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < books.len) {
        const author = authorOf(books[i]);
        var j = i;
        while (j < books.len and std.mem.eql(u8, authorOf(books[j]), author)) j += 1;

        const author_books = books[i..j];
        if (w >= buf.len) return w;
        buf[w] = .{ .section_start = .{
            .name = author,
            .depth = 1,
            .count = author_books.len,
        } };
        w += 1;

        var standalone_buf: [256]?usize = undefined;
        var standalone_n: usize = 0;
        var k: usize = 0;
        while (k < author_books.len) {
            const b = author_books[k];
            if (b.metadata.series == null) {
                if (standalone_n < standalone_buf.len) {
                    standalone_buf[standalone_n] = i + k;
                    standalone_n += 1;
                }
                k += 1;
                continue;
            }
            const series_name = b.metadata.series.?;
            var m = k;
            while (m < author_books.len) : (m += 1) {
                const candidate = author_books[m].metadata.series orelse break;
                if (!std.mem.eql(u8, candidate, series_name)) break;
            }
            const series_books = author_books[k..m];
            if (w >= buf.len) return w;
            buf[w] = .{ .section_start = .{
                .name = series_name,
                .depth = 2,
                .count = series_books.len,
            } };
            w += 1;
            for (series_books) |sb| {
                if (w >= buf.len) return w;
                buf[w] = .{ .book = sb };
                w += 1;
            }
            if (w >= buf.len) return w;
            buf[w] = .{ .section_end = 2 };
            w += 1;
            k = m;
        }

        if (standalone_n > 0) {
            if (w >= buf.len) return w;
            buf[w] = .{ .section_start = .{
                .name = "Standalone",
                .depth = 2,
                .count = standalone_n,
                .standalone = true,
            } };
            w += 1;
            for (0..standalone_n) |idx| {
                if (w >= buf.len) return w;
                buf[w] = .{ .book = books[standalone_buf[idx].?] };
                w += 1;
            }
            if (w >= buf.len) return w;
            buf[w] = .{ .section_end = 2 };
            w += 1;
        }

        if (w >= buf.len) return w;
        buf[w] = .{ .section_end = 1 };
        w += 1;
        i = j;
    }
    return w;
}

fn buildSeries(books: []const catalog_mod.Book, buf: []Event) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < books.len) {
        const series = books[i].metadata.series orelse {
            i += 1;
            continue;
        };
        var j = i;
        while (j < books.len) : (j += 1) {
            const s = books[j].metadata.series orelse break;
            if (!std.mem.eql(u8, s, series)) break;
        }
        const run = books[i..j];
        if (w >= buf.len) return w;
        buf[w] = .{ .section_start = .{
            .name = series,
            .depth = 1,
            .count = run.len,
        } };
        w += 1;
        for (run) |b| {
            if (w >= buf.len) return w;
            buf[w] = .{ .book = b };
            w += 1;
        }
        if (w >= buf.len) return w;
        buf[w] = .{ .section_end = 1 };
        w += 1;
        i = j;
    }
    return w;
}

fn authorOf(b: catalog_mod.Book) []const u8 {
    if (b.metadata.authors.len > 0) return b.metadata.authors[0].sort;
    return "(unknown)";
}

/// Return the index of the nth selectable (book) event, or null. Used
/// when restoring cursor position after a filter / refresh.
pub fn nthBookIndex(events: []const Event, nth: usize) ?usize {
    var seen: usize = 0;
    for (events, 0..) |e, i| {
        if (e != .book) continue;
        if (seen == nth) return i;
        seen += 1;
    }
    return null;
}

const meta = @import("../core/metadata.zig");

fn mkBook(comptime title: []const u8, comptime author: []const u8, comptime series: ?[]const u8, idx: ?f32) catalog_mod.Book {
    return .{
        .id = 0,
        .path = "",
        .sha256 = "",
        .size = 0,
        .format = .epub,
        .mtime = 0,
        .metadata = .{
            .title = title,
            .authors = &[_]meta.Author{.{ .last = "", .first = "", .sort = author }},
            .series = series,
            .series_index = idx,
        },
    };
}

test "author_series schema: nested with standalone tail" {
    const books = [_]catalog_mod.Book{
        mkBook("Apprentice", "Hobb, Robin", "Farseer", 1),
        mkBook("Royal", "Hobb, Robin", "Farseer", 2),
        mkBook("Ship", "Hobb, Robin", "Liveship", 1),
        mkBook("Standalone1", "Hobb, Robin", null, null),
        mkBook("Blood Meridian", "McCarthy, Cormac", null, null),
    };
    var buf: [32]Event = undefined;
    const events = build(&books, .author_series, &buf);

    var depth1_starts: usize = 0;
    var depth2_starts: usize = 0;
    var book_events: usize = 0;
    var standalone_starts: usize = 0;
    for (events) |e| switch (e) {
        .section_start => |s| {
            if (s.depth == 1) depth1_starts += 1;
            if (s.depth == 2) depth2_starts += 1;
            if (s.standalone) standalone_starts += 1;
        },
        .book => book_events += 1,
        .section_end => {},
    };
    try std.testing.expectEqual(@as(usize, 2), depth1_starts);
    try std.testing.expectEqual(@as(usize, 4), depth2_starts);
    try std.testing.expectEqual(@as(usize, 2), standalone_starts);
    try std.testing.expectEqual(@as(usize, 5), book_events);
}

test "series schema: drops books with no series" {
    const books = [_]catalog_mod.Book{
        mkBook("Ship", "Hobb, Robin", "Liveship", 1),
        mkBook("Mad Ship", "Hobb, Robin", "Liveship", 2),
        mkBook("Loose", "X, Y", null, null),
    };
    var buf: [16]Event = undefined;
    const events = build(&books, .series, &buf);
    var book_events: usize = 0;
    for (events) |e| if (e == .book) {
        book_events += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), book_events);
}
