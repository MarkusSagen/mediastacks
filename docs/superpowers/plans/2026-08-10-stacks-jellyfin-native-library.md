# Jellyfin-native Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement this plan task-by-task. Steps use checkbox (`- [ ]`).

**Goal:** Make `shelve` output match Jellyfin conventions: recognize/place **extras**, trash only promo samples, carry the **full image-name set**, model **multiple versions/multi-part**, and emit `.ignore` so non-media isn't scanned. Offline; no network.

**Architecture:** Pure recognizers in new `core/extras.zig`. `group.zig` gains an extras bucket + attachment phase and a generalized image handler; `plan.Role.extra` + `Fields.edition/part`; `naming` renders edition/part; `apply` emits `.ignore` in the trash tree. Offline output for *already-supported* inputs stays identical.

**Tech Stack:** Zig 0.16. No new deps.

## Global Constraints

- Zig 0.16; arena-allocated organizer code; `std.c` for non-arena FS.
- Existing offline outputs must not regress — `organize-smoke.sh`/`music-smoke.sh` stay green.
- Never trash a legitimately-named extra; never write `.ignore` into the user's source tree.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- `src/core/extras.zig` (new) — `Extra`/`Image` recognizers + version/part parse. (T1)
- `src/core/plan.zig` — `Role.extra`; `Fields.edition`, `Fields.part`. (T2)
- `src/core/naming.zig` — render ` - {edition}` / `-cd{part}` for movies. (T2)
- `src/core/group.zig` — image generalization, extras bucket + attach, sample reconciliation. (T3–T5)
- `src/core/config.zig` — `emit_ignore` (default on). (T6)
- `src/core/apply.zig` — `.ignore` in `.stacks-trash/`. (T6)
- `scripts/organize-smoke.sh`, docs, todo/memory. (T6)

---

## Task 1: core/extras.zig — pure recognizers

**Interfaces — Produces:** `Extra` enum + `extraFromDir(name) ?Extra`, `extraFromSuffix(stem) ?struct{kind,base}`, `subdir(Extra) []const u8`; `Image` enum + `imageFromName(base) ?Image`, `imageOutName(alloc,Image,ext) ![]u8`; `parseEdition(stem) ?struct{edition,base}`, `parsePart(stem) ?struct{part,base}`.

- [ ] **Step 1: Write `src/core/extras.zig`** with tests:

