//! Pure Jellyfin NFO (XML) builders from plan.Fields. No IO. Jellyfin reads
//! local NFO with priority, so these pin identity (provider IDs + basics) and
//! let the server enrich the rest. Missing fields are omitted → always
//! well-formed XML.

const std = @import("std");
const plan = @import("plan.zig");

fn esc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

fn append(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

fn tag(out: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8, val: []const u8) !void {
    if (val.len == 0) return;
    const e = try esc(alloc, val);
    defer alloc.free(e);
    try append(out, alloc, "  <{s}>{s}</{s}>\n", .{ name, e, name });
}
fn tagNum(out: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8, val: ?u32) !void {
    if (val) |n| try append(out, alloc, "  <{s}>{d}</{s}>\n", .{ name, n, name });
}

/// Dedicated provider-id tags + the `<uniqueid>` forms Jellyfin understands.
fn providerIds(out: *std.ArrayList(u8), alloc: std.mem.Allocator, f: plan.Fields) !void {
    if (f.tmdb_id) |x| {
        try tag(out, alloc, "tmdbid", x);
        const e = try esc(alloc, x);
        defer alloc.free(e);
        try append(out, alloc, "  <uniqueid type=\"tmdb\" default=\"true\">{s}</uniqueid>\n", .{e});
    }
    if (f.imdb_id) |x| {
        try tag(out, alloc, "imdbid", x);
        const e = try esc(alloc, x);
        defer alloc.free(e);
        try append(out, alloc, "  <uniqueid type=\"imdb\">{s}</uniqueid>\n", .{e});
    }
    if (f.tvdb_id) |x| {
        try tag(out, alloc, "tvdbid", x);
        const e = try esc(alloc, x);
        defer alloc.free(e);
        try append(out, alloc, "  <uniqueid type=\"tvdb\">{s}</uniqueid>\n", .{e});
    }
}

pub fn movieNfo(alloc: std.mem.Allocator, f: plan.Fields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<movie>\n");
    try tag(&out, alloc, "title", f.title orelse "");
    try tagNum(&out, alloc, "year", f.year);
    try tag(&out, alloc, "language", f.original_language orelse "");
    try providerIds(&out, alloc, f);
    try out.appendSlice(alloc, "</movie>\n");
    return out.toOwnedSlice(alloc);
}

pub fn episodeNfo(alloc: std.mem.Allocator, f: plan.Fields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<episodedetails>\n");
    try tag(&out, alloc, "title", f.title orelse "");
    try tag(&out, alloc, "showtitle", f.series orelse "");
    try tagNum(&out, alloc, "season", f.season);
    try tagNum(&out, alloc, "episode", f.episode);
    try providerIds(&out, alloc, f);
    try out.appendSlice(alloc, "</episodedetails>\n");
    return out.toOwnedSlice(alloc);
}

pub fn tvshowNfo(alloc: std.mem.Allocator, f: plan.Fields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tvshow>\n");
    try tag(&out, alloc, "title", f.series orelse "");
    try tagNum(&out, alloc, "year", f.series_year);
    try tag(&out, alloc, "language", f.original_language orelse "");
    try providerIds(&out, alloc, f);
    try out.appendSlice(alloc, "</tvshow>\n");
    return out.toOwnedSlice(alloc);
}

pub fn seasonNfo(alloc: std.mem.Allocator, season: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try append(&out, alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<season>\n  <seasonnumber>{d}</seasonnumber>\n</season>\n", .{season});
    return out.toOwnedSlice(alloc);
}

pub fn albumNfo(alloc: std.mem.Allocator, f: plan.Fields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<album>\n");
    try tag(&out, alloc, "title", f.album orelse "");
    try tag(&out, alloc, "artist", f.album_artist orelse "");
    try tagNum(&out, alloc, "year", f.year);
    if (f.release_mbid) |x| try tag(&out, alloc, "musicbrainzalbumid", x);
    try out.appendSlice(alloc, "</album>\n");
    return out.toOwnedSlice(alloc);
}

pub fn artistNfo(alloc: std.mem.Allocator, name: []const u8, mbid: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<artist>\n");
    try tag(&out, alloc, "name", name);
    if (mbid) |x| try tag(&out, alloc, "musicbrainzartistid", x);
    try out.appendSlice(alloc, "</artist>\n");
    return out.toOwnedSlice(alloc);
}

const t = std.testing;

test "movieNfo has title/year/ids/uniqueid, escapes" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const s = try movieNfo(a.allocator(), .{ .title = "Tom & Jerry", .year = 1999, .tmdb_id = "603", .imdb_id = "tt0133093", .original_language = "en" });
    try t.expect(std.mem.indexOf(u8, s, "<title>Tom &amp; Jerry</title>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<year>1999</year>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<tmdbid>603</tmdbid>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<uniqueid type=\"tmdb\" default=\"true\">603</uniqueid>") != null);
}

test "episodeNfo + tvshowNfo + seasonNfo" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const al = a.allocator();
    const e = try episodeNfo(al, .{ .series = "Severance", .season = 1, .episode = 2, .title = "Half Loop", .tmdb_id = "95396" });
    try t.expect(std.mem.indexOf(u8, e, "<episodedetails>") != null);
    try t.expect(std.mem.indexOf(u8, e, "<season>1</season>") != null);
    try t.expect(std.mem.indexOf(u8, e, "<showtitle>Severance</showtitle>") != null);
    const sh = try tvshowNfo(al, .{ .series = "Severance", .series_year = 2022, .tmdb_id = "95396" });
    try t.expect(std.mem.indexOf(u8, sh, "<tvshow>") != null);
    try t.expect(std.mem.indexOf(u8, sh, "<year>2022</year>") != null);
    const sn = try seasonNfo(al, 1);
    try t.expect(std.mem.indexOf(u8, sn, "<seasonnumber>1</seasonnumber>") != null);
}

test "albumNfo + artistNfo" {
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    const al = a.allocator();
    const ab = try albumNfo(al, .{ .album = "Blue", .album_artist = "Eric Clapton", .year = 1998, .release_mbid = "rel-1" });
    try t.expect(std.mem.indexOf(u8, ab, "<title>Blue</title>") != null);
    try t.expect(std.mem.indexOf(u8, ab, "<musicbrainzalbumid>rel-1</musicbrainzalbumid>") != null);
    const ar = try artistNfo(al, "Eric Clapton", "art-1");
    try t.expect(std.mem.indexOf(u8, ar, "<name>Eric Clapton</name>") != null);
    try t.expect(std.mem.indexOf(u8, ar, "<musicbrainzartistid>art-1</musicbrainzartistid>") != null);
}
