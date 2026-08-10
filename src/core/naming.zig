//! The single place a destination path is rendered from structured
//! fields + the kind's template. Used by `group.buildPlan` and by the
//! review server when it recomputes names after an edit.

const std = @import("std");
const template = @import("template.zig");
const config = @import("config.zig");
const kind = @import("kind.zig");
const plan = @import("plan.zig");

fn u32str(arena: std.mem.Allocator, n: u32) ![]u8 {
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

/// Insert `suffix` before the final path component's extension.
/// `.../Film (1999).mkv` + `-cd2` → `.../Film (1999)-cd2.mkv`.
fn spliceBeforeExt(arena: std.mem.Allocator, rel: []const u8, suffix: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse 0;
    const dot_rel = std.mem.lastIndexOfScalar(u8, rel[slash..], '.');
    if (dot_rel) |dr| {
        const dot = slash + dr;
        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ rel[0..dot], suffix, rel[dot..] });
    }
    return std.fmt.allocPrint(arena, "{s}{s}", .{ rel, suffix });
}

/// Jellyfin provider-id token for the `{id}` field: tmdb → imdb → tvdb, or ""
/// when none is known or `cfg.id_suffix` is off.
fn idToken(arena: std.mem.Allocator, cfg: config.Config, f: plan.Fields) ![]const u8 {
    if (!cfg.id_suffix) return "";
    if (f.tmdb_id) |x| return std.fmt.allocPrint(arena, "tmdbid-{s}", .{x});
    if (f.imdb_id) |x| return std.fmt.allocPrint(arena, "imdbid-{s}", .{x});
    if (f.tvdb_id) |x| return std.fmt.allocPrint(arena, "tvdbid-{s}", .{x});
    return "";
}

/// Render the library-relative + rooted destination for `f` under `k`'s
/// template. Owned by `arena`.
pub fn dstFor(arena: std.mem.Allocator, cfg: config.Config, k: kind.MediaKind, f: plan.Fields) ![]u8 {
    const rel = switch (k) {
        .tv => blk: {
            const fields = [_]template.Field{
                .{ .name = "series", .value = f.series orelse "" },
                .{ .name = "series_year", .value = if (f.series_year) |y| try u32str(arena, y) else "" },
                .{ .name = "id", .value = try idToken(arena, cfg, f) },
                .{ .name = "season", .value = try u32str(arena, f.season orelse 0) },
                .{ .name = "episode", .value = try u32str(arena, f.episode orelse 0) },
                .{ .name = "title", .value = f.title orelse "" },
                .{ .name = "ext", .value = f.ext orelse "" },
            };
            break :blk try template.renderFields(arena, cfg.tv_template, &fields);
        },
        .movie => blk: {
            const year_str = if (f.year) |y| try u32str(arena, y) else "";
            const fields = [_]template.Field{
                .{ .name = "title", .value = f.title orelse "" },
                .{ .name = "year", .value = year_str },
                .{ .name = "id", .value = try idToken(arena, cfg, f) },
                .{ .name = "ext", .value = f.ext orelse "" },
            };
            var rel = try template.renderFields(arena, cfg.movie_template, &fields);
            // Jellyfin multi-part / version labels live on the *file* stem.
            if (f.part) |p| rel = try spliceBeforeExt(arena, rel, try std.fmt.allocPrint(arena, "-cd{d}", .{p}));
            if (f.edition) |e| rel = try spliceBeforeExt(arena, rel, try std.fmt.allocPrint(arena, " - {s}", .{e}));
            break :blk rel;
        },
        .music => blk: {
            const fields = [_]template.Field{
                .{ .name = "album_artist", .value = f.album_artist orelse "" },
                .{ .name = "album", .value = f.album orelse "" },
                .{ .name = "year", .value = if (f.year) |y| try u32str(arena, y) else "" },
                .{ .name = "track", .value = if (f.track) |tr| try u32str(arena, tr) else "" },
                .{ .name = "title", .value = f.title orelse "" },
                .{ .name = "ext", .value = f.ext orelse "" },
            };
            const base_rel = try template.renderFields(arena, cfg.music_template, &fields);
            if (f.disc) |d| {
                if (std.mem.lastIndexOfScalar(u8, base_rel, '/')) |slash| {
                    break :blk try std.fmt.allocPrint(arena, "{s}/CD{d}/{s}", .{ base_rel[0..slash], d, base_rel[slash + 1 ..] });
                }
            }
            break :blk base_rel;
        },
        else => return error.UnsupportedKind,
    };
    return std.fs.path.join(arena, &.{ cfg.library_root, rel });
}

