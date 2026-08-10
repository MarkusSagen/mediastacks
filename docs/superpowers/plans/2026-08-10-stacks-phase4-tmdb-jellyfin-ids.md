# Phase 4 — TMDB Enrichment + Jellyfin IDs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich movies/TV from TMDB (canonical title/year/episode-name, provider IDs, original_language) and emit Jellyfin `[tmdbid-]/[imdbid-]/[tvdbid-]` suffixes in folder + filename. Config-gated, disk-cached, `MockClient`-tested, offline plan untouched on any failure.

**Architecture:** New `providers/tmdb.zig` mirrors `providers/musicbrainz.zig` (injected `http.HttpClient`, memoizing `Enricher`). Pure `enrich.mergeMovieOnline`/`mergeTvOnline`. `buildPlan`'s per-kind enrichers fold into one `Online{music,video}` bundle. IDs render via a `{id}` token + a new ` []` empty-collapse in the template engine; `original_language` is captured for the later language epic.

**Tech Stack:** Zig 0.16; `std.http.Client` via `util/http.zig`+`util/httpcache.zig`; `std.json.Value`. No new deps.

## Global Constraints

- Zig 0.16 only; arena-allocated organizer code.
- Offline is default: enrichment runs only when `cfg.tmdb_key != null` and not `--offline`. Any failure/miss → offline plan stands.
- Reuse `http.MockClient`; **no real network in unit tests**.
- Non-arena file/UA code uses `std.c` (matches existing modules).
- Changing `DEFAULT_MOVIE`/`DEFAULT_TV` must keep **offline output byte-identical** (empty `[]`/`()` collapse) — existing naming/smoke tests must stay green.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Build `zig build`; test `zig build test`.

## File Structure

- `src/core/plan.zig` — `Fields`: `series_year`, `tmdb_id`, `imdb_id`, `tvdb_id`, `original_language`. (T1)
- `src/core/config.zig` — `tmdb_key`, `id_suffix`. (T1)
- `src/core/template.zig` — ` []` empty-collapse. (T2)
- `src/core/naming.zig` — `{id}` token + `{series_year}`; new defaults. (T2)
- `src/providers/tmdb.zig` (new) — `Tmdb` + `Enricher`. (T3, T5)
- `src/core/enrich.zig` — `mergeMovieOnline` / `mergeTvOnline`. (T4)
- `src/core/group.zig` — `Online` bundle + video wiring (refactor `mb` param). (T5)
- `src/commands/organize.zig`, `src/commands/review.zig` — TMDB client build. (T5)
- `docs`, `justfile`, `scripts/tmdb-smoke.sh`, `todo.md`, memory. (T6)

---

## Task 1: Data model — Fields IDs/lang/series_year + config keys

**Files:** Modify `src/core/plan.zig`, `src/core/config.zig`; Test in `config.zig`.

**Interfaces — Produces:** `Fields.series_year: ?u32`, `.tmdb_id/.imdb_id/.tvdb_id: ?[]const u8`, `.original_language: ?[]const u8`; `Config.tmdb_key: ?[]const u8 = null`, `Config.id_suffix: bool = true`.

- [ ] **Step 1: Failing config tests** — add to `src/core/config.zig`:

```zig
test "parseLines reads tmdb_key and id_suffix" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\tmdb_key = abc123
        \\id_suffix = off
    );
    defer freeConfig(a, cfg);
    try t.expectEqualStrings("abc123", cfg.tmdb_key.?);
    try t.expect(!cfg.id_suffix);
}
test "parseLines id_suffix defaults on, tmdb_key null" {
    const a = t.allocator;
    const cfg = try parseLines(a, "");
    defer freeConfig(a, cfg);
    try t.expect(cfg.id_suffix);
    try t.expectEqual(@as(?[]const u8, null), cfg.tmdb_key);
}
```

- [ ] **Step 2: Run → FAIL** (`Config` has no `tmdb_key`). `zig build test 2>&1 | head`

- [ ] **Step 3: `plan.Fields`** — after `original_language` group (music/mbids), add:

```zig
    // video online (TMDB)
    series_year: ?u32 = null,
    tmdb_id: ?[]const u8 = null,
    imdb_id: ?[]const u8 = null,
    tvdb_id: ?[]const u8 = null,
    original_language: ?[]const u8 = null,
```

- [ ] **Step 4: `config`** — add fields to `Config`:

```zig
    tmdb_key: ?[]const u8 = null,
    id_suffix: bool = true,
```

`freeConfig`: `if (cfg.tmdb_key) |k| alloc.free(k);`. In `parseLines`: add locals `var tmdb_key: ?[]const u8 = null; var id_suffix: ?[]const u8 = null;`, key branches `else if (std.mem.eql(u8, key, "tmdb_key")) tmdb_key = val else if (std.mem.eql(u8, key, "id_suffix")) id_suffix = val`, and in the return: `.tmdb_key = if (tmdb_key) |v| try alloc.dupe(u8, v) else null, .id_suffix = if (id_suffix) |v| boolOn(v) else true,`. (`boolOn` already exists from Music B.)

- [ ] **Step 5: Run → PASS.** `zig build test`

- [ ] **Step 6: Commit** — `feat(phase4): Fields TMDB ids/lang/series_year + config tmdb_key/id_suffix`

---

## Task 2: Template ` []` collapse + naming id-token/series_year

**Files:** Modify `src/core/template.zig`, `src/core/naming.zig`, `src/core/config.zig` (DEFAULT_MOVIE/DEFAULT_TV). Tests in `template.zig`, `naming.zig`.

**Interfaces — Produces:** empty `[…]` collapses like empty `(…)`; `naming.dstFor` renders `{id}` (`tmdbid-N`→`imdbid-tt…`→`tvdbid-N`, empty when `!cfg.id_suffix`) and `{series_year}`.

- [ ] **Step 1: Failing template test** — in `src/core/template.zig`:

```zig
test "renderFields drops empty square-bracket id" {
    const alloc = test_alloc;
    const fields = [_]Field{
        .{ .name = "title", .value = "The Matrix" },
        .{ .name = "year", .value = "1999" },
        .{ .name = "id", .value = "" },
        .{ .name = "ext", .value = "mkv" },
    };
    const out = try renderFields(alloc, "Movies/{title} ({year}) [{id}]/{title} ({year}) [{id}].{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("Movies/The Matrix (1999)/The Matrix (1999).mkv", out);
}
test "renderFields keeps a present id" {
    const alloc = test_alloc;
    const fields = [_]Field{ .{ .name = "title", .value = "The Matrix" }, .{ .name = "year", .value = "1999" }, .{ .name = "id", .value = "tmdbid-603" }, .{ .name = "ext", .value = "mkv" } };
    const out = try renderFields(alloc, "Movies/{title} ({year}) [{id}]/{title} ({year}) [{id}].{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("Movies/The Matrix (1999) [tmdbid-603]/The Matrix (1999) [tmdbid-603].mkv", out);
}
```

- [ ] **Step 2: Run → FAIL** (output keeps ` []`).

- [ ] **Step 3: Add ` []` collapse** — in `collapseSpaces` (`template.zig`), beside the ` ()` rule added in Music A.1, add first in the `stripped` loop:

```zig
        if (s.len >= 3 and s[0] == ' ' and s[1] == '[' and s[2] == ']') {
            i += 3;
            continue;
        }
```

- [ ] **Step 4: naming `{id}`/`{series_year}` + defaults** — in `src/core/naming.zig`, add before the `.tv`/`.movie` branches:

```zig
fn idToken(arena: std.mem.Allocator, cfg: config.Config, f: plan.Fields) ![]const u8 {
    if (!cfg.id_suffix) return "";
    if (f.tmdb_id) |x| return std.fmt.allocPrint(arena, "tmdbid-{s}", .{x});
    if (f.imdb_id) |x| return std.fmt.allocPrint(arena, "imdbid-{s}", .{x});
    if (f.tvdb_id) |x| return std.fmt.allocPrint(arena, "tvdbid-{s}", .{x});
    return "";
}
```

