# Music A.1 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `shelve` music organizing correct on real, messy libraries: one folder per album (multi-disc sets rolled up with `CD{disc}` subfolders), Various-Artists inference, no `()`/`(0)` year suffix, and Latin-1 tags transcoded to UTF-8.

**Architecture:** Add pure, unit-testable helpers to `kinds/music.zig` (`toUtf8`, `discFromDirName`, `albumMeta`, disc-tag reading); teach `core/template.zig` to drop an empty ` ()`; add an optional `disc` to `plan.Fields` and a `CD{disc}/` splice in `core/naming.zig`; rewrite the music path in `core/group.zig` to group by **album source directory** with disc detection and consensus metadata. Tag-path behavior is validated by the real-binary `music-smoke.sh`; disc/layout logic that doesn't need tags is also covered by a no-probe unit test.

**Tech Stack:** Zig 0.16 (via mise). No new dependencies. ffprobe optional (already gated).

## Global Constraints

- Zig 0.16 only — no 0.17 APIs (project builds with the mise-pinned 0.16.0).
- Read-only reorg: move/rename into the library; never mutate source files' bytes. (Tag write-back is Music C, out of scope.)
- ffprobe cannot spawn under the test `std.Io.Threaded` io — so any behavior that needs *tags* is tested via `scripts/music-smoke.sh` (real binary), not the unit suite. Logic that needs only paths/filenames is unit-tested no-probe.
- All organizer code is arena-allocated; the caller owns the arena.
- Default music template (unchanged): `Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}` (`config.DEFAULT_MUSIC`).
- Commit trailer on every commit:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Build: `zig build`. Unit tests: `zig build test`. Music smoke: `./scripts/music-smoke.sh`.

---

## File Structure

- `src/kinds/music.zig` — add `Tags.disc`, `Track.disc`; read disc tag in `parse`; transcode tags + zero-year handling in `fromTags`; new pure helpers `toUtf8`, `discFromDirName`, `albumMeta` (+ `AlbumMeta`). (Tasks 1, 2)
- `src/core/template.zig` — `collapseSpaces` drops a leftover ` ()`. (Task 3)
- `src/core/plan.zig` — `Fields` gains `disc: ?u32 = null`. (Task 4)
- `src/core/naming.zig` — `.music` branch splices `CD{disc}/` when `f.disc` is set. (Task 4)
- `src/core/group.zig` — `Cand` gains `album_dir`/`disc`; walk computes them; Phase B keys music by album dir; music dedup uses `albumMeta` + disc-aware keys; cover attach handles disc subfolders. (Task 5)
- `scripts/music-smoke.sh` — add 2-CD, Various-Artists, and no-year fixtures/assertions. (Task 6)
- `todo.md`, memory file — mark A.1 done. (Task 6)

---

## Task 1: Music tag hardening — disc tag, zero-year, UTF-8 transcode, discFromDirName

**Files:**
- Modify: `src/kinds/music.zig` (`Tags`, `Track`, `parse`, `fromTags`; add `toUtf8`, `discFromDirName`)
- Test: `src/kinds/music.zig` (in-file `test` blocks)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Tags.disc: ?[]const u8`, `Track.disc: ?u32`
  - `pub fn toUtf8(alloc: std.mem.Allocator, s: []const u8) ![]u8`
  - `pub fn discFromDirName(name: []const u8) ?u32`
  - `fromTags` now transcodes title/artist/album/album_artist via `toUtf8`, sets `disc`, and maps year `0` → `null`.

- [ ] **Step 1: Write the failing tests**

Add these tests at the bottom of `src/kinds/music.zig` (after the existing tests):

```zig
test "toUtf8 passes through valid UTF-8 and transcodes Latin-1" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Already-valid UTF-8 is returned unchanged.
    try t.expectEqualStrings("Café", try toUtf8(a, "Café"));
    // Latin-1 0xE9 ('é') → UTF-8 C3 A9.
    const latin1 = [_]u8{ 'C', 'o', 'm', 'm', 'u', 'n', 'i', 'q', 'u', 0xE9 };
    try t.expectEqualStrings("Communiqué", try toUtf8(a, &latin1));
}

