# stacks Phase 1 — Media Organizer (TV + Movies) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `shelve organize <dir>` workflow that scans a messy media folder, groups/classifies TV & movie files, and produces a reviewable, reversible plan to move them into a templated library — then rename the project to `stacks` (lib) + `biblio` (book binary) + `shelve` (organizer binary).

**Architecture:** New additive modules on the existing library (`core/kind`, `core/classify`, `kinds/tv`, `kinds/movie`, `core/mediascore`, `core/plan`, `core/config`, `core/group`, `core/journal`, `core/apply`) plus two new commands (`organize`, `undo`) exposed through a new `shelve` binary that links the same library module as today's binary. The serializable `Plan` (JSON) is the contract every surface shares. The rename is done **last**, guarded by a green test suite.

**Tech Stack:** Zig 0.16 (managed by mise), SQLite/libmobi/libxml2 (unchanged, not touched by this phase), `std.Io` filesystem APIs, `std.json`.

## Global Constraints

- Zig **0.16.0**. Do not use 0.17-only APIs. (`build.zig.zon` `minimum_zig_version = "0.16.0"`.)
- Do **not** add new C dependencies (roadmap is to remove them).
- Command entry signature is always `pub fn run(ctx: cli.Context, args: []const []const u8) !u8`; exit codes: `0` success, `1` bad args / empty result, `2` I/O or external-tool failure.
- Allocation: thread `std.mem.Allocator` explicitly. `std.ArrayList(T)` starts `.empty` and takes the allocator on every call (`.append(alloc, x)`, `.toOwnedSlice(alloc)`, `.deinit(alloc)`). CLI commands use `ctx.arena` (freed wholesale by `main`).
- Tests live **inline** in each source file as `test "..." { ... }` using `std.testing.allocator`. Temp files go under `/tmp` keyed by `std.c.getpid()` + `@import("util/clock.zig").nowSeconds()` for uniqueness, `unlink`ed via `defer`.
- Every new top-level module must be added to `src/root.zig` (both a `pub const` and a line in its `test { }` block) so `zig build test` compiles and runs its tests.
- **No hard deletes.** "Removing" a file means moving it into a trash dir; every mutation is recorded in an undo journal.
- Zig 0.16 filesystem idioms (copy from `src/commands/scan.zig`): `std.Io.Dir.cwd()`, `cwd.openDir(ctx.io, path, .{ .iterate = true })`, `dir.walk(arena)`, `while (try walker.next(ctx.io)) |entry|`, `std.fs.path.join(alloc, &.{ a, b })`, `std.fs.path.extension(name)`. Moves use `std.c.rename` with the EXDEV copy-fallback from `src/core/standardize.zig` (`copyAcrossDevices`, `mkdirParents`).

## File Structure

Created this phase:
- `src/core/kind.zig` — `MediaKind` enum + release-noise token stripping.
- `src/core/classify.zig` — path/basename → `MediaKind`.
- `src/kinds/tv.zig` — TV episode filename parser.
- `src/kinds/movie.zig` — movie filename parser.
- `src/core/mediascore.zig` — kind-agnostic "best copy" comparator (video quality + size).
- `src/core/plan.zig` — `Plan`/`Group`/`Item` model + JSON (de)serialize.
- `src/core/config.zig` — library root + per-kind templates from a config file.
- `src/core/group.zig` — build a `Plan` from a directory (classify → parse → group → dedup → template).
- `src/core/journal.zig` — undo-journal read/write.
- `src/core/apply.zig` — execute a `Plan` (move/trash) + reverse from a journal.
- `src/commands/organize.zig` — the `organize` command.
- `src/commands/undo.zig` — the `undo` command.
- `src/shelve_main.zig`, `src/shelve_cli.zig` — the `shelve` binary entrypoint + dispatcher.
- `scripts/organize-smoke.sh` — end-to-end smoke.

Modified:
- `src/core/template.zig` — add `renderFields` for media templates (reuses `sanitize`).
- `src/root.zig` — export the new modules.
- `build.zig` — add the second executable + its test step.
- Rename sweep (Task 13): `build.zig`, `build.zig.zon`, `src/main.zig`, `src/shelve_main.zig`, `src/cli.zig`, `README.md`, `CLAUDE.md`, docs.

---

### Task 1: `core/kind.zig` — MediaKind + release-noise stripping

**Files:**
- Create: `src/core/kind.zig`
- Modify: `src/root.zig` (add `pub const kind = @import("core/kind.zig");` and `_ = kind;` in `test`)

**Interfaces:**
- Produces: `pub const MediaKind = enum { ebook, comic, movie, tv, game, document, unknown };`
- Produces: `pub fn cleanName(alloc: std.mem.Allocator, raw: []const u8) ![]u8` — strips `www.*` prefixes, `[...]`/`(...)` tag groups, and release/quality/codec/group tokens (`1080p`, `720p`, `web`, `web-dl`, `webdl`, `bluray`, `x264`, `h264`, `h`, `264`, `ddp2`, `hevc`, `cr`, `dual`, `-<group>` suffix after a known token), converts `.`/`_` separators to spaces, collapses whitespace, trims. Returns an owned lowercased-preserving cleaned string.

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

