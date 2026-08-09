# stacks — Music A: read tags + organize into a clean album library

**Date:** 2026-08-09
**Status:** Design approved, pending spec review

## Summary

Add music as a first-class kind. `shelve organize`/`review` classify audio
files, read their tags via **ffprobe**, model each track (title, an
**artist list**, album-artist, album, track#, year, cover), group tracks
into **albums**, and lay them out as a clean, player-standard library:
```
Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}
```
This is **read-only** (move/rename, like the rest of `organize`). Two
follow-ups complete the epic: **B** MusicBrainz enrichment, **C** tag
write-back (the multi-value-artist fix so a track appears under *each*
artist). Music A models the artist list now so C can just write it.

## Goals

- Turn a messy music folder into a tidy `Album Artist / Album (Year) /
  NN - Title` library that Plex/Jellyfin/Navidrome/Apple read correctly.
- Group by **album-artist** so a "Best of Eric Clapton" disc lands wholly
  under `Eric Clapton`, and true compilations under `Various Artists`.
- Model multi-artist as a **list** (split from the flattened tag), even
  though writing per-artist tags is sub-phase C.
- Reuse the shared engine: an album is a `Group`; no new command.

## Non-goals (this sub-phase)

- **Writing tags** (multi-artist fix, embedding covers) — sub-phase C.
- **Online metadata** (MusicBrainz) — sub-phase B.
- **Audiobooks / podcasts** — separate kinds later (`.m4b` etc.).
- Transcoding / format conversion.

## Decisions (from brainstorming)

- Music epic sequenced **incremental A→B→C**; this is A (read + organize,
  read-only).
- Tags read via **ffprobe** (already integrated; no new dependency).
- Group by **(album-artist, album)**; album-artist drives the folder.
- Multi-artist tag is **split into a list**; the folder uses album-artist,
  falling back to the first artist when album-artist is absent.

## Architecture

### New / changed modules

- **`src/kinds/music.zig`** (new)
  ```zig
  pub const Track = struct {
      title: ?[]const u8 = null,
      artists: []const []const u8 = &.{},  // split from the flattened tag
      album_artist: ?[]const u8 = null,
      album: ?[]const u8 = null,
      track: ?u32 = null,
      year: ?u32 = null,
      ext: []const u8,
  };
  /// Split a flattened artist tag into individual artists.
  pub fn splitArtists(alloc, s: []const u8) ![]const []const u8;
  /// Pure: build a Track from a tag lookup + basename (fallback title).
  pub fn fromTags(alloc, tags: TagSet, basename: []const u8) !Track;
  /// Run ffprobe on `path`, build the tag set, call `fromTags`. Null when
  /// ffprobe is absent or the file has no usable audio.
  pub fn parse(alloc, io, path: []const u8) !?Track;
  ```
  - `TagSet` is a tiny wrapper over `std.json`'s `format.tags` object (or a
    `std.StringHashMap([]const u8)` for tests) with case-insensitive `get`.
  - `splitArtists` splits on `;`, `/`, `,`, ` & `, ` x `, ` feat. `,
    ` ft. `, ` featuring ` (case-insensitive), trims, drops empties, dedups.
  - `track "3/12"` → `3`; `date "1998-05-20"`/`"1998"` → `1998`.
  - `fromTags` fills `album_artist` from the `album_artist` tag, else null;
    `artists` from `splitArtists(artist tag)`; `title` from the `title` tag
    else the filename stem.

- **`src/core/classify.zig`** — add `AUDIO_EXT = { .mp3, .flac, .m4a, .aac,
  .ogg, .opus, .wma }` → `.music`. (`.m4b` stays unclassified — audiobook,
  later. `.wav` omitted — usually untagged/huge.)

- **`src/core/plan.zig`** — extend `Fields` (additive) with
  `album_artist: ?[]const u8`, `album: ?[]const u8`, `track: ?u32`,
  `artists: []const []const u8 = &.{}`. (Serializes like the rest.)

- **`src/core/naming.zig`** — add a `.music` branch to `dstFor`:
  fields `{album_artist, album, year, track (zero-padded), title, ext}`
  → `cfg.music_template`.

- **`src/core/config.zig`** — add `music_template` (default
  `Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}`) and a
  `music` line in each preset (jellyfin/plex/kodi share this layout).

- **`src/core/mediascore.zig`** — add `audioScore(lossless: bool,
  bitrate: ?u64, size: u64) f32` (lossless tier > lossy; then bitrate; then
  size). `flac`/`alac` are lossless.

- **`src/core/group.zig`** — in the walk, `.music` candidates parse via
  `music.parse` (needs `io`, gated by the same `inspect` switch as probing).
  Group key `music|{album_artist_lower}|{album_lower}`; `Group.title` =
  album (display). Dedup per (track#, title) with `audioScore`. Populate
  `Item.fields` (album_artist, album, track, title, year, artists, ext) and
  `dst` via `naming.dstFor(.music, …)`. An album **cover** image in the same
  source dir (`cover|folder|front|albumart`.{jpg,jpeg,png}) attaches as a
  **sidecar** to the album (dst = `<album dir>/cover.<ext>`).

### Grouping rules

- `album_artist` = the `album_artist` tag if present; else the track's
  **first** artist; else `"Unknown Artist"`.
- `album` = the `album` tag; else `"Unknown Album"` (flagged with a warning
  so the user notices untagged files).
- Tracks with no tags at all (ffprobe absent, or a bare file) → filename
  stem as title, `Unknown Artist/Unknown Album`, warned.

## Error handling

- ffprobe missing → music files parse from filename only (title = stem),
  everything lands under `Unknown Artist/Unknown Album` with a warning; the
  run still succeeds. (ffprobe present is strongly recommended for music.)
- Unreadable/DRM audio → treated like any unreadable media (organized by
  filename, warned); DRM detection (`.m4p` etc.) is out of scope here.
- Missing track number → omit the `NN - ` prefix (template collapses the
  empty field, like the existing engine).

## Testing

- `splitArtists` — `"Eric Clapton; B.B. King"` → 2; `"A feat. B & C"` → 3;
  single artist → 1; dedups repeats.
- `fromTags` (pure, tag map) — album-artist grouping fields; `track "3/12"`
  → 3; `date` → year; missing title → filename stem.
- `naming.dstFor(.music, …)` — a full track → the Jellyfin path;
  missing year/track collapse cleanly.
- `mediascore.audioScore` — flac beats mp3 at equal size; higher bitrate
  wins within a tier.
- `group` golden — a few `ffmpeg`-tagged files (incl. a 2-artist track and
  a duplicate) → one album Group, correct paths, dup flagged, cover sidecar
  attached.
- smoke (`music-smoke.sh`): `ffmpeg`-generate a tagged mini-album + a
  `cover.jpg`, `shelve organize --apply` into a temp library, assert the
  `Album Artist/Album (Year)/NN - Title` layout + the cover landed, then
  `shelve undo`.

## Task sequencing (for the plan)

1. `splitArtists` + `fromTags` (pure).
2. `music.parse` (ffprobe → Track).
3. `classify` audio → `.music`.
4. `plan.Fields` music fields + `naming.dstFor` `.music` + `config`
   `music_template`/presets.
5. `mediascore.audioScore`.
6. `group.zig` wiring (parse, group-by-album, dedup, cover sidecar, fields).
7. music smoke + docs/justfile note + verification.

## Open items

- Compilation detection when `album_artist` is absent but tracks span many
  artists: v1 uses first-artist fallback (no auto "Various Artists"
  inference). Revisit in B with MusicBrainz.
