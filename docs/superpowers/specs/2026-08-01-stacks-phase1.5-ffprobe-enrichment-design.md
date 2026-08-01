# stacks Phase 1.5 — ffprobe enrichment + naming presets

**Date:** 2026-08-01
**Status:** Design approved, pending spec review

## Summary

Make `shelve` read real metadata from the media files themselves (via
`ffprobe`) instead of trusting only the filename, and let users pick a
naming convention by name. Two features, one theme (better metadata /
output flexibility):

1. **ffprobe enrichment** — when `ffprobe` is on `PATH`, probe each video
   during `organize` to get true resolution/codec/bitrate/duration and any
   embedded library tags, then use that to (a) score duplicates better,
   (b) flag mislabeled/corrupt files, (c) fill/override parsed fields by
   confidence, and (d) show media info in the plan. Auto-on when available,
   with `--no-probe` to skip.
2. **Naming presets** — `preset = jellyfin | plex | kodi` in config (default
   **jellyfin**), resolved to `{…}` template strings; explicit templates and
   a `--preset` flag still override.

Everything here is **read-only**. Writing tags back into files and muxing
subtitles is explicitly deferred (see "Out of scope").

## Goals

- The genuinely-better copy wins dedup, even when both filenames say
  "1080p".
- Surface fakes/mislabels (2-minute "episodes", "1080p" that's really 480p,
  unreadable files) as advisory warnings — without blocking.
- Prefer authoritative embedded tags over filename guesses, transparently.
- Switch naming conventions with one config line.
- Zero new hard dependencies: `ffprobe` is optional, gracefully skipped.

## Non-goals / Out of scope (own future spec)

- **Writing metadata back into files** (embedding tags, correcting
  resolution/bitrate fields, renaming inside the container) — this is
  `ffmpeg` mutating files and needs its own safety design (in-place rewrite
  is riskier than a move).
- **Muxing subtitles into files.**
- **DRM detection** — deferred to its own follow-up (a distinct safety
  concern, not enrichment).
- **Online providers** (TMDB/TVDB) — Phase 4.

## Decisions (from brainstorming)

- Scope: ffprobe enrichment **+** naming presets. DRM detection later.
- Probing runs **automatically when `ffprobe` is installed**, with a
  `--no-probe` escape hatch.
- Probe data is used for **all four**: better dedup, mislabel/corrupt flags,
  fill-from-embedded-tags, and show-media-info-in-plan.
- Conflict resolution is **confidence-based per field**: authoritative
  iTunes-style tags override the filename; generic tags only fill gaps;
  every override/conflict is surfaced.

## Architecture

### Data flow

```
scan/group walk
  → parse from filename            (kinds/tv, kinds/movie)  — unchanged
  → probe file (if enabled)        (core/probe)             — new
  → merge by confidence            (core/enrich)            — new, pure
  → group + dedup                  (core/group + mediascore)— mediascore extended
  → plan (+ media info, warnings)  (core/plan)              — 2 optional Item fields
```

Enrichment lives **inside the existing `group.zig` walk** (right after the
per-file filename parse), because that loop already parses each file. The
merge logic is a **pure function in `core/enrich.zig`** so it's unit-tested
without spawning ffprobe.

### New / changed modules

- **`core/probe.zig`** (new)
  - `pub fn available(alloc, io) bool` — wraps
    `exec.isExecutableInPath(alloc, io, "ffprobe")`.
  - `pub fn run(alloc, io, path) ?Probe` — runs
    `ffprobe -v error -print_format json -show_format -show_streams PATH`
    via `exec.runCaptureStdout`; returns `null` when ffprobe is
    absent/errors, and a `Probe` with `.readable = false` when ffprobe ran
    but couldn't decode the media.
  - `pub fn parse(alloc, json_bytes) !Probe` — **pure**; the JSON→`Probe`
    step, separated from process-spawning so tests feed a captured fixture.
  - Types:
    ```
    pub const Confidence = enum { none, generic, authoritative };
    pub const Embedded = struct {
        series: ?[]const u8 = null,
        season: ?u32 = null,
        episode: ?u32 = null,
        title: ?[]const u8 = null,
        kind_hint: ?kind.MediaKind = null,
        confidence: Confidence = .none,
    };
    pub const Probe = struct {
        readable: bool = true,
        vcodec: ?[]const u8 = null,
        width: ?u32 = null,
        height: ?u32 = null,
        duration_s: ?f64 = null,
        bitrate: ?u64 = null,
        audio_langs: []const []const u8 = &.{},
        sub_langs: []const []const u8 = &.{},
        embedded: Embedded = .{},
    };
    ```
  - Extraction rules:
    - Technical facts from the first video stream (`width`, `height`,
      `codec_name`) and `format` (`duration`, `bit_rate`, `size`).
    - `Embedded.confidence = .authoritative` when `format.tags.media_type`
      indicates TV/Movie **and** the structured tags are present
      (`show` + `season_number` + `episode_id`/`episode_sort` for TV;
      `title` + `media_type` for movie). `.generic` when only a free-form
      `title` tag exists. `.none` otherwise.
    - Also read Matroska stream/format tags (`TITLE`, `SEASON_NUMBER`,
      `EPISODE`/`PART_NUMBER`) as `.generic` (these are user-set and not as
      reliable as iTunes atoms).

