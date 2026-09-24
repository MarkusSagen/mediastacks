//! The Movie Database (TMDB) provider — Jellyfin's default. Search a movie/TV
//! title, then fetch detail (+external_ids) for canonical title/year, provider
//! IDs, and original_language; look up episode titles. Mirrors
//! `providers/musicbrainz.zig`: injected `http.HttpClient` (real+cache / mock),
//! `std.json.Value` parsing, graceful `null` on any failure. TMDB v3, `api_key`
//! query param.

const std = @import("std");
const http = @import("../util/http.zig");

pub const MovieInfo = struct {
    tmdb_id: []const u8,
    imdb_id: ?[]const u8 = null,
    title: []const u8,
    year: ?u32 = null,
    original_language: ?[]const u8 = null,
    poster_path: ?[]const u8 = null, // TMDB image path, e.g. "/abc.jpg"
};

pub const SeriesInfo = struct {
    tmdb_id: []const u8,
    imdb_id: ?[]const u8 = null,
    tvdb_id: ?[]const u8 = null,
    name: []const u8,
    year: ?u32 = null,
    original_language: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
};

pub const Tmdb = struct {
    http_client: http.HttpClient,
    api_key: []const u8,

    pub fn lookupMovie(self: *Tmdb, alloc: std.mem.Allocator, title: []const u8, hint_year: ?u32) !?MovieInfo {
        const et = try urlEncode(alloc, title);
        const year_q = if (hint_year) |y| try std.fmt.allocPrint(alloc, "{d}", .{y}) else try alloc.dupe(u8, "");
        const search_url = try std.fmt.allocPrint(
            alloc,
            "https://api.themoviedb.org/3/search/movie?query={s}&year={s}&api_key={s}&language=en-US",
            .{ et, year_q, self.api_key },
        );
        const sbody = httpGetOk(self.http_client, alloc, search_url) orelse return null;
        const id = chooseResultId(alloc, sbody, "release_date", hint_year) orelse return null;

        const durl = try std.fmt.allocPrint(
            alloc,
            "https://api.themoviedb.org/3/movie/{s}?api_key={s}&language=en-US&append_to_response=external_ids",
            .{ id, self.api_key },
        );
        const dbody = httpGetOk(self.http_client, alloc, durl) orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, dbody, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const o = parsed.value.object;
        return MovieInfo{
            .tmdb_id = id,
            .imdb_id = objStrDup(alloc, o, "imdb_id") orelse externalId(alloc, o, "imdb_id"),
            .title = objStrDup(alloc, o, "title") orelse "",
            .year = objYear(o, "release_date"),
            .original_language = objStrDup(alloc, o, "original_language"),
            .poster_path = objStrDup(alloc, o, "poster_path"),
        };
    }

    pub fn lookupSeries(self: *Tmdb, alloc: std.mem.Allocator, name: []const u8, hint_year: ?u32) !?SeriesInfo {
        const et = try urlEncode(alloc, name);
        const year_q = if (hint_year) |y| try std.fmt.allocPrint(alloc, "{d}", .{y}) else try alloc.dupe(u8, "");
        const search_url = try std.fmt.allocPrint(
            alloc,
            "https://api.themoviedb.org/3/search/tv?query={s}&first_air_date_year={s}&api_key={s}&language=en-US",
            .{ et, year_q, self.api_key },
        );
        const sbody = httpGetOk(self.http_client, alloc, search_url) orelse return null;
        const id = chooseResultId(alloc, sbody, "first_air_date", hint_year) orelse return null;

        const durl = try std.fmt.allocPrint(
            alloc,
            "https://api.themoviedb.org/3/tv/{s}?api_key={s}&language=en-US&append_to_response=external_ids",
            .{ id, self.api_key },
        );
        const dbody = httpGetOk(self.http_client, alloc, durl) orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, dbody, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const o = parsed.value.object;
        return SeriesInfo{
            .tmdb_id = id,
            .imdb_id = externalId(alloc, o, "imdb_id"),
            .tvdb_id = externalId(alloc, o, "tvdb_id"),
            .name = objStrDup(alloc, o, "name") orelse "",
            .year = objYear(o, "first_air_date"),
            .original_language = objStrDup(alloc, o, "original_language"),
            .poster_path = objStrDup(alloc, o, "poster_path"),
        };
    }

    /// Download the poster for `poster_path` (e.g. "/abc.jpg") at w500 width.
    /// Returns the image bytes (owned by `alloc`), or null on any failure.
    pub fn fetchPoster(self: *Tmdb, alloc: std.mem.Allocator, poster_path: []const u8) ?[]u8 {
        if (poster_path.len == 0) return null;
        const url = std.fmt.allocPrint(alloc, "https://image.tmdb.org/t/p/w500{s}", .{poster_path}) catch return null;
        return httpGetOk(self.http_client, alloc, url);
    }

    pub fn episodeTitle(self: *Tmdb, alloc: std.mem.Allocator, tmdb_id: []const u8, season: u32, episode: u32) !?[]const u8 {
        const url = try std.fmt.allocPrint(
            alloc,
            "https://api.themoviedb.org/3/tv/{s}/season/{d}/episode/{d}?api_key={s}&language=en-US",
            .{ tmdb_id, season, episode, self.api_key },
        );
        const body = httpGetOk(self.http_client, alloc, url) orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        return objStrDup(alloc, parsed.value.object, "name");
    }
};