```zig
//! Pure recognizers for Jellyfin extras, images, and version/part labels.
const std = @import("std");

pub const Extra = enum { behind_the_scenes, deleted_scenes, interviews, scenes, samples, shorts, featurettes, clips, trailers, theme_music, backdrops, extras, other };

const dir_names = [_]struct { name: []const u8, kind: Extra }{
    .{ .name = "behind the scenes", .kind = .behind_the_scenes },
    .{ .name = "deleted scenes", .kind = .deleted_scenes },
    .{ .name = "interviews", .kind = .interviews },
    .{ .name = "scenes", .kind = .scenes },
    .{ .name = "samples", .kind = .samples },
    .{ .name = "shorts", .kind = .shorts },
    .{ .name = "featurettes", .kind = .featurettes },
    .{ .name = "clips", .kind = .clips },
    .{ .name = "trailers", .kind = .trailers },
    .{ .name = "theme-music", .kind = .theme_music },
    .{ .name = "backdrops", .kind = .backdrops },
    .{ .name = "extras", .kind = .extras },
    .{ .name = "other", .kind = .other },
};

pub fn extraFromDir(name: []const u8) ?Extra {
    for (dir_names) |d| if (std.ascii.eqlIgnoreCase(name, d.name)) return d.kind;
    return null;
}

pub fn subdir(e: Extra) []const u8 {
    return switch (e) {
        .behind_the_scenes => "behind the scenes",
        .deleted_scenes => "deleted scenes",
        .interviews => "interviews",
        .scenes => "scenes",
        .samples => "samples",
        .shorts => "shorts",
        .featurettes => "featurettes",
        .clips => "clips",
        .trailers => "trailers",
        .theme_music => "theme-music",
        .backdrops => "backdrops",
        .extras => "extras",
        .other => "other",
    };
}

const suffixes = [_]struct { suf: []const u8, kind: Extra }{
    .{ .suf = "-behindthescenes", .kind = .behind_the_scenes },
    .{ .suf = "-deletedscene", .kind = .deleted_scenes },
    .{ .suf = "-deleted", .kind = .deleted_scenes },
    .{ .suf = "-interview", .kind = .interviews },
    .{ .suf = "-scene", .kind = .scenes },
    .{ .suf = "-sample", .kind = .samples },
    .{ .suf = "-short", .kind = .shorts },
    .{ .suf = "-featurette", .kind = .featurettes },
    .{ .suf = "-clip", .kind = .clips },
    .{ .suf = "-trailer", .kind = .trailers },
    .{ .suf = "-other", .kind = .other },
    .{ .suf = "-extra", .kind = .extras },
};

/// A recognized extra suffix on `stem` → its kind + the stem with the suffix
/// removed. Also matches the whole-name forms "trailer"/"sample" (single-file).
pub fn extraFromSuffix(stem: []const u8) ?struct { kind: Extra, base: []const u8 } {
    if (std.ascii.eqlIgnoreCase(stem, "trailer")) return .{ .kind = .trailers, .base = "" };
    if (std.ascii.eqlIgnoreCase(stem, "sample")) return .{ .kind = .samples, .base = "" };
    for (suffixes) |s| {
        if (stem.len > s.suf.len and endsWithCi(stem, s.suf)) {
            return .{ .kind = s.kind, .base = stem[0 .. stem.len - s.suf.len] };
        }
    }
    return null;
}

pub const Image = enum { poster, backdrop, logo, thumb, banner };

pub fn imageFromName(base: []const u8) ?Image {
    const ext = std.fs.path.extension(base);
    const is_img = eqCi(ext, ".jpg") or eqCi(ext, ".jpeg") or eqCi(ext, ".png") or eqCi(ext, ".webp");
    if (!is_img) return null;
    var stem = base[0 .. base.len - ext.len];
    // strip a trailing "-N" (backdrop-1) for matching
    if (std.mem.lastIndexOfScalar(u8, stem, '-')) |d| {
        if (allDigits(stem[d + 1 ..])) stem = stem[0..d];
    }
    const posters = [_][]const u8{ "poster", "cover", "folder", "default", "front", "albumart", "album" };
    for (posters) |n| if (eqCi(stem, n)) return .poster;
    const backdrops = [_][]const u8{ "backdrop", "fanart", "background", "art" };
    for (backdrops) |n| if (eqCi(stem, n)) return .backdrop;
    if (eqCi(stem, "logo") or eqCi(stem, "clearlogo")) return .logo;
    if (eqCi(stem, "thumb") or eqCi(stem, "landscape")) return .thumb;
    if (eqCi(stem, "banner")) return .banner;
    return null;
}

/// Canonical Jellyfin output name for an image kind (music album posters stay
/// `cover.jpg`; handled by the caller passing `.poster` + album context).
pub fn imageOutName(alloc: std.mem.Allocator, e: Image, ext: []const u8) ![]u8 {
    const base = switch (e) { .poster => "poster", .backdrop => "backdrop", .logo => "logo", .thumb => "thumb", .banner => "banner" };
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ base, ext });
}

/// ` - 2160p` / ` - Directors Cut` / `[1080p]` edition label at the end of a
/// stem → { edition, base } with the label removed. Resolution-like labels are
/// normalized lowercase; others kept verbatim.
pub fn parseEdition(stem: []const u8) ?struct { edition: []const u8, base: []const u8 } {
    // bracketed [label] at end
    if (stem.len > 2 and stem[stem.len - 1] == ']') {
        if (std.mem.lastIndexOfScalar(u8, stem, '[')) |o| {
            const label = std.mem.trim(u8, stem[o + 1 .. stem.len - 1], " ");
            const base = std.mem.trim(u8, stem[0..o], " ");
            if (label.len > 0 and base.len > 0) return .{ .edition = label, .base = base };
        }
    }
    // " - label" at end
    if (std.mem.lastIndexOf(u8, stem, " - ")) |sep| {
        const label = std.mem.trim(u8, stem[sep + 3 ..], " ");
        const base = std.mem.trim(u8, stem[0..sep], " ");
        if (label.len > 0 and base.len > 0 and isEditionLabel(label)) return .{ .edition = label, .base = base };
    }
    return null;
}

/// Trailing `-cd1`/`-part2`/`-disc1`/`-pt3` → { part, base } (base = stem sans part).
pub fn parsePart(stem: []const u8) ?struct { part: u32, base: []const u8 } {
    const kinds = [_][]const u8{ "cd", "part", "disc", "disk", "pt" };
    for (kinds) |k| {
        // separators: space . - _ or none, before the kind
        var idx = stem.len;
        // find "<sep>?<kind><digits>" at end
        var i = stem.len;
        while (i > 0) : (i -= 1) {
            if (!std.ascii.isDigit(stem[i - 1])) break;
        }
        if (i == stem.len) continue; // no trailing digits
        const digits = stem[i..];
        if (i < k.len) continue;
        const kstart = i - k.len;
        if (!std.ascii.eqlIgnoreCase(stem[kstart..i], k)) continue;
        // require a separator (or start) before the kind
        var base_end = kstart;
        if (base_end > 0 and (stem[base_end - 1] == ' ' or stem[base_end - 1] == '.' or stem[base_end - 1] == '-' or stem[base_end - 1] == '_')) base_end -= 1;
        const part = std.fmt.parseInt(u32, digits, 10) catch continue;
        idx = base_end;
        return .{ .part = part, .base = stem[0..idx] };
    }
    return null;
}

fn isEditionLabel(s: []const u8) bool {
    // resolution (\d+[pi]) or a small known-edition word set
    if (s.len >= 3 and (s[s.len - 1] == 'p' or s[s.len - 1] == 'i' or s[s.len - 1] == 'P' or s[s.len - 1] == 'I')) {
        var all = true;
        for (s[0 .. s.len - 1]) |c| if (!std.ascii.isDigit(c)) { all = false; break; };
        if (all) return true;
    }
    const words = [_][]const u8{ "directors cut", "director's cut", "extended", "unrated", "theatrical", "remastered", "imax", "final cut", "uncut" };
    for (words) |w| if (containsCi(s, w)) return true;
    return false;
}

fn eqCi(a: []const u8, b: []const u8) bool { return std.ascii.eqlIgnoreCase(a, b); }
fn endsWithCi(h: []const u8, n: []const u8) bool { return h.len >= n.len and std.ascii.eqlIgnoreCase(h[h.len - n.len ..], n); }
fn allDigits(s: []const u8) bool { if (s.len == 0) return false; for (s) |c| if (!std.ascii.isDigit(c)) return false; return true; }
fn containsCi(h: []const u8, n: []const u8) bool {
    if (n.len == 0 or n.len > h.len) return false;
    var i: usize = 0;
    outer: while (i + n.len <= h.len) : (i += 1) {
        for (n, 0..) |c, j| if (std.ascii.toLower(h[i + j]) != std.ascii.toLower(c)) continue :outer;
        return true;
    }
    return false;
}

const t = std.testing;
test "extraFromDir/suffix" {
    try t.expectEqual(Extra.trailers, extraFromDir("Trailers").?);
    try t.expectEqual(@as(?Extra, null), extraFromDir("Season 01"));
    const s = extraFromSuffix("Film-behindthescenes").?;
    try t.expectEqual(Extra.behind_the_scenes, s.kind);
    try t.expectEqualStrings("Film", s.base);
    try t.expectEqual(Extra.trailers, extraFromSuffix("trailer").?.kind);
    try t.expectEqual(@as(?@TypeOf(extraFromSuffix("x")), null), extraFromSuffix("Film"));
}
test "imageFromName canonicalizes" {
    try t.expectEqual(Image.poster, imageFromName("cover.jpg").?);
    try t.expectEqual(Image.backdrop, imageFromName("fanart.png").?);
    try t.expectEqual(Image.backdrop, imageFromName("backdrop-2.jpg").?);
    try t.expectEqual(Image.logo, imageFromName("clearlogo.png").?);
    try t.expectEqual(@as(?Image, null), imageFromName("random.jpg"));
    var a = std.heap.ArenaAllocator.init(t.allocator); defer a.deinit();
    try t.expectEqualStrings("poster.jpg", try imageOutName(a.allocator(), .poster, "jpg"));
}
test "parseEdition / parsePart" {
    const e = parseEdition("The Matrix - Directors Cut").?;
    try t.expectEqualStrings("Directors Cut", e.edition);
    try t.expectEqualStrings("The Matrix", e.base);
    try t.expectEqual(@as(?@TypeOf(parseEdition("x")), null), parseEdition("Plain Title"));
    const p = parsePart("Movie-cd2").?;
    try t.expectEqual(@as(u32, 2), p.part);
    try t.expectEqualStrings("Movie", p.base);
    try t.expectEqual(@as(?@TypeOf(parsePart("x")), null), parsePart("Movie2"));
}
```

