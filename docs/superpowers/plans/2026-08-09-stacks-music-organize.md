# stacks — Music A (read tags + organize album library) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add music as a kind — classify audio, read tags via ffprobe, model tracks (artist list, album-artist, album, track#, year), group into albums, and organize into `Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}` — read-only, through the existing organize/review pipeline.

**Architecture:** An album is a `Group`. New `kinds/music.zig` (pure `splitArtists`/`fromTags` + an ffprobe `parse`); additive `plan.Fields` music fields; a `.music` branch in `naming.dstFor`; a `music_template` in config/presets; `mediascore.audioScore` for dedup; and `group.buildPlan` wiring. No new command.

**Tech Stack:** Zig 0.16, ffprobe via `util/exec`, `std.json`, existing `core/{classify,plan,naming,config,mediascore,group}`.

## Global Constraints

- Zig **0.16.0**; no 0.17-only APIs; no new dependencies (ffprobe optional).
- Read-only: move/rename only. **No tag writing** (that's sub-phase C); **no MusicBrainz** (B).
- Pure parsing (`splitArtists`, `fromTags`) is unit-tested without ffprobe; arena-based tests (like `naming.zig`) so intermediates aren't individually freed.
- `std.ArrayList(T)` starts `.empty`, allocator per call. Inline `test "…"` with `std.testing.allocator`; temp files under `/tmp` keyed by `std.c.getpid()`.
- New module added to `src/root.zig` (`pub const` + `_ = x;`).
- Artist-split delimiters: `;`, `/`, `,`, ` & `, ` x `, ` feat. `/` Feat. `, ` ft. `/` Ft. `, ` featuring `.
- Grouping: key `music|{album_artist_lower}|{album_lower}`; `Group.title` = album. `album_artist` = album_artist tag → else first artist → else `"Unknown Artist"`; `album` = album tag → else `"Unknown Album"` (warned).
- Default music template (all presets share it): `Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}`.

## File Structure

Created:
- `src/kinds/music.zig` — `Tags`, `Track`, `splitArtists`, `fromTags` (pure), `parse` (ffprobe).
- `scripts/music-smoke.sh`.

Modified:
- `src/core/classify.zig` — audio exts → `.music`.
- `src/core/plan.zig` — `Fields` gains `album_artist`, `album`, `track`, `artists`.
- `src/core/naming.zig` — `.music` branch.
- `src/core/config.zig` — `music_template` + presets + `Config` field (update literals).
- `src/core/mediascore.zig` — `audioScore`.
- `src/core/group.zig` — music parse/group/dedup/cover wiring.
- `src/root.zig` — export `music`.
- `justfile` — note music support.

---

### Task 1: `kinds/music.zig` — `splitArtists` + `fromTags` (pure)

**Files:** Create `src/kinds/music.zig`; Modify `src/root.zig`

**Interfaces:**
```zig
pub const Tags = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?[]const u8 = null,
    date: ?[]const u8 = null,
};
pub const Track = struct {
    title: ?[]const u8 = null,
    artists: []const []const u8 = &.{},
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
    year: ?u32 = null,
    ext: []const u8,
};
pub fn splitArtists(alloc, s: []const u8) ![]const []const u8;
pub fn fromTags(alloc, tags: Tags, basename: []const u8) !Track;
```
Owned by `alloc`. `splitArtists` dupes each artist; `fromTags` dupes its strings and calls `splitArtists`.

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

test "splitArtists splits common delimiters, trims, dedups" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try splitArtists(a, "Eric Clapton; B.B. King");
    try t.expectEqual(@as(usize, 2), r.len);
    try t.expectEqualStrings("Eric Clapton", r[0]);
    try t.expectEqualStrings("B.B. King", r[1]);
    const r2 = try splitArtists(a, "A feat. B & C");
    try t.expectEqual(@as(usize, 3), r2.len);
    const r3 = try splitArtists(a, "Solo");
    try t.expectEqual(@as(usize, 1), r3.len);
}

