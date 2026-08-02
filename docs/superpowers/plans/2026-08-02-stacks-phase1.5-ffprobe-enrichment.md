# stacks Phase 1.5 — ffprobe enrichment + naming presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read real metadata from media files via `ffprobe` to improve dedup, flag mislabeled/corrupt files, fill/override parsed fields by confidence, and show media info in the plan — plus config-only naming presets (jellyfin/plex/kodi, global or per media type).

**Architecture:** Enrichment lives inside the existing `group.zig` walk: after parsing a file's name, probe it (`core/probe.zig`, read-only), merge by confidence (`core/enrich.zig`, pure), score with the probe (`mediascore.videoScoreProbed`), and stash media info + warnings into the `Plan`. All parse/merge logic is pure functions so tests never spawn ffprobe. Presets resolve to template strings entirely inside `config.zig`.

**Tech Stack:** Zig 0.16, `ffprobe` (optional, shelled out via existing `util/exec.zig`), `std.json` (dynamic `Value`), existing `core/plan`/`core/group`/`core/mediascore`/`core/config`.

## Global Constraints

- Zig **0.16.0**. No 0.17-only APIs. No new C dependencies.
- `ffprobe` is **optional**: absent → probing silently off; present but a file errors → `Probe{ .readable = false }` + a warning, file still organizes by its filename; malformed JSON → treat as unreadable, never crash.
- Everything here is **read-only** — never write to or remux the media files. (Write-back + subtitle muxing + DRM detection are separate future specs.)
- Command entry stays `pub fn run(ctx: cli.Context, args: []const []const u8) !u8`; exit codes `0`/`1`/`2` as today.
- `std.ArrayList(T)` starts `.empty`, takes the allocator per call. CLI uses `ctx.arena`. Tests are inline `test "…" {}` with `std.testing.allocator`; temp files under `/tmp` keyed by `std.c.getpid()` + `@import("../util/clock.zig").nowSeconds()`.
- Every new top-level module is added to `src/root.zig` (a `pub const` **and** a `_ = x;` line in its `test {}` block).
- External process calls use `exec.runCaptureStdout(alloc, io, argv, max_output)` (returns `RunResult{ stdout: []u8, exit_code: i32 }`) and `exec.isExecutableInPath(alloc, io, name) bool` from `src/util/exec.zig`.
- **Precedence for embedded tags (per field):** `authoritative` tags override the filename (and emit a warning on difference); `generic` tags only fill a field the filename left null.
- **Naming presets are config-only** (no CLI flag). Per-media-type resolution, highest wins: explicit `tv_template`/`movie_template` → `tv_preset`/`movie_preset` → global `preset` → built-in `jellyfin`. Unknown preset name → error at load.
- Preset strings (locked here):
  - **jellyfin** — TV `Shows/{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title}.{ext}` · Movie `Movies/{title} ({year})/{title} ({year}).{ext}`
  - **plex** — TV `TV Shows/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}` · Movie `Movies/{title} ({year})/{title} ({year}).{ext}`
  - **kodi** — TV `TV Shows/{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title}.{ext}` · Movie `Movies/{title} ({year})/{title} ({year}).{ext}`

## File Structure

Created:
- `src/core/probe.zig` — ffprobe wrapper: `available()`, `run()` (spawn), `parse()` (pure JSON → `Probe`), types `Probe`/`Embedded`/`Confidence`, `freeProbe()`.
- `src/core/enrich.zig` — pure merge: `mergeTv()`, `mergeMovie()` → resolved fields + warnings.

