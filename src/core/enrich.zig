//! Pure merge of filename-parsed fields with ffprobe results, by
//! confidence. No I/O — unit-tested without spawning ffprobe.
//!
//! Rules:
//!   - authoritative embedded tags OVERRIDE the filename (and warn on a
//!     real difference);
//!   - generic tags only FILL a field the filename left null;
//!   - real resolution (probe height) sets `quality` for scoring;
//!   - advisory warnings for unreadable / mislabeled / too-short files.

const std = @import("std");
const tv = @import("../kinds/tv.zig");
const movie = @import("../kinds/movie.zig");
const probe = @import("probe.zig");
const plan = @import("plan.zig");
const musicbrainz = @import("../providers/musicbrainz.zig");

pub const TvFields = struct {
    series: []const u8,
    season: u32,
    episode: u32,
    title: ?[]const u8,
    quality: ?[]const u8,
};

pub const MovieFields = struct {
    title: []const u8,
    year: ?u32,
    quality: ?[]const u8,
};

pub const TvResult = struct { fields: TvFields, warnings: []const []const u8 };
pub const MovieResult = struct { fields: MovieFields, warnings: []const []const u8 };

/// Map a real pixel height to the conventional resolution tag.
pub fn qualityFromHeight(h: u32) []const u8 {
    if (h >= 2160) return "2160p";
    if (h >= 1080) return "1080p";
    if (h >= 720) return "720p";
    return "480p";
}

fn isHighTier(q: ?[]const u8) bool {
    const s = q orelse return false;
    return std.mem.startsWith(u8, s, "1080") or std.mem.startsWith(u8, s, "2160");
}

/// Warnings shared by tv & movie. `fq` is the filename-derived quality.
fn appendCommon(alloc: std.mem.Allocator, warns: *std.ArrayList([]const u8), fq: ?[]const u8, pr: probe.Probe) !void {
    if (!pr.readable) {
        try warns.append(alloc, try alloc.dupe(u8, "unreadable (corrupt?)"));
        return;
    }
    if (isHighTier(fq)) {
        if (pr.height) |h| {
            if (h < 720) {
                try warns.append(alloc, try std.fmt.allocPrint(alloc, "named {s}, actually {d}p", .{ fq.?, h }));
            }
        }
    }
    if (pr.duration_s) |d| {
        if (d < 180) {
            const mins: u32 = @intFromFloat(d / 60);
            try warns.append(alloc, try std.fmt.allocPrint(alloc, "{d}m runtime — sample/clip?", .{mins}));
        }
    }
}

fn freeAll(alloc: std.mem.Allocator, warns: *std.ArrayList([]const u8)) void {
    for (warns.items) |w| alloc.free(w);
    warns.deinit(alloc);
}

/// Merge a parsed TV episode with an optional probe. Field slices borrow
/// from `ep`/`p` (same lifetime); only warnings are newly allocated.
pub fn mergeTv(alloc: std.mem.Allocator, ep: tv.Episode, p: ?probe.Probe) !TvResult {
    var f = TvFields{
        .series = ep.series,
        .season = ep.season,
        .episode = ep.episode,
        .title = ep.title,
        .quality = ep.quality,
    };
    var warns: std.ArrayList([]const u8) = .empty;
    errdefer freeAll(alloc, &warns);

    if (p) |pr| {
        if (pr.height) |h| f.quality = qualityFromHeight(h);
        switch (pr.embedded.confidence) {
            .authoritative => {
                if (pr.embedded.series) |s| f.series = s;
                if (pr.embedded.season) |s| f.season = s;
                if (pr.embedded.episode) |e| f.episode = e;
                if (pr.embedded.title) |ti| f.title = ti;
                const season_diff = pr.embedded.season != null and pr.embedded.season.? != ep.season;
                const ep_diff = pr.embedded.episode != null and pr.embedded.episode.? != ep.episode;
                if (season_diff or ep_diff) {
                    try warns.append(alloc, try std.fmt.allocPrint(
                        alloc,
                        "used embedded S{d}E{d} over filename S{d}E{d}",
                        .{ f.season, f.episode, ep.season, ep.episode },
                    ));
                }
            },
            .generic => {
                if (ep.title == null and pr.embedded.title != null) f.title = pr.embedded.title;
            },
            .none => {},
        }
        try appendCommon(alloc, &warns, ep.quality, pr);
    }

    return .{ .fields = f, .warnings = try warns.toOwnedSlice(alloc) };
}