test "cleanName strips site prefix, tokens, and dotted separators" {
    const a = t.allocator;
    const out = try cleanName(a, "witch.hat.atelier.s01e12.1080p.web.h264-skyanime[EZTVx.to]");
    defer a.free(out);
    try t.expectEqualStrings("witch hat atelier s01e12", out);
}

test "cleanName strips UIndex wrapper and codec noise" {
    const a = t.allocator;
    const out = try cleanName(a, "www.UIndex.org    -    Witch Hat Atelier S01E04 Meetings in Kalhn 1080p CR WEB-DL DUAL DDP2 0 H 264-Kitsune");
    defer a.free(out);
    try t.expectEqualStrings("Witch Hat Atelier S01E04 Meetings in Kalhn", out);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `cleanName` is not defined.

- [ ] **Step 3: Write minimal implementation**

Implement `MediaKind` and `cleanName`. Approach: (a) drop a leading `www.<...>` run up to the first ` - ` / `-` delimiter; (b) tokenize on whitespace/`.`/`_`; (c) drop tokens that are bracket groups or match a case-insensitive noise set (`NOISE = .{ "1080p","720p","480p","2160p","4k","web","webdl","web-dl","bluray","bdrip","hdtv","x264","x265","h264","h265","hevc","h","264","265","cr","dual","ddp2","ddp5","aac","0" }`), and drop a trailing `-<group>` token and anything after the first noise token that is clearly release trailer (keep this conservative: stop dropping once you hit end); (d) join remaining tokens with single spaces and trim. Preserve original case of kept tokens. Keep `SxxExx`/`sNNeNN` tokens (they are NOT noise — the TV parser needs them; the first test keeps `s01e12`, the second keeps the descriptive title but drops trailing quality — implement by: once you encounter the first noise token *after* an `SxxExx` token, drop the remainder).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/kind.zig src/root.zig
git commit -m "feat(organize): MediaKind enum + release-noise name cleaner"
```

---

### Task 2: `core/classify.zig` — path → MediaKind

**Files:**
- Create: `src/core/classify.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Consumes: `kind.MediaKind` (Task 1).
- Produces: `pub fn classify(basename: []const u8, is_dir: bool) kind.MediaKind` — deterministic rules on extension + filename signals.

Rules (first match wins):
- Junk basenames (`.DS_Store`, `Thumbs.db`, `.nfo`, `.srt`, `.sub`, `.ass`) → return `.unknown` (handled separately as junk/sidecar by the grouper; classify only decides media kind for media files).
- Video extension (`.mkv`, `.mp4`, `.avi`, `.m4v`, `.mov`, `.wmv`, `.ts`): if the basename matches an `SxxExx`/`sNNeNN`/`NxNN` season-episode pattern → `.tv`, else → `.movie`.
- Ebook ext (`.epub`,`.mobi`,`.azw3`) → `.ebook`; comic ext (`.cbz`,`.cbr`,`.cb7`,`.cbt`) → `.comic`; `.pdf` → `.document`.
- Game ext (`.nes`,`.sfc`,`.smc`,`.gba`,`.gb`,`.gbc`,`.n64`,`.z64`,`.iso`,`.chd`,`.rom`) → `.game`.
- Doc ext (`.pdf` already; `.txt`,`.docx`,`.md`) → `.document`.
- Else → `.unknown`.

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;
const kind = @import("kind.zig");

test "classify detects tv from SxxExx video file" {
    try t.expectEqual(kind.MediaKind.tv, classify("witch.hat.atelier.s01e12.1080p.web.h264-skyanime.mkv", false));
}
test "classify detects movie from plain video file" {
    try t.expectEqual(kind.MediaKind.movie, classify("Blade Runner 2049 (2017) 1080p.mkv", false));
}
test "classify routes ebook and pdf" {
    try t.expectEqual(kind.MediaKind.ebook, classify("book.epub", false));
    try t.expectEqual(kind.MediaKind.document, classify("paper.pdf", false));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `classify` not defined.

- [ ] **Step 3: Write minimal implementation**

Write `classify`. Add a private `hasSeasonEpisode(name) bool` helper that scans for `s`/`S` followed by 1–2 digits then `e`/`E` then 1–2 digits (also accept `1x12`). Extension comparison via `std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".mkv")` etc.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/classify.zig src/root.zig
git commit -m "feat(organize): media-kind classifier"
```

---

### Task 3: `kinds/tv.zig` — TV episode parser

**Files:**
- Create: `src/kinds/tv.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Consumes: `kind.cleanName` (Task 1).
- Produces:
```zig
pub const Episode = struct {
    series: []const u8,      // owned by caller's allocator, cleaned
    season: u32,
    episode: u32,
    title: ?[]const u8 = null, // episode title if recoverable, else null
    quality: ?[]const u8 = null, // e.g. "1080p" if present in raw name
    ext: []const u8,          // extension without dot
};
pub fn parse(alloc: std.mem.Allocator, basename: []const u8) !?Episode;
```
`parse` returns `null` when no `SxxExx` can be found. `series` is everything before the `SxxExx` token, run through `cleanName`. `title` is the text after the `SxxExx` token with trailing quality/release noise removed (empty → null). `quality` is the first `\d+p` token if present.

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

test "parse dotted skyanime name" {
    const a = t.allocator;
    const ep = (try parse(a, "witch.hat.atelier.s01e12.1080p.web.h264-skyanime.mkv")).?;
    defer freeEpisode(a, ep);
    try t.expectEqualStrings("witch hat atelier", ep.series);
    try t.expectEqual(@as(u32, 1), ep.season);
    try t.expectEqual(@as(u32, 12), ep.episode);
    try t.expectEqualStrings("1080p", ep.quality.?);
}

test "parse UIndex descriptive name keeps episode title" {
    const a = t.allocator;
    const ep = (try parse(a, "Witch Hat Atelier S01E04 Meetings in Kalhn 1080p CR WEB-DL DUAL DDP2 0 H 264-Kitsune.mkv")).?;
    defer freeEpisode(a, ep);
    try t.expectEqualStrings("Witch Hat Atelier", ep.series);
    try t.expectEqual(@as(u32, 4), ep.episode);
    try t.expectEqualStrings("Meetings in Kalhn", ep.title.?);
}

test "parse returns null without season-episode marker" {
    const a = t.allocator;
    try t.expect((try parse(a, "just a movie (2020).mkv")) == null);
}
```

Provide a `fn freeEpisode(a, ep)` test helper that frees `series`, and (if non-null) `title`, `quality`, `ext`.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `parse` not defined.

- [ ] **Step 3: Write minimal implementation**

Locate the `SxxExx` span (reuse the same scanner shape as `classify.hasSeasonEpisode`, but return the byte range and parsed season/episode). Split `stem = basename without extension` into `before` and `after` around that span. `series = try kind.cleanName(alloc, before)`. For `title`: run the `after` text through a title-cleaner that converts separators to spaces and stops at the first release/quality noise token (reuse the noise set from `kind.zig` — expose it as `pub const NOISE` there and import it). `quality`: scan tokens for one matching `\d+p`. `ext = std.fs.path.extension(basename)` without the dot, `alloc.dupe`'d.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/kinds/tv.zig src/core/kind.zig src/root.zig
git commit -m "feat(organize): TV episode filename parser"
```

---

### Task 4: `kinds/movie.zig` — movie parser

**Files:**
- Create: `src/kinds/movie.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Consumes: `kind.cleanName`, `kind.NOISE`.
- Produces:
```zig
pub const Movie = struct {
    title: []const u8,      // cleaned, owned
    year: ?u32 = null,
    quality: ?[]const u8 = null,
    ext: []const u8,
};
pub fn parse(alloc: std.mem.Allocator, basename: []const u8) !Movie;
```
`title` is everything before the first `(YYYY)` or bare 19xx/20xx year token (or the whole stem if no year), cleaned. `year` is that 4-digit token if present (1900–2099).

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

test "parse movie with parenthesized year" {
    const a = t.allocator;
    const m = try parse(a, "Blade Runner 2049 (2017) 1080p BluRay x264.mkv");
    defer freeMovie(a, m);
    try t.expectEqualStrings("Blade Runner 2049", m.title);
    try t.expectEqual(@as(u32, 2017), m.year.?);
}

test "parse dotted movie without parens" {
    const a = t.allocator;
    const m = try parse(a, "The.Matrix.1999.1080p.mkv");
    defer freeMovie(a, m);
    try t.expectEqualStrings("The Matrix", m.title);
    try t.expectEqual(@as(u32, 1999), m.year.?);
}
```

Note: "Blade Runner 2049 (2017)" is the classic trap — `2049` is part of the title, `2017` is the year. Resolve by preferring a **parenthesized** year; only if none exists, take the **last** standalone 4-digit year token as the year and everything before it as the title.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `parse` not defined.

- [ ] **Step 3: Write minimal implementation**

Strip extension. Search for `(YYYY)`; if found, `year` = inside, `title` = text before `(`. Else tokenize (split on space/`.`/`_`) and find the **last** token that is a bare 4-digit 1900–2099; `year` = it, `title` = tokens before it. Clean the title via `kind.cleanName`. `quality` = first `\d+p` token. `ext` dup'd.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/kinds/movie.zig src/root.zig
git commit -m "feat(organize): movie filename parser"
```

---

### Task 5: `core/mediascore.zig` — best-copy comparator

**Files:**
- Create: `src/core/mediascore.zig`
- Modify: `src/root.zig`

**Rationale:** `core/quality.zig` / `core/score.zig` score `catalog.Book` (ISBN/series/format) — book-specific and not reusable for video. This is the honest media equivalent.

**Interfaces:**
- Produces: `pub fn videoScore(quality: ?[]const u8, size: u64) f32` — quality tier rank (2160p=40, 1080p=30, 720p=20, 480p=10, null=0) plus `@log2(@max(size,1))`.

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

test "1080p beats 720p at equal size" {
    try t.expect(videoScore("1080p", 1_000_000) > videoScore("720p", 1_000_000));
}
test "larger file breaks ties within a tier" {
    try t.expect(videoScore("1080p", 10_000_000) > videoScore("1080p", 1_000_000));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `videoScore` not defined.

- [ ] **Step 3: Write minimal implementation**

Implement `videoScore` with a small `tierScore(?[]const u8) f32` inner switch on the quality string.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/mediascore.zig src/root.zig
git commit -m "feat(organize): video best-copy scoring"
```

---

### Task 6: `template.renderFields` — generic media templating

**Files:**
- Modify: `src/core/template.zig` (add a new public function; do not change existing `render`)
- Test: inline in `src/core/template.zig`

**Interfaces:**
- Produces:
```zig
pub const Field = struct { name: []const u8, value: []const u8 };
/// Render `template` substituting `{name}` / `{name:0N}` from `fields`.
/// Numeric zero-padding (`{season:02}`) applies when the value is all digits.
/// Missing fields render empty (adjacent " - " / " / " collapse, reusing the
/// same cleanup path as `render`). Values are sanitized like `render`.
pub fn renderFields(alloc: std.mem.Allocator, template: []const u8, fields: []const Field) ![]u8;
```

- [ ] **Step 1: Write the failing test**

```zig
test "renderFields builds a TV path with zero-padding" {
    const alloc = test_alloc;
    const fields = [_]Field{
        .{ .name = "series", .value = "Witch Hat Atelier" },
        .{ .name = "season", .value = "1" },
        .{ .name = "episode", .value = "12" },
        .{ .name = "title", .value = "The Shadow of Romonon" },
        .{ .name = "ext", .value = "mkv" },
    };
    const out = try renderFields(alloc, "TV/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("TV/Witch Hat Atelier/Season 01/Witch Hat Atelier - S01E12 - The Shadow of Romonon.mkv", out);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `renderFields` not defined.

- [ ] **Step 3: Write minimal implementation**

Mirror `render`'s placeholder scan but resolve each `{field[:spec]}` from the `fields` slice (linear search). Reuse the existing private `sanitize` and `collapseSpaces` (same file, so they're in scope). Zero-pad: if `spec` is `0N` and the looked-up value is all ASCII digits and shorter than N, left-pad with `'0'`. Unknown field → render empty (so `collapseSpaces` tidies separators). Do **not** call `IncompleteMetadata` logic — media fields differ from book metadata.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/template.zig
git commit -m "feat(organize): generic renderFields for media templates"
```

---

### Task 7: `core/plan.zig` — Plan model + JSON round-trip

**Files:**
- Create: `src/core/plan.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Consumes: `kind.MediaKind`.
- Produces:
```zig
pub const Role = enum { primary, sidecar, duplicate, junk };
pub const Op = enum { move, copy, trash, skip };
pub const Item = struct {
    src: []const u8,
    role: Role,
    op: Op,
    dst: ?[]const u8 = null, // null for trash/skip
    reason: []const u8 = "",
};
pub const Group = struct {
    kind: kind.MediaKind,
    title: []const u8,
    year: ?u32 = null,
    items: []Item,
    warnings: []const []const u8 = &.{},
};
pub const Plan = struct {
    library_root: []const u8,
    source: []const u8,
    groups: []Group,
    unclassified: []const []const u8 = &.{},
};
pub fn toJson(alloc: std.mem.Allocator, plan: Plan) ![]u8;
pub fn fromJson(alloc: std.mem.Allocator, bytes: []const u8) !Plan; // arena-backed; caller owns via arena
```

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;
const kind = @import("kind.zig");

test "plan json round-trips group and item shape" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var items = [_]Item{.{ .src = "/x/a.mkv", .role = .primary, .op = .move, .dst = "/lib/TV/Show/Season 01/Show - S01E01.mkv", .reason = "" }};
    var groups = [_]Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const plan = Plan{ .library_root = "/lib", .source = "/x", .groups = groups[0..] };

    const bytes = try toJson(a, plan);
    const back = try fromJson(a, bytes);
    try t.expectEqual(@as(usize, 1), back.groups.len);
    try t.expectEqual(kind.MediaKind.tv, back.groups[0].kind);
    try t.expectEqualStrings("/x/a.mkv", back.groups[0].items[0].src);
    try t.expectEqualStrings("/lib/TV/Show/Season 01/Show - S01E01.mkv", back.groups[0].items[0].dst.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `toJson`/`fromJson` not defined.

- [ ] **Step 3: Write minimal implementation**

Implement with `std.json`. Verify the exact 0.16 signatures before writing (`zig std` docs): serialize with `std.json.Stringify`/`std.json.stringify(value, .{}, writer)` into an `std.ArrayList(u8)` writer; parse with `std.json.parseFromSlice(Plan, alloc, bytes, .{})` and return `.value` (enums serialize as their tag names by default — the test asserts that works). If the 0.16 JSON API cannot map the enums directly, fall back to a hand-written serializer/parser over the same struct shape; keep the public `toJson`/`fromJson` signatures identical either way.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/plan.zig src/root.zig
git commit -m "feat(organize): Plan model with JSON round-trip"
```

---

### Task 8: `core/config.zig` — library root + templates

**Files:**
- Create: `src/core/config.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Produces:
```zig
pub const Config = struct {
    library_root: []const u8,   // default: "$HOME/Media"
    tv_template: []const u8,    // default below
    movie_template: []const u8, // default below
};
pub const DEFAULT_TV = "TV/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}";
pub const DEFAULT_MOVIE = "Movies/{title} ({year})/{title} ({year}).{ext}";
/// Load $XDG_CONFIG_HOME/booktool/config.toml (key = value lines). Missing
/// file → all defaults. Unknown keys ignored. All strings owned by `alloc`.
pub fn load(alloc: std.mem.Allocator, env: *std.process.Environ.Map) !Config;
```
Config file format is simple `key = value` lines (no TOML dependency): keys `library_root`, `tv_template`, `movie_template`; `#` comment lines and blanks ignored.

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

test "parseLines overrides only provided keys" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\# my config
        \\library_root = /Volumes/Media
        \\tv_template = TV/{series}/{title}.{ext}
    );
    defer freeConfig(a, cfg);
    try t.expectEqualStrings("/Volumes/Media", cfg.library_root);
    try t.expectEqualStrings("TV/{series}/{title}.{ext}", cfg.tv_template);
    try t.expectEqualStrings(DEFAULT_MOVIE, cfg.movie_template);
}
```

Expose an internal `fn parseLines(alloc, text) !Config` that `load` calls after reading the file (so the parser is testable without touching disk). `freeConfig` frees the three strings.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `parseLines` not defined.

- [ ] **Step 3: Write minimal implementation**

`parseLines`: start from defaults (`alloc.dupe` each default), split on `\n`, for each line trim, skip empty/`#`, split on first `=`, trim both sides, match key, replace the corresponding owned string. `load`: resolve `$XDG_CONFIG_HOME` (fallback `$HOME/.config`) + `/booktool/config.toml`, read file if present (`std.Io` read or `std.fs`), pass to `parseLines`; on `FileNotFound` return defaults. `$HOME` for the `library_root` default via `env.get("HOME")`.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/config.zig src/root.zig
git commit -m "feat(organize): config loader for library root + templates"
```

---

### Task 9: `core/group.zig` — build a Plan from a directory

**Files:**
- Create: `src/core/group.zig`
- Modify: `src/root.zig`

**Interfaces:**
- Consumes: `classify.classify`, `tv.parse`, `movie.parse`, `mediascore.videoScore`, `template.renderFields`, `config.Config`, `plan.*`.
- Produces:
```zig
pub fn buildPlan(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    cfg: config.Config,
) !plan.Plan;
```
Algorithm:
1. Walk `dir_path` recursively (scan.zig pattern). For each **file** entry, record `{ abs_path, basename, size }` (stat for size).
2. Classify each. `.tv`/`.movie` → parse. Junk basenames (`.DS_Store`, `Thumbs.db`, `sample`/`sample.*`, `.txt` under 2KB named like `readme`) → junk list. Sidecars (`.nfo`,`.srt`,`.sub`,`.ass`) → held to attach later.
3. Group `.tv` items by `(series_lowercased, season)`; within a season group by `episode`, choosing the highest `videoScore(quality,size)` as `role=.primary` (op `move`), the rest `role=.duplicate` (op `skip`, reason `"duplicate of primary"`). Group `.movie` items by `(title_lowercased, year)`, best copy primary.
4. Attach a sidecar to the episode/movie whose stem it shares (same directory + same stem prefix) as `role=.sidecar` (op `move`, dst = primary's dst with the sidecar's extension).
5. Junk files and now-empty wrapper dirs → a single synthetic group `{ kind=.unknown, title="junk", items=[trash…] }` (op `trash`, dst null).
6. Compute each primary's `dst` = `std.fs.path.join(arena, &.{ cfg.library_root, renderFields(tv_or_movie_template, fields) })`.
7. Files that classified `.unknown` and aren't junk → `plan.unclassified`.

- [ ] **Step 1: Write the failing test**

Create a fixture tree under `/tmp` in the test (episodes in two naming styles for the same show, a `.DS_Store`, and a `.nfo` sidecar), then:

```zig
const std = @import("std");
const t = std.testing;
const config = @import("config.zig");