/// Pick a result id: first result whose `date_key` year == hint (when given),
/// else the first result. Returns the id as an owned string.
fn chooseResultId(alloc: std.mem.Allocator, body: []const u8, date_key: []const u8, hint_year: ?u32) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const results = parsed.value.object.get("results") orelse return null;
    if (results != .array or results.array.items.len == 0) return null;

    var chosen: ?std.json.Value = null;
    if (hint_year) |hy| {
        for (results.array.items) |r| {
            if (r != .object) continue;
            if (objYear(r.object, date_key)) |y| {
                if (y == hy) {
                    chosen = r;
                    break;
                }
            }
        }
    }
    const pick = chosen orelse results.array.items[0];
    if (pick != .object) return null;
    const idv = pick.object.get("id") orelse return null;
    if (idv != .integer) return null;
    return std.fmt.allocPrint(alloc, "{d}", .{idv.integer}) catch null;
}

fn objStrDup(alloc: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return alloc.dupe(u8, v.string) catch null;
}

/// `external_ids.{key}` (string, non-empty) or null.
fn externalId(alloc: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const ext = o.get("external_ids") orelse return null;
    if (ext != .object) return null;
    return objStrDup(alloc, ext.object, key);
}

fn objYear(o: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = o.get(key) orelse return null;
    if (v != .string) return null;
    return findYear(v.string);
}

fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            try buf.append(alloc, ch);
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(alloc, '%');
            try buf.append(alloc, hex[ch >> 4]);
            try buf.append(alloc, hex[ch & 0x0f]);
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn httpGetOk(client: http.HttpClient, alloc: std.mem.Allocator, url: []const u8) ?[]u8 {
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        var resp = client.fetchGet(alloc, url, .{}) catch continue;
        if (resp.status >= 200 and resp.status < 300) return resp.body;
        if (resp.status >= 400 and resp.status < 500) {
            resp.deinit(alloc);
            return null;
        }
        resp.deinit(alloc);
    }
    return null;
}

fn findYear(s: []const u8) ?u32 {
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        const slice = s[i .. i + 4];
        var all_digit = true;
        for (slice) |c| if (!std.ascii.isDigit(c)) {
            all_digit = false;
            break;
        };
        if (all_digit) {
            const y = std.fmt.parseInt(u32, slice, 10) catch continue;
            if (y >= 1000 and y < 3000) return y;
        }
    }
    return null;
}