Modified:
- `src/core/mediascore.zig` — add `videoScoreProbed(height, bitrate, size)`.
- `src/core/config.zig` — `preset`/`tv_preset`/`movie_preset` keys + `PRESETS` table + resolution in `load`.
- `src/core/plan.zig` — add optional `MediaInfo` + `Item.media`.
- `src/core/group.zig` — `buildPlan(..., probe_enabled)`; probe + merge + score + media/warnings.
- `src/commands/organize.zig` — `--no-probe`; pass through; media suffix + `Warnings:` block in `printPlan`.
- `src/root.zig` — export `probe`, `enrich`.
- `scripts/organize-smoke.sh` — `--no-probe` + real-mp4 probe assertions.

---

### Task 1: `core/probe.zig` — types + `parse` (technical facts)

**Files:**
- Create: `src/core/probe.zig`
- Modify: `src/root.zig` (add `pub const probe = @import("core/probe.zig");` + `_ = probe;`)

**Interfaces:**
- Produces:
```zig
pub const Confidence = enum { none, generic, authoritative };
pub const Embedded = struct {
    series: ?[]const u8 = null,
    season: ?u32 = null,
    episode: ?u32 = null,
    title: ?[]const u8 = null,
    confidence: Confidence = .none,
};
pub const Probe = struct {
    readable: bool = true,
    vcodec: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    duration_s: ?f64 = null,
    bitrate: ?u64 = null,
    embedded: Embedded = .{},
};
/// Pure: parse ffprobe `-print_format json` output. Strings owned by `alloc`.
pub fn parse(alloc: std.mem.Allocator, json_bytes: []const u8) !Probe;
pub fn freeProbe(alloc: std.mem.Allocator, p: Probe) void;
```

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

const SCENE_MKV_JSON =
    \\{"streams":[
    \\  {"codec_type":"video","codec_name":"h264","width":1920,"height":1080},
    \\  {"codec_type":"audio","codec_name":"aac","channels":2,"tags":{"language":"jpn"}}
    \\],
    \\"format":{"duration":"1420.087000","size":"1526000000","bit_rate":"8200000","tags":{"title":"witch.hat.atelier.s01e12.mkv"}}}
;

test "parse extracts technical facts from scene mkv" {
    const a = t.allocator;
    const p = try parse(a, SCENE_MKV_JSON);
    defer freeProbe(a, p);
    try t.expect(p.readable);
    try t.expectEqualStrings("h264", p.vcodec.?);
    try t.expectEqual(@as(u32, 1920), p.width.?);
    try t.expectEqual(@as(u32, 1080), p.height.?);
    try t.expectEqual(@as(u64, 8_200_000), p.bitrate.?);
    try t.expect(p.duration_s.? > 1419 and p.duration_s.? < 1421);
}