test "buildPlan groups a season, dedups, trashes junk, attaches nfo" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try makeFixtureTree(a); // helper: creates the dir, returns its path
    defer removeTree(root);

    const cfg = config.Config{
        .library_root = "/lib",
        .tv_template = config.DEFAULT_TV,
        .movie_template = config.DEFAULT_MOVIE,
    };
    const p = try buildPlan(a, testIo(), root, cfg);

    // one TV group for the show
    var tv_groups: usize = 0;
    for (p.groups) |g| { if (g.kind == .tv) tv_groups += 1; }
    try t.expectEqual(@as(usize, 1), tv_groups);

    // S01E04 has two source copies -> exactly one primary
    var primaries: usize = 0;
    var dups: usize = 0;
    for (p.groups) |g| for (g.items) |it| {
        if (it.role == .primary) primaries += 1;
        if (it.role == .duplicate) dups += 1;
    };
    try t.expect(primaries >= 1);
    try t.expect(dups >= 1);

    // at least one trash op for the .DS_Store
    var trashed: usize = 0;
    for (p.groups) |g| for (g.items) |it| { if (it.op == .trash) trashed += 1; };
    try t.expect(trashed >= 1);
}
```

Write `makeFixtureTree`, `removeTree`, and a `testIo()` helper (obtain a `std.Io` for tests — check how existing tests get one; if tests can't easily get `std.Io`, restructure `buildPlan` to take a `std.Io.Dir` already opened, and open it in the helper). Keep filenames drawn from the real Witch Hat examples.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `buildPlan` not defined.

- [ ] **Step 3: Write minimal implementation**

Implement the 7-step algorithm. Use small local structs and `std.ArrayList`. Lowercase keys for grouping via a stack buffer + `std.ascii.lowerString`. For "empty wrapper dir" detection, after assigning files, a directory is trashable only if every file under it was itself trashed/moved — for v1 keep it simple: only trash the explicit junk basenames and leave dirs (note this limitation in a code comment and in the smoke script). Attach sidecars by matching directory + stem.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/group.zig src/root.zig
git commit -m "feat(organize): directory -> Plan builder (group, dedup, junk, sidecars)"
```

