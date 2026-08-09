# stacks — Web review over the Plan JSON Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `shelve review <dir>` serves a local web UI to review & edit a reorganization Plan (keep/skip/trash, retitle with live path recompute, drag-to-regroup, video posters) then Apply (real moves + undo journal).

**Architecture:** Server-authoritative session — the browser sends edit ops; a self-contained `web/review.zig` mutates the in-memory `Plan` and recomputes destinations with the Zig template engine via a shared `core/naming.dstFor`, then returns the updated Plan. `Plan.Item` gains an additive `fields` so names can be recomputed after edits. The Catalog-coupled book server is untouched.

**Tech Stack:** Zig 0.16, `std.http.Server` (mirroring `web/server.zig`), `@embedFile` assets, vanilla JS frontend, `ffmpeg` (optional, posters).

## Global Constraints

- Zig **0.16.0**. No 0.17-only APIs. No new dependencies (ffmpeg optional).
- Bind **`127.0.0.1`** only. Nothing moves until Apply; Apply writes the undo journal so `shelve undo` reverts.
- The review server is **single-threaded** (one request at a time): the session is mutable, and ops are fast. (A slow `/api/thumb` briefly blocks — acceptable for a local single user; noted.)
- `std.ArrayList(T)` starts `.empty`, allocator per call. Tests inline `test "…"` with `std.testing.allocator`; temp files under `/tmp` keyed by `std.c.getpid()` + `@import("../util/clock.zig").nowSeconds()`.
- New modules added to `src/root.zig` (`pub const` + `_ = x;` in `test {}`).
- HTTP handlers take `(*std.http.Server.Request)`; respond via `request.respond(body, .{ .status, .extra_headers })`. Read bodies via a local `readBody` mirroring `web/api.zig` (uses `request.readerExpectNone`/`readerExpectContinue`). JSON responses use `content-type: application/json`.
- The `Plan` is the single contract; edit ops mutate it server-side and the server re-serializes it — the browser never recomputes names.
- Frontend assets are `@embedFile`d (like `web/static.zig`); editing them requires `zig build`.

## File Structure

Created:
- `src/core/naming.zig` — `dstFor(arena, cfg, kind, fields)`; the one place destinations are rendered.
- `src/web/review.zig` — the review HTTP server + `applyEdit` op handlers + `Session`.
- `src/web/assets/review.html`, `review.js`, `review.css` — the page.
- `src/commands/review.zig` — the `shelve review` subcommand.
- `scripts/review-smoke.sh` — API-contract smoke.

Modified:
- `src/core/plan.zig` — `Fields` + `Item.fields`.
- `src/core/group.zig` — use `naming.dstFor`; populate `Item.fields`.
- `src/web/static.zig` — embed the review assets.
- `src/shelve_cli.zig` — route `review`.
- `src/root.zig` — export `naming`, `review`.
- `justfile` — a `review` recipe.

---

### Task 1: `plan.Fields` + `Item.fields`

**Files:** Modify `src/core/plan.zig`

**Interfaces:**
```zig
pub const Fields = struct {
    series: ?[]const u8 = null,
    season: ?u32 = null,
    episode: ?u32 = null,
    title: ?[]const u8 = null,
    year: ?u32 = null,
    ext: ?[]const u8 = null,
};
// Item gains: fields: ?Fields = null,
```

- [ ] **Step 1: Write the failing test**

```zig
test "plan json round-trips item fields" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = [_]Item{.{ .src = "/x/a.mkv", .role = .primary, .op = .move, .dst = "/lib/a.mkv",
        .fields = .{ .series = "Show", .season = 1, .episode = 2, .ext = "mkv" } }};
    var groups = [_]Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const plan = Plan{ .library_root = "/lib", .source = "/x", .groups = groups[0..] };
    const back = try fromJson(a, try toJson(a, plan));
    try t.expectEqual(@as(u32, 2), back.groups[0].items[0].fields.?.episode.?);
    try t.expectEqualStrings("Show", back.groups[0].items[0].fields.?.series.?);
}
```