/// Merge a parsed movie with an optional probe.
pub fn mergeMovie(alloc: std.mem.Allocator, mv: movie.Movie, p: ?probe.Probe) !MovieResult {
    var f = MovieFields{ .title = mv.title, .year = mv.year, .quality = mv.quality };
    var warns: std.ArrayList([]const u8) = .empty;
    errdefer freeAll(alloc, &warns);

    if (p) |pr| {
        if (pr.height) |h| f.quality = qualityFromHeight(h);
        // Movie embedded metadata is generic; movie.title is never null, so
        // there's nothing to fill — probe only affects quality + warnings.
        try appendCommon(alloc, &warns, mv.quality, pr);
    }

    return .{ .fields = f, .warnings = try warns.toOwnedSlice(alloc) };
}

pub const MusicEnrichResult = struct { fields: plan.Fields, warnings: []const []const u8 };

fn findTrack(release: musicbrainz.Release, position: u32) ?musicbrainz.TrackInfo {
    for (release.tracks) |tk| if (tk.position == position) return tk;
    return null;
}

/// Heuristic: a title that starts with a track-number prefix (e.g. "01 ",
/// "03 - ") is filename-derived and safe to replace with a canonical title.
fn titleLooksFilename(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    return i >= 1 and i <= 3 and i < s.len and (s[i] == ' ' or s[i] == '-' or s[i] == '_' or s[i] == '.');
}

/// Merge a MusicBrainz release into one track's fields. `album_from_folder`
/// marks that `base.album` was derived from the source folder (A.1 fallback),
/// in which case MB's canonical album wins; otherwise a tag-authoritative
/// album is kept and any MB difference is only a warning. Fills missing
/// year/album-artist; replaces filename-derived titles; populates multi-artist
/// credits + MBIDs. Field slices borrow from `base`/`release`; only warnings
/// are newly allocated.
pub fn mergeMusic(
    alloc: std.mem.Allocator,
    base: plan.Fields,
    position: u32,
    release: musicbrainz.Release,
    album_from_folder: bool,
) !MusicEnrichResult {
    var f = base;
    var warns: std.ArrayList([]const u8) = .empty;
    errdefer freeAll(alloc, &warns);

    if (release.title.len > 0) {
        if (album_from_folder or f.album == null) {
            f.album = release.title;
        } else if (f.album) |cur| {
            if (!std.ascii.eqlIgnoreCase(cur, release.title)) {
                try warns.append(alloc, try std.fmt.allocPrint(alloc, "MusicBrainz suggests album \"{s}\"", .{release.title}));
            }
        }
    }
    if ((f.album_artist == null or f.album_artist.?.len == 0) and release.album_artist.len > 0) {
        f.album_artist = release.album_artist;
    }
    if (f.year == null and release.year != null) f.year = release.year;
    f.release_mbid = release.mbid;

    if (findTrack(release, position)) |tk| {
        if (tk.title.len > 0) {
            const looks_filename = f.title == null or titleLooksFilename(f.title.?);
            if (looks_filename) f.title = tk.title;
        }
        if (tk.artists.len > 0) f.artists = tk.artists;
        if (tk.recording_mbid) |rid| f.recording_mbid = rid;
    }

    return .{ .fields = f, .warnings = try warns.toOwnedSlice(alloc) };
}

const t = std.testing;

fn epOf(series: []const u8, s: u32, e: u32, title: ?[]const u8, q: ?[]const u8) tv.Episode {
    return .{ .series = series, .season = s, .episode = e, .title = title, .quality = q, .ext = "mkv" };
}

fn freeWarnings(a: std.mem.Allocator, ws: []const []const u8) void {
    for (ws) |w| a.free(w);
    a.free(ws);
}