test "fromTags models album grouping fields" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = try fromTags(a, .{ .title = "Layla", .artist = "Eric Clapton", .album_artist = "Eric Clapton", .album = "Best of Blues", .track = "3/12", .date = "1998" }, "03 layla.mp3");
    try t.expectEqualStrings("Layla", tr.title.?);
    try t.expectEqualStrings("Eric Clapton", tr.album_artist.?);
    try t.expectEqualStrings("Best of Blues", tr.album.?);
    try t.expectEqual(@as(u32, 3), tr.track.?);
    try t.expectEqual(@as(u32, 1998), tr.year.?);
    try t.expectEqualStrings("mp3", tr.ext);
}

test "fromTags falls back to filename stem for title" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = try fromTags(a, .{}, "some song.flac");
    try t.expectEqualStrings("some song", tr.title.?);
    try t.expectEqual(@as(usize, 0), tr.artists.len);
}
```

- [ ] **Step 2: Run** `zig build test` — FAIL (undefined).
- [ ] **Step 3: Implement**

```zig
const DELIMS = [_][]const u8{ "; ", ";", " / ", "/", ", ", ",", " & ", " x ", " feat. ", " Feat. ", " ft. ", " Ft. ", " featuring " };

pub fn splitArtists(alloc: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    outer: while (i < s.len) {
        for (DELIMS) |d| {
            if (i + d.len <= s.len and std.mem.eql(u8, s[i .. i + d.len], d)) {
                try appendArtist(alloc, &out, s[start..i]);
                i += d.len;
                start = i;
                continue :outer;
            }
        }
        i += 1;
    }
    try appendArtist(alloc, &out, s[start..]);
    return out.toOwnedSlice(alloc);
}

fn appendArtist(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8) !void {
    const a = std.mem.trim(u8, raw, " \t");
    if (a.len == 0) return;
    for (out.items) |e| if (std.ascii.eqlIgnoreCase(e, a)) return; // dedupe
    try out.append(alloc, try alloc.dupe(u8, a));
}

fn firstInt(s: []const u8) ?u32 {
    var v: ?u32 = null;
    for (s) |c| {
        if (std.ascii.isDigit(c)) {
            v = (v orelse 0) * 10 + (c - '0');
        } else if (v != null) break;
    }
    return v;
}

pub fn fromTags(alloc: std.mem.Allocator, tags: Tags, basename: []const u8) !Track {
    const ext_dot = std.fs.path.extension(basename);
    const ext = try alloc.dupe(u8, if (ext_dot.len > 0) ext_dot[1..] else ext_dot);
    const stem = basename[0 .. basename.len - ext_dot.len];
    return .{
        .title = try alloc.dupe(u8, tags.title orelse stem),
        .artists = if (tags.artist) |ar| try splitArtists(alloc, ar) else &.{},
        .album_artist = if (tags.album_artist) |x| try alloc.dupe(u8, x) else null,
        .album = if (tags.album) |x| try alloc.dupe(u8, x) else null,
        .track = if (tags.track) |x| firstInt(x) else null,
        .year = if (tags.date) |x| firstInt(x) else null,
        .ext = ext,
    };
}
```
(`firstInt` handles `"3/12"` → 3 and `"1998-05-20"` → 1998.) Add `pub const music = @import("kinds/music.zig");` + `_ = music;` to `root.zig`.

- [ ] **Step 4: Run** `zig build test` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/kinds/music.zig src/root.zig && git commit -m "feat(music): splitArtists + fromTags (pure tag model)"
```

---

### Task 2: `music.parse` — ffprobe → Track

**Files:** Modify `src/kinds/music.zig`

**Interfaces:** `pub fn parse(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Track` — runs ffprobe `-show_format`, extracts `format.tags` (case-insensitive), calls `fromTags`. ffprobe absent/failed/tagless → a filename-only Track (title = stem).

