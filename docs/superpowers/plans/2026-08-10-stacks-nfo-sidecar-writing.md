# NFO Sidecar Writing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline). Steps use checkbox (`- [ ]`).

**Goal:** Write Jellyfin-native NFO sidecars (`movie.nfo`, `<episode>.nfo`, `tvshow.nfo`, `season.nfo`, `album.nfo`, `artist.nfo`) from the Plan so the library is self-describing and identity is pinned via provider IDs. Opt-in (default on), safe (new files), journaled + undoable.

**Architecture:** Pure XML builders in new `core/nfo.zig` (from `plan.Fields`). `apply` derives NFO targets from each primary item + its group kind (no new plan fields) and writes them via `std.c`, journaling `.create` entries (reused from the Jellyfin epic). Config `write_nfo` (default on) + `--nfo`/`--no-nfo`.

**Tech Stack:** Zig 0.16. No new deps.

## Global Constraints

- Zig 0.16; `std.c` file IO in apply.
- NFO writes never mutate media; only add `.nfo` files; `.create` journal → undo unlinks them.
- Missing fields are omitted (always well-formed XML). Existing NFO respected via `--on-conflict` (default skip).
- Commit trailer as before. Build `zig build`; test `zig build test`.

## File Structure

- `src/core/nfo.zig` (new) — pure builders + XML escape. (T1, T2)
- `src/core/apply.zig` — NFO write step + `write_nfo` param; container-once tracking. (T3)
- `src/core/config.zig` — `write_nfo` (default on). (T4)
- `src/commands/organize.zig`, `src/web/review.zig` — pass `write_nfo`; `--nfo`/`--no-nfo`. (T4)
- `scripts/nfo-smoke.sh`, docs, todo/memory. (T5)

---

## Task 1: core/nfo.zig — video builders

**Interfaces — Produces:** `movieNfo(alloc,f)`, `episodeNfo(alloc,f)`, `tvshowNfo(alloc,f)`, `seasonNfo(alloc,season)` → `![]u8`; `escape(alloc,s)`.

- [ ] **Step 1: Write `src/core/nfo.zig`** with builders + tests:

```zig
//! Pure Jellyfin NFO (XML) builders from plan.Fields. No IO.
const std = @import("std");
const plan = @import("plan.zig");

fn esc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

fn tag(out: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8, val: []const u8) !void {
    if (val.len == 0) return;
    const e = try esc(alloc, val);
    defer alloc.free(e);
    try out.print(alloc, "  <{s}>{s}</{s}>\n", .{ name, e, name });
}
fn tagNum(out: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8, val: ?u32) !void {
    if (val) |n| try out.print(alloc, "  <{s}>{d}</{s}>\n", .{ name, n, name });
}

/// Provider-id tags + <uniqueid> forms Jellyfin understands.
fn providerIds(out: *std.ArrayList(u8), alloc: std.mem.Allocator, f: plan.Fields) !void {
    if (f.tmdb_id) |x| {
        try tag(out, alloc, "tmdbid", x);
        const e = try esc(alloc, x); defer alloc.free(e);
        try out.print(alloc, "  <uniqueid type=\"tmdb\" default=\"true\">{s}</uniqueid>\n", .{e});
    }
    if (f.imdb_id) |x| {
        try tag(out, alloc, "imdbid", x);
        const e = try esc(alloc, x); defer alloc.free(e);
        try out.print(alloc, "  <uniqueid type=\"imdb\">{s}</uniqueid>\n", .{e});
    }
    if (f.tvdb_id) |x| {
        try tag(out, alloc, "tvdbid", x);
        const e = try esc(alloc, x); defer alloc.free(e);
        try out.print(alloc, "  <uniqueid type=\"tvdb\">{s}</uniqueid>\n", .{e});
    }
}

pub fn movieNfo(alloc: std.mem.Allocator, f: plan.Fields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<movie>\n");
    try tag(&out, alloc, "title", f.title orelse "");
    try tagNum(&out, alloc, "year", f.year);
    try tag(&out, alloc, "language", f.original_language orelse "");
    try providerIds(&out, alloc, f);
    try out.appendSlice(alloc, "</movie>\n");
    return out.toOwnedSlice(alloc);
}

pub fn episodeNfo(alloc: std.mem.Allocator, f: plan.Fields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<episodedetails>\n");
    try tag(&out, alloc, "title", f.title orelse "");
    try tag(&out, alloc, "showtitle", f.series orelse "");
    try tagNum(&out, alloc, "season", f.season);
    try tagNum(&out, alloc, "episode", f.episode);
    try providerIds(&out, alloc, f);
    try out.appendSlice(alloc, "</episodedetails>\n");
    return out.toOwnedSlice(alloc);
}

pub fn tvshowNfo(alloc: std.mem.Allocator, f: plan.Fields) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tvshow>\n");
    try tag(&out, alloc, "title", f.series orelse "");
    try tagNum(&out, alloc, "year", f.series_year);
    try tag(&out, alloc, "language", f.original_language orelse "");
    try providerIds(&out, alloc, f);
    try out.appendSlice(alloc, "</tvshow>\n");
    return out.toOwnedSlice(alloc);
}

pub fn seasonNfo(alloc: std.mem.Allocator, season: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(alloc, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<season>\n  <seasonnumber>{d}</seasonnumber>\n</season>\n", .{season});
    return out.toOwnedSlice(alloc);
}

const t = std.testing;
test "movieNfo has title/year/ids/uniqueid, escapes" {
    var a = std.heap.ArenaAllocator.init(t.allocator); defer a.deinit();
    const s = try movieNfo(a.allocator(), .{ .title = "Tom & Jerry", .year = 1999, .tmdb_id = "603", .imdb_id = "tt0133093", .original_language = "en" });
    try t.expect(std.mem.indexOf(u8, s, "<title>Tom &amp; Jerry</title>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<year>1999</year>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<tmdbid>603</tmdbid>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<uniqueid type=\"tmdb\" default=\"true\">603</uniqueid>") != null);
}
test "episodeNfo + tvshowNfo + seasonNfo" {
    var a = std.heap.ArenaAllocator.init(t.allocator); defer a.deinit();
    const al = a.allocator();
    const e = try episodeNfo(al, .{ .series = "Severance", .season = 1, .episode = 2, .title = "Half Loop", .tmdb_id = "95396" });
    try t.expect(std.mem.indexOf(u8, e, "<episodedetails>") != null);
    try t.expect(std.mem.indexOf(u8, e, "<season>1</season>") != null);
    try t.expect(std.mem.indexOf(u8, e, "<showtitle>Severance</showtitle>") != null);
    const sh = try tvshowNfo(al, .{ .series = "Severance", .series_year = 2022, .tmdb_id = "95396" });
    try t.expect(std.mem.indexOf(u8, sh, "<tvshow>") != null);
    try t.expect(std.mem.indexOf(u8, sh, "<year>2022</year>") != null);
    const sn = try seasonNfo(al, 1);
    try t.expect(std.mem.indexOf(u8, sn, "<seasonnumber>1</seasonnumber>") != null);
}
```

- [ ] **Step 2:** register in `root.zig` (`pub const nfo = @import("core/nfo.zig");`). Run `zig build test`. NOTE: verify `std.ArrayList(u8).print(alloc, fmt, args)` exists in 0.16; if not, use `out.appendSlice(alloc, try std.fmt.allocPrint(alloc, ...))`. **Commit** — `feat(nfo): video NFO builders (movie/episode/tvshow/season)`.

---

## Task 2: core/nfo.zig — music builders

- [ ] **Step 1:** add `albumNfo(alloc, f)` (`<album>`: title=`f.album`, `<artist>`=`f.album_artist`, year, `<musicbrainzalbumid>`=`f.release_mbid`) and `artistNfo(alloc, name, mbid)` (`<artist>`: `<name>`, `<musicbrainzartistid>`), + tests asserting the tags. **Commit** — `feat(nfo): music NFO builders (album/artist)`.

