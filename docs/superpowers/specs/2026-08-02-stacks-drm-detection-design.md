# stacks — DRM detection (video + ebooks)

**Date:** 2026-08-02
**Status:** Design approved, pending spec review

## Summary

Detect DRM-protected media and **flag** it — never remove or circumvent it.
A shared `core/drm.zig` sniffs container structure for encryption markers.
`shelve` flags protected videos during `organize` (organized normally by
filename, with a `DRM — <scheme>` warning, no ffprobe read). `biblio`
reports DRM ebooks in `info` and `scan`.

Detection is a **targeted container sniff** (deterministic, high-confidence),
not an ffprobe/heuristic guess.

## Goals

- Reliably flag the common real-world cases: iTunes/Apple TV FairPlay and
  CENC (Widevine/PlayReady) MP4 video; Adobe ADEPT epub + `.acsm` tokens.
- Zero false positives on ordinary (unprotected) files.
- Keep it read-only and cheap: parse box/zip structure, don't decode media.
- Shared across both binaries via one `core/drm.zig`.

## Non-goals / Out of scope

- **DRM removal / circumvention** — detection only (legal + policy line).
- **Matroska (MKV/WebM) `ContentEncryption`** — real but very rare in
  practice, and reliable EBML detection is disproportionate work. Deferred
  with a note; `detectVideo` returns `.none` for MKV in v1.
- **Kindle KFX/AZW DRM** — proprietary, hard to detect reliably. Deferred.
- **Music** (`.m4p` FairPlay audio) — shelve doesn't handle music.

## Decisions (from brainstorming)

- Scope: **video (shelve) + ebooks (biblio)**, shared module.
- Video disposition: **organize normally, but flagged** (a warning; no probe).
- Mechanism: **targeted container sniff** (MP4 boxes; epub zip member).

## Architecture

### Shared module — `core/drm.zig`

```zig
pub const Scheme = enum { none, fairplay, cenc, adept, acsm };

/// Human label for a scheme, e.g. "FairPlay", "CENC (Widevine/PlayReady)".
pub fn label(s: Scheme) []const u8;

/// Sniff a video container for encryption. Reads only the box structure.
pub fn detectVideo(alloc: std.mem.Allocator, io: std.Io, path: []const u8) Scheme;

/// Detect ebook DRM: epub `META-INF/encryption.xml` (ADEPT) or `.acsm`.
pub fn detectEbook(alloc: std.mem.Allocator, io: std.Io, path: []const u8) Scheme;

// Pure, unit-tested without real DRM files:
/// Return the byte range of top-level box `kind` (e.g. "moov"), or null.
pub fn findBox(bytes: []const u8, kind: *const [4]u8) ?[]const u8;
/// Classify DRM markers within a moov byte slice.
pub fn scanForDrmMarkers(moov: []const u8) Scheme;
```

**MP4 detection (`detectVideo`):**
- Read the file's top-level boxes: each is `[u32 size big-endian][4CC type]`;
  when `size == 1` a `u64` largesize follows the type; `size == 0` means "to
  EOF". Walk them to locate `moov` (bounded: only read box headers + the
  `moov` payload, never the huge `mdat`).
- `scanForDrmMarkers(moov)`: if it contains `pssh` → `.cenc`; else if it
  contains `sinf`/`schm` with a FairPlay scheme, or `drms`, or sample-entry
  types `encv`/`enca` alongside a FairPlay `sinf` → `.fairplay`; else `.none`.
  (Encrypted sample entries `encv`/`enca` + a `pssh` ⇒ CENC; `sinf`/`drms`
  without `pssh` ⇒ FairPlay. These 4CCs don't occur in an unprotected
  `moov`.)
- Non-MP4 extensions (`.mkv`, `.webm`, `.avi`, …) → `.none` (Matroska
  deferred).

**Ebook detection (`detectEbook`):**
- `.acsm` extension → `.acsm` (an Adobe fulfillment token, not a book).
- `.epub` → open with `ffi/miniz.zig`'s `ZipReader`; if member
  `META-INF/encryption.xml` exists → `.adept`. (Use `readMember`; treat a
  not-found error as "no member". Reuse the `forEachMember` pattern from
  `cbz.zig` if a case-insensitive scan is cleaner.)
- Other ebook formats → `.none` (Kindle deferred).

### Video side — `core/group.zig`

Inside the existing per-candidate block, under the same `do_probe` gate
(both are "inspect the file"; `--no-probe` skips both):

```
if (do_probe) {
    const scheme = drm.detectVideo(arena, io, abs);
    if (scheme != .none) {
        // organize by filename, flagged, no probe
        c.warnings = &.{ try std.fmt.allocPrint(arena, "DRM — {s}", .{drm.label(scheme)}) };
    } else {
        c.probe = probe.run(arena, io, abs);
        // …existing enrich.mergeTv/mergeMovie…
    }
}
```

A DRM candidate stays a normal primary/duplicate (organized by its filename
fields), carries the `DRM — …` warning (surfaced in the `Warnings:` block),
and has no media-info suffix. Dedup falls back to the filename-quality
score (`videoScore`) since there's no probe.

### Ebook side — `biblio`

- `src/commands/info.zig`: after printing metadata, call `drm.detectEbook`
  and, when not `.none`, print a `DRM:  <label>` line.
- `src/commands/scan.zig`: detect per ebook; count DRM files and include
  `drm=<n>` in the summary line (a DRM ebook still ingests by path, but its
  embedded metadata can't be read — the flag explains the gap).

## Error handling

- Unreadable/short/oddly-structured files → `.none` (never a false DRM flag,
  never a crash). A truncated box walk stops and returns what it found.
- Zip open failure on a supposed epub → `.none`.
- `detectVideo`/`detectEbook` never error out; they return a `Scheme`.

## Testing

- `findBox` — fixtures: box before/after `moov`; 64-bit `size==1`; `moov`
  absent → null.
- `scanForDrmMarkers` — a `moov` slice containing `pssh` → `.cenc`; one with
  `sinf`+`drms` (no `pssh`) → `.fairplay`; a plain `moov` → `.none`.
- `detectVideo` end-to-end on a hand-assembled minimal MP4 (`ftyp` + `moov`
  with a marker) written to a temp file → correct scheme; a plain MP4 →
  `.none`.
- `detectEbook` — build a temp zip via `ZipWriter` with and without
  `META-INF/encryption.xml` → `.adept` / `.none`; `foo.acsm` path → `.acsm`.
- No smoke (can't portably generate a real protected file); unit fixtures
  carry it — noted in `organize-smoke.sh` comments.

## Open items

- Exact FairPlay-vs-CENC disambiguation edge cases (files with both `sinf`
  and `pssh`): default to `.cenc` when `pssh` present. Finalize in the plan.
