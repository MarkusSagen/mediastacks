//! Open Library provider.
//!
//! Endpoints used:
//!   ISBN:  https://openlibrary.org/api/books?bibkeys=ISBN:{isbn}&format=json&jscmd=data
//!   Search: https://openlibrary.org/search.json?title=...&author=...
//!
//! HTTP currently goes through util/http.zig which is a stub. The JSON
//! parsing logic is implemented and tested against fixtures so when the
//! transport lands, integration is one wire-up.

const std = @import("std");
const meta = @import("../core/metadata.zig");
const provider_iface = @import("provider.zig");
const http = @import("../util/http.zig");

pub const OpenLibrary = struct {
    pub fn provider(self: *OpenLibrary) provider_iface.Provider {
        return .{
            .ctx = self,
            .name_str = "openlibrary",
            .lookup_fn = lookupShim,
        };
    }

    fn lookupShim(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        q: provider_iface.Query,
    ) !?meta.BookMetadata {
        const self: *OpenLibrary = @ptrCast(@alignCast(ctx));
        return self.lookup(allocator, io, q);
    }

    pub fn lookup(
        self: *OpenLibrary,
        allocator: std.mem.Allocator,
        io: std.Io,
        q: provider_iface.Query,
    ) !?meta.BookMetadata {
        _ = self;

        const url = if (q.isbn) |isbn|
            try std.fmt.allocPrint(
                allocator,
                "https://openlibrary.org/api/books?bibkeys=ISBN:{s}&format=json&jscmd=data",
                .{isbn},
            )
        else
            return null; // title/author search support comes next
        defer allocator.free(url);

        var resp = http.get(allocator, io, url, .{}) catch |err| switch (err) {
            error.NotImplemented => return null, // soft-fail until http lands
            else => return err,
        };
        defer resp.deinit(allocator);
        if (resp.status != 200) return null;

        return parseIsbnPayload(allocator, q.isbn.?, resp.body);
    }
};

/// Parse Open Library's ISBN-keyed jscmd=data response.
/// Top-level shape: { "ISBN:9780...": { ...book... } }
pub fn parseIsbnPayload(
    allocator: std.mem.Allocator,
    isbn: []const u8,
    body: []const u8,
) !?meta.BookMetadata {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "ISBN:{s}", .{isbn}) catch return null;

    const book_value = root.object.get(key) orelse return null;
    if (book_value != .object) return null;
    const book = book_value.object;

    var md: meta.BookMetadata = .{
        .source = .openlibrary,
        .confidence = 0.7,
        .isbn = try allocator.dupe(u8, isbn),
    };

    if (book.get("title")) |t| {
        if (t == .string) md.title = try allocator.dupe(u8, t.string);
    }

    if (book.get("publish_date")) |d| {
        if (d == .string and d.string.len >= 4) {
            // Open Library returns strings like "October 2024" or "2024".
            const yr = findYear(d.string);
            if (yr) |y| md.published_year = y;
        }
    }

    if (book.get("publishers")) |ps| {
        if (ps == .array and ps.array.items.len > 0) {
            const first = ps.array.items[0];
            if (first == .object) {
                if (first.object.get("name")) |n| {
                    if (n == .string) md.publisher = try allocator.dupe(u8, n.string);
                }
            }
        }
    }

    if (book.get("authors")) |authors_v| {
        if (authors_v == .array) {
            var authors_buf: std.ArrayList(meta.Author) = .empty;
            for (authors_v.array.items) |a| {
                if (a != .object) continue;
                const name_v = a.object.get("name") orelse continue;
                if (name_v != .string) continue;
                const author = try meta.Author.fromDisplay(allocator, name_v.string);
                try authors_buf.append(allocator, author);
            }
            md.authors = try authors_buf.toOwnedSlice(allocator);
        }
    }

    if (book.get("cover")) |cv| {
        if (cv == .object) {
            const url_v = cv.object.get("large") orelse cv.object.get("medium") orelse cv.object.get("small");
            if (url_v) |u| {
                if (u == .string) md.cover_path = try allocator.dupe(u8, u.string);
            }
        }
    }

    return md;
}

fn findYear(s: []const u8) ?u16 {
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        const slice = s[i .. i + 4];
        var all_digit = true;
        for (slice) |c| if (!std.ascii.isDigit(c)) { all_digit = false; break; };
        if (all_digit) {
            const y = std.fmt.parseInt(u16, slice, 10) catch continue;
            if (y >= 1000 and y < 3000) return y;
        }
    }
    return null;
}

// ---- Tests --------------------------------------------------------------

test "parseIsbnPayload extracts title and authors" {
    const fixture =
        \\{
        \\  "ISBN:9780545010221": {
        \\    "title": "Harry Potter and the Deathly Hallows",
        \\    "publish_date": "July 21, 2007",
        \\    "publishers": [{"name": "Arthur A. Levine Books"}],
        \\    "authors": [{"name": "J. K. Rowling"}]
        \\  }
        \\}
    ;
    const alloc = std.testing.allocator;
    const md_opt = try parseIsbnPayload(alloc, "9780545010221", fixture);
    try std.testing.expect(md_opt != null);
    const md = md_opt.?;
    defer if (md.title) |t| alloc.free(t);
    defer if (md.publisher) |p| alloc.free(p);
    defer if (md.isbn) |i| alloc.free(i);
    defer {
        for (md.authors) |a| {
            alloc.free(a.last);
            alloc.free(a.first);
            alloc.free(a.sort);
        }
        alloc.free(md.authors);
    }
    try std.testing.expectEqualStrings("Harry Potter and the Deathly Hallows", md.title.?);
    try std.testing.expectEqual(@as(u16, 2007), md.published_year.?);
    try std.testing.expectEqual(@as(usize, 1), md.authors.len);
    try std.testing.expectEqualStrings("Rowling", md.authors[0].last);
}

test "findYear pulls 4-digit year from text" {
    try std.testing.expectEqual(@as(u16, 2007), findYear("July 21, 2007").?);
    try std.testing.expectEqual(@as(u16, 1984), findYear("1984").?);
    try std.testing.expectEqual(@as(?u16, null), findYear("forever"));
}
