//! MusicBrainz provider — search a release by album+artist+track-count, then
//! fetch its detail (canonical title, year, per-track titles + multi-artist
//! credits + recording MBIDs). Mirrors `openlibrary.zig`: injected
//! `http.HttpClient` (prod real / test mock), `std.json.Value` parsing, and
//! graceful `null` on any HTTP/parse failure. Throttling + caching live in
//! `util/httpcache.zig`.

const std = @import("std");
const http = @import("../util/http.zig");

pub const TrackInfo = struct {
    position: u32,
    title: []const u8,
    recording_mbid: ?[]const u8 = null,
    artists: []const []const u8 = &.{},
};

pub const Release = struct {
    mbid: []const u8,
    title: []const u8,
    album_artist: []const u8,
    year: ?u32 = null,
    cover_url: ?[]const u8 = null,
    tracks: []const TrackInfo = &.{},
};

pub const MusicBrainz = struct {
    http_client: http.HttpClient,
    contact: ?[]const u8 = null,

    /// Search + fetch the best release for an album. `track_count` gates the
    /// match (exact-count required). Returns null on no confident match or any
    /// failure. All strings owned by `alloc`.
    pub fn lookupRelease(
        self: *MusicBrainz,
        alloc: std.mem.Allocator,
        album: []const u8,
        album_artist: []const u8,
        track_count: usize,
        hint_year: ?u32,
    ) !?Release {
        const ea = try urlEncode(alloc, album);
        const eaa = try urlEncode(alloc, album_artist);
        const search_url = try std.fmt.allocPrint(
            alloc,
            "https://musicbrainz.org/ws/2/release?query=release:%22{s}%22%20AND%20artist:%22{s}%22%20AND%20tracks:{d}&fmt=json&limit=5",
            .{ ea, eaa, track_count },
        );
        const search_body = httpGetOk(self.http_client, alloc, search_url) orelse return null;
        const mbid = chooseRelease(alloc, search_body, track_count, hint_year) orelse return null;

        const detail_url = try std.fmt.allocPrint(
            alloc,
            "https://musicbrainz.org/ws/2/release/{s}?inc=recordings+artist-credits+release-groups&fmt=json",
            .{mbid},
        );
        const detail_body = httpGetOk(self.http_client, alloc, detail_url) orelse return null;
        return parseRelease(alloc, mbid, detail_body);
    }
};

/// Percent-encode for a MusicBrainz query value; space → %20 (not +).
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

/// Pick the best release MBID: highest `score` among releases whose
/// `track-count` equals `want`, with a bonus for a year within 1 of `hint`.
fn chooseRelease(alloc: std.mem.Allocator, body: []const u8, want: usize, hint_year: ?u32) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const rels = parsed.value.object.get("releases") orelse return null;
    if (rels != .array) return null;

    var best_id: ?[]const u8 = null;
    var best_score: i64 = std.math.minInt(i64);
    for (rels.array.items) |rv| {
        if (rv != .object) continue;
        const tc = rv.object.get("track-count") orelse continue;
        if (tc != .integer or @as(usize, @intCast(tc.integer)) != want) continue;
        var score: i64 = 0;
        if (rv.object.get("score")) |s| if (s == .integer) {
            score = s.integer;
        };
        if (hint_year) |hy| {
            if (rv.object.get("date")) |d| if (d == .string) {
                if (findYear(d.string)) |y| {
                    const diff = if (y > hy) y - hy else hy - y;
                    if (diff <= 1) score += 50;
                }
            };
        }
        if (score > best_score) {
            best_score = score;
            if (rv.object.get("id")) |idv| if (idv == .string) {
                best_id = alloc.dupe(u8, idv.string) catch return null;
            };
        }
    }
    return best_id;
}

fn creditNames(alloc: std.mem.Allocator, credit: std.json.Value) ![]const []const u8 {
    if (credit != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (credit.array.items) |c| {
        if (c != .object) continue;
        const n = c.object.get("name") orelse continue;
        if (n != .string or n.string.len == 0) continue;
        try out.append(alloc, try alloc.dupe(u8, n.string));
    }
    return out.toOwnedSlice(alloc);
}

fn joinNames(alloc: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    if (names.len == 0) return alloc.dupe(u8, "");
    if (names.len == 1) return alloc.dupe(u8, names[0]);
    var buf: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, n);
    }
    return buf.toOwnedSlice(alloc);
}