test "authoritative embedded overrides filename and warns" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .height = 1080, .embedded = .{
        .series = "Severance", .season = 2, .episode = 5, .title = "Real Title", .confidence = .authoritative,
    } };
    const r = try mergeTv(a, epOf("severance", 2, 4, null, "720p"), p);
    defer freeWarnings(a, r.warnings);
    try t.expectEqual(@as(u32, 5), r.fields.episode);
    try t.expectEqualStrings("Real Title", r.fields.title.?);
    try t.expectEqualStrings("1080p", r.fields.quality.?); // from height
    try t.expect(r.warnings.len >= 1); // episode override warned
}

test "generic embedded only fills a missing title" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .height = 1080, .embedded = .{
        .title = "From Tag", .confidence = .generic,
    } };
    const r = try mergeTv(a, epOf("show", 1, 1, null, null), p);
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("From Tag", r.fields.title.?);
    try t.expectEqual(@as(u32, 1), r.fields.episode); // filename kept
}

test "generic embedded does not clobber an existing title" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .embedded = .{ .title = "Tag", .confidence = .generic } };
    const r = try mergeTv(a, epOf("show", 1, 1, "Filename Title", null), p);
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("Filename Title", r.fields.title.?);
}

test "resolution mismatch warns" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .height = 480 };
    const r = try mergeTv(a, epOf("show", 1, 1, null, "1080p"), p);
    defer freeWarnings(a, r.warnings);
    var found = false;
    for (r.warnings) |w| {
        if (std.mem.indexOf(u8, w, "actually") != null) found = true;
    }
    try t.expect(found);
    try t.expectEqualStrings("480p", r.fields.quality.?);
}

test "short runtime warns" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .height = 1080, .duration_s = 90 };
    const r = try mergeTv(a, epOf("show", 1, 1, null, "1080p"), p);
    defer freeWarnings(a, r.warnings);
    var found = false;
    for (r.warnings) |w| {
        if (std.mem.indexOf(u8, w, "runtime") != null) found = true;
    }
    try t.expect(found);
}

test "no probe mirrors parsed fields, no warnings" {
    const a = t.allocator;
    const r = try mergeTv(a, epOf("show", 3, 7, "T", "720p"), null);
    defer freeWarnings(a, r.warnings);
    try t.expectEqual(@as(u32, 7), r.fields.episode);
    try t.expectEqualStrings("720p", r.fields.quality.?);
    try t.expectEqual(@as(usize, 0), r.warnings.len);
}

test "mergeMusic fills year, canonical title, multi-artist, mbids" {
    const a = t.allocator;
    const rel = musicbrainz.Release{
        .mbid = "rel-1", .title = "Blue", .album_artist = "Eric Clapton", .year = 1998,
        .tracks = &.{.{ .position = 1, .title = "Layla", .recording_mbid = "rec-1", .artists = &.{ "Eric Clapton", "Duane Allman" } }},
    };
    const base = plan.Fields{ .album_artist = "Eric Clapton", .album = "blue album folder", .title = "01 layla", .track = 1, .ext = "flac" };
    const r = try mergeMusic(a, base, 1, rel, true); // album came from folder
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("Blue", r.fields.album.?); // folder → canonical
    try t.expectEqual(@as(u32, 1998), r.fields.year.?); // filled
    try t.expectEqualStrings("Layla", r.fields.title.?); // canonical title
    try t.expectEqual(@as(usize, 2), r.fields.artists.len); // multi-artist
    try t.expectEqualStrings("rel-1", r.fields.release_mbid.?);
    try t.expectEqualStrings("rec-1", r.fields.recording_mbid.?);
}

test "mergeMusic keeps a tag-authoritative album but warns on MB difference" {
    const a = t.allocator;
    const rel = musicbrainz.Release{ .mbid = "r", .title = "Canonical Name", .album_artist = "X", .year = 2000, .tracks = &.{} };
    const base = plan.Fields{ .album_artist = "X", .album = "Tagged Name", .title = "Song", .track = 1, .ext = "flac" };
    const r = try mergeMusic(a, base, 1, rel, false); // album from a real tag
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("Tagged Name", r.fields.album.?); // not overwritten
    var warned = false;
    for (r.warnings) |w| if (std.mem.indexOf(u8, w, "MusicBrainz") != null) {
        warned = true;
    };
    try t.expect(warned);
}
