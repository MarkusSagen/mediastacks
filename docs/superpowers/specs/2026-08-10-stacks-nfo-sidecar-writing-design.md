# stacks — NFO / OPF sidecar writing (Jellyfin-authoritative metadata)

**Date:** 2026-08-10
**Status:** Design approved, pending spec review

## Summary

Write Jellyfin-native metadata sidecar files next to organized media so the
library is self-describing and identification is pinned — Jellyfin reads local
NFO with priority. Scope this wave: **video** (`movie.nfo`, `<episode>.nfo`,
`tvshow.nfo`, `season.nfo`) and **music** (`album.nfo`, `artist.nfo`). Content
is built purely from the shared `Plan.Fields`; files are written during apply as
new sidecars (no media-byte mutation), journaled so `shelve undo` removes them.

## Goals

- Emit correct NFO filenames/locations with the fields we hold: title,
  originaltitle, year, **providerids** (tmdbid/imdbid/tvdbid, musicbrainz*),
  language, plus season/episode numbers for episodes.
- Pin identity via provider IDs so Jellyfin enriches confidently (avoids the
  "sparse NFO blocks remote enrichment" trap — IDs let Jellyfin fetch the rest).
- Work offline (IDs/fields from A.1 + tags) and richer when TMDB/MusicBrainz are
  on. Reversible via the existing journal.

## Non-goals

- Books `.opf` / `ComicInfo.xml` (arrives with the documents kind, Phase 2).
- Fetching plot/cast/genres (TMDB spec fetches IDs/title/year/lang; a richer
  fetch is a later enhancement — NFO simply includes whatever `Fields` holds).
- Editing/merging pre-existing NFO the user already has (we write our own;
  on-conflict respects the same `--on-conflict` policy as media).

## Decisions (from brainstorming)

- **Video + music now.**
- Sidecars are safe (new files) → `write_nfo = on` **default on** for organized
  libraries; `--no-nfo` / `write_nfo = off` disables. Journaled + undoable.

## Architecture

### `core/nfo.zig` (new) — pure XML builders

```zig
pub fn movieNfo(alloc, f: plan.Fields) ![]u8;          // <movie>
pub fn episodeNfo(alloc, f: plan.Fields) ![]u8;        // <episodedetails>
pub fn tvshowNfo(alloc, series, year, ids) ![]u8;      // <tvshow>
pub fn seasonNfo(alloc, season: u32) ![]u8;            // <season>
pub fn albumNfo(alloc, f: plan.Fields) ![]u8;          // <album>
pub fn artistNfo(alloc, name, mbid) ![]u8;             // <artist>
```

Each emits minimal valid XML with an escaped-text helper. Provider IDs use both
Jellyfin forms for compatibility: dedicated tags **and** a `<uniqueid>`:
```xml
<movie>
  <title>The Matrix</title>
  <originaltitle>The Matrix</originaltitle>
  <year>1999</year>
  <tmdbid>603</tmdbid>
  <imdbid>tt0133093</imdbid>
  <uniqueid type="tmdb" default="true">603</uniqueid>
  <uniqueid type="imdb">tt0133093</uniqueid>
  <language>en</language>
</movie>
```
Episodes add `<season>`, `<episode>`, `<showtitle>`. Album adds
`<musicbrainzalbumid>` / `<musicbrainzreleasegroupid>`; artist adds
`<musicbrainzartistid>`. `originaltitle` is emitted when `original_language`
differs from the display language. Builders are pure → unit-tested by asserting
substrings + well-formedness.

### Plan model (`plan.zig`)

Add `Item.nfo_role: ?NfoRole = null` where
`NfoRole = enum { movie, episode, album }` set on primaries, plus **group-level
NFO intents**: emit `tvshow.nfo` once per TV series folder, `season.nfo` per
season, `artist.nfo` per artist. Simplest: `Group` gains an optional
`nfo: ?GroupNfo` describing the container-level file(s) to write (series/season/
artist), computed in `group.zig` from the group's kind + fields.

### Writing during apply (`apply.zig`, `journal.zig`)

- `TagOpts`-style `NfoOpts { write: bool, }`; apply writes NFO after moves.
- For each primary with `nfo_role`, write the per-item NFO beside its
  destination (`movie.nfo` in the movie folder; `{episode-stem}.nfo` beside the
  episode; `album.nfo` in the album folder).
- Container NFO from `Group.nfo`: `tvshow.nfo` at the series root, `season.nfo`
  in each `Season NN`, `artist.nfo` at the artist root (written once).
- New `journal.Action.create` (`to` = created path; undo unlinks it). Reuses the
  same journal that Music C / `.ignore` use — no schema change beyond the enum.
- On-conflict: if an NFO already exists, honor `--on-conflict`
  (skip/overwrite/suffix — default skip preserves a user's existing NFO).

### Config / CLI

`write_nfo: bool = true`; key `write_nfo = on|off`; flags `--nfo` / `--no-nfo`
(flag beats config). `organize`/`review`/web apply thread `NfoOpts`. Plan/apply
output notes `wrote N nfo file(s)`.

## Data flow

```
Plan.Item.fields (+ Group.nfo)  — offline A.1/tags, richer with TMDB/MusicBrainz
  └─ apply (write_nfo on): per-item nfo beside media + container nfo (tvshow/
     season/artist) once → journal .create entries
shelve undo: .create → unlink the nfo; media move/tagwrite reverse as before
```

## Error handling

- Missing fields → omit those tags (never emit empty/invalid XML); a movie with
  only title/year still yields valid `<movie>`.
- Write failure → warn, skip that NFO, continue (never fatal, never blocks the
  media move).
- Pre-existing NFO under `--on-conflict skip` → left untouched (no journal
  entry), warned.

## Testing

- Pure builders (`nfo.zig`): movie/episode/tvshow/season/album/artist →
  assert required tags, `<uniqueid>` forms, XML-escaping of `&<>"`, and
  `originaltitle` only-when-foreign; parse-back well-formedness via a tiny check.
- `apply`: `write_nfo` emits the right files at the right paths; `undo` removes
  exactly the created NFO (media restored as before); `--on-conflict skip`
  leaves an existing NFO.
- `nfo-smoke.sh`: organize a synthetic movie + album with `--nfo`; assert
  `movie.nfo`/`album.nfo` exist and contain the IDs; `undo` removes them.

## Task sequencing (for the plan)

1. `core/nfo.zig` pure builders (video) + tests.
2. `core/nfo.zig` music builders + tests.
3. `plan` `Item.nfo_role` + `Group.nfo`; `group.zig` computes them + tests.
4. `journal.Action.create`; `apply` NFO write step (per-item + container) + undo.
5. `config.write_nfo` + `--nfo/--no-nfo` + on-conflict handling.
6. CLI/web wiring + `nfo-smoke.sh` + docs/todo/memory.

## Open items

- Whether to also write `<genre>`/`<plot>` once TMDB fetches them (follow-up).
- Season/episode NFO for specials (Season 00) — same path rules; verify.