In the `.tv` field list add `.{ .name = "series_year", .value = if (f.series_year) |y| try u32str(arena, y) else "" }` and `.{ .name = "id", .value = try idToken(arena, cfg, f) }`. In the `.movie` list add `.{ .name = "id", .value = try idToken(arena, cfg, f) }`. (`config` is already imported.)

In `src/core/config.zig` update the defaults:

```zig
pub const DEFAULT_TV = "Shows/{series} ({series_year}) [{id}]/Season {season:02}/{series} S{season:02}E{episode:02} - {title}.{ext}";
pub const DEFAULT_MOVIE = "Movies/{title} ({year}) [{id}]/{title} ({year}) [{id}].{ext}";
```

- [ ] **Step 5: naming tests** — in `src/core/naming.zig`:

```zig
test "dstFor movie with tmdb id in folder and file" {
    var a_s = std.heap.ArenaAllocator.init(t.allocator); defer a_s.deinit(); const a = a_s.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .movie, .{ .title = "The Matrix", .year = 1999, .ext = "mkv", .tmdb_id = "603", .imdb_id = "tt0133093" });
    try t.expectEqualStrings("/lib/Movies/The Matrix (1999) [tmdbid-603]/The Matrix (1999) [tmdbid-603].mkv", out);
}
test "dstFor tv with series year + id on series folder" {
    var a_s = std.heap.ArenaAllocator.init(t.allocator); defer a_s.deinit(); const a = a_s.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .tv, .{ .series = "Severance", .season = 1, .episode = 1, .title = "Good News About Hell", .ext = "mkv", .series_year = 2022, .tmdb_id = "95396" });
    try t.expectEqualStrings("/lib/Shows/Severance (2022) [tmdbid-95396]/Season 01/Severance S01E01 - Good News About Hell.mkv", out);
}
test "dstFor movie offline (no id/year) unchanged" {
    var a_s = std.heap.ArenaAllocator.init(t.allocator); defer a_s.deinit(); const a = a_s.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .movie, .{ .title = "Old Film", .ext = "mkv" });
    try t.expectEqualStrings("/lib/Movies/Old Film/Old Film.mkv", out); // no year → collapses
}
```

Update the existing `dstFor renders a movie path` / TV tests if their literals changed (they should still pass: The Matrix (1999) with no id → same string). Run and fix any that assumed the old default.

- [ ] **Step 6: Run whole suite → PASS**, incl. `organize-smoke.sh`/`music-smoke.sh` (offline output must be identical).

```bash
zig build test && ./scripts/organize-smoke.sh && ./scripts/music-smoke.sh
```

- [ ] **Step 7: Commit** — `feat(phase4): [] collapse + naming id-token/series_year (offline output unchanged)`

---

## Task 3: providers/tmdb.zig — movie/tv/episode lookups

**Files:** Create `src/providers/tmdb.zig`; register in `src/root.zig`; tests in-file.

**Interfaces — Produces:** `MovieInfo`, `SeriesInfo`; `Tmdb{ http_client, api_key }` with `lookupMovie(alloc,title,hint_year)`, `lookupSeries(alloc,name,hint_year)`, `episodeTitle(alloc,tmdb_id,season,episode)`.

- [ ] **Step 1: Failing tests (MockClient)** — canned JSON. Note URLs include `&api_key=K`:

```zig
const std = @import("std");
const http = @import("../util/http.zig");
// ... impl ...
const t = std.testing;

test "lookupMovie: search then detail with external ids" {
    var arena = std.heap.ArenaAllocator.init(t.allocator); defer arena.deinit(); const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator); defer mock.deinit();
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
}

test "lookupSeries + episodeTitle" {
    var arena = std.heap.ArenaAllocator.init(t.allocator); defer arena.deinit(); const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator); defer mock.deinit();
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
    var arena = std.heap.ArenaAllocator.init(t.allocator); defer arena.deinit(); const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator); defer mock.deinit();
    try mock.add("https://api.themoviedb.org/3/search/movie?query=Nope&year=2000&api_key=K&language=en-US", 200, \\{"results":[]}
    );
    var api = Tmdb{ .http_client = mock.client(), .api_key = "K" };
    try t.expect((try api.lookupMovie(a, "Nope", 2000)) == null);
}
```

