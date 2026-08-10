# stacks — Music C: native tag write-back (the multi-artist fix)

**Date:** 2026-08-10
**Status:** Design approved, pending spec review

## Summary

Write corrected metadata back into music files, with **multi-value ARTIST**
tags so a track lists under *each* of its artists in players/libraries. Native
writers for FLAC (Vorbis comments) and MP3 (ID3v2.4) — the only way to emit true
multi-value tags (ffmpeg collapses them). Opt-in (mutation), crash-safe
(temp-file + atomic rename), and reversible (backup + `shelve undo`). Consumes
the Plan's `Fields`, so it works offline from A's `splitArtists` and better with
B's canonical data + MBIDs.

## Goals

- Emit multiple `ARTIST` values per track (Music epic's headline fix).
- Write album/album-artist/title/year/track/disc corrected by A.1 (+ B online).
- Embed `release_mbid`/`recording_mbid` when present.
- Never risk data loss: atomic write + a byte-backup restorable via `shelve undo`.
- Off by default; only ever runs on explicit opt-in.

## Non-goals

- Formats beyond FLAC + MP3 (skip `.m4a`/others with a warning) — later.
- Embedding cover-art picture blocks (APIC / FLAC PICTURE) — later.
- Re-encoding/transcoding audio — streams are copied byte-for-byte.
- Removing "leaking" release/site tags beyond the fields we manage — a separate
  write-back/remux spec owns aggressive stripping.

## Decisions (from brainstorming)

- **Mechanism:** native writers (FLAC Vorbis comments + MP3 ID3v2.4). No new deps.
- **Activation:** off by default; `--write-tags` flag or config `write_tags = on`.
- **Undo:** byte-backup under `$XDG_DATA_HOME/stacks/backup/<journal-id>/` +
  a `tagwrite` journal entry restored by `shelve undo`.

## Architecture

### `src/kinds/music_tags.zig` (new) — pure byte assembly + writers

```zig
pub const TagSet = struct {
    title: ?[]const u8 = null,
    artists: []const []const u8 = &.{}, // multi-value
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
    year: ?u32 = null,
    release_mbid: ?[]const u8 = null,
    recording_mbid: ?[]const u8 = null,
};

/// Build the new FLAC metadata-block region (marker + STREAMINFO + others,
/// with VORBIS_COMMENT replaced) for an existing file's blocks. Pure.
pub fn buildFlacBlocks(alloc, existing_blocks: []const u8, tags: TagSet) ![]u8;
/// Build a complete ID3v2.4 tag (header + frames), UTF-8, multi-value TPE1
/// via 0x00 separators, synchsafe sizes. Pure.
pub fn buildId3v24(alloc, tags: TagSet) ![]u8;

pub const Error = error{ UnsupportedFormat, MalformedFile, OutOfMemory, IoError };
/// Dispatch by extension; write via temp file + atomic rename. Returns
/// Error.UnsupportedFormat for anything but .flac/.mp3.
pub fn writeTags(alloc, io, path: []const u8, tags: TagSet) Error!void;
```

**FLAC** (`writeTags` → `.flac`): read the file; verify `fLaC` marker; walk
metadata blocks (each: 1 header byte `[last-block flag | 7-bit type]` + 24-bit
big-endian length). Keep all blocks except `VORBIS_COMMENT` (type 4); build a
fresh `VORBIS_COMMENT` (vendor string + fields: `ARTIST` × N, `ALBUMARTIST`,
`ALBUM`, `TITLE`, `DATE`, `TRACKNUMBER`, `DISCNUMBER`, `MUSICBRAINZ_ALBUMID`,
`MUSICBRAINZ_TRACKID` when present). Emit: `fLaC` + STREAMINFO + kept blocks +
new VORBIS_COMMENT (last-block flag on the final metadata block) + original
audio frames copied verbatim. Write to `path.tmp`, `fsync`, atomic `rename`.

**MP3** (`writeTags` → `.mp3`): detect a leading `ID3` v2 tag (`"ID3"` +
version + flags + synchsafe size); the audio starts after it (or at offset 0).
Build a new **ID3v2.4** tag: header `ID3\x04\x00\x00` + synchsafe total size;
frames with UTF-8 encoding byte `0x03`: `TPE1` = artists joined by `0x00`
(spec-correct multi-value), `TALB`, `TIT2`, `TPE2` (album artist), `TDRC`
(year), `TRCK`, `TPOS`, and `TXXX`/`UFID` for MB IDs. Emit new tag + original
audio (from after any old tag) to `path.tmp`, atomic rename. No existing tag →
audio copied from offset 0.

Byte assembly (`buildFlacBlocks`, `buildId3v24`) is pure → unit-tested by
building then re-parsing and asserting fields incl. multi-value artist.

### Apply integration (`src/core/apply.zig`, `src/core/journal.zig`)

- `apply` gains a `write_tags: bool` param (threaded from CLI/config).
- For each music **primary** move, when `write_tags`:
  1. move `src → dst` (existing journaled move entry);
  2. copy `dst → $XDG_DATA_HOME/stacks/backup/<journal-id>/<n>.bak`;
  3. `music_tags.writeTags(dst, tagsFromFields(item.fields))`;
  4. journal a `tagwrite` entry `{ target: dst, backup: <path> }`.
- `.m4a`/other → skip with a warning; FLAC/MP3 only.
- `TagSet` is built from `item.fields` (album_artist/album/title/track/disc/
  year/artists[]/MBIDs) — the shared Plan contract, no new data path.

Journal (`journal.zig`) entry model gains a `tagwrite` variant (additive to the
JSON). `apply.undo` processes entries in reverse: a `tagwrite` entry copies its
backup over `target` (restoring pre-tag bytes), then the paired move entry moves
the file back to `src`. Net: original bytes at the original path. Backups are
deleted after a successful undo; a `--keep-backups` escape hatch is out of scope.

### CLI wiring (`commands/organize.zig`, `commands/review.zig`, `config.zig`)

- `config` gains `write_tags: bool = false` (key `write_tags = on|off`).
- Flags `--write-tags` / `--no-write-tags` (flag beats config). Because this
  mutates the user's files, it stays **off** unless explicitly enabled.
- Web review: a per-run "Write tags on apply" checkbox posts the flag to
  `/api/apply` (server-authoritative; default unchecked).
- Plan/apply output notes `wrote tags: N file(s)` and any skipped formats.

## Data flow

```
Plan.Item.fields (A.1 corrected + B canonical/MBIDs)
  └─ apply (write_tags on) per music primary:
       move src→dst → backup dst → music_tags.writeTags(dst, TagSet) → journal tagwrite
shelve undo: tagwrite (restore backup over dst) → move (dst→src)  ⇒ original restored
```

## Error handling

- `writeTags` never writes in place: temp + atomic rename; a failure leaves the
  original untouched (temp discarded).
- Malformed FLAC/MP3 (bad marker/size) → `Error.MalformedFile`, file skipped
  with a warning, apply continues; nothing mutated.
- Unsupported extension → `Error.UnsupportedFormat` → skip + warn.
- Backup copy failure → skip write for that file (warn); never write without a
  restorable backup.
- Undo missing a backup → warn and leave the (moved-back) file as-is rather than
  fail the whole undo.

## Testing

- **Pure build/parse round-trips**: `buildId3v24` → parse back → `TPE1` yields
  the exact multi-artist list; MBID frames present; synchsafe sizes decode.
  `buildFlacBlocks` on a synthetic block set → re-walk → VORBIS_COMMENT has
  multiple `ARTIST` fields, audio bytes unchanged.
- **writeTags** on tiny synthetic FLAC/MP3 fixtures: temp+rename leaves valid
  files; audio region byte-identical; unsupported ext → error.
- **Journal/undo**: `tagwrite` round-trips through JSON; `apply` then `undo`
  restores original bytes (hash-compare) and original location.
- **`scripts/tag-smoke.sh`** (real ffmpeg/ffprobe, authoritative): ffmpeg makes
  a FLAC + an MP3 with two artists flattened into one tag; `organize
  --write-tags`; `ffprobe` confirms **two** artist values on the destination;
  `shelve undo` restores the byte-identical originals. Skips cleanly when ffmpeg
  absent (like `music-smoke.sh`).

## Task sequencing (for the plan)

1. `music_tags.buildId3v24` (pure) + round-trip tests.
2. `music_tags.buildFlacBlocks` (pure) + round-trip tests.
3. `music_tags.writeTags` (dispatch + temp/atomic-rename) + fixture tests.
4. `journal` `tagwrite` entry + `plan`/`config`/flags plumbing.
5. `apply` integration (backup + write + journal) and `undo` restore.
6. CLI/web wiring + `tag-smoke.sh` + docs/todo/memory.

## Open items

- Vendor string for the FLAC VORBIS_COMMENT: use `stacks`.
- Whether to also write a legacy ID3v2.3 TPE1 (`/`-joined) for old players —
  default no (2.4 only); revisit if a player can't read 2.4.