- [ ] **Step 2:** register in `src/root.zig` (`pub const extras = @import("core/extras.zig");`). Run `zig build test` → PASS.
- [ ] **Step 3: Commit** — `feat(jellyfin): core/extras.zig recognizers (extras/images/versions)`.

---

## Task 2: plan.Role.extra + Fields.edition/part + naming

**Interfaces — Produces:** `plan.Role` gains `extra`; `Fields.edition: ?[]const u8`, `Fields.part: ?u32`; movie naming appends ` - {edition}` and `-cd{part}` (edition before ext; part suffix on the stem).

- [ ] **Step 1:** `plan.zig` — `Role = enum { primary, sidecar, duplicate, junk, extra };`; add `edition`/`part` to `Fields`.
- [ ] **Step 2:** naming — add `{edition}` and `{part}` to the movie field list; new `DEFAULT_MOVIE` keeps a `- {edition}` before `.{ext}` only via a post-render splice (simplest): render as today, then if `f.part` splice `-cd{part}` before ext, and if `f.edition` splice ` - {edition}` before ext (and mirror into the folder? no — Jellyfin wants the *file* to carry version; folder stays the base). Implement in `dstFor` `.movie` branch after render.
- [ ] **Step 3: tests** in naming: movie with `edition = "1080p"` → `…/Film (1999)/Film (1999) - 1080p.mkv`; `part = 2` → `…/Film (1999)/Film (1999)-cd2.mkv`; both absent → unchanged.
- [ ] **Step 4:** Run suite + smokes → PASS. **Commit** — `feat(jellyfin): Role.extra + Fields.edition/part + movie naming`.