- [ ] **Step 2: Run → FAIL** (`Tmdb` undefined).

- [ ] **Step 3: Types + lookups** — implement `Tmdb`. Build URLs with `urlEncode` (space→`%20`, copy from `musicbrainz.zig`). Movie: search → pick `results[0]` (best; TMDB pre-sorts by popularity/relevance) whose `release_date` year matches `hint_year` when given, else `results[0]`; then detail. TV analogous. `episodeTitle` = one GET. Parsing via `std.json.Value` (mirror `musicbrainz.parseRelease` style). `httpGetOk` retry helper (copy from `musicbrainz.zig`). Year via a local `findYear`.

```zig
pub const MovieInfo = struct { tmdb_id: []const u8, imdb_id: ?[]const u8 = null, title: []const u8, year: ?u32 = null, original_language: ?[]const u8 = null };
pub const SeriesInfo = struct { tmdb_id: []const u8, imdb_id: ?[]const u8 = null, tvdb_id: ?[]const u8 = null, name: []const u8, year: ?u32 = null, original_language: ?[]const u8 = null };
pub const Tmdb = struct {
    http_client: http.HttpClient,
    api_key: []const u8,
    pub fn lookupMovie(self: *Tmdb, alloc: std.mem.Allocator, title: []const u8, hint_year: ?u32) !?MovieInfo { /* search → chooseByYear → detail(external_ids) */ }
    pub fn lookupSeries(self: *Tmdb, alloc: std.mem.Allocator, name: []const u8, hint_year: ?u32) !?SeriesInfo { /* same shape */ }
    pub fn episodeTitle(self: *Tmdb, alloc: std.mem.Allocator, tmdb_id: []const u8, season: u32, episode: u32) !?[]const u8 { /* GET name */ }
};
```

Implement the parse helpers to read `id` (int→string via `allocPrint`), `title`/`name`, `release_date`/`first_air_date` (findYear), `original_language`, `imdb_id`/`external_ids.imdb_id`, `external_ids.tvdb_id`. Selection helper `chooseByYear(results, hint)`: first result whose year == hint, else first result.

- [ ] **Step 4: Register** in `src/root.zig`: `pub const tmdb = @import("providers/tmdb.zig");`

- [ ] **Step 5: Run → PASS.**

- [ ] **Step 6: Commit** — `feat(phase4): TMDB provider (movie/tv/episode via MockClient)`

---

## Task 4: enrich.mergeMovieOnline / mergeTvOnline

**Files:** Modify `src/core/enrich.zig`; import `tmdb`; tests in-file.

**Interfaces — Produces:** `pub fn mergeMovieOnline(alloc, base: plan.Fields, info: tmdb.MovieInfo) !MusicEnrichResult`-shaped result `{fields,warnings}`; `pub fn mergeTvOnline(alloc, base: plan.Fields, s: tmdb.SeriesInfo, episode_title: ?[]const u8) !...`. (Reuse a shared `Result = struct { fields: plan.Fields, warnings: []const []const u8 }` — the music one already exists as `MusicEnrichResult`; add `pub const OnlineResult = MusicEnrichResult;` or a new alias.)

- [ ] **Step 1: Failing tests**:

```zig
const tmdb = @import("../providers/tmdb.zig");

test "mergeMovieOnline fills canonical title/year/ids/lang, warns on mismatch" {
    const a = t.allocator;
    const info = tmdb.MovieInfo{ .tmdb_id = "603", .imdb_id = "tt0133093", .title = "The Matrix", .year = 1999, .original_language = "en" };
    const base = plan.Fields{ .title = "the matrix", .year = 1999, .ext = "mkv" };
    const r = try mergeMovieOnline(a, base, info);
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("The Matrix", r.fields.title.?);
    try t.expectEqualStrings("603", r.fields.tmdb_id.?);
    try t.expectEqualStrings("en", r.fields.original_language.?);
}
test "mergeTvOnline fills episode title + series year + ids" {
    const a = t.allocator;
    const s = tmdb.SeriesInfo{ .tmdb_id = "95396", .tvdb_id = "371980", .name = "Severance", .year = 2022, .original_language = "en" };
    const base = plan.Fields{ .series = "severance", .season = 1, .episode = 1, .ext = "mkv" };
    const r = try mergeTvOnline(a, base, s, "Good News About Hell");
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("Severance", r.fields.series.?);
    try t.expectEqual(@as(u32, 2022), r.fields.series_year.?);
    try t.expectEqualStrings("Good News About Hell", r.fields.title.?);
    try t.expectEqualStrings("95396", r.fields.tmdb_id.?);
    try t.expectEqualStrings("371980", r.fields.tvdb_id.?);
}
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — mirror `mergeMusic` (fill/keep/warn). Movie: set `tmdb_id/imdb_id/original_language`; `title`/`year` ← canonical when base looks lower-confidence (base title case-insensitively equals or is a slug) else keep + warn on real difference. TV: set series name (canonical), `series_year`, ids, `original_language`; `title` ← `episode_title` when present (episode titles are usually filename-derived/absent). Return `{fields, warnings}`.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit** — `feat(phase4): enrich.mergeMovieOnline/mergeTvOnline`

---

## Task 5: Online bundle + wiring (refactor mb param) + CLI

**Files:** Modify `src/core/group.zig`, `src/providers/tmdb.zig` (add `Enricher`), `src/commands/organize.zig`, `src/commands/review.zig`. Update all `buildPlan` call sites.

**Interfaces — Produces:** `group.Online{ music: ?*musicbrainz.Enricher = null, video: ?*tmdb.Enricher = null }`; `buildPlan(arena, io, dir, cfg, probe_enabled, online: Online)`; `tmdb.Enricher` with `lookupMovie`/`lookupSeries`/`episodeTitle` memoized.

- [ ] **Step 1: `tmdb.Enricher`** — mirror `musicbrainz.Enricher`: memo maps for movie(`title|year`), series(`name|year`→SeriesInfo), and episode(`sid|s|e`→title). Methods return cached-or-fetch.

- [ ] **Step 2: `Online` bundle in group.zig** — replace the `mb: ?*musicbrainz.Enricher` param:

```zig
pub const Online = struct {
    music: ?*musicbrainz.Enricher = null,
    video: ?*tmdb.Enricher = null,
};
pub fn buildPlan(arena, io, dir_path, cfg, probe_enabled, online: Online) !plan.Plan
```

Replace the music-enrichment guard `if (mb) |enr|` with `if (online.music) |enr|`. Add `const tmdb = @import("../providers/tmdb.zig");`.

- [ ] **Step 3: Video enrichment** — in the tv and movie dedup blocks, after fields/dst computed, add:

```zig
        if (online.video) |venr| {
            // movie group:
            if (venr.lookupMovie(arena, winner.mv.?.title, winner.mv.?.year) catch null) |info| {
                const m = try enrich.mergeMovieOnline(arena, winner.fields.?, info);
                winner.fields = m.fields; winner.dst = try naming.dstFor(arena, cfg, .movie, m.fields);
                for (m.warnings) |w| try gb.warnings.append(arena, w);
                gb.title = info.title; if (info.year) |y| gb.year = y;
                try gb.warnings.append(arena, try std.fmt.allocPrint(arena, "TMDB: matched \"{s}\"", .{info.title}));
            } else try gb.warnings.append(arena, "TMDB: no confident match");
        }
```

TV analog: `lookupSeries(series, null)` once per group; per primary episode, `episodeTitle(sid, season, episode)`, then `mergeTvOnline`, recompute dst, update `primary_dst` for sidecars. (Series-level fields — series_year/id — flow through each episode's Fields so the series folder path carries them.) Ensure sidecars/covers still resolve: recompute `c.primary_dst` after the merge, before Phase C.

- [ ] **Step 4: Update call sites** — `group.zig` tests: `buildPlan(..., .{})` (was `..., null`). `organize.zig`/`review.zig`: build the video enricher and pass `Online`:

```zig
    var real = http.RealHttpClient{ .io = ctx.io };
    var caching = httpcache.CachingHttpClient{ .inner = real.client(), .dir = try mbCacheDir(ctx.arena, ctx.env), .throttle_ms = 250 };
    var mb = musicbrainz.MusicBrainz{ .http_client = caching.client(), .contact = cfg.musicbrainz_contact };
    var music_enr = musicbrainz.Enricher.init(ctx.arena, &mb);
    var tmdb_api = tmdb.Tmdb{ .http_client = caching.client(), .api_key = cfg.tmdb_key orelse "" };
    var video_enr = tmdb.Enricher.init(ctx.arena, &tmdb_api);
    const online = group.Online{
        .music = if (cfg.musicbrainz_enabled and !opts.offline) &music_enr else null,
        .video = if (cfg.tmdb_key != null and !opts.offline) &video_enr else null,
    };
    break :blk group.buildPlan(ctx.arena, ctx.io, dir, cfg, !opts.no_probe, online) catch |err| { ... };