/// Parse a release detail body into a Release, flattening media[].tracks[].
fn parseRelease(alloc: std.mem.Allocator, mbid: []const u8, body: []const u8) !?Release {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    const title = if (root.get("title")) |tv| (if (tv == .string) try alloc.dupe(u8, tv.string) else "") else "";

    // Year: prefer release-group first-release-date, else the release date.
    var year: ?u32 = null;
    if (root.get("release-group")) |rg| if (rg == .object) {
        if (rg.object.get("first-release-date")) |d| if (d == .string) {
            year = findYear(d.string);
        };
    };
    if (year == null) if (root.get("date")) |d| if (d == .string) {
        year = findYear(d.string);
    };

    const aa_names = if (root.get("artist-credit")) |ac| try creditNames(alloc, ac) else &[_][]const u8{};
    const album_artist = try joinNames(alloc, aa_names);

    var tracks: std.ArrayList(TrackInfo) = .empty;
    if (root.get("media")) |media| if (media == .array) {
        for (media.array.items) |m| {
            if (m != .object) continue;
            const tks = m.object.get("tracks") orelse continue;
            if (tks != .array) continue;
            for (tks.array.items) |tk| {
                if (tk != .object) continue;
                var ti: TrackInfo = .{ .position = 0, .title = "" };
                if (tk.object.get("position")) |p| if (p == .integer) {
                    ti.position = @intCast(p.integer);
                };
                if (tk.object.get("title")) |tt| if (tt == .string) {
                    ti.title = try alloc.dupe(u8, tt.string);
                };
                if (tk.object.get("recording")) |rec| if (rec == .object) {
                    if (rec.object.get("id")) |rid| if (rid == .string) {
                        ti.recording_mbid = try alloc.dupe(u8, rid.string);
                    };
                    if (rec.object.get("artist-credit")) |rac| {
                        ti.artists = try creditNames(alloc, rac);
                    }
                };
                try tracks.append(alloc, ti);
            }
        }
    };

    const cover = try std.fmt.allocPrint(alloc, "https://coverartarchive.org/release/{s}/front-500", .{mbid});
    return Release{
        .mbid = try alloc.dupe(u8, mbid),
        .title = title,
        .album_artist = album_artist,
        .year = year,
        .cover_url = cover,
        .tracks = try tracks.toOwnedSlice(alloc),
    };
}

/// GET with a small retry; null on 4xx or terminal failure. Throttling and
/// caching live in CachingHttpClient — this only tolerates transient errors.
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

/// Per-run wrapper: memoizes album lookups so a re-encountered album (or a
/// multi-disc album seen once per source folder) hits the network at most once.
pub const Enricher = struct {
    mb: *MusicBrainz,
    memo: std.StringHashMap(?Release),

    pub fn init(alloc: std.mem.Allocator, mb: *MusicBrainz) Enricher {
        return .{ .mb = mb, .memo = std.StringHashMap(?Release).init(alloc) };
    }

    pub fn lookupAlbum(
        self: *Enricher,
        alloc: std.mem.Allocator,
        album: []const u8,
        album_artist: []const u8,
        track_count: usize,
        hint_year: ?u32,
    ) !?Release {
        const key = try std.fmt.allocPrint(alloc, "{s}|{s}|{d}", .{ album, album_artist, track_count });
        if (self.memo.get(key)) |cached| return cached;
        const rel = self.mb.lookupRelease(alloc, album, album_artist, track_count, hint_year) catch null;
        try self.memo.put(key, rel);
        return rel;
    }
};

const t = std.testing;

test "lookupRelease: search then detail parses tracks + multi-artist" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add(
        "https://musicbrainz.org/ws/2/release?query=release:%22Blue%22%20AND%20artist:%22Eric%20Clapton%22%20AND%20tracks:2&fmt=json&limit=5",
        200,
        \\{"releases":[{"id":"rel-1","title":"Blue","score":100,"track-count":2,"date":"1998","artist-credit":[{"name":"Eric Clapton"}],"release-group":{"first-release-date":"1998-03-01"}}]}
        ,
    );
    try mock.add(
        "https://musicbrainz.org/ws/2/release/rel-1?inc=recordings+artist-credits+release-groups&fmt=json",
        200,
        \\{"id":"rel-1","title":"Blue","date":"1998","artist-credit":[{"name":"Eric Clapton"}],"media":[{"tracks":[{"position":1,"title":"Layla","recording":{"id":"rec-1","artist-credit":[{"name":"Eric Clapton","joinphrase":" & "},{"name":"Duane Allman"}]}},{"position":2,"title":"Cocaine","recording":{"id":"rec-2","artist-credit":[{"name":"Eric Clapton"}]}}]}]}
        ,
    );

    var mb = MusicBrainz{ .http_client = mock.client() };
    const rel = (try mb.lookupRelease(a, "Blue", "Eric Clapton", 2, 1998)).?;
    try t.expectEqualStrings("rel-1", rel.mbid);
    try t.expectEqualStrings("Blue", rel.title);
    try t.expectEqual(@as(u32, 1998), rel.year.?);
    try t.expectEqual(@as(usize, 2), rel.tracks.len);
    try t.expectEqualStrings("Layla", rel.tracks[0].title);
    try t.expectEqualStrings("rec-1", rel.tracks[0].recording_mbid.?);
    try t.expectEqual(@as(usize, 2), rel.tracks[0].artists.len);
    try t.expectEqualStrings("Duane Allman", rel.tracks[0].artists[1]);
    try t.expectEqual(@as(usize, 2), mock.calls.items.len); // search + detail
}

test "lookupRelease: track-count mismatch → null (no detail call)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add(
        "https://musicbrainz.org/ws/2/release?query=release:%22X%22%20AND%20artist:%22Y%22%20AND%20tracks:5&fmt=json&limit=5",
        200,
        \\{"releases":[{"id":"r","title":"X","score":90,"track-count":9,"artist-credit":[{"name":"Y"}]}]}
        ,
    );
    var mb = MusicBrainz{ .http_client = mock.client() };
    try t.expect((try mb.lookupRelease(a, "X", "Y", 5, null)) == null);
    try t.expectEqual(@as(usize, 1), mock.calls.items.len); // no detail call
}

test "lookupRelease: HTTP failure → null" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    var mb = MusicBrainz{ .http_client = mock.client() };
    try t.expect((try mb.lookupRelease(a, "No", "Body", 1, null)) == null);
}
