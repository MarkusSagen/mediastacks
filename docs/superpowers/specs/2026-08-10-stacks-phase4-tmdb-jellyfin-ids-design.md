# stacks — Phase 4: TMDB enrichment + Jellyfin provider IDs

**Date:** 2026-08-10
**Status:** Design approved, pending spec review

## Summary

Enrich movies and TV from **The Movie Database (TMDB)** — Jellyfin's default
provider — with canonical title, year, per-episode titles, provider IDs
(TMDb/IMDb/TVDb), and `original_language`. Emit Jellyfin-native provider-ID
suffixes in **both folder and filename** (`[tmdbid-603]`, `[imdbid-tt…]`).
Mirrors Music B's shape (config-gated, disk-cached, `MockClient`-tested, pure
merge, graceful degradation). Read-only network.

## Goals

- Canonical movie/series/episode metadata + IDs from TMDB.
- Jellyfin ID suffixes on the movie folder+file and the series folder.
- Capture `original_language` (feeds the later language/subtitle policy epic).
- Zero network unless a TMDB key is configured and `--offline` is not set.

## Non-goals

- TVDB / IGDB / OMDb providers (later; TMDB covers movies + TV).
- Artwork/backdrop download (Jellyfin-native library spec owns image *naming*;
  fetching remote art is out of scope).
- NFO writing (the Jellyfin-native library spec).

## Decisions (from brainstorming)

- **TMDB only** (movies + TV) this wave.
- **ID suffix on by default when online**, `id_suffix = off` disables. IDs go
  in **folder + filename** (movies) and the **series folder** (TV).
- Activation: config `tmdb_key = …` present and not `--offline`.

## Architecture

Reuse `util/http.zig` + `util/httpcache.zig` verbatim. New provider mirrors
`providers/musicbrainz.zig`; merge mirrors `enrich.mergeMusic`.

### `providers/tmdb.zig` (new)

Injected `http.HttpClient`; TMDB v3 with `api_key` query param. Any HTTP/parse
failure → `null`.

```zig
pub const MovieInfo = struct {
    tmdb_id: []const u8, imdb_id: ?[]const u8 = null,
    title: []const u8, year: ?u32 = null, original_language: ?[]const u8 = null,
};
pub const SeriesInfo = struct {
    tmdb_id: []const u8, imdb_id: ?[]const u8 = null, tvdb_id: ?[]const u8 = null,
    name: []const u8, year: ?u32 = null, original_language: ?[]const u8 = null,
};
pub const Tmdb = struct {
    http_client: http.HttpClient,
    api_key: []const u8,
    pub fn lookupMovie(self, alloc, title, hint_year) !?MovieInfo;
    pub fn lookupSeries(self, alloc, name, hint_year) !?SeriesInfo;
    pub fn episodeTitle(self, alloc, tmdb_id, season, episode) !?[]const u8;
};
```

Endpoints (`&api_key={key}&language=en-US`):
- Movie search `/3/search/movie?query=…&year=YYYY` → best by exact title + year;
  detail `/3/movie/{id}?append_to_response=external_ids` → title, `release_date`
  year, `imdb_id`, `original_language`.
- TV search `/3/search/tv?query=…&first_air_date_year=YYYY` → best; detail
  `/3/tv/{id}?append_to_response=external_ids` → `name`, `first_air_date` year,
  `external_ids.imdb_id`/`tvdb_id`, `original_language`.
- Episode `/3/tv/{id}/season/{s}/episode/{e}` → `name`.

`Enricher` (per-run memo) mirrors MusicBrainz's, keyed by movie/series + a
season memo for episode titles so a series is fetched once.

### `plan.Fields` (extend, additive)

```zig
    series_year: ?u32 = null,
    tmdb_id: ?[]const u8 = null,
    imdb_id: ?[]const u8 = null,
    tvdb_id: ?[]const u8 = null,
    original_language: ?[]const u8 = null,
```

### Naming — IDs in folder + filename, series year

`core/template.zig`: add a ` []` empty-collapse rule alongside the existing
` ()` rule (Music A.1), so an empty `[{id}]` drops cleanly.