- **`core/enrich.zig`** (new, pure)
  - ```
    pub const Warning = []const u8;
    pub const Merged = struct { /* the resolved fields the templater uses */
        series: ?[]const u8, season: ?u32, episode: ?u32,
        title: ?[]const u8, quality: ?[]const u8,
    };
    pub fn mergeTv(alloc, parsed: tv.Episode, probe: ?probe.Probe)
        !struct { fields: Merged, warnings: []const Warning };
    pub fn mergeMovie(alloc, parsed: movie.Movie, probe: ?probe.Probe)
        !struct { fields: Merged, warnings: []const Warning };
    ```
  - Rules:
    - `authoritative` embedded season/episode/title **override** the parsed
      value; on a difference, emit `used embedded SxxEyy over filename …`.
    - `generic`/Matroska tags only **fill** a field the filename left null.
    - `quality`: derive from probe `height` when present
      (`>=2160→2160p`, `>=1080→1080p`, `>=720→720p`, else `480p`); this
      becomes the value fed to `mediascore` and the `{quality}`-style checks.
  - Warning generators (advisory, never block):
    - `probe.readable == false` → `unreadable (corrupt?)`.
    - filename tier says 1080p+ but probe height < 720 → `named <tier>,
      actually <real>`.
    - `duration_s` present and < 180s for a tv/movie primary →
      `<n>m runtime — sample/clip?`.

- **`core/mediascore.zig`** (changed)
  - Add `pub fn videoScoreProbed(height: ?u32, bitrate: ?u64, size: u64) f32`
    — tier from real `height` (2160/1080/720/480), then `log2(bitrate)` as
    the in-tier tiebreaker, then `log2(size)`. Keep the existing
    `videoScore(quality, size)` for the no-probe path. `group` calls the
    probed variant when a `Probe` is present, else the filename variant.

- **`core/config.zig`** (changed)
  - Add `preset` key + a built-in table:
    ```
    pub const PRESETS = ... // name -> {tv, movie}
    // jellyfin (current defaults), plex, kodi
    ```
  - Resolution order (highest wins): explicit `tv_template`/`movie_template`
    → `preset` → built-in default (`jellyfin`). `load` resolves to concrete
    strings so downstream is unchanged.
  - `Config` keeps `tv_template`/`movie_template` as the resolved strings;
    add nothing else downstream needs to know about presets.

- **`core/plan.zig`** (changed — additive)
  - `pub const MediaInfo = struct { codec: ?[]const u8 = null, width: ?u32 =
    null, height: ?u32 = null, duration_s: ?f64 = null };`
  - `Item` gains `media: ?MediaInfo = null`. Optional → serializes cleanly,
    survives `--plan`/`--from`, and the future TUI reuses it.

- **`core/group.zig`** (changed)
  - New signature param: `buildPlan(arena, io, dir_path, cfg, probe_enabled)`.
  - Per media candidate: if `probe_enabled` and `probe.available`, run
    `probe.run`; feed `enrich.mergeTv/mergeMovie` to get resolved fields +
    warnings; stash the `Probe` on the `Cand` for scoring + `MediaInfo`.
  - Dedup uses `mediascore.videoScoreProbed` when a probe exists.
  - Group templating uses the merged fields.
  - Collect per-file warnings onto the owning `Group.warnings`.

- **`src/commands/organize.zig`** (changed)
  - Flags: `--no-probe` (default probes when available) and `--preset NAME`
    (overrides config preset for this run).
  - Resolve `probe_enabled = !opts.no_probe`; pass to `buildPlan`.
  - `printPlan`: when `item.media` present, append `  · <codec> <res> · <Nm>`
    to the line. Print a `Warnings:` block (from group warnings) before the
    summary.

## CLI surface

```
shelve organize DIR [--dry-run|-n] [--no-probe] [--preset jellyfin|plex|kodi]
                    [--to LIB] [--on-conflict …] [--plan FILE] [--from FILE]
```

Dry-run line, probed:
```
  ~/Media/Shows/Witch Hat Atelier/Season 01/
      Witch Hat Atelier S01E01 - The Magic That Started Everything.mkv   · h264 1080p · 24m
```

Warnings block (when any):
```
Warnings:
  Witch Hat Atelier S01E00 …  ⚠ 2m runtime — sample/clip?
```

## Error handling

- `ffprobe` absent → probing silently off (no warning spam; `--no-probe` is
  irrelevant then).
- `ffprobe` present but a file errors → `Probe{ .readable = false }`, a
  warning, and the file still organizes by its filename.
- Malformed ffprobe JSON → treat as unreadable (same as above), never crash.
- All probe strings are arena-owned; the pure `parse`/`merge` funcs take an
  allocator and own their outputs.

## Testing

- **`probe.parse`** — feed captured ffprobe JSON fixtures (an iTunes-tagged
  MP4, a scene MKV, a corrupt/empty case) → assert technical fields + the
  `Confidence` classification. No ffprobe at test time.
- **`enrich.mergeTv/mergeMovie`** — pure tests: authoritative override
  (+warning), generic fill, quality-from-height, each warning generator.
- **`mediascore.videoScoreProbed`** — real 1080p beats filename-720p;
  bitrate breaks an in-tier tie; size is the final tiebreaker.
- **`config`** — `preset = plex` yields plex strings; explicit `tv_template`
  overrides the preset; default is jellyfin.
- **`group`** — merge wiring via the pure functions (inject a `Probe`); no
  ffprobe dependency in the unit test.
- **smoke** (`organize-smoke.sh`) — assert `--no-probe` runs clean and the
  existing flow is unaffected; ffprobe is installed on the dev box, so also
  assert probing doesn't break organize/undo.

## Open items

- Preset exact strings for plex/kodi (jellyfin is the current default) —
  finalize in the plan.
- Whether `--preset` is worth a CLI flag vs config-only. Included as cheap;
  drop if it complicates completion.