---

### Task 10: `core/journal.zig` + `core/apply.zig` — apply & undo

**Files:**
- Create: `src/core/journal.zig`, `src/core/apply.zig`
- Modify: `src/root.zig`

**Interfaces (`journal.zig`):**
```zig
pub const Action = enum { move, trash };
pub const Entry = struct { action: Action, from: []const u8, to: []const u8 };
pub const Journal = struct { created: i64, entries: []Entry };
pub fn dir(alloc, env) ![]u8;              // $XDG_DATA_HOME/booktool/undo
pub fn write(alloc, env, j: Journal) ![]u8; // returns the journal file path
pub fn latest(alloc, env) !?[]u8;           // newest journal file path or null
pub fn load(alloc, path: []const u8) !Journal;
```
**Interfaces (`apply.zig`):**
```zig
pub const OnConflict = enum { skip, suffix, overwrite };
pub const Result = struct { moved: u32, trashed: u32, skipped: u32, journal_path: []const u8 };
pub fn apply(alloc, plan_v: plan.Plan, on_conflict: OnConflict, env) !Result;
pub fn undo(alloc, j: journal.Journal) !void; // reverse entries last-to-first
```
Behavior: `apply` iterates groups/items; `move`/`copy`/`sidecar` → mkdir dst parent + `std.c.rename` (EXDEV fallback from `standardize.zig`), on existing dst honor `on_conflict`; `trash` → move into `<library_root>/.stacks-trash/<created>/<basename>` (recorded as `Action.trash`); `skip`/`duplicate` → do nothing. Every executed move/trash appends a `journal.Entry`. Journal written even on partial failure so `undo` can roll back. `undo` reverses each entry `to`→`from` (recreating parent dirs), last-to-first.