- [ ] **Step 1: Write the failing test** (uses ffmpeg if present, else skips)

```zig
test "parse reads tags from a real tagged file" {
    if (!haveFfmpeg()) return; // skip on machines without ffmpeg
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pid = std.c.getpid();
    var pb: [128]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "/tmp/music-parse-{d}.mp3", .{pid}) catch unreachable;
    defer _ = std.c.unlink(pz.ptr);
    genTagged(pz); // ffmpeg helper below

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const tr = try parse(a, threaded.io(), pz);
    try t.expectEqualStrings("Layla", tr.title.?);
    try t.expectEqualStrings("Eric Clapton", tr.album_artist.?);
    try t.expectEqual(@as(u32, 1998), tr.year.?);
}
```
Provide `haveFfmpeg()` (`exec.isExecutableInPath`) and `genTagged(pz)` (shells `ffmpeg -f lavfi -i sine=d=1 -metadata title=Layla -metadata artist="Eric Clapton" -metadata album_artist="Eric Clapton" -metadata date=1998 -y <pz>` via `std.c.system` or `exec.runCaptureStdout`).

- [ ] **Step 2: Run** `zig build test` — FAIL (`parse` undefined).
- [ ] **Step 3: Implement**

```zig
const exec = @import("../util/exec.zig");

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn tagStr(tagsv: std.json.Value, key: []const u8) ?[]const u8 {
    // case-insensitive lookup over the tags object
    if (tagsv != .object) return null;
    var it = tagsv.object.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, key)) {
            const v = e.value_ptr.*;
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return null;
}

pub fn parse(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Track {
    const base = std.fs.path.basename(path);
    const argv = [_][]const u8{ "ffprobe", "-v", "error", "-print_format", "json", "-show_format", path };
    const r = exec.runCaptureStdout(alloc, io, &argv, 1 * 1024 * 1024) catch return fromTags(alloc, .{}, base);
    defer alloc.free(r.stdout);
    if (r.exit_code != 0 or r.stdout.len == 0) return fromTags(alloc, .{}, base);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), r.stdout, .{}) catch return fromTags(alloc, .{}, base);
    const tagsv = if (objGet(root, "format")) |fmt| (objGet(fmt, "tags") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
    const tags = Tags{
        .title = tagStr(tagsv, "title"),
        .artist = tagStr(tagsv, "artist"),
        .album_artist = tagStr(tagsv, "album_artist"),
        .album = tagStr(tagsv, "album"),
        .track = tagStr(tagsv, "track"),
        .date = tagStr(tagsv, "date"),
    };
    // `tags` slices point into the arena; fromTags dupes into `alloc`.
    return fromTags(alloc, tags, base);
}
```

- [ ] **Step 4: Run** `zig build test` — PASS (test runs on this dev box; skips where ffmpeg is absent).
- [ ] **Step 5: Commit**

```bash
git add src/kinds/music.zig && git commit -m "feat(music): parse — ffprobe tags -> Track"
```

---

### Task 3: `classify` audio → `.music`

**Files:** Modify `src/core/classify.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "classify detects music from audio extensions" {
    try t.expectEqual(kind.MediaKind.music, classify("03 - Layla.mp3", false));
    try t.expectEqual(kind.MediaKind.music, classify("song.flac", false));
    try t.expectEqual(kind.MediaKind.music, classify("x.m4a", false));
}
```

- [ ] **Step 2: Run** `zig build test` — FAIL (returns `.unknown`/`.document`).
- [ ] **Step 3: Implement** — add
  `const AUDIO_EXT = [_][]const u8{ ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wma" };`
  and, before the doc/ebook checks, `if (extIn(ext, &AUDIO_EXT)) return .music;`. (`kind.MediaKind` already has a `music` variant from Phase 1.)
