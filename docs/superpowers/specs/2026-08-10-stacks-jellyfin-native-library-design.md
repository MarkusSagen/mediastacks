# stacks — Jellyfin-native library (extras, exclusions, images, versions)

**Date:** 2026-08-10
**Status:** Design approved, pending spec review

## Summary

Make `shelve`'s output match Jellyfin's own conventions out of the box:
recognize and correctly place **extras** (trailers/behind-the-scenes/…), stop
misclassifying legitimately-named extras as junk, emit `.ignore` so non-media
never gets scanned, carry the **full image-name set** (poster/backdrop/logo/…),
and model **multiple versions/editions** and **multi-part** files. Fully
offline; no network. NFO writing is a separate spec.

## Goals

- Extras land in Jellyfin's recognized subfolders (or keep their recognized
  filename suffixes) and are marked as extras, not primaries/junk.
- Only genuine release-promo sample clips are trashed; named extras are kept.
- `.stacks-trash/` (and any non-media leftover we create in the library) carries
  a `.ignore` so Jellyfin skips it.
- All Jellyfin image types are recognized on input and written to their
  canonical names in the destination.
- Multiple versions (`- 2160p`, `- Directors Cut`) coexist in one movie folder;
  multi-part files (`-cd1`, `-part1`) are grouped as one item.

## Non-goals

- NFO / `.opf` / `ComicInfo.xml` writing (separate spec).
- Remote artwork download; language/subtitle *policy* (later epic — this spec
  only ensures external-subtitle *naming* is recognized/preserved).
- Chapter images / media segments (Jellyfin runtime/plugin features).

## Decisions (from brainstorming)

- **Full extras + exclusion support**, including `.ignore` emission.
- Keep trashing tiny promo samples; preserve named extras.
- (IDs in folder+filename and series-year live in the TMDB spec.)

## Architecture

Changes concentrate in `core/group.zig` (classification/roles) and
`core/naming.zig` (extras/image target paths); a new `core/extras.zig` holds the
pure recognizers.

### `core/extras.zig` (new) — pure recognizers

```zig
pub const Extra = enum { behind_the_scenes, deleted_scenes, interviews, scenes,
    samples, shorts, featurettes, clips, trailers, theme_music, backdrops, extras, other };
/// Jellyfin extras subfolder name → category (case-insensitive).
pub fn extraFromDir(name: []const u8) ?Extra;
/// Jellyfin filename suffix (-trailer/.sample/-behindthescenes/…) → category,
/// returning the category and the stem with the suffix stripped.
pub fn extraFromSuffix(stem: []const u8) ?struct { kind: Extra, base: []const u8 };
/// Canonical destination subfolder for a category ("behind the scenes", …).
pub fn subdir(e: Extra) []const u8;

pub const Image = enum { poster, backdrop, logo, thumb, banner };
/// cover/poster/folder/default → poster; backdrop/fanart/background/art →
/// backdrop; logo/clearlogo → logo; thumb/landscape → thumb; banner → banner.
pub fn imageFromName(base: []const u8) ?Image;
/// Canonical output filename for an image kind ("poster.jpg", "backdrop.jpg", …)
/// given the source extension.
pub fn imageOutName(alloc, e: Image, ext: []const u8) ![]u8;
```

### Extras classification (`group.zig`)

- Phase A walk: if a file's containing dir (or an ancestor within the source)
  matches `extraFromDir`, or its stem matches `extraFromSuffix`, bucket it as an
  **extra** with its category and the owning media dir.
- New `plan.Role.extra` (additive to the enum + JSON). Extras attach to the
  nearest media group like sidecars (same/parent dir), destination =
  `{media_folder}/{subdir(category)}/{cleanName}.{ext}` (or keep the suffix form
  for single-file trailers/samples per Jellyfin). Unattached extras →
  `unclassified`.

### Sample reconciliation (`group.zig isJunkBase`)