---

## Task 3: apply — write NFO from items (container-once), undo

**Interfaces — Produces:** `applyInMemory(..., write_nfo: bool)`; NFO written per primary + once per series/season/album/artist container; `.create` journal entries (undo unlinks).

- [ ] **Step 1:** add `write_nfo: bool` param to `applyInMemory`/`apply` (after `emit_ignore`); update all call sites (2 tests → `false`; organize/review → config/flag).
- [ ] **Step 2:** after a successful primary `.move` (reuse the same block that does tag write-back), when `write_nfo` and `item.fields != null`, call a helper `writeNfos(alloc, &entries, &seen, g.kind, item, final)`:
  - movie: `nfo.movieNfo` → `{dirname(final)}/movie.nfo`.
  - tv: `nfo.episodeNfo` → `{stem(final)}.nfo`; and once per series root (`dirname(dirname(final))`) `tvshow.nfo`; once per season dir (`dirname(final)`) `season.nfo` (seasonnumber from `item.fields.season`).
  - music: `nfo.albumNfo` → `{dirname(final)}/album.nfo` once per album dir; `artist.nfo` once per artist root (`dirname(dirname(final))`) — but only when it's the album root (skip for multi-disc `CD1/`; use `albumRootOf`-equivalent: if `dirname` basename matches `CD\d`, go up). Keep simple: album.nfo at `dirname(final)`; artist.nfo at `dirname(dirname(final))`.
  - `seen: std.StringHashMap(void)` keyed by the target path prevents duplicate container writes.
  - Each write: skip if exists AND `on_conflict == .skip` (respect user NFO); else write via `touchWrite(path, bytes)` and journal `.create`.
- [ ] **Step 3: test** (`apply`): a movie primary with `write_nfo=true` → `movie.nfo` beside it containing `<tmdbid>`; `undo` removes it. A tv primary → `tvshow.nfo` at series root + `<stem>.nfo`. **Commit** — `feat(nfo): write NFO sidecars during apply (+ undo)`.

---

## Task 4: config write_nfo + CLI flags

- [ ] **Step 1:** `config.write_nfo: bool = true` (key `write_nfo = on|off`), parsed like `emit_ignore`.
- [ ] **Step 2:** organize `Opts.write_nfo_flag: ?bool`; `--nfo`/`--no-nfo`; effective = flag orelse `cfg.write_nfo`; pass to `apply`. web review passes `session.cfg.write_nfo`. **Commit** — `feat(nfo): config write_nfo + --nfo/--no-nfo`.

---

## Task 5: nfo-smoke + docs

- [ ] **Step 1:** `scripts/nfo-smoke.sh` — organize a synthetic movie (`The.Matrix.1999.mkv`) with `--nfo --offline`; assert `movie.nfo` exists in the movie folder and contains `<movie>`; `shelve undo` removes it. `just nfo-smoke`.
- [ ] **Step 2:** docs (`write_nfo`, `--nfo/--no-nfo`); mark NFO spec done in `todo.md` + memory. **Commit** — `docs(nfo): smoke + mark NFO writing done`.

---

## Self-Review

**Spec coverage:** video (T1) + music (T2) builders; per-item + container NFO with once-tracking (T3); config/flags (T4); provider-id `<uniqueid>` (T1); on-conflict-skip respects existing NFO (T3); undo via `.create` (T3); smoke (T5). Simplification vs spec: NFO targets derived from items + `g.kind` (no `Item.nfo_role`/`Group.nfo`). **Placeholder scan:** builders fully written; T3 integration steps concrete against the known apply structure. **Type consistency:** `nfo.*` builders take `plan.Fields`; `write_nfo` threads through `applyInMemory`/`apply`/CLI; `.create` reused from journal.