- [ ] **Step 4: Run** `zig build test` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/core/classify.zig && git commit -m "feat(music): classify audio extensions as .music"
```

---

### Task 4: `plan.Fields` music fields + `naming.dstFor` + `config`

**Files:** Modify `src/core/plan.zig`, `src/core/naming.zig`, `src/core/config.zig`; update `Config` literals in `src/core/group.zig`, `src/web/review.zig`

**Interfaces:**
- `plan.Fields` gains `album_artist: ?[]const u8 = null`, `album: ?[]const u8 = null`, `track: ?u32 = null`, `artists: []const []const u8 = &.{}`.
- `config`: `pub const DEFAULT_MUSIC = "Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}";`, `Config.music_template: []const u8` (required), `Preset` gains `music`, `resolve` handles it, `parseLines` reads `music_template`/`music_preset`.
- `naming.dstFor` `.music` branch.

- [ ] **Step 1: Write the failing test** (in `naming.zig`)

```zig
test "dstFor renders a music path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .music, .{ .album_artist = "Eric Clapton", .album = "Best of Blues", .year = 1998, .track = 3, .title = "Layla", .ext = "mp3" });
    try t.expectEqualStrings("/lib/Music/Eric Clapton/Best of Blues (1998)/03 - Layla.mp3", out);
}
```
And in `config.zig`:
```zig
test "music preset + default" {
    const a = t.allocator;
    const cfg = try parseLines(a, "");
    defer freeConfig(a, cfg);
    try t.expectEqualStrings(DEFAULT_MUSIC, cfg.music_template);
}
```

- [ ] **Step 2: Run** `zig build test` — FAIL (`music_template` missing; `.music` unhandled).
- [ ] **Step 3: Implement**

  - `plan.Fields`: add the four fields.
  - `config.zig`: add `DEFAULT_MUSIC`; `Preset = struct { tv, movie, music }`; every `presetByName` return gets `.music = DEFAULT_MUSIC`; `Config` gets `music_template`; in `parseLines` add locals `music_preset`/`music_template`, read the keys, and `const music = try resolve("music", music_template, music_preset, preset);`, then `const mu = try alloc.dupe(u8, music);` and include `.music_template = mu` in the returned Config; `freeConfig` frees `music_template`.
  - `naming.dstFor`: add
    ```zig
    .music => blk: {
        const fields = [_]template.Field{
            .{ .name = "album_artist", .value = f.album_artist orelse "" },
            .{ .name = "album", .value = f.album orelse "" },
            .{ .name = "year", .value = if (f.year) |y| try u32str(arena, y) else "" },
            .{ .name = "track", .value = if (f.track) |tr| try u32str(arena, tr) else "" },
            .{ .name = "title", .value = f.title orelse "" },
            .{ .name = "ext", .value = f.ext orelse "" },
        };
        break :blk try template.renderFields(arena, cfg.music_template, &fields);
    },
    ```
  - Update every `config.Config{ … }` literal to add `.music_template = config.DEFAULT_MUSIC`:
    `src/core/naming.zig` (2 existing tests), `src/core/group.zig:~431` and `~475` (test literals), and `src/web/review.zig` `mkSession` (`.cfg = .{ …, .music_template = config.DEFAULT_MUSIC }`).

- [ ] **Step 4: Run** `zig build test` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/core/plan.zig src/core/naming.zig src/core/config.zig src/core/group.zig src/web/review.zig
git commit -m "feat(music): Fields + naming.dstFor(.music) + music_template preset"
```

---

### Task 5: `mediascore.audioScore`

**Files:** Modify `src/core/mediascore.zig`

**Interfaces:** `pub fn audioScore(lossless: bool, bitrate: ?u64, size: u64) f32` — lossless adds a large constant; then `log2(bitrate)`; then `log2(size)`.

- [ ] **Step 1: Write the failing test**