test "discFromDirName parses disc subfolder names" {
    try t.expectEqual(@as(?u32, 1), discFromDirName("CD 1"));
    try t.expectEqual(@as(?u32, 1), discFromDirName("CD1"));
    try t.expectEqual(@as(?u32, 1), discFromDirName("cd 01"));
    try t.expectEqual(@as(?u32, 2), discFromDirName("Disc 2"));
    try t.expectEqual(@as(?u32, 3), discFromDirName("Disk 3"));
    try t.expectEqual(@as(?u32, null), discFromDirName("Season 1"));
    try t.expectEqual(@as(?u32, null), discFromDirName("Discography"));
    try t.expectEqual(@as(?u32, null), discFromDirName("Blue"));
}

test "fromTags reads disc, drops zero year, transcodes latin-1 tags" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const latin1_album = [_]u8{ 'C', 'o', 'm', 'm', 'u', 'n', 'i', 'q', 'u', 0xE9 };
    const tr = try fromTags(a, .{ .title = "T", .album = &latin1_album, .track = "5", .disc = "2/2", .date = "0" }, "05 t.mp3");
    try t.expectEqual(@as(u32, 2), tr.disc.?);
    try t.expectEqual(@as(?u32, null), tr.year); // date "0" is not a real year
    try t.expectEqualStrings("Communiqué", tr.album.?);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `toUtf8`/`discFromDirName` undefined, and `Tags`/`Track` have no `disc` field.

- [ ] **Step 3: Add the `disc` fields and pure helpers**

In `src/kinds/music.zig`, add `disc` to `Tags` (after `track`):

```zig
pub const Tags = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?[]const u8 = null,
    disc: ?[]const u8 = null,
    date: ?[]const u8 = null,
};
```

Add `disc` to `Track` (after `track`):

```zig
pub const Track = struct {
    title: ?[]const u8 = null,
    artists: []const []const u8 = &.{},
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
    year: ?u32 = null,
    ext: []const u8,
};
```

Add the two pure helpers just above `fromTags`:

```zig
/// Transcode a tag value to UTF-8. Valid UTF-8 is duped unchanged; otherwise
/// the bytes are treated as Latin-1 (each byte → a codepoint) and re-encoded,
/// so a mis-encoded tag never yields invalid UTF-8. Owned by `alloc`.
pub fn toUtf8(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return alloc.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        if (b < 0x80) {
            try out.append(alloc, b);
        } else {
            try out.append(alloc, 0xC0 | (b >> 6));
            try out.append(alloc, 0x80 | (b & 0x3F));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Disc number from a source subfolder name: "CD 1"/"CD1"/"Disc 2"/"Disk 3"
/// (case-insensitive) → n; anything else → null.
pub fn discFromDirName(name: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (name.len == 0 or name.len >= buf.len) return null;
    const lo = std.ascii.lowerString(buf[0..name.len], name);
    const prefixes = [_][]const u8{ "disc", "disk", "cd" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, lo, p)) {
            const rest = std.mem.trim(u8, lo[p.len..], " _-");
            if (rest.len == 0) return null;
            for (rest) |c| if (!std.ascii.isDigit(c)) return null;
            return std.fmt.parseInt(u32, rest, 10) catch null;
        }
    }
    return null;
}
```

- [ ] **Step 4: Wire disc + transcode + zero-year into `fromTags` and `parse`**

Replace the body of `fromTags` (keep the signature) with:

```zig
pub fn fromTags(alloc: std.mem.Allocator, tags: Tags, basename: []const u8) !Track {
    const ext_dot = std.fs.path.extension(basename);
    const ext = try alloc.dupe(u8, if (ext_dot.len > 0) ext_dot[1..] else ext_dot);
    const stem = basename[0 .. basename.len - ext_dot.len];
    return .{
        .title = try toUtf8(alloc, tags.title orelse stem),
        .artists = if (tags.artist) |ar| try splitArtists(alloc, try toUtf8(alloc, ar)) else &.{},
        .album_artist = if (tags.album_artist) |x| try toUtf8(alloc, x) else null,
        .album = if (tags.album) |x| try toUtf8(alloc, x) else null,
        .track = if (tags.track) |x| firstInt(x) else null,
        .disc = if (tags.disc) |x| firstInt(x) else null,
        .year = blk: {
            const v = if (tags.date) |x| firstInt(x) else null;
            break :blk if (v) |n| (if (n == 0) null else n) else null;
        },
        .ext = ext,
    };
}
```

In `parse`, add the disc tag read to the `Tags{...}` literal (after `.track`):

```zig
        .track = tagStr(tagsv, "track"),
        .disc = tagStr(tagsv, "disc") orelse tagStr(tagsv, "discnumber"),
        .date = tagStr(tagsv, "date"),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (all music tests green, including the three new ones).

- [ ] **Step 6: Commit**

```bash
git add src/kinds/music.zig
git commit -m "feat(music): disc tag, zero-year drop, Latin-1 transcode, discFromDirName

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: albumMeta — consensus album/artist/year with Various-Artists fallback