---

## Task 3: Full image set in group.zig

- [ ] **Step 1:** replace `isCoverImage` usage with `extras.imageFromName`. In the walk, bucket recognized images into `covers` (rename to `images`) carrying the `Image` kind. In Phase C2, attach each image to its media group; destination filename = `extras.imageOutName(kind, ext)` **except** music albums, where a `.poster` writes `cover.jpg` (Jellyfin music). Multiple backdrops → `backdrop-1.jpg`, `backdrop-2.jpg` (counter per group+kind).
- [ ] **Step 2: tests** (no-probe, synthetic): a movie folder with `poster.jpg` + `fanart.jpg` → `poster.jpg` + `backdrop.jpg` at the movie folder; two backdrops → `backdrop-1/2.jpg`; music `cover.jpg` still `cover.jpg`. Existing music cover test stays green.
- [ ] **Step 3: Commit** — `feat(jellyfin): full Jellyfin image-name set on output`.

---

## Task 4: Extras bucket + attachment in group.zig

- [ ] **Step 1:** In the walk, before `classify`, detect extras: `extraFromDir(basename(d))` OR `extraFromSuffix(stem)`. Bucket `Extra{abs,dir,stem,ext,kind,base}`. (Skip when the file is under a `Season NN`/album context where it's clearly primary — i.e. only treat as extra when a category matched.)
- [ ] **Step 2:** New Phase (after media groups): attach each extra to a media cand in the same or parent dir (like covers). Destination = `{mediaFolder}/{subdir(kind)}/{cleanBase}.{ext}` where `mediaFolder` = for movie: `dirname(primary_dst)`; for tv: series root `dirname(dirname(primary_dst))`. Emit an item `{role=.extra, op=.move, dst, reason="extra:<kind>"}`. Unattached → `unclassified`.
- [ ] **Step 3: tests:** movie folder with `trailers/x.mkv` + `Film-behindthescenes.mkv` → two `.extra` items with dsts under `…/trailers/` and `…/behind the scenes/`.
- [ ] **Step 4: Commit** — `feat(jellyfin): recognize + place extras (subfolders + suffixes)`.

---

## Task 5: Sample reconciliation (size-aware)

- [ ] **Step 1:** Remove the blanket `sample`→junk line from `isJunkBase` (keep rarbg/yts/torrent/.url/.DS_Store). In the walk, when an extra resolves to `.samples` (or a bare `sample`/`-sample`) AND `statSize < 50 MB` → route to `junk` instead of extras (promo clip). Larger samples stay extras.
- [ ] **Step 2: tests:** tiny `RARBG-sample.mkv` (site marker) → junk (already); a small `sample.mkv` (<50MB) → junk; a large `sample.mkv` → `.extra`(samples). Reuse the existing group test tree; the current "trashes junk" assertion must still hold (`.DS_Store`).
- [ ] **Step 3:** Run suite + `organize-smoke.sh` (its `Sample.mkv` is tiny → still trashed). **Commit** — `feat(jellyfin): size-aware promo-sample trashing; keep real extras`.

---

## Task 6: .ignore emission + config + docs

- [ ] **Step 1:** `config.emit_ignore: bool = true` (key `emit_ignore = on|off`), parsed like other bools.
- [ ] **Step 2:** `apply.zig` — when anything is trashed and `emit_ignore`, ensure `{library_root}/.stacks-trash/.ignore` exists (empty). Journal a `.create` entry (add `.create` to `journal.Action`; undo unlinks `to`). (If Task from the NFO plan already added `.create`, reuse it.)
- [ ] **Step 3: tests:** `applyInMemory` with a trashed item + `emit_ignore` → `.stacks-trash/.ignore` exists; `undo` removes it. Thread `emit_ignore` via `TagOpts`-style field or a new `apply` param defaulting on.
- [ ] **Step 4:** `organize-smoke.sh` assert `.ignore` present after a run that trashes. Docs for `emit_ignore`; mark the Jellyfin-native-library spec done in `todo.md` + memory.
- [ ] **Step 5: Commit** — `feat(jellyfin): emit .ignore in trash tree; mark Jellyfin-native-library done`.

---

## Self-Review

**Spec coverage:** extras recognizers (T1) + placement (T4) ✓; samples (T5) ✓; images (T3) ✓; versions/parts (T1 parse, T2 naming) ✓; `.ignore` (T6) ✓; `Role.extra`/`Fields.edition/part` (T2) ✓. **Placeholder scan:** T3–T6 give concrete integration steps + test intents grounded in the existing Phase C/C2 attach pattern; pure code is fully written in T1–T2. **Type consistency:** `Extra`/`Image` (T1) used by group (T3,T4); `Role.extra`/`Fields.edition/part` (T2) rendered by naming (T2) and emitted by group (T4); `journal.Action.create` shared with the NFO plan.