- A file is a **promo sample** (junk) only when it looks like release litter:
  contains a site marker (`rarbg`/`yts`/`yify`) OR (`sample` in name AND file
  size < 50 MB). Larger/plainly-named `sample.mkv` or a `samples/` extra is kept
  as an extra. `isJunkBase` gains a size-aware variant used in the walk (it
  already `stat`s media).

### `.ignore` emission (`apply.zig`)

- When trashing, ensure `{library_root}/.stacks-trash/.ignore` exists (empty →
  Jellyfin skips the whole trash tree). Journaled as a created file (removed on
  undo if we created it).
- Config `emit_ignore = on` (default on). No `.ignore` is ever written into the
  user's *source* tree.

### Full image set (`group.zig` cover handling → generalized)

- Replace `isCoverImage` with `extras.imageFromName`. Each recognized image
  attaches to its media group and is written to the canonical Jellyfin name in
  the destination folder (`poster.jpg`, `backdrop.jpg`, `logo.png`, …). Music
  keeps `cover.jpg` (poster maps to `cover.jpg` for album folders, matching
  Jellyfin music). Multiple backdrops → `backdrop-1.jpg`, `backdrop-2.jpg`.

### Multiple versions + multi-part (`kinds/movie.zig`, `naming.zig`, `group.zig`)

- **Multi-part**: filenames differing only by a `-cd1/-cd2`, `-part1`,
  `-disc1`, `-pt1` suffix group into one movie item; output keeps the
  `Movie (Year)-cd1.ext` part naming. `movie.parse` extracts an optional
  `part: ?u32`.
- **Versions/editions**: a ` - 2160p` / ` - Directors Cut` / `[1080p]` label is
  parsed as `edition: ?[]const u8`; multiple editions of the same title+year
  share a folder and are emitted as `… [id] - {edition}.ext` (label kept). Two
  files that are genuinely the same edition still dedupe by `mediascore`.
- `plan.Fields` gains `edition: ?[]const u8`, `part: ?u32`; `naming.dstFor`
  appends ` - {edition}` / `-cd{part}` for movies.

## Data model (`plan.zig`)

- `Role` gains `extra`.
- `Fields` gains `edition: ?[]const u8`, `part: ?u32`.
- `Item` optionally carries the extra category in `reason` (e.g. `extra:trailer`)
  for review surfaces.

## Error handling

- Ambiguous extra (matches a category but no owning media in scope) →
  `unclassified` (never trashed).
- Unknown image name → treated as a normal file (unclassified), not forced.
- `.ignore` write failure → warn, continue (never fatal).

## Testing

Pure (`extras.zig`): `extraFromDir` (all Jellyfin names + negatives),
`extraFromSuffix` (each suffix + stem strip), `imageFromName`/`imageOutName`
(every alias → canonical), version/part parsing.
`group.zig` (no-probe, synthetic trees): a movie with `trailers/x.mkv` +
`Film-behindthescenes.mkv` → both `extra` with correct dst; a tiny
`RARBG-sample.mkv` → trashed; a large `sample.mkv` → kept as extra; `poster.jpg`
+ `backdrop.jpg` → canonical names; `Movie-cd1/-cd2` → one item, two parts;
`Movie - 2160p`/`- 1080p` → one folder, two editions.
`apply` + smoke: `.ignore` present in `.stacks-trash/`; extras land in the right
subfolders; `organize-smoke.sh` extended.

## Task sequencing (for the plan)

1. `core/extras.zig` recognizers (pure) + tests.
2. `plan.Role.extra` + `Fields.edition/part`; naming for edition/part + tests.
3. Image set generalization (`imageFromName`/`imageOutName`) in group + tests.
4. Extras classification + attachment in group + tests.
5. Sample reconciliation (size-aware) in group + tests.
6. `.ignore` emission in apply (+ `emit_ignore` config) + undo + smoke; docs/todo.

## Open items

- Season/series-level images (`Season 01/poster.jpg`) — support movie/album/
  series-root first; per-season posters a follow-up.
- Multi-part beyond `cd/part/disc/pt` (rare) — deferred.