Reuse `mkdirParents` and `copyAcrossDevices` from `standardize.zig` — either import them (make them `pub` there) or copy into a shared `util/fsmove.zig`. Prefer making them `pub` in `standardize.zig` and importing; note this small edit.

- [ ] **Step 1: Write the failing test** (in `apply.zig`)

```zig
const std = @import("std");
const t = std.testing;
const plan = @import("plan.zig");
const journal = @import("journal.zig");

test "apply moves a primary and undo restores it" {
    const a = t.allocator;
    // build a real temp file
    const src = try tmpPath(a, "src.mkv"); defer a.free(src);
    const dst = try tmpPath(a, "out/Show - S01E01.mkv"); defer a.free(dst);
    try writeFile(src, "video");
    defer std.fs.deleteFileAbsolute(src) catch {};
    defer std.fs.deleteTreeAbsolute(std.fs.path.dirname(dst).?) catch {};

    var items = [_]plan.Item{.{ .src = src, .role = .primary, .op = .move, .dst = dst }};
    var groups = [_]plan.Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const p = plan.Plan{ .library_root = "/tmp", .source = "/tmp", .groups = groups[0..] };

    const res = try applyInMemory(a, p, .skip); // test variant that returns the Journal instead of writing to XDG
    try t.expect(fileExists(dst));
    try t.expect(!fileExists(src));

    try undo(a, res.journal);
    try t.expect(fileExists(src));
    try t.expect(!fileExists(dst));
}
```