**Files:**
- Modify: `src/kinds/music.zig` (add `AlbumMeta`, `albumMeta`)
- Test: `src/kinds/music.zig`

**Interfaces:**
- Consumes: `Track` (from Task 1).
- Produces:
  - `pub const AlbumMeta = struct { album: []const u8, album_artist: []const u8, year: ?u32 }`
  - `pub fn albumMeta(alloc: std.mem.Allocator, tracks: []const Track, folder_name: []const u8) !AlbumMeta`

- [ ] **Step 1: Write the failing tests**

Add to `src/kinds/music.zig`:

```zig
test "albumMeta: album_artist tag wins" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tracks = [_]Track{
        .{ .album = "Blue", .album_artist = "Eric Clapton", .artists = &.{"Eric Clapton"}, .year = 1998, .ext = "mp3" },
        .{ .album = "Blue", .album_artist = "Eric Clapton", .artists = &.{"Session Band"}, .year = 1998, .ext = "mp3" },
    };
    const m = try albumMeta(a, &tracks, "Some Folder");
    try t.expectEqualStrings("Blue", m.album);
    try t.expectEqualStrings("Eric Clapton", m.album_artist);
    try t.expectEqual(@as(u32, 1998), m.year.?);
}

test "albumMeta: all-same artist, no album_artist" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tracks = [_]Track{
        .{ .album = "X", .artists = &.{"Solo"}, .ext = "mp3" },
        .{ .album = "X", .artists = &.{"Solo"}, .ext = "mp3" },
    };
    const m = try albumMeta(a, &tracks, "Folder");
    try t.expectEqualStrings("Solo", m.album_artist);
}

test "albumMeta: differing artists, no album_artist -> Various Artists" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tracks = [_]Track{
        .{ .album = "Comp", .artists = &.{"Alice"}, .ext = "mp3" },
        .{ .album = "Comp", .artists = &.{"Bob"}, .ext = "mp3" },
    };
    const m = try albumMeta(a, &tracks, "Folder");
    try t.expectEqualStrings("Various Artists", m.album_artist);
}

test "albumMeta: no tags -> folder name album, Unknown Artist, no year" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tracks = [_]Track{ .{ .ext = "mp3" }, .{ .ext = "mp3" } };
    const m = try albumMeta(a, &tracks, "My Folder");
    try t.expectEqualStrings("My Folder", m.album);
    try t.expectEqualStrings("Unknown Artist", m.album_artist);
    try t.expectEqual(@as(?u32, null), m.year);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `albumMeta`/`AlbumMeta` undefined.

- [ ] **Step 3: Implement `albumMeta`**

Add above the `const t = std.testing;` line in `src/kinds/music.zig`:

```zig
pub const AlbumMeta = struct {
    album: []const u8,
    album_artist: []const u8,
    year: ?u32,
};

