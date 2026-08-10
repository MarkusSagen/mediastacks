# stacks — Music B: MusicBrainz enrichment

**Date:** 2026-08-10
**Status:** Design approved, pending spec review

## Summary

Correct and complete music album metadata from MusicBrainz: canonical album
title, release year, canonical per-track titles, and — critically — the
**per-track artist credits** (the multi-artist data that Music C writes back).
Read-only network, opt-in via config, disk-cached, and folded into the existing
`Plan` so `organize`/`review` surface the corrections. Never overrides a usable
existing tag with lower-confidence data.

## Goals

- Fill/repair album, album-artist, year, and track titles for music groups.
- Populate each track's `artists[]` from MusicBrainz artist-credits.
- Attach `release_mbid` / `recording_mbid` (feeds C's tag write-back and a
  future Jellyfin `[mbid-…]` suffix).
- Zero network unless explicitly enabled; graceful degradation on any failure —
  a lookup miss/timeout leaves the offline plan intact.

## Non-goals

- Tag write-back (Music C).
- Downloading cover art (record the Cover Art Archive URL only).
- TV/movie online providers (Phase 4 proper); this is music-only.
- Fuzzy multi-release disambiguation UI — pick the best single release or skip.

## Decisions (from brainstorming)

- **Activation:** config `musicbrainz = on` (default off). When on, every
  `organize`/`review` does lookups. `--offline` force-bypasses.
- **Caching:** disk cache under `$XDG_CACHE_HOME/stacks/mb/`.
- Enrichment unit = a music **album group** (album-folder grouping from A.1).

## Architecture

Mirror the existing Open Library provider (`src/providers/openlibrary.zig`) and
the pure confidence-merge in `src/core/enrich.zig`. Reuse `util/http.zig`
(`HttpClient` + `MockClient`) verbatim.

### `src/providers/musicbrainz.zig` (new)

Injected `http.HttpClient` (prod: `RealHttpClient`; tests: `MockClient`). All
parsing via `std.json.Value`; any HTTP/parse failure → `null` (never throws to
the pipeline).

```zig
pub const TrackInfo = struct {
    position: u32,
    title: []const u8,
    recording_mbid: ?[]const u8 = null,
    artists: []const []const u8 = &.{}, // from artist-credit, in order
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
    /// Search + fetch the best release for an album. `track_count` gates the
    /// match (exact-count required). Returns null on no confident match.
    pub fn lookupRelease(
        self: *MusicBrainz, alloc: std.mem.Allocator,
        album: []const u8, album_artist: []const u8,
        track_count: usize, hint_year: ?u32,
    ) !?Release;
};
```

Endpoints (all `&fmt=json`):
- Search: `https://musicbrainz.org/ws/2/release?query=release:"{album}" AND artist:"{album_artist}" AND tracks:{N}&limit=5`
- Detail: `https://musicbrainz.org/ws/2/release/{mbid}?inc=recordings+artist-credits+release-groups`
- Cover URL (recorded, not fetched): `https://coverartarchive.org/release/{mbid}/front-500`

Selection: rank search results by MusicBrainz `score`, **require exact
`track_count` match**, bonus for `|release.year − hint_year| ≤ 1`. Year prefers
the release-group `first-release-date`, else the release `date`. `album_artist`
from the release `artist-credit` joined string; per-track `artists[]` from each
track's recording/artist-credit list (split into individual names, in order).

Reused helpers (copy the proven ones from `openlibrary.zig`): `urlEncode`,
`httpGetOk` (backoff + `shutdown` checks), `containsCi`, `findYear`.

### `src/util/httpcache.zig` (new) — caching HttpClient wrapper

```zig
pub const CachingHttpClient = struct {
    inner: http.HttpClient,
    dir: []const u8,          // $XDG_CACHE_HOME/stacks/mb
    throttle_ms: u64 = 1100,  // MB 1 req/sec; applied on network miss only
    pub fn client(self: *CachingHttpClient) http.HttpClient; // vtable shim
};
```

- Key = lowercase hex SHA-256 of the URL → `{dir}/{key}.json` storing a tiny
  header line `status\n` then the body. Read/write via `std.c` file ops
  (`fopen`/`fread`/`fwrite`), matching how `group.zig` tests already touch the
  FS without threading `std.Io`.