To keep the test off the user's real XDG dir, factor the move/trash loop into `fn applyInMemory(alloc, plan, on_conflict) !struct{ journal: journal.Journal, ... }` that does the filesystem work and returns the in-memory journal; the public `apply` calls `applyInMemory` then `journal.write`. Add `tmpPath`, `writeFile`, `fileExists` helpers.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `applyInMemory`/`undo` not defined.

- [ ] **Step 3: Write minimal implementation**

Implement `journal.zig` (JSON via the Task 7 approach) and `apply.zig`. Make `standardize.mkdirParents` and `standardize.copyAcrossDevices` `pub` and import them.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/journal.zig src/core/apply.zig src/core/standardize.zig src/root.zig
git commit -m "feat(organize): apply plans + undo journal"
```

---

### Task 11: `commands/organize.zig` + `commands/undo.zig`

**Files:**
- Create: `src/commands/organize.zig`, `src/commands/undo.zig`

**Interfaces:**
- Consumes: `config.load`, `group.buildPlan`, `plan.toJson`/`fromJson`, `apply.apply`, `journal.latest`/`load`, `apply.undo`.
- Produces: `pub fn run(ctx: cli.Context, args: []const []const u8) !u8` in each.

`organize` args:
- positional `<dir>` (required unless `--from` given).
- `--to <lib>` override `cfg.library_root`.
- `--apply` execute (default: dry-run).
- `--plan <file>` write plan JSON to file.
- `--from <file>` load a plan from JSON instead of building one (skips scan; used by TUI/Web later).
- `--on-conflict skip|suffix|overwrite` (default `skip`).
Dry-run prints a human summary: per group, the destination of each primary, `[dup]`/`[junk]`/`[sidecar]` markers, and a footer `groups=N move=N trash=N dup=N unclassified=N`. `--apply` prints the same then applies and prints the `Result` + journal path.

`undo`: no positional args; resolves `journal.latest`, loads it, calls `apply.undo`, prints how many entries reversed. Exit `1` if no journal exists.

- [ ] **Step 1: Write the failing test**

These are command wrappers; cover them via the smoke script (Task 12/Task…). Add one inline unit test in `organize.zig` for the arg parser only:

```zig
test "parseArgs reads flags" {
    const args = [_][]const u8{ "/downloads/show", "--to", "/lib", "--apply", "--on-conflict", "suffix" };
    const opts = try parseArgs(args[0..]);
    try std.testing.expectEqualStrings("/downloads/show", opts.dir.?);
    try std.testing.expectEqualStrings("/lib", opts.to.?);
    try std.testing.expect(opts.apply);
}
```

Factor an internal `fn parseArgs(args) !Opts` (with `Opts{ dir: ?[]const u8, to: ?[]const u8, apply: bool, plan_out: ?[]const u8, from: ?[]const u8, on_conflict: apply.OnConflict }`).

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `parseArgs` not defined.

- [ ] **Step 3: Write minimal implementation**

Implement `parseArgs`, then `run` for both commands wiring the core modules. Follow `scan.zig` for `ctx` usage, error printing, and exit codes.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/commands/organize.zig src/commands/undo.zig
git commit -m "feat(organize): organize + undo commands"
```