/// Per-run memo so a movie/series is fetched once (and each episode once).
pub const Enricher = struct {
    api: *Tmdb,
    movies: std.StringHashMap(?MovieInfo),
    series: std.StringHashMap(?SeriesInfo),
    episodes: std.StringHashMap(?[]const u8),

    pub fn init(alloc: std.mem.Allocator, api: *Tmdb) Enricher {
        return .{
            .api = api,
            .movies = std.StringHashMap(?MovieInfo).init(alloc),
            .series = std.StringHashMap(?SeriesInfo).init(alloc),
            .episodes = std.StringHashMap(?[]const u8).init(alloc),
        };
    }

    pub fn lookupMovie(self: *Enricher, alloc: std.mem.Allocator, title: []const u8, hint_year: ?u32) !?MovieInfo {
        const key = try std.fmt.allocPrint(alloc, "{s}|{?d}", .{ title, hint_year });
        if (self.movies.get(key)) |c| return c;
        const r = try self.api.lookupMovie(alloc, title, hint_year); // propagate errors (network/provider) — don't cache them as "no match"
        try self.movies.put(key, r);
        return r;
    }

    /// Best-effort poster download for an enriched movie/series result.
    pub fn fetchPoster(self: *Enricher, alloc: std.mem.Allocator, poster_path: []const u8) ?[]u8 {
        return self.api.fetchPoster(alloc, poster_path);
    }

    pub fn lookupSeries(self: *Enricher, alloc: std.mem.Allocator, name: []const u8, hint_year: ?u32) !?SeriesInfo {
        const key = try std.fmt.allocPrint(alloc, "{s}|{?d}", .{ name, hint_year });
        if (self.series.get(key)) |c| return c;
        const r = try self.api.lookupSeries(alloc, name, hint_year); // propagate errors — don't cache as "no match"
        try self.series.put(key, r);
        return r;
    }

    pub fn episodeTitle(self: *Enricher, alloc: std.mem.Allocator, tmdb_id: []const u8, season: u32, episode: u32) !?[]const u8 {
        const key = try std.fmt.allocPrint(alloc, "{s}|{d}|{d}", .{ tmdb_id, season, episode });
        if (self.episodes.get(key)) |c| return c;
        const r = self.api.episodeTitle(alloc, tmdb_id, season, episode) catch null;
        try self.episodes.put(key, r);
        return r;
    }
};

const t = std.testing;

test "lookupMovie: search then detail with external ids" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://api.themoviedb.org/3/search/movie?query=The%20Matrix&year=1999&api_key=K&language=en-US", 200,
        \\{"results":[{"id":603,"title":"The Matrix","release_date":"1999-03-31"}]}
    );
    try mock.add("https://api.themoviedb.org/3/movie/603?api_key=K&language=en-US&append_to_response=external_ids", 200,
        \\{"id":603,"title":"The Matrix","release_date":"1999-03-31","original_language":"en","imdb_id":"tt0133093","external_ids":{"imdb_id":"tt0133093"}}
    );
    var api = Tmdb{ .http_client = mock.client(), .api_key = "K" };
    const m = (try api.lookupMovie(a, "The Matrix", 1999)).?;
    try t.expectEqualStrings("603", m.tmdb_id);
    try t.expectEqualStrings("tt0133093", m.imdb_id.?);
    try t.expectEqualStrings("The Matrix", m.title);
    try t.expectEqual(@as(u32, 1999), m.year.?);
    try t.expectEqualStrings("en", m.original_language.?);
    try t.expectEqual(@as(usize, 2), mock.calls.items.len);
}

test "lookupSeries + episodeTitle" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://api.themoviedb.org/3/search/tv?query=Severance&first_air_date_year=2022&api_key=K&language=en-US", 200,
        \\{"results":[{"id":95396,"name":"Severance","first_air_date":"2022-02-18"}]}
    );
    try mock.add("https://api.themoviedb.org/3/tv/95396?api_key=K&language=en-US&append_to_response=external_ids", 200,
        \\{"id":95396,"name":"Severance","first_air_date":"2022-02-18","original_language":"en","external_ids":{"imdb_id":"tt11280740","tvdb_id":"371980"}}
    );
    try mock.add("https://api.themoviedb.org/3/tv/95396/season/1/episode/1?api_key=K&language=en-US", 200,
        \\{"name":"Good News About Hell"}
    );
    var api = Tmdb{ .http_client = mock.client(), .api_key = "K" };
    const s = (try api.lookupSeries(a, "Severance", 2022)).?;
    try t.expectEqualStrings("95396", s.tmdb_id);
    try t.expectEqualStrings("371980", s.tvdb_id.?);
    try t.expectEqual(@as(u32, 2022), s.year.?);
    const et = (try api.episodeTitle(a, "95396", 1, 1)).?;
    try t.expectEqualStrings("Good News About Hell", et);
}

test "lookupMovie: no results → null" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://api.themoviedb.org/3/search/movie?query=Nope&year=2000&api_key=K&language=en-US", 200,
        \\{"results":[]}
    );
    var api = Tmdb{ .http_client = mock.client(), .api_key = "K" };
    try t.expect((try api.lookupMovie(a, "Nope", 2000)) == null);
}
