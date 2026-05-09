//! Duplicate detection.
//!
//! Two-tier strategy:
//!   - Tier 1: identical SHA-256 → certain duplicate.
//!   - Tier 2: normalized title + Jaro-Winkler similarity above threshold,
//!     same author. Reported for review, never auto-deleted.

const std = @import("std");
const fuzzy = @import("../util/fuzzy.zig");

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

// ---- Tests --------------------------------------------------------------

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