- [ ] **Step 2: Run** `zig build test 2>&1 | tail -20` — FAIL (no `fields`).
- [ ] **Step 3: Implement** — add `Fields` and `fields: ?Fields = null` to `Item`.
- [ ] **Step 4: Run** `zig build test` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/core/plan.zig && git commit -m "feat(plan): additive Item.fields for name recompute"
```

---

### Task 2: `core/naming.zig` + use it in `group.zig`

**Files:** Create `src/core/naming.zig`; Modify `src/core/group.zig`, `src/root.zig`

**Interfaces:**
```zig
pub fn dstFor(arena: std.mem.Allocator, cfg: config.Config, k: kind.MediaKind, f: plan.Fields) ![]u8;
```
Renders a destination path from `f` using the kind's template + library root. `tv` → `tv_template` with `{series}{season}{episode}{title}{ext}`; `movie` → `movie_template` with `{title}{year}{ext}`; other kinds → `error.UnsupportedKind`.

- [ ] **Step 1: Write the failing test** (in `naming.zig`)

```zig
const std = @import("std");
const t = std.testing;
const config = @import("config.zig");
const kind = @import("kind.zig");
const plan = @import("plan.zig");

test "dstFor renders a jellyfin tv path" {
    const a = t.allocator;
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE };
    const out = try dstFor(a, cfg, .tv, .{ .series = "Witch Hat Atelier", .season = 1, .episode = 12, .title = "The Shadow of Romonon", .ext = "mkv" });
    defer a.free(out);
    try t.expectEqualStrings("/lib/Shows/Witch Hat Atelier/Season 01/Witch Hat Atelier S01E12 - The Shadow of Romonon.mkv", out);
}
test "dstFor renders a movie path" {
    const a = t.allocator;
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE };
    const out = try dstFor(a, cfg, .movie, .{ .title = "The Matrix", .year = 1999, .ext = "mkv" });
    defer a.free(out);
    try t.expectEqualStrings("/lib/Movies/The Matrix (1999)/The Matrix (1999).mkv", out);
}
```

- [ ] **Step 2: Run** `zig build test` — FAIL (`dstFor` undefined).
- [ ] **Step 3: Implement**

```zig
const template = @import("template.zig");

