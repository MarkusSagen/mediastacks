//! Per-item online enrichment for an already-organized library item: fetch
//! canonical metadata from TMDB (movie/tv) or MusicBrainz (music), write the
//! Jellyfin NFO under the item's folder, and re-upsert the catalog row with
//! provider identity + `has_metadata`. Non-destructive — no rename/move.

const std = @import("std");
const mc = @import("../core/mediacatalog.zig");
const group = @import("../core/group.zig");
const enrich = @import("../core/enrich.zig");
const nfo = @import("../core/nfo.zig");
const plan = @import("../core/plan.zig");
const tmdb = @import("../providers/tmdb.zig");
const musicbrainz = @import("../providers/musicbrainz.zig");
const http = @import("../util/http.zig");
const clock = @import("../util/clock.zig");

pub const Outcome = enum { ok, no_match, err };

fn yearU32(y: ?i64) ?u32 {
    return if (y) |v| (if (v > 0) @intCast(v) else null) else null;
}

fn writeNfo(arena: std.mem.Allocator, dir_abs: []const u8, name: []const u8, bytes: []const u8) !void {
    const full = try std.fs.path.join(arena, &.{ dir_abs, name });
    var pz: [4096]u8 = undefined;
    if (full.len >= pz.len) return error.PathTooLong;
    const pzp = try std.fmt.bufPrintZ(&pz, "{s}", .{full});
    const fp = std.c.fopen(pzp.ptr, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) return error.WriteFailed;
}

/// Re-upsert `item` with enriched provider metadata. Keeps every other column.
fn upsertEnriched(cat: *mc.Catalog, item: mc.Item, provider: []const u8, provider_id: ?[]const u8, title: []const u8, year: ?u32) !void {
    var it = item;
    it.provider = provider;
    it.provider_id = provider_id;
    it.title = title;
    if (year) |y| it.year = @intCast(y);
    it.has_metadata = true;
    try cat.upsertItem(it);
}

/// Enrich one organized item in place (non-destructive: NFO + catalog only).
pub fn enrichOne(arena: std.mem.Allocator, cat: *mc.Catalog, item: mc.Item, online: group.Online, library_root: []const u8) Outcome {
    const dir_abs = std.fs.path.join(arena, &.{ library_root, item.path }) catch return .err;

    if (std.mem.eql(u8, item.kind, "movie")) {
        const video = online.video orelse return .no_match;
        const info = (video.lookupMovie(arena, item.title, yearU32(item.year)) catch return .err) orelse return .no_match;
        const merged = enrich.mergeMovieOnline(arena, .{ .title = item.title, .year = yearU32(item.year) }, info) catch return .err;
        const bytes = nfo.movieNfo(arena, merged.fields) catch return .err;
        writeNfo(arena, dir_abs, "movie.nfo", bytes) catch return .err;
        upsertEnriched(cat, item, "tmdb", merged.fields.tmdb_id, merged.fields.title orelse item.title, merged.fields.year) catch return .err;
        return .ok;
    }
    if (std.mem.eql(u8, item.kind, "tv")) {
        const video = online.video orelse return .no_match;
        const s = (video.lookupSeries(arena, item.title, yearU32(item.year)) catch return .err) orelse return .no_match;
        const merged = enrich.mergeTvOnline(arena, .{ .series = item.title, .series_year = yearU32(item.year) }, s, null) catch return .err;
        const bytes = nfo.tvshowNfo(arena, merged.fields) catch return .err;
        writeNfo(arena, dir_abs, "tvshow.nfo", bytes) catch return .err;
        upsertEnriched(cat, item, "tmdb", merged.fields.tmdb_id, merged.fields.series orelse item.title, merged.fields.series_year) catch return .err;
        return .ok;
    }
    if (std.mem.eql(u8, item.kind, "music")) {
        const music = online.music orelse return .no_match;
        const artist = item.subtitle orelse "";
        const rel = (music.lookupAlbum(arena, item.title, artist, @intCast(item.file_count), yearU32(item.year)) catch return .err) orelse return .no_match;
        const fields = plan.Fields{ .album = rel.title, .album_artist = rel.album_artist, .year = rel.year, .release_mbid = rel.mbid };
        const bytes = nfo.albumNfo(arena, fields) catch return .err;
        writeNfo(arena, dir_abs, "album.nfo", bytes) catch return .err;
        upsertEnriched(cat, item, "musicbrainz", rel.mbid, rel.title, rel.year) catch return .err;
        return .ok;
    }
    return .no_match; // audiobook / comic: no online provider
}

test "enrichOne enriches a movie via mocked TMDB" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // temp library with the movie folder on disk
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const root = try std.fmt.allocPrint(a, "/tmp/stacks-enrich-{d}", .{clock.nowSeconds()});
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ root, "Movies", "Dune (2021)" }));

    // temp catalog with a movie item lacking metadata
    const db = try std.fmt.allocPrint(a, "/tmp/stacks-enrich-{d}.db", .{clock.nowSeconds()});
    var dbz: [96]u8 = undefined;
    const dbzp = std.fmt.bufPrintZ(&dbz, "{s}", .{db}) catch unreachable;
    defer _ = std.c.unlink(dbzp.ptr);
    var cat = try mc.Catalog.open(db);
    defer cat.close();
    try cat.upsertItem(.{ .kind = "movie", .path = "Movies/Dune (2021)", .title = "Dune", .sort_title = "dune", .year = 2021 });
    const item = (try cat.getByPath(a, "Movies/Dune (2021)")).?;

    // mocked TMDB: search then detail, copied from tmdb.zig's own MockClient tests.
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://api.themoviedb.org/3/search/movie?query=Dune&year=2021&api_key=k&language=en-US", 200,
        \\{"results":[{"id":438631,"title":"Dune","release_date":"2021-10-01"}]}
    );
    try mock.add("https://api.themoviedb.org/3/movie/438631?api_key=k&language=en-US&append_to_response=external_ids", 200,
        \\{"id":438631,"title":"Dune","release_date":"2021-10-01","original_language":"en","imdb_id":"tt1160419","external_ids":{"imdb_id":"tt1160419"}}
    );

    var tmdb_api = tmdb.Tmdb{ .http_client = mock.client(), .api_key = "k" };
    var video = tmdb.Enricher.init(a, &tmdb_api);
    const online = group.Online{ .video = &video };

    const outcome = enrichOne(a, &cat, item, online, root);
    try t.expectEqual(Outcome.ok, outcome);

    const after = (try cat.getByPath(a, "Movies/Dune (2021)")).?;
    try t.expect(after.has_metadata);
    try t.expectEqualStrings("tmdb", after.provider.?);
    try t.expect(after.provider_id != null);

    // movie.nfo was written
    var f = try cwd.openFile(io, try std.fs.path.join(a, &.{ root, "Movies/Dune (2021)/movie.nfo" }), .{});
    f.close(io);
}