---

### Task 12: `shelve` binary + build wiring + smoke

**Files:**
- Create: `src/shelve_main.zig`, `src/shelve_cli.zig`, `scripts/organize-smoke.sh`
- Modify: `build.zig`, `src/root.zig`

**Interfaces:**
- `shelve_cli.run(ctx: booktool.cli.Context) !u8` — dispatcher over `organize`, `undo`, `help`, `version`. (Mirror `cli.zig`.)
- `root.zig` exports `pub const shelve_cli = @import("shelve_cli.zig");` so tests compile.

- [ ] **Step 1: Write `shelve_main.zig` and `shelve_cli.zig`**

`shelve_main.zig` copies `main.zig` verbatim but calls `booktool.shelve_cli.run(...)`. `shelve_cli.zig` copies the `cli.zig` `Context`/`run` shape, importing only `organize` and `undo` commands, with its own `printUsage`.

- [ ] **Step 2: Add the second executable to `build.zig`**

After the existing `exe`/`installArtifact(exe)` block, add:

```zig
    // ---- Second executable: the media organizer -----------------------
    const shelve_exe = b.addExecutable(.{
        .name = "shelve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shelve_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "booktool", .module = booktool_mod },
            },
        }),
    });
    b.installArtifact(shelve_exe);

    const shelve_run_step = b.step("run-shelve", "Run shelve");
    const shelve_run_cmd = b.addRunArtifact(shelve_exe);
    shelve_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| shelve_run_cmd.addArgs(args);
    shelve_run_step.dependOn(&shelve_run_cmd.step);
```

And add its tests to the existing test step:

```zig
    const shelve_tests = b.addTest(.{ .root_module = shelve_exe.root_module });
    test_step.dependOn(&b.addRunArtifact(shelve_tests).step);
```

- [ ] **Step 3: Build both binaries**

Run: `zig build 2>&1 | tail -20`
Expected: builds `./zig-out/bin/booktool` **and** `./zig-out/bin/shelve`.

- [ ] **Step 4: Write `scripts/organize-smoke.sh` and run it**

Script: make a temp source tree reproducing the Witch Hat mix (two naming styles for a couple episodes + a `.DS_Store` + a `.nfo`), point `--to` at a temp library, run dry-run and assert the plan footer counts, run `--apply`, assert the expected files exist at their templated paths under the temp library and `.DS_Store` landed in `.stacks-trash`, then run `shelve undo` and assert the source tree is restored. Isolate `XDG_DATA_HOME`/`XDG_CONFIG_HOME` to temp dirs (as `smoke.sh` already does). Exit non-zero on any failed assertion.

Run: `./scripts/organize-smoke.sh`
Expected: all assertions pass.

- [ ] **Step 5: Run full test suite + commit**