`core/naming.zig`: build an **id token** — first of `tmdbid-{tmdb}`,
`imdbid-{imdb}`, `tvdbid-{tvdb}` — and pass it as the `{id}` field (empty when
none or `cfg.id_suffix == false`). New defaults:
- `DEFAULT_MOVIE = "Movies/{title} ({year}) [{id}]/{title} ({year}) [{id}].{ext}"`
- `DEFAULT_TV = "Shows/{series} ({series_year}) [{id}]/Season {season:02}/{series} S{season:02}E{episode:02} - {title}.{ext}"`
  (ID on the **series folder**; episode files stay clean — Jellyfin matches by
  series + SxxEyy. Movie ID is on folder **and** file per Jellyfin docs.)

Offline (no IDs, no series year) both collapse to today's output — verified by
existing naming tests plus new empty-collapse cases.

### `core/enrich.zig` (extend) — pure merges

```zig
pub fn mergeMovieOnline(alloc, base: plan.Fields, info: tmdb.MovieInfo) !Result;
pub fn mergeTvOnline(alloc, base: plan.Fields, series: tmdb.SeriesInfo, episode_title: ?[]const u8) !Result;
```
Fill canonical title/year/episode-name + ids + `series_year` +
`original_language`; keep the filename value but **warn** on a large title/year
mismatch (never blind-overwrite). `Result = { fields, warnings }`.

### `core/group.zig` (extend)

Replace the `mb: ?*musicbrainz.Enricher` param with a bundle:
```zig
pub const Online = struct {
    music: ?*musicbrainz.Enricher = null,
    video: ?*tmdb.Enricher = null,
};
buildPlan(arena, io, dir, cfg, probe_enabled, online: Online)
```
After tv/movie group fields are computed, if `online.video != null`: look up,
`mergeMovieOnline`/`mergeTvOnline` per item, recompute `dst`, append warnings,
set group title/year. Null/miss → offline plan untouched.

### `core/config.zig` (extend)

`tmdb_key: ?[]const u8 = null`, `id_suffix: bool = true`. Keys `tmdb_key`,
`id_suffix = on|off`. Enabled = `tmdb_key != null and !offline`.

### CLI (`organize.zig`, `review.zig`)

Build the `tmdb.Tmdb` + `Enricher` (behind `CachingHttpClient`, throttle ~250ms)
when `tmdb_key` set and not `--offline`; pass in the `Online` bundle alongside
the existing music enricher. Plan output shows `TMDB: matched "<title>" (<year>)
[tmdbid-…]` or a warning.

## Error handling

- No key / `--offline` / miss / parse error → offline plan stands (+ optional
  `TMDB: no confident match` warning).
- Title/year mismatch beyond tolerance → keep filename value, warn (no wrong
  overwrite).
- Cache/network errors degrade to passthrough (httpcache) then to offline.

## Testing

- Provider (`MockClient`): canned movie search+detail, tv search+detail, one
  episode; asserts parsed IDs + `original_language` + call sequence; 404 → null.
- Pure merges: fill, mismatch-warn, id-token precedence (tmdb→imdb→tvdb),
  `series_year` fill.
- Naming: movie folder+file id + empty-collapse; series folder id + series year;
  offline (all empty) equals today.
- Live smoke `TMDB_SMOKE=1` + `tmdb_key` env (skipped by default; unit tests
  need neither key nor network).

## Task sequencing (for the plan)

1. `plan.Fields` id/lang/series_year + `config.tmdb_key`/`id_suffix`.
2. `template` ` []` collapse; `naming` id-token + new defaults + tests.
3. `providers/tmdb.zig` (movie/tv/episode) + `MockClient` tests.
4. `enrich.mergeMovieOnline`/`mergeTvOnline` + tests.
5. `group.Online` bundle + wiring (refactor `mb` param) + CLI + `--offline`.
6. Docs, justfile, `tmdb-smoke.sh` (TMDB_SMOKE), todo/memory.

## Open items

- TMDB key acquisition is on the user (free). Document clearly.
- `language=en-US` fixed for now; could follow the preferred-language config
  once the language epic lands.
