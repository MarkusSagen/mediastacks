# stacks — Music A.1: real-world album hardening

**Date:** 2026-08-09
**Status:** Design approved, pending spec review

## Summary

Make music organizing trustworthy on real, messy libraries. Four fixes,
found dry-running actual folders:

1. **Group albums by source folder** (not by tags), rolling `CD N`/`Disc N`
   subfolders up to their parent — a 2-CD set becomes one album. Derive
   album / album-artist / year by **consensus** over the folder's tracks,
   with a **Various-Artists** fallback.
2. **Multi-disc → `CD{disc}` subfolders**, so track numbers never collide.
3. **Drop the ` (year)` suffix** when the year is missing or zero.
4. **Transcode Latin-1 tags to UTF-8** (`Communiqué`, not `Communiqu�`).

Read-only (move/rename), through the existing `organize`/`review`.

## Goals

- One folder per album regardless of tag quality; multi-disc sets stay
  together with per-disc subfolders.
- Compilations without an `album_artist` land under `Various Artists`, not
  scattered across per-track artist folders.
- No `()`/`(0)` folder suffixes; no mojibake from Latin-1 tags.

## Non-goals

- Audiobook classification (`.mp3` chapters still land in music) — a
  separate audiobook kind, later.
- MusicBrainz enrichment (B); tag write-back / multi-artist fix (C).
- Merging inconsistently-named discs (e.g. `Alchemy - Disc One`/`Disc Two`
  as *separate* sibling folders with the disc in the album name) — only the
  clean `CD N`/`Disc N` **subfolder** case rolls up.

## Decisions (from brainstorming)

- Album grouping: **by source folder** (album dir), disc subfolders roll up.
- Multi-disc layout: **`CD{disc}` subfolders**.
- Consensus metadata with **Various-Artists** fallback.

## Architecture

### `kinds/music.zig` — new pure helpers

```zig
/// Disc number from a source subfolder name: "CD 1"/"CD1"/"Disc 2"/"Disk 3"
/// → n; anything else → null.
pub fn discFromDirName(name: []const u8) ?u32;

/// Consensus album metadata over a group of tracks + the album folder name.
pub const AlbumMeta = struct { album: []const u8, album_artist: []const u8, year: ?u32 };
pub fn albumMeta(alloc, tracks: []const Track, folder_name: []const u8) !AlbumMeta;

/// Transcode a tag value to UTF-8: valid UTF-8 is duped as-is; otherwise the
/// bytes are treated as Latin-1 (each byte → a codepoint) and re-encoded.
pub fn toUtf8(alloc, s: []const u8) ![]u8;
```

- `albumMeta`:
  - `album` = the first non-empty `album` among tracks, else `folder_name`.
  - `album_artist` = the first non-empty `album_artist`; else if every
    track's primary artist (`artists[0]`) is equal → that artist; else
    `"Various Artists"`.
  - `year` = the first non-zero `year`, else null.
- `music.parse` applies `toUtf8` to every extracted tag value; `fromTags`
  treats `year == 0` as null (via `firstInt` returning null for 0).

### `plan.Fields` + `naming.dstFor`

- `Fields` gains `disc: ?u32 = null` (additive). Set only for **multi-disc**
  albums.
- `naming.dstFor(.music, …)`: render the album path, and when `f.disc` is
  present insert a `CD{disc}` segment before the track file, i.e. the rel
  path becomes `…/{album} ({year})/CD{disc}/{track:02} - {title}.{ext}`.
  (Implemented by rendering the `music_template` then, if `disc` set,
  splicing `CD{d}/` before the final path component — keeps the template
  free of a conditional `{disc}` placeholder.)

### Template: drop empty ` (year)`

`core/template.zig` `renderFields` already collapses ` - ` around a missing
field; add the same for a leftover ` ()` (space + empty parens) and a bare
`()`. So `{album} ({year})` with an empty year → `{album}`. This also fixes
movies with no year.

### `core/group.zig` — music path rewrite

- `Cand` gains `album_dir: ?[]const u8` and `disc: ?u32`.
- In the walk, for a `.music` file: `parent = dirname(abs)`; if
  `discFromDirName(basename(parent))` → `disc = that`, `album_dir =
  dirname(parent)`; else `disc = null`, `album_dir = parent`.
- Phase B groups music by **`album_dir`** (string key) instead of
  `(album_artist, album)`.
- Per music group: `meta = albumMeta(tracks, basename(album_dir))`;
  `multi = (distinct non-null discs among tracks > 1)`. Dedup by
  `(disc orelse 1, track#, lower(title))` via `audioScore`. Each item's
  `Fields` = `{ album_artist = meta.album_artist, album = meta.album,
  year = meta.year, track, title, artists, ext, disc = if (multi)
  (cand.disc orelse 1) else null }`; `dst = naming.dstFor(.music, fields)`.
  `Group.title` = `meta.album`, `Group.year` = `meta.year`.
- Cover attach (Phase C2) unchanged; for multi-disc the cover sits at the
  album root (its source dir = `album_dir`).

## Error handling

- No `album` tag and unusable folder name → `"Unknown Album"` (warned), as
  today.
- Disc subfolder present but track has its own `disc` tag → the tag wins.
- Non-UTF-8 that isn't Latin-1 either still produces *some* UTF-8 (Latin-1
  maps every byte), never invalid output.
- A flat folder of singles from many albums becomes one album dir group —
  documented caveat (album-per-folder is the norm).

## Testing

Pure: `discFromDirName` (CD 1/CD1/Disc 2/Disk 3 → n; "Season 1" → null);
`albumMeta` (album_artist tag wins; all-same-artist; mixed → Various
Artists; folder-name album fallback; non-zero year pick); `toUtf8`
(valid UTF-8 passthrough; Latin-1 `Communiqu\xE9` → `Communiqué`);
`renderFields` empty-`()` collapse; `naming.dstFor(.music)` with `disc`
set → `CD1/` segment.

Smoke (`music-smoke.sh`, real ffmpeg/ffprobe — authoritative), extend with:
- a **2-CD** album (`CD 1`/`CD 2` subfolders) → assert `…/CD1/01 - …` and
  `…/CD2/01 - …` both exist (no collision);
- a **mixed-artist, no-album_artist** folder → assert `Music/Various
  Artists/…`;
- a **no-year** track → assert the folder has no `()`;
- a **Latin-1-tagged** album → assert the accented folder name.

## Task sequencing (for the plan)

1. `music.toUtf8` + `discFromDirName` + `year==0 → null` (pure).
2. `music.albumMeta` (consensus + Various-Artists) (pure).
3. `template.renderFields` empty-`()` collapse.
4. `plan.Fields.disc` + `naming.dstFor(.music)` `CD{disc}` segment.
5. `group.zig` music rewrite (album-dir grouping, disc detection, meta,
   dedup, fields).
6. smoke fixtures (2-CD, VA, no-year, Latin-1) + verification.

## Open items

- `CD{disc}` vs `Disc {disc}` folder name: use `CD{disc}` (matches the
  common `CD 1` source convention). Finalize in the plan.
