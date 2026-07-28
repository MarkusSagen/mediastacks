//! Duplicate detection.
//!
//! Two-tier strategy:
//!   - Tier 1: identical SHA-256 → certain duplicate.
//!   - Tier 2: normalized title + Jaro-Winkler similarity above threshold,
//!     same author. Reported for review, never auto-deleted.

const std = @import("std");
const fuzzy = @import("../util/fuzzy.zig");
const catalog_mod = @import("catalog.zig");
const quality = @import("quality.zig");
const meta = @import("metadata.zig");

pub const FUZZY_THRESHOLD: f32 = 0.92;

pub const MatchKind = enum { exact, fuzzy };

pub const Match = struct {
    a_id: i64,
    b_id: i64,
    kind: MatchKind,
    score: f32,
};

const LEADING_ARTICLES = [_][]const u8{ "the ", "a ", "an " };
const TRAILING_ARTICLES = [_][]const u8{ ", the", ", a", ", an" };

/// Lowercase, strip subtitle after `:`, collapse whitespace, drop
/// punctuation, and remove a leading or trailing article. Common
/// shelving convention so "The Way of Kings" ↔ "Way of Kings, The"
/// fuzzily-match.
pub fn normalizeTitle(allocator: std.mem.Allocator, title: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const cut: usize = blk: {
        if (std.mem.indexOf(u8, title, ": ")) |idx| break :blk idx;
        break :blk title.len;
    };
    const trimmed = std.mem.trim(u8, title[0..cut], " \t\r\n");

    var prev_space = true;
    for (trimmed) |raw| {
        const ch = std.ascii.toLower(raw);
        if (std.ascii.isAlphanumeric(ch)) {
            try buf.append(allocator, ch);
            prev_space = false;
        } else if (ch == ' ' or ch == '\t' or ch == ',') {
            if (!prev_space) try buf.append(allocator, ' ');
            prev_space = true;
        }
    }
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        _ = buf.pop();
    }

    var s = buf.items;
    inline for (LEADING_ARTICLES) |art| {
        if (s.len > art.len and std.mem.startsWith(u8, s, art)) {
            s = s[art.len..];
        }
    }
    inline for ([_][]const u8{ " the", " a", " an" }) |art| {
        if (s.len > art.len and std.mem.endsWith(u8, s, art)) {
            s = s[0 .. s.len - art.len];
        }
    }

    return allocator.dupe(u8, s);
}

pub fn compareTitles(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !f32 {
    const na = try normalizeTitle(allocator, a);
    defer allocator.free(na);
    const nb = try normalizeTitle(allocator, b);
    defer allocator.free(nb);
    return fuzzy.jaroWinkler(na, nb);
}

test "normalizeTitle strips subtitle, punctuation, and leading article" {
    const alloc = std.testing.allocator;
    const out = try normalizeTitle(alloc, "The Way of Kings: Book One of the Stormlight Archive");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("way of kings", out);
}

test "normalizeTitle handles trailing-comma article form" {
    const alloc = std.testing.allocator;
    const out = try normalizeTitle(alloc, "Way of Kings, The");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("way of kings", out);
}

test "normalizeTitle collapses whitespace" {
    const alloc = std.testing.allocator;
    const out = try normalizeTitle(alloc, "  Mistborn:  The   Final Empire  ");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("mistborn", out);
}

test "compareTitles flags near-duplicates" {
    const alloc = std.testing.allocator;
    const score = try compareTitles(alloc, "The Way of Kings", "Way of Kings, The");
    try std.testing.expect(score > FUZZY_THRESHOLD);
}

pub const Group = struct {
    /// Ordered with the highest-quality book first ("keep" candidate).
    books: []const catalog_mod.Book,
    /// Reason this group was formed.
    reason: enum { exact_sha, fuzzy_title } = .fuzzy_title,
};

/// Group books that represent the same logical work, regardless of
/// format or edition: same author (first-author sort-name match) and
/// near-identical normalized title. Books within a group are sorted
/// best-first by `quality.scoreBook`.
///
/// Caller owns the returned slice; each group's `books` slice is allocated
/// from the same allocator.
pub fn groupByLogicalIdentity(
    allocator: std.mem.Allocator,
    books: []const catalog_mod.Book,
) ![]Group {
    var groups: std.ArrayList(Group) = .empty;
    var claimed = try allocator.alloc(bool, books.len);
    @memset(claimed, false);

    var i: usize = 0;
    while (i < books.len) : (i += 1) {
        if (claimed[i]) continue;
        const a = books[i];
        if (a.metadata.title == null or a.metadata.authors.len == 0) continue;

        var bucket: std.ArrayList(catalog_mod.Book) = .empty;
        try bucket.append(allocator, a);
        claimed[i] = true;

        var j: usize = i + 1;
        while (j < books.len) : (j += 1) {
            if (claimed[j]) continue;
            const b = books[j];
            if (b.metadata.title == null or b.metadata.authors.len == 0) continue;
            if (!std.ascii.eqlIgnoreCase(a.metadata.authors[0].sort, b.metadata.authors[0].sort)) continue;

            const score = try compareTitles(allocator, a.metadata.title.?, b.metadata.title.?);
            if (score < FUZZY_THRESHOLD) continue;

            try bucket.append(allocator, b);
            claimed[j] = true;
        }
        if (bucket.items.len < 2) {
            bucket.deinit(allocator);
            continue;
        }

        const owned = try bucket.toOwnedSlice(allocator);
        sortByQualityDesc(owned);
        try groups.append(allocator, .{ .books = owned });
    }

    allocator.free(claimed);
    return groups.toOwnedSlice(allocator);
}

fn sortByQualityDesc(books: []catalog_mod.Book) void {
    std.mem.sort(catalog_mod.Book, books, {}, scoreCmp);
}
fn scoreCmp(_: void, a: catalog_mod.Book, b: catalog_mod.Book) bool {
    return quality.scoreBook(a) > quality.scoreBook(b);
}

test "groupByLogicalIdentity finds cross-format duplicates" {
    const alloc = std.testing.allocator;
    const author = [_]meta.Author{.{ .last = "Hobb", .first = "Robin", .sort = "Hobb, Robin" }};
    const a = catalog_mod.Book{
        .id = 1,
        .path = "a.epub",
        .sha256 = "aaa",
        .size = 500_000,
        .format = .epub,
        .mtime = 0,
        .metadata = .{ .title = "Assassin's Apprentice", .authors = &author, .confidence = 0.9 },
    };
    const b = catalog_mod.Book{
        .id = 2,
        .path = "b.mobi",
        .sha256 = "bbb",
        .size = 400_000,
        .format = .mobi,
        .mtime = 0,
        .metadata = .{ .title = "Assassin's Apprentice", .authors = &author, .confidence = 0.9 },
    };
    const c = catalog_mod.Book{
        .id = 3,
        .path = "c.epub",
        .sha256 = "ccc",
        .size = 100_000,
        .format = .epub,
        .mtime = 0,
        .metadata = .{ .title = "Royal Assassin", .authors = &author, .confidence = 0.9 },
    };

    const books = [_]catalog_mod.Book{ a, b, c };
    const groups = try groupByLogicalIdentity(alloc, &books);
    defer {
        for (groups) |g| alloc.free(g.books);
        alloc.free(groups);
    }

    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].books.len);
    try std.testing.expectEqual(meta.Format.epub, groups[0].books[0].format);
}
