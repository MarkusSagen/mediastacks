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
