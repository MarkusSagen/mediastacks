//! TV episode filename parser.
//!
//! Splits a basename around its `SxxExx` marker: the text before becomes
//! the (cleaned) series name, the text after becomes the episode title up
//! to the first release-noise token. Returns null when no season-episode
//! marker is present.

const std = @import("std");
const kind = @import("../core/kind.zig");
const textnorm = @import("../core/textnorm.zig");

pub const Episode = struct {
    series: []const u8,
    season: u32,
    episode: u32,
    title: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    ext: []const u8,
};

const SE = struct { start: usize, end: usize, season: u32, episode: u32 };

fn isBoundary(c: u8) bool {
    return c == ' ' or c == '.' or c == '_' or c == '-' or c == '\t';
}

/// Locate the first `SxxExx` marker sitting on a token boundary.
fn findSE(stem: []const u8) ?SE {
    var i: usize = 0;
    while (i < stem.len) : (i += 1) {
        if (stem[i] != 's' and stem[i] != 'S') continue;
        if (i > 0 and !isBoundary(stem[i - 1])) continue;
        var j = i + 1;
        var season: u32 = 0;
        var sd: usize = 0;
        while (j < stem.len and std.ascii.isDigit(stem[j])) : (j += 1) {
            season = season * 10 + (stem[j] - '0');
            sd += 1;
        }
        if (sd < 1 or sd > 2) continue;
        if (j >= stem.len or (stem[j] != 'e' and stem[j] != 'E')) continue;
        j += 1;
        var episode: u32 = 0;
        var ed: usize = 0;
        while (j < stem.len and std.ascii.isDigit(stem[j])) : (j += 1) {
            episode = episode * 10 + (stem[j] - '0');
            ed += 1;
        }
        if (ed < 1 or ed > 2) continue;
        return .{ .start = i, .end = j, .season = season, .episode = episode };
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

fn extractTitle(alloc: std.mem.Allocator, after: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, after, " ._-\t");
    while (it.next()) |tok| {
        if (kind.isNoiseToken(tok)) break;
        if (out.items.len > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, tok);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

/// Parse `basename` into an `Episode`, or null if it isn't an episode.
/// All non-null slices are owned by `alloc`.
pub fn parse(alloc: std.mem.Allocator, basename: []const u8) !?Episode {
    const ext_dot = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext_dot.len];
    const ext = if (ext_dot.len > 0) ext_dot[1..] else ext_dot;

    const se = findSE(stem) orelse return null;

    const raw_series = try kind.cleanName(alloc, stem[0..se.start]);
    const series = try textnorm.clean(alloc, raw_series);
    alloc.free(raw_series);
    errdefer alloc.free(series);
    const title = if (try extractTitle(alloc, stem[se.end..])) |raw| blk: {
        const cleaned = try textnorm.clean(alloc, raw);
        alloc.free(raw);
        break :blk cleaned;
    } else null;
    errdefer if (title) |x| alloc.free(x);
    const quality = try findQuality(alloc, stem);
    errdefer if (quality) |x| alloc.free(x);
    const ext_owned = try alloc.dupe(u8, ext);

    return Episode{
        .series = series,
        .season = se.season,
        .episode = se.episode,
        .title = title,
        .quality = quality,
        .ext = ext_owned,
    };
}

const t = std.testing;

fn freeEpisode(a: std.mem.Allocator, ep: Episode) void {
    a.free(ep.series);
    if (ep.title) |x| a.free(x);
    if (ep.quality) |x| a.free(x);
    a.free(ep.ext);
}

test "parse dotted skyanime name" {
    const a = t.allocator;
    const ep = (try parse(a, "witch.hat.atelier.s01e12.1080p.web.h264-skyanime.mkv")).?;
    defer freeEpisode(a, ep);
    try t.expectEqualStrings("witch hat atelier", ep.series);
    try t.expectEqual(@as(u32, 1), ep.season);
    try t.expectEqual(@as(u32, 12), ep.episode);
    try t.expectEqualStrings("1080p", ep.quality.?);
    try t.expect(ep.title == null);
    try t.expectEqualStrings("mkv", ep.ext);
}

test "parse UIndex descriptive name keeps episode title" {
    const a = t.allocator;
    const ep = (try parse(a, "Witch Hat Atelier S01E04 Meetings in Kalhn 1080p CR WEB-DL DUAL DDP2 0 H 264-Kitsune.mkv")).?;
    defer freeEpisode(a, ep);
    try t.expectEqualStrings("Witch Hat Atelier", ep.series);
    try t.expectEqual(@as(u32, 4), ep.episode);
    try t.expectEqualStrings("Meetings in Kalhn", ep.title.?);
}

test "parse returns null without season-episode marker" {
    const a = t.allocator;
    try t.expect((try parse(a, "just a movie (2020).mkv")) == null);
}
