//! Movie filename parser.
//!
//! Prefers a parenthesized `(YYYY)` as the year (so "Blade Runner 2049
//! (2017)" keeps 2049 in the title and reads 2017 as the year). Falling
//! back to a trailing bare year token when no parenthesized year exists.

const std = @import("std");
const kind = @import("../core/kind.zig");
const textnorm = @import("../core/textnorm.zig");

pub const Movie = struct {
    title: []const u8,
    year: ?u32 = null,
    quality: ?[]const u8 = null,
    ext: []const u8,
};

fn yearValue(tok: []const u8) ?u32 {
    if (tok.len != 4) return null;
    var v: u32 = 0;
    for (tok) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return if (v >= 1900 and v <= 2099) v else null;
}

const ParenYear = struct { start: usize, year: u32 };

fn findParenYear(stem: []const u8) ?ParenYear {
    var i: usize = 0;
    while (i + 5 < stem.len) : (i += 1) {
        if (stem[i] != '(') continue;
        if (stem[i + 5] != ')') continue;
        if (yearValue(stem[i + 1 .. i + 5])) |y| return .{ .start = i, .year = y };
    }
    return null;
}

fn isResolution(tok: []const u8) bool {
    if (tok.len < 3 or tok.len > 5) return false;
    if (tok[tok.len - 1] != 'p' and tok[tok.len - 1] != 'P') return false;
    for (tok[0 .. tok.len - 1]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn findQuality(alloc: std.mem.Allocator, stem: []const u8) !?[]u8 {
    var it = std.mem.tokenizeAny(u8, stem, " ._-\t");
    while (it.next()) |tok| {
        if (isResolution(tok)) return try alloc.dupe(u8, tok);
    }
    return null;
}

/// Drop a trailing bare year token from an already-cleaned title, returning
/// the stripped title (owned) and the year. Frees `cleaned`.
fn splitTrailingYear(alloc: std.mem.Allocator, cleaned: []u8) !struct { title: []u8, year: ?u32 } {
    var last_year: ?u32 = null;
    var it = std.mem.tokenizeScalar(u8, cleaned, ' ');
    var last_tok: []const u8 = "";
    while (it.next()) |tok| last_tok = tok;
    if (yearValue(last_tok)) |y| last_year = y;

    if (last_year == null) return .{ .title = cleaned, .year = null };

    // Rebuild without the final token.
    const cut = std.mem.lastIndexOfScalar(u8, cleaned, ' ') orelse cleaned.len;
    const title = try alloc.dupe(u8, cleaned[0..cut]);
    alloc.free(cleaned);
    return .{ .title = title, .year = last_year };
}

/// Parse `basename` into a `Movie`. All non-null slices owned by `alloc`.
pub fn parse(alloc: std.mem.Allocator, basename: []const u8) !Movie {
    const ext_dot = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext_dot.len];
    const ext = if (ext_dot.len > 0) ext_dot[1..] else ext_dot;

    var year: ?u32 = null;
    var title: []u8 = undefined;

    if (findParenYear(stem)) |py| {
        year = py.year;
        title = try kind.cleanName(alloc, stem[0..py.start]);
    } else {
        const cleaned = try kind.cleanName(alloc, stem);
        const split = try splitTrailingYear(alloc, cleaned);
        title = split.title;
        year = split.year;
    }
    errdefer alloc.free(title);

    const quality = try findQuality(alloc, stem);
    errdefer if (quality) |x| alloc.free(x);
    const ext_owned = try alloc.dupe(u8, ext);

    const title_clean = try textnorm.clean(alloc, title);
    alloc.free(title);
    return Movie{ .title = title_clean, .year = year, .quality = quality, .ext = ext_owned };
}

const t = std.testing;

fn freeMovie(a: std.mem.Allocator, m: Movie) void {
    a.free(m.title);
    if (m.quality) |x| a.free(x);
    a.free(m.ext);
}

test "parse movie with parenthesized year" {
    const a = t.allocator;
    const m = try parse(a, "Blade Runner 2049 (2017) 1080p BluRay x264.mkv");
    defer freeMovie(a, m);
    try t.expectEqualStrings("Blade Runner 2049", m.title);
    try t.expectEqual(@as(u32, 2017), m.year.?);
}

test "parse dotted movie without parens" {
    const a = t.allocator;
    const m = try parse(a, "The.Matrix.1999.1080p.mkv");
    defer freeMovie(a, m);
    try t.expectEqualStrings("The Matrix", m.title);
    try t.expectEqual(@as(u32, 1999), m.year.?);
}