```zig
test "flac beats mp3 at equal size" {
    try t.expect(audioScore(true, 900_000, 5_000_000) > audioScore(false, 320_000, 5_000_000));
}
test "higher bitrate wins within a tier" {
    try t.expect(audioScore(false, 320_000, 4_000_000) > audioScore(false, 128_000, 4_000_000));
}
```

- [ ] **Step 2: Run** `zig build test` — FAIL.
- [ ] **Step 3: Implement**

```zig
pub fn audioScore(lossless: bool, bitrate: ?u64, size: u64) f32 {
    var s: f32 = if (lossless) 100 else 0;
    if (bitrate) |b| s += @log2(@as(f32, @floatFromInt(@max(b, 1))));
    s += @log2(@as(f32, @floatFromInt(@max(size, 1))));
    return s;
}
```

- [ ] **Step 4: Run** `zig build test` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/core/mediascore.zig && git commit -m "feat(music): audioScore for track dedup"
```

---

### Task 6: `group.zig` — parse, group by album, dedup, cover sidecar

**Files:** Modify `src/core/group.zig`

**Interfaces:** Consumes `music.parse`, `music.Track`, `mediascore.audioScore`, `naming.dstFor(.music, …)`, `plan.Fields` music fields.

Changes:
- `Cand` gains `track: ?music.Track = null` (music parse result).
- In the walk, `.music` candidates: if `inspect` → `c.track = try music.parse(arena, io, abs)`; else → `c.track = try music.fromTags(arena, .{}, base)`. Also collect album-cover image files (`cover|folder|front|albumart` + `.jpg/.jpeg/.png`) into a `covers` list of `{abs, dir}` (checked before the tv/movie classify, similar to junk/sidecar buckets).
- Group key for music: `music|{lower(album_artist)}|{lower(album)}` where `album_artist = track.album_artist orelse (first artist) orelse "Unknown Artist"`, `album = track.album orelse "Unknown Album"`. `Group.kind = .music`, `Group.title = album`. Warn on `Unknown Album`.
- Dedup within an album by `(track#, lower(title))`: keep the best by `audioScore(lossless, bitrate, size)` — `lossless = ext is "flac" or "alac"`; `bitrate`/`size` from a light stat (size via `statSize`; bitrate unknown here → pass null, size dominates). Others → duplicate/skip.
- Primary item `fields` = `{ .album_artist = resolved_album_artist, .album = resolved_album, .track = track.track, .title = track.title, .year = track.year, .artists = track.artists, .ext = track.ext }`; `dst = naming.dstFor(arena, cfg, .music, fields)`.
- Cover: for each album group, find a `covers` entry whose `dir` equals the album's tracks' source dir; attach as a `.sidecar` item with `dst = <dirname(primary dst)>/cover.<coverext>`.

- [ ] **Step 1: Write the failing test**

Build (with ffmpeg) a temp album dir: two tagged tracks (same album, one a 2-artist track), a duplicate of track 1, and a `cover.jpg`. Then:
```zig
test "buildPlan groups an album, dedups, attaches cover" {
    if (!musicFfmpeg()) return; // skip without ffmpeg
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try makeAlbumFixture(a); // helper: mkdir + ffmpeg 3 tracks + cover.jpg
    defer removeAlbumFixture(root);
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const p = try buildPlan(a, threaded.io(), root, cfg, true);
    var music_groups: usize = 0; var primaries: usize = 0; var dups: usize = 0; var covers: usize = 0;
    for (p.groups) |g| { if (g.kind == .music) music_groups += 1;
        for (g.items) |it| { if (it.role == .primary) primaries += 1; if (it.role == .duplicate) dups += 1;
            if (it.role == .sidecar and std.mem.endsWith(u8, it.dst.?, "cover.jpg")) covers += 1; } }
    try t.expectEqual(@as(usize, 1), music_groups);
    try t.expect(primaries >= 2);
    try t.expect(dups >= 1);
    try t.expectEqual(@as(usize, 1), covers);
}
```
Write `musicFfmpeg`, `makeAlbumFixture` (ffmpeg-tag 3 mp3s: `01/02` distinct titles + a 2nd copy of `01`; write a tiny `cover.jpg`), `removeAlbumFixture`.

- [ ] **Step 2: Run** `zig build test` — FAIL (arity/kind unhandled).
- [ ] **Step 3: Implement** the wiring above.
- [ ] **Step 4: Run** `zig build test && ./scripts/organize-smoke.sh` — PASS (music test green on this box; tv/movie unaffected).
- [ ] **Step 5: Commit**

```bash
git add src/core/group.zig && git commit -m "feat(music): group tracks into albums, dedup, cover sidecar"
```

---

### Task 7: music smoke + verification

**Files:** Create `scripts/music-smoke.sh`; Modify `justfile`

- [ ] **Step 1: Write `scripts/music-smoke.sh`**

Guard on `ffmpeg`. Build an album under a temp dir: `ffmpeg`-generate `t1.mp3`/`t2.mp3` tagged `album="Blue"`, `album_artist="Eric Clapton"`, `date=1998`, `title`/`track` set; drop a `cover.jpg`. `shelve organize --apply --to <lib>` (isolated XDG); assert `<lib>/Music/Eric Clapton/Blue (1998)/01 - *.mp3` exists and `cover.jpg` landed in that folder; then `shelve undo` and assert the library folder is gone. Exit non-zero on failure.

- [ ] **Step 2: Add justfile note** — extend the `organize` recipe comment: "handles TV, movies, and music". (No new recipe needed.)

- [ ] **Step 3: Run the smoke** — `zig build && ./scripts/music-smoke.sh` → passes.

- [ ] **Step 4: Full verification**

```bash
rm -rf .zig-cache zig-out && zig build && zig build test && ./scripts/smoke.sh --offline && ./scripts/organize-smoke.sh && ./scripts/review-smoke.sh && ./scripts/music-smoke.sh
```
Expected: clean build, unit, and all four smokes green.

- [ ] **Step 5: Commit**

```bash
git add scripts/music-smoke.sh justfile && git commit -m "test(music): album-layout smoke"
```

---

## Self-Review

**Spec coverage:**
- ffprobe tags → Track (artist list, album-artist, album, track#, year) → Tasks 1–2. ✓
- Classify audio → `.music` → Task 3. ✓
- `Plan.Fields` music fields + `naming.dstFor(.music)` + `music_template`/presets → Task 4. ✓
- `audioScore` dedup → Tasks 5–6. ✓
- Group by album-artist/album, Unknown fallbacks + warning, cover sidecar → Task 6. ✓
- Album-artist grouping + first-artist fallback (Eric Clapton case) → Task 6 (resolved_album_artist). ✓
- Works through existing organize/review (no new command) → Tasks 4, 6 (kind flows through). ✓
- Testing: pure splitArtists/fromTags, naming, audioScore, group golden, smoke → Tasks 1–7. ✓
- **Deferred per spec:** tag write-back (C), MusicBrainz (B), audiobooks/podcasts, transcoding.

**Placeholder scan:** Task 6 references "helper `makeAlbumFixture`" etc. — those are defined in the same task's Step 1 test (ffmpeg shell-outs), not hidden work. ffmpeg-dependent tests explicitly `return` (skip) when ffmpeg is absent. No "TBD"/"handle edge cases".

**Type consistency:** `music.Track`/`Tags` (1) consumed by `parse` (2) and `group` (6). `fromTags(alloc, Tags, basename)` and `parse(alloc, io, path)` consistent (1–2, 6). `plan.Fields` music fields (4) consumed by `naming.dstFor(.music)` (4) and set in `group` (6). `config.Config.music_template` + `DEFAULT_MUSIC` consistent across Task 4 and every literal. `audioScore(lossless, bitrate, size)` consistent (5–6). `buildPlan(…, probe_enabled)` unchanged.