/// Consensus album metadata over a folder's tracks. `album` = first non-empty
/// album tag, else `folder_name` (else "Unknown Album"). `album_artist` = a
/// present album_artist tag; else the shared primary artist if all tracks agree;
/// else "Various Artists" when they differ; else "Unknown Artist" when no track
/// carries an artist. `year` = first non-zero year. Strings owned by `alloc`.
pub fn albumMeta(alloc: std.mem.Allocator, tracks: []const Track, folder_name: []const u8) !AlbumMeta {
    var album: []const u8 = if (folder_name.len > 0) folder_name else "Unknown Album";
    for (tracks) |tr| if (tr.album) |al| if (al.len > 0) {
        album = al;
        break;
    };

    var album_artist: []const u8 = undefined;
    var found_aa = false;
    for (tracks) |tr| if (tr.album_artist) |aa| if (aa.len > 0) {
        album_artist = aa;
        found_aa = true;
        break;
    };
    if (!found_aa) {
        var common: ?[]const u8 = null;
        var all_same = true;
        var any = false;
        for (tracks) |tr| {
            if (tr.artists.len == 0) continue;
            any = true;
            const a0 = tr.artists[0];
            if (common) |c| {
                if (!std.ascii.eqlIgnoreCase(c, a0)) all_same = false;
            } else common = a0;
        }
        if (!any) {
            album_artist = "Unknown Artist";
        } else if (all_same) {
            album_artist = common.?;
        } else {
            album_artist = "Various Artists";
        }
    }

    var year: ?u32 = null;
    for (tracks) |tr| if (tr.year) |y| if (y != 0) {
        year = y;
        break;
    };

    return .{
        .album = try alloc.dupe(u8, album),
        .album_artist = try alloc.dupe(u8, album_artist),
        .year = year,
    };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/kinds/music.zig
git commit -m "feat(music): albumMeta consensus with Various-Artists fallback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Template — drop an empty ` ()` year suffix

**Files:**
- Modify: `src/core/template.zig` (`collapseSpaces`)
- Test: `src/core/template.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces: `renderFields`/`render` output no longer contains a ` ()` left by an empty `{year}` between literal parens.

- [ ] **Step 1: Write the failing test**

Add to `src/core/template.zig` (near the other `renderFields` tests):

```zig
test "renderFields drops empty parenthesized year" {
    const alloc = test_alloc;
    const fields = [_]Field{
        .{ .name = "album_artist", .value = "Solo" },
        .{ .name = "album", .value = "NoYear" },
        .{ .name = "year", .value = "" },
        .{ .name = "track", .value = "1" },
        .{ .name = "title", .value = "Song" },
        .{ .name = "ext", .value = "mp3" },
    };
    const out = try renderFields(alloc, "Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("Music/Solo/NoYear/01 - Song.mp3", out);
}

test "renderFields drops empty year before extension" {
    const alloc = test_alloc;
    const fields = [_]Field{
        .{ .name = "title", .value = "The Matrix" },
        .{ .name = "year", .value = "" },
        .{ .name = "ext", .value = "mkv" },
    };
    const out = try renderFields(alloc, "Movies/{title} ({year})/{title} ({year}).{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("Movies/The Matrix/The Matrix.mkv", out);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — output still contains ` ()` (e.g. `NoYear ()` / `The Matrix ()`).

- [ ] **Step 3: Add a ` ()` stripping case to `collapseSpaces`**

In `src/core/template.zig`, inside `collapseSpaces`, the `stripped` pass is a `while` loop matching leading slices of `unslashed.items[i..]`. Add a case at the **top** of that loop body (before the `/ - ` case), so ` ()` (space + empty parens) is removed entirely:

```zig
        const s = unslashed.items[i..];
        if (s.len >= 3 and s[0] == ' ' and s[1] == '(' and s[2] == ')') {
            i += 3;
            continue;
        }
        if (s.len >= 4 and s[0] == '/' and std.mem.eql(u8, s[0..4], "/ - ")) {
```

(The rest of the loop is unchanged — this just inserts the first `if` block.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS. Existing template/naming tests stay green (they never emit a ` ()`; the music path test still yields `Best of Blues (1998)`).

- [ ] **Step 5: Commit**

```bash
git add src/core/template.zig
git commit -m "feat(template): drop empty parenthesized year suffix

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Fields.disc + naming splices CD{disc}/ for multi-disc albums

**Files:**
- Modify: `src/core/plan.zig` (`Fields`)
- Modify: `src/core/naming.zig` (`.music` branch)
- Test: `src/core/naming.zig`

**Interfaces:**
- Consumes: `plan.Fields` (from all prior tasks), `config.DEFAULT_MUSIC`.
- Produces: `Fields.disc: ?u32 = null`; `naming.dstFor(.., .music, f)` inserts `CD{f.disc}/` before the track filename when `f.disc != null`.

- [ ] **Step 1: Write the failing test**

Add to `src/core/naming.zig`:

```zig
test "dstFor renders a multi-disc music path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const out = try dstFor(a, cfg, .music, .{ .album_artist = "V/A", .album = "Night of the Kings", .year = 1992, .disc = 2, .track = 3, .title = "Layla", .ext = "flac" });
    try t.expectEqualStrings("/lib/Music/VA/Night of the Kings (1992)/CD2/03 - Layla.flac", out);
}
```

(Note: `V/A` sanitizes/collapses to `VA` via the existing template sanitizer — this also confirms the splice runs after rendering.)

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `Fields` has no `disc` field (compile error).

- [ ] **Step 3: Add `disc` to `plan.Fields`**

In `src/core/plan.zig`, add to the music section of `Fields` (after `track`):

```zig
    // music
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
    artists: []const []const u8 = &.{},
```

- [ ] **Step 4: Splice `CD{disc}/` in `naming.dstFor`**

In `src/core/naming.zig`, replace the `.music => blk: { ... }` branch with:

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
            const base_rel = try template.renderFields(arena, cfg.music_template, &fields);
            if (f.disc) |d| {
                if (std.mem.lastIndexOfScalar(u8, base_rel, '/')) |slash| {
                    break :blk try std.fmt.allocPrint(arena, "{s}/CD{d}/{s}", .{ base_rel[0..slash], d, base_rel[slash + 1 ..] });
                }
            }
            break :blk base_rel;
        },
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS. The existing single-disc `dstFor renders a music path` test stays green (disc null → no splice).

- [ ] **Step 6: Commit**

```bash
git add src/core/plan.zig src/core/naming.zig
git commit -m "feat(naming): Fields.disc + CD{disc} splice for multi-disc albums

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: group.zig — album-source-folder grouping, disc detection, consensus meta

**Files:**
- Modify: `src/core/group.zig` (`Cand`, Phase A walk, Phase B music key + music dedup block, Phase C2 cover attach)
- Test: `src/core/group.zig` (no-probe multi-disc test)

**Interfaces:**
- Consumes: `music.discFromDirName`, `music.albumMeta`, `plan.Fields.disc`, `naming.dstFor(.music, ..)` (Tasks 1,2,4).
- Produces: music groups keyed by album source directory; multi-disc albums emit `CD{disc}/` destinations; consensus album/artist/year; covers land at the album root.

- [ ] **Step 1: Write the failing test**

Add to `src/core/group.zig` (after the existing music group test):

```zig
test "buildPlan rolls CD subfolders into one multi-disc album (no-probe)" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pid = std.c.getpid();
    var rb: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/stacks-disc-{d}", .{pid});
    mkdirAt("{s}", .{root});
    mkdirAt("{s}/CD 1", .{root});
    mkdirAt("{s}/CD 2", .{root});
    try writeFileAt("{s}/CD 1/01 song one.mp3", .{root}, "aaa");
    try writeFileAt("{s}/CD 2/01 song two.mp3", .{root}, "bbbb");

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const p = try buildPlan(a, threaded.io(), root, cfg, false); // no probe: disc comes from folder names

    var music_groups: usize = 0;
    var primaries: usize = 0;
    var cd1 = false;
    var cd2 = false;
    for (p.groups) |g| {
        if (g.kind != .music) continue;
        music_groups += 1;
        for (g.items) |it| {
            if (it.role != .primary) continue;
            primaries += 1;
            const dst = it.dst orelse "";
            if (std.mem.indexOf(u8, dst, "/CD1/") != null) cd1 = true;
            if (std.mem.indexOf(u8, dst, "/CD2/") != null) cd2 = true;
        }
    }
    try t.expectEqual(@as(usize, 1), music_groups); // both discs → one album
    try t.expectEqual(@as(usize, 2), primaries);
    try t.expect(cd1);
    try t.expect(cd2);

    unlinkAt("{s}/CD 1/01 song one.mp3", .{root});
    unlinkAt("{s}/CD 2/01 song two.mp3", .{root});
    rmdirAt("{s}/CD 1", .{root});
    rmdirAt("{s}/CD 2", .{root});
    rmdirAt("{s}", .{root});
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — currently the two discs form two "Unknown Album" groups and destinations have no `/CD1/`. (Compile also fails once you reference `album_dir`/`disc` before adding them — that's fine, iterate.)

- [ ] **Step 3: Add `album_dir` + `disc` to `Cand`**

In `src/core/group.zig`, add to the `Cand` struct (after `fields`):

```zig
    fields: ?plan.Fields = null,
    album_dir: ?[]const u8 = null,
    disc: ?u32 = null,
```

- [ ] **Step 4: Compute album_dir + disc in the Phase A walk**

Replace the music branch in the walk (`if (mk == .music) { ... }`) with:

```zig
        if (mk == .music) {
            const c = try arena.create(Cand);
            c.* = .{ .abs = abs, .dir = d, .stem = stem, .size = statSize(io, abs), .mkind = .music };
            c.track = if (inspect) try music.parse(arena, io, abs) else try music.fromTags(arena, .{}, base);
            const parent_base = std.fs.path.basename(d);
            const sub_disc = music.discFromDirName(parent_base);
            c.disc = c.track.?.disc orelse sub_disc;
            // A "CD N"/"Disc N" subfolder rolls up to its parent album dir.
            c.album_dir = if (sub_disc != null) (std.fs.path.dirname(d) orelse d) else d;
            try media.append(arena, c);
        } else if (mk == .tv or mk == .movie) {
```

- [ ] **Step 5: Key music groups by album_dir in Phase B**

In the Phase B key `switch`, replace the `.music` arm:

```zig
            .music => try std.fmt.allocPrint(arena, "mu|{s}", .{c.album_dir.?}),
```

The group-creation `gtitle`/`gyear` switch still references `musicAlbum(c)` / `c.track.?.year`; leave those as provisional placeholders — the music dedup block below overwrites `gb.title`/`gb.year` with consensus values. (No change needed there.)

- [ ] **Step 6: Rewrite the music dedup block with albumMeta + disc keys**

Replace the entire music `else` block inside the `for (gbs.items, 0..) |*gb, gi|` loop (the block starting with the comment `// Music: one album; dedup by (track#, title) ...`) with:

```zig
        } else {
            // Music: one album per source folder. Consensus album/artist/year
            // (Various-Artists fallback); dedup by (disc, track#, title).
            var tracks = try arena.alloc(music.Track, cands.items.len);
            for (cands.items, 0..) |c, i| tracks[i] = c.track.?;
            const folder_name = std.fs.path.basename(cands.items[0].album_dir.?);
            const meta = try music.albumMeta(arena, tracks, folder_name);

            var distinct = std.AutoHashMap(u32, void).init(arena);
            for (cands.items) |c| if (c.disc) |dn| try distinct.put(dn, {});
            const multi = distinct.count() > 1;

            gb.title = meta.album;
            gb.year = meta.year;

            var best = std.StringHashMap(*Cand).init(arena);
            for (cands.items) |c| {
                const dkey: u32 = if (multi) (c.disc orelse 1) else 0;
                const tk = try std.fmt.allocPrint(arena, "{d}|{?d}|{s}", .{ dkey, c.track.?.track, try lower(arena, c.track.?.title orelse "") });
                const gop = try best.getOrPut(tk);
                if (!gop.found_existing or audioScoreOf(c) > audioScoreOf(gop.value_ptr.*)) gop.value_ptr.* = c;
            }
            var it = best.valueIterator();
            while (it.next()) |cp| {
                const f = plan.Fields{
                    .album_artist = meta.album_artist,
                    .album = meta.album,
                    .year = meta.year,
                    .track = cp.*.track.?.track,
                    .title = cp.*.track.?.title,
                    .artists = cp.*.track.?.artists,
                    .ext = cp.*.track.?.ext,
                    .disc = if (multi) (cp.*.disc orelse 1) else null,
                };
                cp.*.fields = f;
                cp.*.dst = try naming.dstFor(arena, cfg, .music, f);
            }
            if (std.mem.eql(u8, meta.album, "Unknown Album")) try gb.warnings.append(arena, "untagged — filed under Unknown Album");
            for (cands.items) |c| {
                const dkey: u32 = if (multi) (c.disc orelse 1) else 0;
                const tk = try std.fmt.allocPrint(arena, "{d}|{?d}|{s}", .{ dkey, c.track.?.track, try lower(arena, c.track.?.title orelse "") });
                const winner = best.get(tk).?;
                c.primary_dst = winner.dst;
                c.fields = winner.fields;
                if (c == winner) {
                    c.role = .primary;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .primary, .op = .move, .dst = winner.dst, .reason = "", .fields = winner.fields });
                } else {
                    c.role = .duplicate;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .duplicate, .op = .skip, .dst = null, .reason = "duplicate track" });
                }
            }
        }
```

- [ ] **Step 7: Fix cover attach for disc subfolders (Phase C2)**

Add this helper just above `pub fn buildPlan` (after `commonPrefixLen`):

```zig
/// Album root for a music destination: the file's parent, or its grandparent
/// when the parent is a "CD N"/"Disc N" folder (so covers land at album root).
fn albumRootOf(p: []const u8) []const u8 {
    const dir = std.fs.path.dirname(p) orelse p;
    const b = std.fs.path.basename(dir);
    if (music.discFromDirName(b) != null) return std.fs.path.dirname(dir) orelse dir;
    return dir;
}
```

Then replace the Phase C2 body (`for (covers.items) |cov| { ... }`) with:

```zig
    for (covers.items) |cov| {
        var attached = false;
        for (media.items) |c| {
            if (c.mkind != .music) continue;
            const same_dir = std.mem.eql(u8, c.dir, cov.dir) or
                (c.album_dir != null and std.mem.eql(u8, c.album_dir.?, cov.dir));
            if (!same_dir) continue;
            if (c.primary_dst) |pd| {
                const album_root = albumRootOf(pd);
                const dst = try std.fmt.allocPrint(arena, "{s}/cover.{s}", .{ album_root, cov.ext });
                try gbs.items[c.group_idx].items.append(arena, .{ .src = cov.abs, .role = .sidecar, .op = .move, .dst = dst, .reason = "cover" });
                attached = true;
            }
            break;
        }
        if (!attached) try unclassified.append(arena, cov.abs);
    }
```

- [ ] **Step 8: Run the whole suite**

Run: `zig build test 2>&1 | tail -8`
Expected: PASS — new multi-disc test green; the existing `buildPlan groups music into an album and attaches cover (no-probe)` test still green (single folder → one group, 2 primaries, 1 cover; album now falls back to the temp folder name and artist to "Unknown Artist", but that test only checks counts).

- [ ] **Step 9: Commit**

```bash
git add src/core/group.zig
git commit -m "feat(group): album-folder music grouping, disc roll-up, consensus meta

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Smoke fixtures + docs/memory

**Files:**
- Modify: `scripts/music-smoke.sh` (add 2-CD, Various-Artists, no-year cases)
- Modify: `todo.md`, `/Users/markussagen/.claude/projects/-Users-markussagen-code-hobby/memory/stacks-media-organizer.md`

**Interfaces:**
- Consumes: the built `shelve` binary (real ffmpeg/ffprobe path).
- Produces: authoritative tag-path coverage for multi-disc, Various-Artists, and no-year.

Note: ffmpeg writes tags as UTF-8, so the Latin-1 fix cannot be exercised via an ffmpeg fixture — it is covered by the `toUtf8`/`fromTags` unit tests (Task 1). Do not add a Latin-1 smoke case.

- [ ] **Step 1: Extend `music-smoke.sh` with new fixtures**

In `scripts/music-smoke.sh`, after the existing single-album fixture block (the three `ffmpeg ...` lines that create `$SRC/01.mp3`, `$SRC/02.mp3`, `$SRC/cover.jpg`), add:

```bash
# --- multi-disc set: CD 1 / CD 2 subfolders roll up to one album ---
MD="$TMP/dl/nights"; mkdir -p "$MD/CD 1" "$MD/CD 2"
dmeta=(-metadata album="Night of the Kings" -metadata album_artist="Various Artists" -metadata date=1992)
ffmpeg -v error -f lavfi -i sine=d=1 "${dmeta[@]}" -metadata title=Opening -metadata track=1 -metadata disc=1 -y "$MD/CD 1/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 "${dmeta[@]}" -metadata title=Finale  -metadata track=1 -metadata disc=2 -y "$MD/CD 2/01.mp3"

# --- compilation with differing artists and NO album_artist -> Various Artists ---
VA="$TMP/dl/comp"; mkdir -p "$VA"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=Comp -metadata artist=Alice -metadata title=First  -metadata track=1 -y "$VA/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=Comp -metadata artist=Bob   -metadata title=Second -metadata track=2 -y "$VA/02.mp3"

# --- album with no date tag -> no (year) suffix ---
NY="$TMP/dl/noyear"; mkdir -p "$NY"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=NoYear -metadata artist=Solo -metadata title=Alone -metadata track=1 -y "$NY/01.mp3"
```

- [ ] **Step 2: Add assertions**

In the `== apply ==` section, after the existing single-album checks, apply and assert the new cases:

```bash
"$SHELVE" organize "$MD" --to "$LIB" >/dev/null
check "multi-disc CD1 track landed" '[[ -f "$LIB/Music/Various Artists/Night of the Kings (1992)/CD1/01 - Opening.mp3" ]]'
check "multi-disc CD2 track landed" '[[ -f "$LIB/Music/Various Artists/Night of the Kings (1992)/CD2/01 - Finale.mp3" ]]'

"$SHELVE" organize "$VA" --to "$LIB" >/dev/null
check "compilation filed under Various Artists" '[[ -f "$LIB/Music/Various Artists/Comp/01 - First.mp3" && -f "$LIB/Music/Various Artists/Comp/02 - Second.mp3" ]]'

"$SHELVE" organize "$NY" --to "$LIB" >/dev/null
check "no-year album has no () suffix" '[[ -f "$LIB/Music/Solo/NoYear/01 - Alone.mp3" ]]'
check "no-year album did not create a () folder" '[[ ! -d "$LIB/Music/Solo/NoYear ()" ]]'
```

Leave the existing `== undo ==` section as-is (it undoes only the first `organize`; that is acceptable for the smoke — the temp dir is cleaned by the `trap` regardless).

- [ ] **Step 3: Run the music smoke**

Run: `zig build && ./scripts/music-smoke.sh`
Expected: all `ok:` lines, `FAIL=0`, exit 0. (If ffmpeg/ffprobe are absent the script prints "skipping" and exits 0 — in that case rely on `zig build test` for coverage.)

- [ ] **Step 4: Mark A.1 done in `todo.md`**

In `todo.md`, change the `## Music epic` A.1 block header and its four sub-bullets from `[ ]` to `[x]`, and append a one-line result. Replace the `- [ ] **A.1 — real-world hardening**` line and its child bullets with:

```markdown
- [x] **A.1 — real-world hardening** (done 2026-08-09):
  - [x] **Multi-disc sets** — album grouped by source folder; `CD N`/`Disc N`
        subfolders (or a `disc` tag) roll up to one album; layout gains a
        `CD{disc}/` segment so track numbers never collide.
  - [x] **Empty/zero year** — template drops the ` ()` suffix (also helps movies).
  - [x] **Various-Artists inference** — consensus album-artist; differing
        artists with no `album_artist` → "Various Artists" (no artists → "Unknown Artist").
  - [x] **Latin-1 / non-UTF-8 tags** — `music.toUtf8` transcodes tag bytes to UTF-8.
  - [ ] **Audiobooks misclassified as music** — still deferred to the audiobook kind.
```

- [ ] **Step 5: Update the memory file**

Append to `/Users/markussagen/.claude/projects/-Users-markussagen-code-hobby/memory/stacks-media-organizer.md` (before the `Gotcha:` line) a short status line:

```markdown
Music A.1 DONE (2026-08-09): music grouped by ALBUM SOURCE FOLDER (kinds/music.zig
discFromDirName + albumMeta consensus w/ Various-Artists fallback); CD N/Disc N
subfolders (or disc tag) roll up → one album with CD{disc}/ layout (plan.Fields.disc,
naming.dstFor splice); empty/zero year dropped (template ` ()` collapse + fromTags
year==0→null); Latin-1 tags transcoded (music.toUtf8). group.zig music path rewritten
(Cand.album_dir/disc; cover lands at album root via albumRootOf). Unit tests for the
pure helpers; multi-disc verified no-probe in group.zig; music-smoke.sh extended
(2-CD, Various-Artists, no-year). Latin-1 is unit-test-only (ffmpeg emits UTF-8).
```

- [ ] **Step 6: Commit**

```bash
git add scripts/music-smoke.sh todo.md
git commit -m "test(music): smoke fixtures for multi-disc/VA/no-year; mark A.1 done

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

(The memory file lives outside the repo; no need to git-add it.)

---

## Self-Review

**Spec coverage:**
- Source-folder album grouping + CD roll-up → Task 5 (walk `album_dir`/`disc`, Phase B key). ✓
- `CD{disc}` disc subfolders → Task 4 (naming splice) + Task 5 (multi detection, `Fields.disc`). ✓
- Various-Artists / consensus album/artist/year → Task 2 (`albumMeta`) wired in Task 5. ✓
- Empty/zero year drop → Task 1 (`fromTags` year 0→null) + Task 3 (template ` ()` collapse). ✓
- Latin-1 → UTF-8 → Task 1 (`toUtf8` + `fromTags`). ✓
- disc from tag OR subfolder ("tag wins") → Task 1 (`Track.disc`) + Task 5 (`c.track.?.disc orelse sub_disc`). ✓
- Cover at album root for multi-disc → Task 5 (`albumRootOf` + dir/album_dir match). ✓
- Tests: pure (`toUtf8`, `discFromDirName`, `albumMeta`, template, naming), no-probe group multi-disc, smoke (2-CD/VA/no-year). ✓ Latin-1 smoke intentionally omitted (ffmpeg emits UTF-8) — noted in Task 6.

**Placeholder scan:** No TBD/TODO; every code and test step has concrete Zig/bash. ✓

**Type consistency:** `Track.disc: ?u32`, `Tags.disc: ?[]const u8`, `Fields.disc: ?u32`, `AlbumMeta{album,album_artist,year}`, `albumMeta(alloc,tracks,folder_name)`, `discFromDirName(name)->?u32`, `toUtf8(alloc,s)`, `albumRootOf(p)->[]const u8` — names/signatures match across Tasks 1→5. ✓