```

(One shared `CachingHttpClient` is fine — both providers key by full URL. If per-host throttle matters later, split; not needed now.) Same in `review.zig`.

- [ ] **Step 5: Build + test + offline smokes** — `zig build test && ./scripts/organize-smoke.sh && ./scripts/music-smoke.sh`. Offline (no `tmdb_key`) output unchanged.

- [ ] **Step 6: Commit** — `feat(phase4): Online{music,video} bundle + TMDB wiring + --offline`

---

## Task 6: Docs + tmdb-smoke + todo/memory

**Files:** `docs`, `justfile`, `scripts/tmdb-smoke.sh`, `todo.md`, memory.

- [ ] **Step 1: `scripts/tmdb-smoke.sh`** (gated `TMDB_SMOKE=1` + `TMDB_KEY`):

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ "${TMDB_SMOKE:-0}" == "1" && -n "${TMDB_KEY:-}" ]] || { echo "TMDB_SMOKE!=1 or TMDB_KEY unset — skipping"; exit 0; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$XDG_CONFIG_HOME/stacks" "$TMP/dl"
printf 'tmdb_key = %s\n' "$TMDB_KEY" > "$XDG_CONFIG_HOME/stacks/config.toml"
: > "$TMP/dl/The.Matrix.1999.1080p.mkv"
OUT="$("$ROOT/zig-out/bin/shelve" organize "$TMP/dl" --to "$TMP/lib" --dry-run)"
echo "$OUT" | grep -E "tmdbid-|TMDB" || { echo "FAIL: no TMDB id/line"; exit 1; }
echo "ok: TMDB enrichment produced an id"
```

Add `just tmdb-smoke` (`TMDB_SMOKE=1 ./scripts/tmdb-smoke.sh`). Add `--offline` note already present; document `tmdb_key`/`id_suffix` in the config docs.

- [ ] **Step 2: todo/memory** — mark Phase 4 (TMDB) done with a one-liner; append a memory status line (providers/tmdb.zig, Online bundle, id-token naming, Fields ids/lang/series_year, config tmdb_key/id_suffix, `--offline`, tmdb-smoke).

- [ ] **Step 3: Commit** — `docs(phase4): TMDB config + smoke; mark Phase 4 done`

---

## Self-Review

**Spec coverage:** provider movie/tv/episode (T3) ✓; ids folder+file via `{id}` token + `[]` collapse (T2) ✓; series_year (T1,T2) ✓; original_language captured (T1,T3,T4) ✓; pure merges w/ warn (T4) ✓; Online bundle refactor + wiring + `--offline` (T5) ✓; config gate (T1,T5) ✓; offline output unchanged (T2 tests + T5 smokes) ✓; docs+smoke (T6) ✓.

**Placeholder scan:** T3 leaves lookup *bodies* described rather than fully typed — acceptable as the parse shape mirrors the tested `musicbrainz.parseRelease`; every other step has literal code. Implementer follows the MockClient tests as the contract.

**Type consistency:** `MovieInfo`/`SeriesInfo` (T3) consumed by merges (T4) and wiring (T5); `Online{music,video}` (T5) replaces `mb` at all `buildPlan` call sites; `Fields` id/lang/series_year (T1) rendered by naming (T2), filled by merges (T4); `id_suffix`/`tmdb_key` (T1) read in naming (T2) + CLI (T5).