test "parse of empty/garbage json is unreadable, not a crash" {
    const a = t.allocator;
    const p = try parse(a, "");
    defer freeProbe(a, p);
    try t.expect(!p.readable);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `parse` not defined.

- [ ] **Step 3: Write minimal implementation**

Parse into a dynamic `std.json.Value` on an internal arena (freed before return); dupe extracted strings into `alloc`. Empty/invalid input → `Probe{ .readable = false }`.

```zig
const std = @import("std");

// (types as in Interfaces above)

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn asU32(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}
fn asU64Str(v: ?std.json.Value) ?u64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}
fn asF64(v: ?std.json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
fn dupStr(alloc: std.mem.Allocator, v: ?std.json.Value) !?[]const u8 {
    const x = v orelse return null;
    if (x != .string) return null;
    return try alloc.dupe(u8, x.string);
}

pub fn parse(alloc: std.mem.Allocator, json_bytes: []const u8) !Probe {
    if (json_bytes.len == 0) return .{ .readable = false };
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_bytes, .{}) catch
        return .{ .readable = false };

    var p: Probe = .{};
    // first video stream
    if (objGet(root, "streams")) |streams| {
        if (streams == .array) {
            for (streams.array.items) |s| {
                const ct = objGet(s, "codec_type") orelse continue;
                if (ct == .string and std.mem.eql(u8, ct.string, "video")) {
                    p.vcodec = try dupStr(alloc, objGet(s, "codec_name"));
                    p.width = asU32(objGet(s, "width"));
                    p.height = asU32(objGet(s, "height"));
                    break;
                }
            }
        }
    }
    if (objGet(root, "format")) |fmt| {
        p.duration_s = asF64(objGet(fmt, "duration"));
        p.bitrate = asU64Str(objGet(fmt, "bit_rate"));
    }
    // A file with no video stream and no format is effectively unreadable.
    if (p.vcodec == null and p.duration_s == null and p.width == null) p.readable = false;
    return p;
}

pub fn freeProbe(alloc: std.mem.Allocator, p: Probe) void {
    if (p.vcodec) |x| alloc.free(x);
    if (p.embedded.series) |x| alloc.free(x);
    if (p.embedded.title) |x| alloc.free(x);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/probe.zig src/root.zig
git commit -m "feat(shelve): probe.parse — ffprobe JSON -> technical facts"
```

---

### Task 2: `core/probe.zig` — embedded tags + confidence

**Files:**
- Modify: `src/core/probe.zig`

**Interfaces:**
- Consumes: `Probe`/`Embedded`/`Confidence` (Task 1).
- Produces: `parse` now also fills `Probe.embedded`.

Rules:
- **authoritative** (TV identity): `format.tags` has `show` **and** `season_number` **and** (`episode_sort` **or** `episode_id`). Set `series`=`show`, `season`=`season_number`, `episode`=`episode_sort`/`episode_id`, `title`=`title` (if any), `confidence=.authoritative`.
- else **generic**: only a free-form `format.tags.title` (or Matroska `TITLE`) exists → `title` only, `confidence=.generic`.
- else `.none`.

- [ ] **Step 1: Write the failing test**

```zig
const ITUNES_MP4_JSON =
    \\{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080}],
    \\"format":{"duration":"1400.0","bit_rate":"5000000","tags":{
    \\  "media_type":"10","show":"Severance","season_number":"2","episode_sort":"5","title":"Goodbye, Mrs. Selvig"}}}
;
test "parse classifies iTunes tags as authoritative" {
    const a = t.allocator;
    const p = try parse(a, ITUNES_MP4_JSON);
    defer freeProbe(a, p);
    try t.expectEqual(Confidence.authoritative, p.embedded.confidence);
    try t.expectEqualStrings("Severance", p.embedded.series.?);
    try t.expectEqual(@as(u32, 2), p.embedded.season.?);
    try t.expectEqual(@as(u32, 5), p.embedded.episode.?);
    try t.expectEqualStrings("Goodbye, Mrs. Selvig", p.embedded.title.?);
}
test "parse classifies a lone title tag as generic" {
    const a = t.allocator;
    const p = try parse(a, SCENE_MKV_JSON); // has only format.tags.title
    defer freeProbe(a, p);
    try t.expectEqual(Confidence.generic, p.embedded.confidence);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — confidence is `.none`.

- [ ] **Step 3: Write minimal implementation**

In `parse`, after reading `format`, extract tags (a nested object). Add before `return p;`:

```zig
    if (objGet(root, "format")) |fmt| {
        if (objGet(fmt, "tags")) |tags| {
            const show = strTag(tags, "show");
            const snum = asU32(objGet(tags, "season_number"));
            const enum_ = asU32(objGet(tags, "episode_sort")) orelse asU32(objGet(tags, "episode_id"));
            if (show != null and snum != null and enum_ != null) {
                p.embedded = .{
                    .series = try alloc.dupe(u8, show.?),
                    .season = snum,
                    .episode = enum_,
                    .title = try dupStr(alloc, objGet(tags, "title")),
                    .confidence = .authoritative,
                };
            } else if (strTag(tags, "title") orelse strTag(tags, "TITLE")) |ti| {
                p.embedded = .{ .title = try alloc.dupe(u8, ti), .confidence = .generic };
            }
        }
    }
```

Add helper:
```zig
fn strTag(tags: std.json.Value, key: []const u8) ?[]const u8 {
    const v = objGet(tags, key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}
```
(Move the technical-facts `format` read to not double-read: keep the single `if (objGet(root,"format"))` block and read duration/bitrate/tags inside it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/probe.zig
git commit -m "feat(shelve): probe extracts embedded tags + confidence"
```

---

### Task 3: `core/probe.zig` — `available()` + `run()`

**Files:**
- Modify: `src/core/probe.zig`

**Interfaces:**
- Consumes: `exec.runCaptureStdout`, `exec.isExecutableInPath` (`src/util/exec.zig`).
- Produces:
```zig
pub fn available(alloc: std.mem.Allocator, io: std.Io) bool;
/// Spawn ffprobe on `path`; null when ffprobe missing/errored. `.readable=false`
/// when ffprobe ran but couldn't decode. Strings owned by `alloc`.
pub fn run(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?Probe;
```

- [ ] **Step 1: Write the failing test**

```zig
test "available reflects ffprobe on PATH" {
    // Cannot assert true/false portably, but it must not crash and must
    // return a bool consistent with `which`.
    const a = t.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    _ = available(a, threaded.io()); // smoke: no crash
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `available` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
const exec = @import("../util/exec.zig");

pub fn available(alloc: std.mem.Allocator, io: std.Io) bool {
    return exec.isExecutableInPath(alloc, io, "ffprobe");
}

pub fn run(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?Probe {
    const argv = [_][]const u8{
        "ffprobe", "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", path,
    };
    const r = exec.runCaptureStdout(alloc, io, &argv, 8 * 1024 * 1024) catch return null;
    defer alloc.free(r.stdout);
    if (r.exit_code != 0 or r.stdout.len == 0) return Probe{ .readable = false };
    return parse(alloc, r.stdout) catch Probe{ .readable = false };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/probe.zig
git commit -m "feat(shelve): probe.available + probe.run (ffprobe spawn)"
```

---

### Task 4: `core/enrich.zig` — pure confidence merge + warnings

**Files:**
- Create: `src/core/enrich.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Consumes: `tv.Episode`, `movie.Movie`, `probe.Probe`/`Confidence`.
- Produces:
```zig
pub const TvFields = struct {
    series: []const u8, season: u32, episode: u32,
    title: ?[]const u8, quality: ?[]const u8,
};
pub const MovieFields = struct { title: []const u8, year: ?u32, quality: ?[]const u8 };
pub const TvResult = struct { fields: TvFields, warnings: []const []const u8 };
pub const MovieResult = struct { fields: MovieFields, warnings: []const []const u8 };
pub fn mergeTv(alloc, ep: tv.Episode, p: ?probe.Probe) !TvResult;
pub fn mergeMovie(alloc, mv: movie.Movie, p: ?probe.Probe) !MovieResult;
```
Owned by `alloc`. When `p == null`, fields mirror the parsed values and `warnings` is empty.

Behavior (mergeTv):
- Start from `ep` (series/season/episode/title/quality).
- `quality`: if `p.height` present, derive tier via `qualityFromHeight` (below) and use it; else keep `ep.quality`.
- If `p.embedded.confidence == .authoritative`: override season/episode/series/title from embedded; if embedded season/episode differ from `ep`, push warning `used embedded S{d:02}E{d:02} over filename S{d:02}E{d:02}`.
- Else if `.generic` and `ep.title == null` and `p.embedded.title != null`: fill title.
- Warnings (also for movie): `!p.readable` → `unreadable (corrupt?)`; filename tier ≥1080 but real height <720 → `named {s}, actually {d}p`; duration <180 → `{d}m runtime — sample/clip?`.

Provide `pub fn qualityFromHeight(h: u32) []const u8` (`>=2160→"2160p"`, `>=1080→"1080p"`, `>=720→"720p"`, else `"480p"`).

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;
const tv = @import("../kinds/tv.zig");
const probe = @import("probe.zig");

fn ep(series: []const u8, s: u32, e: u32, title: ?[]const u8, q: ?[]const u8) tv.Episode {
    return .{ .series = series, .season = s, .episode = e, .title = title, .quality = q, .ext = "mkv" };
}

test "authoritative embedded overrides filename and warns" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .height = 1080, .embedded = .{
        .series = "Severance", .season = 2, .episode = 5, .title = "Real Title", .confidence = .authoritative } };
    const r = try mergeTv(a, ep("severance", 2, 4, null, "720p"), p);
    defer freeWarnings(a, r.warnings);
    try t.expectEqual(@as(u32, 5), r.fields.episode);
    try t.expectEqualStrings("Real Title", r.fields.title.?);
    try t.expectEqualStrings("1080p", r.fields.quality.?); // from height
    try t.expect(r.warnings.len >= 1); // episode override warned
}

test "generic embedded only fills a missing title" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .height = 1080, .embedded = .{
        .title = "From Tag", .confidence = .generic } };
    const r = try mergeTv(a, ep("show", 1, 1, null, null), p);
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("From Tag", r.fields.title.?);
    try t.expectEqual(@as(u32, 1), r.fields.episode); // filename kept
}

test "resolution mismatch warns" {
    const a = t.allocator;
    const p = probe.Probe{ .readable = true, .height = 480 };
    const r = try mergeTv(a, ep("show", 1, 1, null, "1080p"), p);
    defer freeWarnings(a, r.warnings);
    var found = false;
    for (r.warnings) |w| if (std.mem.indexOf(u8, w, "actually") != null) { found = true; };
    try t.expect(found);
}
```

Add a test-local `fn freeWarnings(a, ws)` that frees each warning + the slice.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `mergeTv` not defined.

- [ ] **Step 3: Write minimal implementation**

Implement `mergeTv`/`mergeMovie` per Behavior; collect warnings in a `std.ArrayList([]const u8)` with `std.fmt.allocPrint`. `qualityFromHeight` as specified. For "filename tier ≥1080" detect by string-prefix compare of `ep.quality` (`"1080p"`/`"2160p"`). Dup `series`/`title` into `alloc` so the result owns them.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/enrich.zig src/root.zig
git commit -m "feat(shelve): enrich — confidence merge + mislabel warnings"
```

---

### Task 5: `mediascore.videoScoreProbed`

**Files:**
- Modify: `src/core/mediascore.zig`

**Interfaces:**
- Produces: `pub fn videoScoreProbed(height: ?u32, bitrate: ?u64, size: u64) f32` — tier from real height (2160=40,1080=30,720=20,480/none=10→0), then `@log2(bitrate)` in-tier tiebreaker, then `@log2(size)`.

- [ ] **Step 1: Write the failing test**

```zig
test "probed 1080p beats filename-720p-equivalent" {
    try t.expect(videoScoreProbed(1080, 5_000_000, 1_000_000) > videoScoreProbed(720, 5_000_000, 1_000_000));
}
test "bitrate breaks ties within a tier" {
    try t.expect(videoScoreProbed(1080, 9_000_000, 1_000_000) > videoScoreProbed(1080, 3_000_000, 1_000_000));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `videoScoreProbed` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
fn heightTier(h: ?u32) f32 {
    const y = h orelse return 0;
    if (y >= 2160) return 40;
    if (y >= 1080) return 30;
    if (y >= 720) return 20;
    if (y >= 480) return 10;
    return 0;
}
pub fn videoScoreProbed(height: ?u32, bitrate: ?u64, size: u64) f32 {
    var s = heightTier(height);
    if (bitrate) |b| s += @log2(@as(f32, @floatFromInt(@max(b, 1))));
    s += @log2(@as(f32, @floatFromInt(@max(size, 1))));
    return s;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/mediascore.zig
git commit -m "feat(shelve): probe-aware videoScoreProbed"
```

---

### Task 6: `config.zig` — presets (global + per-type)

**Files:**
- Modify: `src/core/config.zig`

**Interfaces:**
- Produces: unchanged `Config` shape (resolved `tv_template`/`movie_template`); new internal keys `preset`/`tv_preset`/`movie_preset`; `pub const PresetError = error{UnknownPreset};` surfaced from `parseLines`/`load`.

- [ ] **Step 1: Write the failing test**

```zig
test "global preset resolves both, per-type overrides, explicit wins" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\preset = plex
        \\movie_preset = kodi
    );
    defer freeConfig(a, cfg);
    try t.expect(std.mem.startsWith(u8, cfg.tv_template, "TV Shows/")); // plex tv
    try t.expect(std.mem.indexOf(u8, cfg.tv_template, " - S") != null); // plex dash form
    // movie preset kodi still = Movies/...
    try t.expect(std.mem.startsWith(u8, cfg.movie_template, "Movies/"));
}
test "explicit template overrides preset" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\preset = plex
        \\tv_template = X/{series}.{ext}
    );
    defer freeConfig(a, cfg);
    try t.expectEqualStrings("X/{series}.{ext}", cfg.tv_template);
}
test "unknown preset errors" {
    try t.expectError(error.UnknownPreset, parseLines(t.allocator, "preset = nope"));
}
test "default is jellyfin" {
    const a = t.allocator;
    const cfg = try parseLines(a, "");
    defer freeConfig(a, cfg);
    try t.expectEqualStrings(DEFAULT_TV, cfg.tv_template);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — preset keys unhandled / `UnknownPreset` missing.

- [ ] **Step 3: Write minimal implementation**

Add a preset table and rework `parseLines` to a two-phase parse: first collect raw keys (`preset`, `tv_preset`, `movie_preset`, `tv_template`, `movie_template`, `library_root`), then resolve. Keep `DEFAULT_TV`/`DEFAULT_MOVIE` as the jellyfin strings (already are).

```zig
const Preset = struct { tv: []const u8, movie: []const u8 };
fn presetByName(name: []const u8) ?Preset {
    if (std.mem.eql(u8, name, "jellyfin")) return .{ .tv = DEFAULT_TV, .movie = DEFAULT_MOVIE };
    if (std.mem.eql(u8, name, "plex")) return .{
        .tv = "TV Shows/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}",
        .movie = DEFAULT_MOVIE };
    if (std.mem.eql(u8, name, "kodi")) return .{
        .tv = "TV Shows/{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title}.{ext}",
        .movie = DEFAULT_MOVIE };
    return null;
}
```

Resolution per type: `explicit template` → `presetByName(per-type preset)` → `presetByName(global preset)` → `presetByName("jellyfin")`. An unknown preset name in any of the three preset keys → `return error.UnknownPreset`. `library_root` unchanged. Keep the `~` expansion in `load`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (existing config tests still pass — they set no preset).

- [ ] **Step 5: Commit**

```bash
git add src/core/config.zig
git commit -m "feat(shelve): naming presets (global + per media type)"
```

---

### Task 7: `plan.Item.media` (additive)

**Files:**
- Modify: `src/core/plan.zig`

**Interfaces:**
- Produces:
```zig
pub const MediaInfo = struct {
    codec: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    duration_s: ?f64 = null,
};
// Item gains: media: ?MediaInfo = null,
```

- [ ] **Step 1: Write the failing test** (extend the existing round-trip test)

```zig
test "plan json round-trips media info" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = [_]Item{.{ .src = "/x/a.mkv", .role = .primary, .op = .move, .dst = "/lib/a.mkv",
        .media = .{ .codec = "h264", .width = 1920, .height = 1080, .duration_s = 1400 } }};
    var groups = [_]Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const plan = Plan{ .library_root = "/lib", .source = "/x", .groups = groups[0..] };
    const bytes = try toJson(a, plan);
    const back = try fromJson(a, bytes);
    try t.expectEqual(@as(u32, 1080), back.groups[0].items[0].media.?.height.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `media` field / `MediaInfo` missing.

- [ ] **Step 3: Write minimal implementation**

Add `MediaInfo` and `media: ?MediaInfo = null` to `Item`. `.alloc_always` is already set on `fromJson`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/plan.zig
git commit -m "feat(shelve): optional MediaInfo on plan items"
```

---

### Task 8: `group.zig` — wire probe + enrich

**Files:**
- Modify: `src/core/group.zig`

**Interfaces:**
- Consumes: `probe.available`/`probe.run`, `enrich.mergeTv`/`mergeMovie`, `mediascore.videoScoreProbed`, `plan.MediaInfo`.
- Produces: `pub fn buildPlan(arena, io, dir_path, cfg, probe_enabled: bool) !plan.Plan` (new trailing param).

Changes:
- `Cand` gains `probe: ?probe.Probe = null` and `warnings: []const []const u8 = &.{}`.
- Compute `const do_probe = probe_enabled and probe.available(arena, io);` once.
- Per tv/movie candidate: if `do_probe`, `c.probe = probe.run(arena, io, abs)`; run `enrich.mergeTv/mergeMovie` and use the **merged fields** for grouping key, dedup, and dst; store `c.warnings`.
- Dedup: when `c.probe` present, score with `mediascore.videoScoreProbed(c.probe.?.height, c.probe.?.bitrate, c.size)`, else `mediascore.videoScore(quality, c.size)`.
- Primary item: set `media` from `c.probe` (codec/width/height/duration).
- Group: append each candidate's warnings to `gb.warnings` (dedupe-free; simple concat).

- [ ] **Step 1: Write the failing test**

```zig
test "buildPlan probe_enabled=false keeps prior behavior (regression)" {
    // reuse the existing fixture-tree helpers
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = ... // same synthetic tree as the existing buildPlan test
    defer ...;
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE };
    const p = try buildPlan(a, threaded.io(), root, cfg, false);
    // same assertions as before: 1 tv group, primaries>=2, dups>=1, trash>=1
}
```

Update the **existing** buildPlan test call to pass `false` as the new arg.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — arity mismatch on `buildPlan`.

- [ ] **Step 3: Write minimal implementation**

Add the param + wiring. Keep the merged-fields path minimal: build a small local `Fields { series, season, episode, title, quality }` for tv (from `enrich.mergeTv` when probing, else straight from `c.ep`), and use it in the grouping key + `tvDst`. Same for movie.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/group.zig
git commit -m "feat(shelve): group wires ffprobe enrichment (opt-out) into plan"
```

---

### Task 9: `organize.zig` — `--no-probe` + richer output

**Files:**
- Modify: `src/commands/organize.zig`

**Interfaces:**
- Consumes: `group.buildPlan(..., probe_enabled)`, `plan.MediaInfo`, group warnings.
- Produces: `Opts` gains `no_probe: bool`; `printPlan` shows media suffix + a `Warnings:` block.

Changes:
- parseArgs: `--no-probe` → `o.no_probe = true`.
- run: `const probe_enabled = !opts.no_probe;` and pass to `buildPlan`. (When `--from`, skip probing — the plan already carries media info.)
- printPlan: when the item behind a kept `dst` has `media`, append `   · {codec} {height}p · {duration}m`. Also print a `Warnings:` section listing `group.warnings` before the summary. (printPlan already receives the `Plan`; media is on the item, warnings on the group.)

- [ ] **Step 1: Write the failing test**

```zig
test "parseArgs --no-probe" {
    const o = try parseArgs((&[_][]const u8{ "/x", "--no-probe" })[0..]);
    try std.testing.expect(o.no_probe);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `no_probe` field missing.

- [ ] **Step 3: Write minimal implementation**

Add the field + flag + wiring. In `printPlan`, since it currently iterates `keep` as `dst` strings, extend it to iterate items (carry the `Item` so `media` is reachable) — keep the folder-grouping + sort by building a small `{dst, media}` array and sorting by `dst`. Format duration minutes as `@round(duration_s/60)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/commands/organize.zig
git commit -m "feat(shelve): --no-probe + media info & warnings in plan output"
```

---

### Task 10: smoke — probe path end-to-end

**Files:**
- Modify: `scripts/organize-smoke.sh`

- [ ] **Step 1: Add probe assertions**

After the existing checks, add a block that only runs when `ffprobe`/`ffmpeg` exist:

```bash
if command -v ffprobe >/dev/null && command -v ffmpeg >/dev/null; then
    echo "== probe =="
    PSRC="$TMP/psrc"; mkdir -p "$PSRC"
    ffmpeg -v error -f lavfi -i testsrc=d=1:s=1280x720 -y "$PSRC/Test.Show.S01E01.720p.mkv"
    OUT2="$("$SHELVE" organize "$PSRC" --to "$TMP/plib" --dry-run)"
    check "probe shows media info" 'grep -qE "· .*720" <<<"$OUT2"'
    check "no-probe suppresses media info" '! "$SHELVE" organize "$PSRC" --to "$TMP/plib" --dry-run --no-probe | grep -qE "· .*720"'
fi
```

- [ ] **Step 2: Run the smoke**

Run: `zig build && ./scripts/organize-smoke.sh`
Expected: all checks pass (incl. probe block on this dev box).

- [ ] **Step 3: Full verification + commit**

Run: `zig build test && ./scripts/smoke.sh --offline && ./scripts/organize-smoke.sh`
Expected: unit + biblio smoke + organize smoke all green.

```bash
git add scripts/organize-smoke.sh
git commit -m "test(shelve): smoke covers ffprobe media-info + --no-probe"
```

---

## Self-Review

**Spec coverage:**
- ffprobe run/parse (technical + embedded + confidence) → Tasks 1–3. ✓
- Confidence-based merge + mislabel/corrupt warnings → Task 4. ✓
- Better dedup via probe → Task 5 + Task 8. ✓
- Fill/override embedded → Task 4 + Task 8. ✓
- Media info in plan → Task 7 (schema) + Task 9 (display). ✓
- Auto-on with `--no-probe` → Task 9; `available()` gate → Tasks 3, 8. ✓
- Presets global + per-type, config-only, jellyfin default, unknown-errors → Task 6. ✓
- Optional `ffprobe`, graceful absence, never crash on bad JSON → Tasks 1, 3, 8. ✓
- Testing incl. smoke with real mp4 → Task 10. ✓
- **Deferred (not in this plan, per spec):** write-back/tag-embed, subtitle muxing, DRM detection.

**Placeholder scan:** Task 8's test sketch reuses "the existing fixture-tree helpers / same synthetic tree" — the implementer copies the helper calls already present in `group.zig`'s current buildPlan test (it's in the same file, in view); the only real change there is passing `false`. Not a hidden requirement. No "TBD"/"handle edge cases".

**Type consistency:** `probe.Probe`/`Embedded`/`Confidence` (Tasks 1–3) used verbatim in enrich (4), group (8). `enrich.mergeTv/mergeMovie` return `TvResult`/`MovieResult` consumed in group (8). `mediascore.videoScoreProbed(height, bitrate, size)` consistent between Task 5 and Task 8. `plan.MediaInfo{codec,width,height,duration_s}` consistent between Task 7 and Task 9. `config` keeps `tv_template`/`movie_template` field names (Task 6) that group (8) already reads. `buildPlan(..., probe_enabled)` signature consistent between Task 8 and the Task 9 caller.