fn u32str(arena: std.mem.Allocator, n: u32) ![]u8 {
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

pub fn dstFor(arena: std.mem.Allocator, cfg: config.Config, k: kind.MediaKind, f: plan.Fields) ![]u8 {
    const rel = switch (k) {
        .tv => blk: {
            const fields = [_]template.Field{
                .{ .name = "series", .value = f.series orelse "" },
                .{ .name = "season", .value = try u32str(arena, f.season orelse 0) },
                .{ .name = "episode", .value = try u32str(arena, f.episode orelse 0) },
                .{ .name = "title", .value = f.title orelse "" },
                .{ .name = "ext", .value = f.ext orelse "" },
            };
            break :blk try template.renderFields(arena, cfg.tv_template, &fields);
        },
        .movie => blk: {
            const year_str = if (f.year) |y| try u32str(arena, y) else "";
            const fields = [_]template.Field{
                .{ .name = "title", .value = f.title orelse "" },
                .{ .name = "year", .value = year_str },
                .{ .name = "ext", .value = f.ext orelse "" },
            };
            break :blk try template.renderFields(arena, cfg.movie_template, &fields);
        },
        else => return error.UnsupportedKind,
    };
    return std.fs.path.join(arena, &.{ cfg.library_root, rel });
}
```

  Then in `group.zig`: `const naming = @import("naming.zig");`. Replace the bodies of `tvDst`/`movieDst` to build a `plan.Fields` and call `naming.dstFor`, OR delete them and inline. Populate `Item.fields` on every primary and sidecar:
  - tv primary: `const f = plan.Fields{ .series = gb.title, .season = c.ep.?.season, .episode = c.ep.?.episode, .title = c.ep.?.title, .ext = c.ep.?.ext };` → `c.dst = try naming.dstFor(arena, cfg, .tv, f);` and set `.fields = f` on the emitted item.
  - movie primary: `const f = plan.Fields{ .title = winner.mv.?.title, .year = winner.mv.?.year, .ext = winner.mv.?.ext };` similarly.
  - sidecar: `const f = plan.Fields{ .series = gbs.items[c.group_idx].title, .season = c.ep.?.season, .episode = c.ep.?.episode, .title = c.ep.?.title, .ext = sc.ext };` (c = the matched media cand) → dst via `naming.dstFor`, set `.fields = f`. (This lets a later retitle recompute the sidecar too.) For a matched movie cand, use its `mv` fields with `.ext = sc.ext`.
  Add `pub const naming = @import("core/naming.zig");` + `_ = naming;` to `root.zig`.

- [ ] **Step 4: Run** `zig build test && ./scripts/organize-smoke.sh` — PASS (existing group golden + smoke unchanged; the DRM/probe tests still hold).
- [ ] **Step 5: Commit**

```bash
git add src/core/naming.zig src/core/group.zig src/root.zig
git commit -m "feat(core): shared naming.dstFor; group populates Item.fields"
```

---

### Task 3: `web/review.zig` — `Session` + `applyEdit` op handlers (pure)

**Files:** Create `src/web/review.zig`; Modify `src/root.zig`

**Interfaces:**
```zig
pub const Session = struct { arena: std.mem.Allocator, cfg: config.Config, plan: plan.Plan };
/// Apply one edit op (JSON) to `s.plan`, recomputing destinations. Bad
/// index/op → error; the plan is otherwise mutated in place.
pub fn applyEdit(s: *Session, op_json: []const u8) !void;
```
Ops (JSON `{"op":…}`): `set-role` {group,item,role:"primary|skip|trash"}, `retitle` {group,title}, `move-item` {from,item,to}, `split` {group,items:[…],title}.

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;
const config = @import("../core/config.zig");
const plan = @import("../core/plan.zig");

fn mkSession(a: std.mem.Allocator) Session {
    const items = a.alloc(plan.Item, 1) catch unreachable;
    items[0] = .{ .src = "/x/a.mkv", .role = .primary, .op = .move, .dst = "/lib/old.mkv",
        .fields = .{ .series = "Old", .season = 1, .episode = 1, .ext = "mkv" } };
    const groups = a.alloc(plan.Group, 1) catch unreachable;
    groups[0] = .{ .kind = .tv, .title = "Old", .items = items };
    return .{ .arena = a, .cfg = .{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE }, .plan = .{ .library_root = "/lib", .source = "/x", .groups = groups } };
}

test "retitle recomputes dst" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try applyEdit(&s, "{\"op\":\"retitle\",\"group\":0,\"title\":\"New Show\"}");
    try t.expectEqualStrings("New Show", s.plan.groups[0].title);
    try t.expect(std.mem.indexOf(u8, s.plan.groups[0].items[0].dst.?, "New Show") != null);
}

test "set-role trash clears dst and sets trash op" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try applyEdit(&s, "{\"op\":\"set-role\",\"group\":0,\"item\":0,\"role\":\"trash\"}");
    try t.expectEqual(plan.Op.trash, s.plan.groups[0].items[0].op);
    try t.expect(s.plan.groups[0].items[0].dst == null);
}

test "bad index errors" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try t.expectError(error.BadIndex, applyEdit(&s, "{\"op\":\"retitle\",\"group\":9,\"title\":\"x\"}"));
}
```

- [ ] **Step 2: Run** `zig build test` — FAIL (`applyEdit` undefined).
- [ ] **Step 3: Implement**

Parse `op_json` into `std.json.Value` (arena). Helpers: `fn gi(v,key) ?usize` (integer field), `fn gs(v,key) ?[]const u8` (string field; dupe into `s.arena`). Bounds-check every index → `error.BadIndex`; unknown op → `error.BadOp`. Recompute helper:
```zig
fn recompute(s: *Session, g: usize, i: usize) !void {
    var it = &s.plan.groups[g].items[i];
    if (it.role == .primary or it.role == .sidecar) {
        if (it.fields) |f| it.dst = try naming.dstFor(s.arena, s.cfg, s.plan.groups[g].kind, f);
    } else it.dst = null;
}
```
- `set-role`: map role string → `{role, op}` (`primary`→move, `skip`→skip, `trash`→trash); set both; `recompute`.
- `retitle`: set `groups[g].title` (dupe); for each item with `fields`, set `fields.series = title` (tv) and `recompute`.
- `move-item`: append the item to group `to` (adopt `to`'s title as `fields.series` for tv), remove from `from` (rebuild that group's items slice without it), `recompute` on the moved item at its new index.
- `split`: allocate a new group with `title`, move the listed items into it (same rebuild-slice mechanics), append it to `groups`.

Add `const naming = @import("../core/naming.zig");`, `const kind = @import("../core/kind.zig");`. Register `pub const review = @import("web/review.zig");` + `_ = review;` in `root.zig`.

- [ ] **Step 4: Run** `zig build test` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/web/review.zig src/root.zig
git commit -m "feat(review): session + applyEdit op handlers (pure)"
```

---

### Task 4: `web/review.zig` — HTTP server (`/api/plan`, `/api/apply`, static)

**Files:** Modify `src/web/review.zig`, `src/web/static.zig`; Create empty `src/web/assets/review.{html,js,css}`

**Interfaces:**
```zig
pub const Options = struct { bind: []const u8 = "127.0.0.1", port: u16 = 8788 };
pub fn serve(io: std.Io, session: *Session, env: *std.process.Environ.Map, opts: Options, log: *std.Io.Writer) !void;
```

- [ ] **Step 1: Create placeholder assets + embed them**

Create `src/web/assets/review.html` (`<!doctype html><title>shelve review</title><link rel=stylesheet href=/review.css><body><div id=app>loading…</div><script src=/review.js></script>`), empty `review.css`, and `review.js` (`fetch('/api/plan').then(r=>r.json()).then(p=>{document.getElementById('app').textContent = p.groups.length+' groups';});`). Add to `static.zig`:
```zig
pub const review_html = @embedFile("assets/review.html");
pub const review_js = @embedFile("assets/review.js");
pub const review_css = @embedFile("assets/review.css");
```

- [ ] **Step 2: Implement `serve` (single-threaded loop)**

Mirror `web/server.zig`'s accept loop but handle each request inline (no thread spawn). Routes:
- `GET /` → `review_html` (text/html); `/review.js` (application/javascript); `/review.css` (text/css).
- `GET /api/plan` → `respondJson(request, try plan.toJson(session.arena, session.plan))`.
- `POST /api/edit` → `const body = try readBody(...); applyEdit(session, body) catch return respond 400; respondJson(plan)`.
- `POST /api/apply` → `const res = try apply.apply(session.arena, session.plan, .skip, env); respondJson({moved,trashed,skipped,journal})`.
- `GET /api/thumb` → 404 for now (Task 7).
- else 404.

Copy `readBody`/`claimReader`/`respondJson` from `web/api.zig` (they're small; duplicate into `review.zig` to keep it self-contained). Use `pathOnly` for query stripping. Respond helper for 400: `request.respond(msg, .{ .status = .bad_request })`.

- [ ] **Step 3: Manual verify (no unit test for the socket loop)**

```bash
zig build
# serve a fixture in the background, curl the API, then kill:
```
(Deferred to the Task 5 command + Task 8 smoke; here just confirm it compiles: `zig build`.)

- [ ] **Step 4: Run** `zig build && zig build test` — PASS (compiles; edit-op tests still green).
- [ ] **Step 5: Commit**

```bash
git add src/web/review.zig src/web/static.zig src/web/assets/review.html src/web/assets/review.js src/web/assets/review.css
git commit -m "feat(review): HTTP server — /api/plan, /api/edit, /api/apply + assets"
```

---

### Task 5: `shelve review` command + minimal working frontend

**Files:** Create `src/commands/review.zig`; Modify `src/shelve_cli.zig`, `src/web/assets/review.{html,js,css}`

**Interfaces:** `pub fn run(ctx: cli.Context, args: []const []const u8) !u8`

- [ ] **Step 1: Implement the command**

Parse args: positional `<dir>`, `--to LIB`, `--port N` (default 8788), `--no-probe`, `--from FILE`. Load `cfg = config.load`; override `library_root` with `--to`. Build the plan: `--from` → `readFile` + `plan.fromJson`; else `group.buildPlan(ctx.arena, ctx.io, dir, cfg, !no_probe)`. Then:
```zig
var session = review.Session{ .arena = ctx.arena, .cfg = cfg, .plan = p };
try ctx.stdout.print("reviewing at http://127.0.0.1:{d}/  (Ctrl+C to stop)\n", .{opts.port});
try ctx.stdout.flush();
try review.serve(ctx.io, &session, ctx.env, .{ .port = opts.port }, ctx.stdout);
return 0;
```
Wire into `shelve_cli.zig`: `if (eq(cmd, "review")) return review_cmd.run(ctx, rest);` + a usage line. Add `const review_cmd = @import("commands/review.zig");`.

- [ ] **Step 2: Write the real minimal frontend (render + role + apply)**

`review.html`: a header, `<div id=app>`, a footer with `<button id=apply>Apply</button>` and `<div id=summary>`. `review.js`: fetch `/api/plan`; render each group as a `<section>` with the folder header (dirname of the first item's dst, `~`-abbreviated) and a list of items; each primary/sidecar row shows the dst basename + a `<select>` (keep/skip/trash) that POSTs `/api/edit` `set-role` and re-renders from the response; duplicates/junk shown read-only. `Apply` POSTs `/api/apply` and shows the result. Keep it ~120 lines of vanilla JS. `review.css`: minimal readable styling.

- [ ] **Step 3: Manual end-to-end check**

```bash
zig build
TMP=$(mktemp -d); mkdir -p "$TMP/src"; printf x > "$TMP/src/The.Show.S01E01.720p.mkv"
XDG_CONFIG_HOME=$TMP/c XDG_DATA_HOME=$TMP/d ./zig-out/bin/shelve review "$TMP/src" --to "$TMP/lib" --port 8790 &
sleep 1
curl -s localhost:8790/api/plan | head -c 400; echo
curl -s -XPOST localhost:8790/api/apply | head; echo
kill %1; rm -rf "$TMP"
```
Expected: `/api/plan` returns Plan JSON with a group; `/api/apply` returns `{"moved":1,…,"journal":…}`.

- [ ] **Step 4: Run** `zig build test && ./scripts/smoke.sh --offline` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/commands/review.zig src/shelve_cli.zig src/web/assets/review.html src/web/assets/review.js src/web/assets/review.css
git commit -m "feat(shelve): review command + minimal render/toggle/apply UI"
```

---

### Task 6: Frontend — retitle + drag-to-regroup

**Files:** Modify `src/web/assets/review.js`, `review.css`

- [ ] **Step 1: Implement**

- Make each group's folder title an inline-editable element (`contenteditable` or an `<input>`); on blur, POST `/api/edit` `{op:"retitle",group,title}` and re-render (dst paths update live).
- Add a drag handle to each primary card; use HTML5 DnD (`draggable=true`, `dragstart` stores `{group,item}`, group `<section>` is a `dragover`/`drop` target → POST `{op:"move-item",from,item,to}` and re-render).
- Re-render always uses the server's returned Plan (source of truth).

- [ ] **Step 2: Manual check** — retitle a group in the browser, confirm the destination filenames update; drag an item to another group, confirm it re-parents. (`zig build` + open the page.)
- [ ] **Step 3: Run** `zig build` — compiles (assets embed).
- [ ] **Step 4: Commit**

```bash
git add src/web/assets/review.js src/web/assets/review.css
git commit -m "feat(review): inline retitle + drag-to-regroup"
```

---

### Task 7: `/api/thumb` + poster lazy-load

**Files:** Modify `src/web/review.zig`, `src/web/assets/review.js`, `review.css`

- [ ] **Step 1: Implement `/api/thumb`**

In `review.zig`, handle `GET /api/thumb?src=<path>`:
- Parse `src` from the query (url-decode minimal). **Reject** any `src` not present as an item `src` in `session.plan` → 403.
- Run `exec.runCaptureStdout(session.arena, io, &.{ "ffmpeg","-v","error","-ss","60","-i",src,"-frames:v","1","-vf","scale=320:-1","-f","image2pipe","-vcodec","mjpeg","-" }, 4*1024*1024)`. If ffmpeg missing / exit != 0 / empty → 404. Else `request.respond(jpeg, .{ .status = .ok, .extra_headers = &.{ .{ .name="content-type", .value="image/jpeg" }, .{ .name="cache-control", .value="max-age=3600" } } })`.

- [ ] **Step 2: Frontend** — each primary card gets an `<img loading=lazy src="/api/thumb?src=<encoded item.src>">` with an `onerror` that hides it (placeholder). Style posters small (e.g. 96px wide).

- [ ] **Step 3: Manual check (ffmpeg present here)**

```bash
zig build
TMP=$(mktemp -d); mkdir -p "$TMP/src"
ffmpeg -v error -f lavfi -i testsrc=d=2:s=640x480 -y "$TMP/src/The.Show.S01E01.mp4"
XDG_CONFIG_HOME=$TMP/c XDG_DATA_HOME=$TMP/d ./zig-out/bin/shelve review "$TMP/src" --to "$TMP/lib" --port 8791 &
sleep 1
src=$(curl -s localhost:8791/api/plan | python3 -c 'import json,sys;print(json.load(sys.stdin)["groups"][0]["items"][0]["src"])')
curl -s "localhost:8791/api/thumb?src=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$src")" -o "$TMP/t.jpg"
file "$TMP/t.jpg"   # expect JPEG image data
kill %1; rm -rf "$TMP"
```
Expected: a JPEG is returned.

- [ ] **Step 4: Run** `zig build test` — PASS.
- [ ] **Step 5: Commit**

```bash
git add src/web/review.zig src/web/assets/review.js src/web/assets/review.css
git commit -m "feat(review): ffmpeg poster thumbnails (/api/thumb)"
```

---

### Task 8: smoke + docs + verification

**Files:** Create `scripts/review-smoke.sh`; Modify `justfile`

- [ ] **Step 1: Write `scripts/review-smoke.sh`**

Start `shelve review` on a synthetic messy dir (`--port` fixed, isolated XDG), then: `curl /api/plan` (assert a group + an item `dst` present), `curl -XPOST /api/edit` a retitle (assert the returned dst contains the new title), `curl -XPOST /api/apply` (assert `moved` > 0), assert the templated file exists under the temp library, then `shelve undo` and assert it's gone from the library. `kill` the server; `trap` cleanup. Uses `python3` for JSON asserts (available). Exit non-zero on any failure.

- [ ] **Step 2: Add a justfile recipe**

```make
# Review a folder in the browser (applies on click; undo with `just undo`).
review DIR="" *FLAGS="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just review DIR [--to LIB] [--port N]"; exit 1; fi
    ./zig-out/bin/shelve review "{{DIR}}" {{FLAGS}}
```

- [ ] **Step 3: Run the smoke**

`zig build && ./scripts/review-smoke.sh` → all assertions pass.

- [ ] **Step 4: Full verification**

```bash
rm -rf .zig-cache zig-out && zig build && zig build test && ./scripts/smoke.sh --offline && ./scripts/organize-smoke.sh && ./scripts/review-smoke.sh
```
Expected: clean build (biblio + shelve), unit tests, all three smokes green.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-smoke.sh justfile
git commit -m "test(review): API smoke + justfile recipe"
```

---

## Self-Review

**Spec coverage:**
- `shelve review` command + local server → Tasks 4–5. ✓
- Server-authoritative session, edit ops (set-role/retitle/move-item/split) → Task 3; recompute via Zig engine → Tasks 2–3. ✓
- `Plan.Fields` + shared `naming.dstFor` → Tasks 1–2. ✓
- `/api/plan`, `/api/edit`, `/api/apply`, `/api/thumb` → Tasks 4, 7. ✓
- Frontend: render + keep/skip/trash → Task 5; retitle + drag-regroup → Task 6; posters → Task 7. ✓
- Apply = real move + journal; 127.0.0.1; nothing until Apply → Tasks 4–5. ✓
- `/api/thumb` path-allowlist + ffmpeg-optional → Task 7. ✓
- Testing: `naming.dstFor` (2), edit-op handlers (3), review smoke (8) → covered; frontend not unit-tested (noted). ✓
- **Deferred per spec:** TUI review (3b), auth/remote, file write-back.

**Placeholder scan:** Task 2/3 say "mirror"/"copy readBody from api.zig" — that's concrete, currently-present code the implementer copies verbatim; not hidden work. Frontend steps specify exact endpoints, payload shapes, and behaviors. No "TBD"/"handle edge cases".

**Type consistency:** `plan.Fields`/`Item.fields` (1) consumed by `naming.dstFor` (2) and `applyEdit`/`recompute` (3). `naming.dstFor(arena, cfg, kind, fields)` signature consistent across Tasks 2–3, 7. `review.Session{arena,cfg,plan}` + `review.serve(io, *Session, env, Options, log)` consistent between Tasks 3–5. `apply.apply(alloc, plan, .skip, env)` matches the existing signature. Edit-op JSON shapes (`op`/`group`/`item`/`role`/`title`/`from`/`to`/`items`) consistent between Task 3 handlers and Task 5–6 frontend.