const t = std.testing;

test "dstFor renders a jellyfin tv path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .tv, .{ .series = "Witch Hat Atelier", .season = 1, .episode = 12, .title = "The Shadow of Romonon", .ext = "mkv" });
    try t.expectEqualStrings("/lib/Shows/Witch Hat Atelier/Season 01/Witch Hat Atelier S01E12 - The Shadow of Romonon.mkv", out);
}

test "dstFor renders a music path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .music, .{ .album_artist = "Eric Clapton", .album = "Best of Blues", .year = 1998, .track = 3, .title = "Layla", .ext = "mp3" });
    try t.expectEqualStrings("/lib/Music/Eric Clapton/Best of Blues (1998)/03 - Layla.mp3", out);
}

test "dstFor renders a multi-disc music path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .music, .{ .album_artist = "Various Artists", .album = "Night of the Kings", .year = 1992, .disc = 2, .track = 3, .title = "Layla", .ext = "flac" });
    try t.expectEqualStrings("/lib/Music/Various Artists/Night of the Kings (1992)/CD2/03 - Layla.flac", out);
}

test "dstFor renders a movie path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .movie, .{ .title = "The Matrix", .year = 1999, .ext = "mkv" });
    try t.expectEqualStrings("/lib/Movies/The Matrix (1999)/The Matrix (1999).mkv", out);
}

test "dstFor movie with tmdb id in folder and file" {
    var a_s = std.heap.ArenaAllocator.init(t.allocator);
    defer a_s.deinit();
    const a = a_s.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .movie, .{ .title = "The Matrix", .year = 1999, .ext = "mkv", .tmdb_id = "603", .imdb_id = "tt0133093" });
    try t.expectEqualStrings("/lib/Movies/The Matrix (1999) [tmdbid-603]/The Matrix (1999) [tmdbid-603].mkv", out);
}

test "dstFor tv with series year + id on series folder" {
    var a_s = std.heap.ArenaAllocator.init(t.allocator);
    defer a_s.deinit();
    const a = a_s.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .tv, .{ .series = "Severance", .season = 1, .episode = 1, .title = "Good News About Hell", .ext = "mkv", .series_year = 2022, .tmdb_id = "95396" });
    try t.expectEqualStrings("/lib/Shows/Severance (2022) [tmdbid-95396]/Season 01/Severance S01E01 - Good News About Hell.mkv", out);
}

test "dstFor movie with edition and part labels" {
    var a_s = std.heap.ArenaAllocator.init(t.allocator);
    defer a_s.deinit();
    const a = a_s.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const ed = try dstFor(a, cfg, .movie, .{ .title = "Film", .year = 1999, .ext = "mkv", .edition = "1080p" });
    try t.expectEqualStrings("/lib/Movies/Film (1999)/Film (1999) - 1080p.mkv", ed);
    const pt = try dstFor(a, cfg, .movie, .{ .title = "Film", .year = 1999, .ext = "mkv", .part = 2 });
    try t.expectEqualStrings("/lib/Movies/Film (1999)/Film (1999)-cd2.mkv", pt);
}

test "dstFor id_suffix off drops the id" {
    var a_s = std.heap.ArenaAllocator.init(t.allocator);
    defer a_s.deinit();
    const a = a_s.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC, .id_suffix = false };
    const out = try dstFor(a, cfg, .movie, .{ .title = "The Matrix", .year = 1999, .ext = "mkv", .tmdb_id = "603" });
    try t.expectEqualStrings("/lib/Movies/The Matrix (1999)/The Matrix (1999).mkv", out);
}