Run: `zig build test && ./scripts/smoke.sh --offline && ./scripts/organize-smoke.sh`
Expected: existing 66 tests still pass; both smokes pass.

```bash
git add build.zig src/shelve_main.zig src/shelve_cli.zig src/root.zig scripts/organize-smoke.sh
git commit -m "feat(organize): shelve binary, build wiring, end-to-end smoke"
```

---

### Task 13: Rename booktool → stacks / biblio / shelve

Done **last**, with the full green suite as a safety net. Purely mechanical; no behavior change.

**Files:** `build.zig`, `build.zig.zon`, `src/main.zig`, `src/shelve_main.zig`, `src/root.zig`, `src/cli.zig`, `src/shelve_cli.zig`, `README.md`, `CLAUDE.md`, `docs/*`.

- [ ] **Step 1: Rename the library module and book binary in `build.zig`**

In `build.zig`: change `b.addModule("booktool", …)` → `b.addModule("stacks", …)`; the book executable `.name = "booktool"` → `.name = "biblio"`; every import `.{ .name = "booktool", .module = booktool_mod }` → `.{ .name = "stacks", .module = stacks_mod }` (rename the local `booktool_mod` var to `stacks_mod` too, in both executables). Update the comment cluster names to `stacks`.

- [ ] **Step 2: Update `.zon` and entrypoint imports**

`build.zig.zon`: `.name = .booktool` → `.name = .stacks`. In `src/main.zig` and `src/shelve_main.zig`: `const booktool = @import("booktool");` → `const stacks = @import("stacks");` and update all `booktool.` references to `stacks.`.

- [ ] **Step 3: Update XDG paths, env var, and usage strings**

Change the catalog/journal/config path segment `booktool` → `stacks` in `catalog.defaultPath`, `journal.dir`, and `config.load` (so state lives at `$XDG_DATA_HOME/stacks/…` and `$XDG_CONFIG_HOME/stacks/…`). Change `BOOKTOOL_DEBUG` → `STACKS_DEBUG` in `main.zig`/`shelve_main.zig`. Update the version strings (`booktool 0.0.0` → `biblio 0.0.0`, `shelve 0.0.0`) and the `printUsage` banners.

- [ ] **Step 4: Update docs and scripts**

`README.md`, `CLAUDE.md`, `docs/*`, and `scripts/smoke.sh`'s `BOOKTOOL="$ROOT/zig-out/bin/booktool"` → `BIBLIO="$ROOT/zig-out/bin/biblio"` (and references). Reword the top-line description from "manage an ebook library" split across the two binaries.

- [ ] **Step 5: Full verification + commit**

Run: `rm -rf .zig-cache zig-out && zig build && zig build test && ./scripts/smoke.sh --offline && ./scripts/organize-smoke.sh`
Expected: clean build produces `biblio` + `shelve`; all tests and both smokes pass.

```bash
git add -A
git commit -m "refactor: rename project to stacks (lib) + biblio (books) + shelve (organizer)"
```

---

## Self-Review

**Spec coverage** (against `2026-07-28-stacks-media-organizer-design.md`):
- Project structure (shared lib + `biblio` + `shelve`, no umbrella) → Tasks 12–13. ✓
- Pipeline `classify → parse → group → plan → apply+journal` → Tasks 2, 3–4, 9, 7, 10. ✓
- `core/kind` release-token stripping → Task 1. ✓
- Per-kind parsers (TV, Movies this phase; games/docs are Phase 2, noted) → Tasks 3–4. ✓
- Dedup / best-copy → Task 5 + Task 9 step 3. Note: spec said "reuse quality/score"; those are book-specific, so this plan adds `mediascore` instead and says so. ✓ (deviation documented)
- Templates + config → Tasks 6, 8. ✓
- Plan JSON contract → Task 7; consumed by `--plan`/`--from` in Task 11 (the TUI/Web hook, built in Phase 3). ✓
- Apply model: move-into-library, trash-not-delete, undo journal, conflict policy → Tasks 10–11. ✓
- CLI surface `organize`/`undo` with dry-run default → Task 11. ✓
- Testing: parser unit tests, classifier truth-table, planner golden, e2e smoke+undo → Tasks 1–5, 9, 12. ✓
- **Deferred to later phases (explicitly out of scope here):** games/documents parsers (Phase 2), TUI/Web review (Phase 3), online providers TMDB/TVDB/IGDB (Phase 4), catalog `kind` column (only needed once `scan`/library-tracking consumes organize output — not required for the `organize` flow, which is filesystem-based). The catalog is intentionally untouched this phase to keep `biblio` risk-free.

**Placeholder scan:** No "TBD"/"implement later". The two places that say "verify the exact 0.16 API" (JSON in Tasks 7/10) are honest version caveats with a concrete fallback, not deferred work.

**Type consistency:** `plan.Item.op`/`role` enums used consistently across Tasks 7, 9, 10, 11. `apply.OnConflict` shared by Tasks 10–11. `config.Config` field names (`library_root`, `tv_template`, `movie_template`) consistent across Tasks 8, 9, 11. `kind.MediaKind`/`kind.NOISE` shared by Tasks 1–4. `tv.Episode`/`movie.Movie` field names consistent with their use in Task 9.