- On hit: return cached status+body immediately (no throttle, no network).
- On miss: `std.time`-based sleep of `throttle_ms` since the last *network*
  call, delegate to `inner.fetchGet`, persist 2xx/4xx bodies (skip 5xx so
  transient errors aren't cached), return.
- Cache is best-effort: any FS error degrades to a straight passthrough.

### `src/core/enrich.zig` (extend) — pure merge

```zig
pub const MusicEnrichResult = struct { fields: plan.Fields, warnings: []const []const u8 };
/// Merge a MusicBrainz Release into an album's per-track fields. Fills
/// missing/low-confidence values; never overwrites a usable existing tag when
/// MB disagrees only slightly. Returns corrected Fields per track (matched by
/// track number) + warnings. Pure; no IO.
pub fn mergeMusic(
    arena, base: plan.Fields, track_position: u32, release: musicbrainz.Release,
) !MusicEnrichResult;
```

Rules: album/album_artist ← MB when `base` came from a folder fallback or is
empty; keep `base` when it looks tag-authoritative and differs from MB (warn
"MusicBrainz suggests <x>"). year ← MB when `base.year == null`. title ← MB
canonical when `base.title` looks filename-derived. `artists[]` ← MB
artist-credit when non-empty. `release_mbid`/`recording_mbid` always attached.

### `src/core/plan.zig` (extend)

`Fields` gains (additive):
```zig
    release_mbid: ?[]const u8 = null,
    recording_mbid: ?[]const u8 = null,
```

### `src/core/group.zig` (extend)

`buildPlan(arena, io, dir_path, cfg, probe_enabled, mb: ?*Enricher)` — add an
optional enricher. `Enricher` bundles the `MusicBrainz` provider + a per-run
memo (album key → `?Release`) so multi-disc / re-encountered albums hit the
network once. After a music group's fields are computed, if `mb != null`:
`release = mb.lookupAlbum(alloc, meta.album, meta.album_artist, track_count, meta.year)`;
for each track item, `enrich.mergeMusic(...)` → replace `item.fields`, recompute
`item.dst = naming.dstFor(.music, fields)`; append group warnings; set
`group.title/year` from the corrected release. Null release → leave offline
plan untouched.

### `src/core/config.zig` (extend)

- `Config` gains `musicbrainz_enabled: bool = false`.
- `parseLines` key `musicbrainz = on|off|true|false`.
- Optional `musicbrainz_contact = <email/url>` → folded into the HTTP
  `User-Agent` (MusicBrainz requires a descriptive UA); default
  `stacks/0.1 ( +https://github.com/markussagen/booktool )`.

### CLI wiring (`commands/organize.zig`, `commands/review.zig`)

- When `cfg.musicbrainz_enabled and !opts.offline`: construct
  `RealHttpClient{ .io }` → `CachingHttpClient` → `MusicBrainz` → `Enricher`,
  pass to `buildPlan`.
- New flag `--offline` (both commands) sets `opts.offline`.
- Plan output (`printPlan`): per music group, a line
  `MusicBrainz: matched "<title>" (<year>)` or the merge warnings.
- justfile `organize`/`review` help strings gain `--offline`.

## Data flow

```
buildPlan → music group formed (A.1 albumMeta)
  └─ if online: Enricher.lookupAlbum → CachingHttpClient (disk hit? else 1/sec net)
        → MusicBrainz.lookupRelease (search → detail)
        → enrich.mergeMusic per track → corrected Fields + MBIDs
        → naming.dstFor recompute dst
  └─ else: offline plan unchanged
```

## Error handling

- Any network/parse failure or low-confidence match → `null` → offline plan
  stands (warn `MusicBrainz: no confident match`).
- Track-count mismatch → skip enrichment for that album (warn), never a partial
  wrong match.
- Cache/FS errors → passthrough to network; never fatal.
- `Ctrl+C` honored between throttled calls via `shutdown.isRequested()`.

## Testing

- **Provider** (`MockClient`): canned search JSON → chooses exact-track-count
  release; canned detail JSON → parses `Release` incl. per-track `artists[]` +
  recording MBIDs; 404/HTTP-error → `null`; asserts the search→detail call
  sequence via `mock.calls`.
- **Merge** (`enrich.mergeMusic`, pure): fill-missing-year; don't-override
  tag-authoritative album; filename-title → canonical; multi-artist populated;
  MBIDs attached.
- **Cache** (`httpcache`): write→hit (no second network call, asserted via a
  counting mock); miss persists; 5xx not cached; corrupt cache file →
  passthrough.
- **Optional** real-network smoke behind `MB_SMOKE=1` (skipped by default),
  one known release (e.g. Dire Straits – Communiqué) → asserts canonical
  `Communiqué` title recovered (also fixes A.1's mojibake gap online).

## Task sequencing (for the plan)

1. `plan.Fields` MBID fields + `config.musicbrainz_enabled`/contact.
2. `util/httpcache.zig` (keyed disk store + throttle) + tests.
3. `providers/musicbrainz.zig` search+detail parsing (MockClient tests).
4. `enrich.mergeMusic` pure merge + tests.
5. `group.buildPlan` enricher wiring (memoized) + `--offline` + plan output.
6. Docs (`COMMANDS.md`), justfile help, todo/memory; optional MB smoke.

## Open items

- User-Agent contact string: default provided; overridable via config.
- Multi-disc: enrich per source-folder album (A.1 unit); a real 2-disc MB
  release maps by absolute track position — handle in mergeMusic via position.
