# stacks — Web review over the Plan JSON

**Date:** 2026-08-09
**Status:** Design approved, pending spec review

## Summary

A browser review surface for `shelve`: `shelve review <dir>` builds a
reorganization `Plan`, serves a small local web UI, and lets you review and
**edit** the plan — toggle keep/skip/trash, fix titles (paths recompute
live), drag items between groups, see video posters — then Apply (real
moves + undo journal). The server is **authoritative** for naming: the
browser sends edit ops, the server recomputes destinations with the Zig
template engine and returns the updated Plan. The `Plan` stays the single
shared contract.

This is Phase 3a. The TUI review (Phase 3b) is a separate cycle over the
same Plan/edit-op model.

## Goals

- Review a plan visually and fix its mistakes before applying.
- Edits: keep/skip/trash per item; retitle a group (live path recompute);
  drag an item to another group (merge/split); video posters.
- Reuse the `Plan` contract and all naming/grouping logic (no JS
  duplication of the template engine).
- Local, safe: `127.0.0.1` only; nothing moves until Apply; every Apply is
  reversible via `shelve undo`.

## Non-goals

- Auth / remote access / multi-user. Localhost single session.
- Editing the media files themselves (that's write-back, deferred).
- Persisting a partially-edited plan across server restarts (the session is
  in memory; `--from plan.json` loads a saved plan, `--plan out.json` still
  saves the built one from the CLI).

## Decisions (from brainstorming)

- Web review **first**; TUI review is a later cycle.
- v1 edits: **all four** — keep/skip/trash, retitle+live-dst,
  drag-to-regroup (merge/split), video thumbnails.
- **Server-authoritative session:** browser sends edit ops; server mutates
  the in-memory Plan, recomputes `dst` via the Zig template engine, returns
  the updated Plan.
- New self-contained `web/review.zig`; the Catalog-coupled book server
  (`web/server.zig`, `web/api.zig`) is untouched.

## Architecture

### Invocation

`src/commands/review.zig` → `shelve review` subcommand:
```
shelve review <dir> [--to LIB] [--port N] [--no-probe] [--from plan.json]
```
Builds the Plan (`group.buildPlan`, honoring `--no-probe` and config
`preset`), or loads it from `--from`, then calls `review.serve`. Prints
`reviewing at http://127.0.0.1:<port>/`. Wired into `shelve_cli.zig`.

### `Plan` enrichment + shared naming

- `plan.zig`: add `pub const Fields = struct { series: ?[]const u8 = null,
  season: ?u32 = null, episode: ?u32 = null, title: ?[]const u8 = null,
  year: ?u32 = null, ext: ?[]const u8 = null };` and `Item.fields: ?Fields
  = null` (additive, serializes like the existing `media`).
- New `core/naming.zig`: `pub fn dstFor(arena, cfg: config.Config, kind:
  kind.MediaKind, f: plan.Fields) ![]u8` — the single place that renders a
  destination from fields + the kind's template. `group.zig`'s current
  `tvDst`/`movieDst` are replaced by calls to it, and `buildPlan` populates
  `Item.fields` for every primary/sidecar so the review server can
  recompute after edits.

### Server — `web/review.zig`

Self-contained HTTP server (mirrors `web/server.zig`'s accept/response
loop; `std.http.Server`), bound to `127.0.0.1`. Holds a mutable session:
```
const Session = struct {
    arena: std.mem.Allocator,
    cfg: config.Config,
    plan: plan.Plan,   // mutated in place by edit ops
};
```
`pub fn serve(arena, io, session: *Session, port, log) !void`.

### Routes

- `GET /` → `review.html`; `GET /review.js`, `/review.css` → embedded assets.
- `GET /api/plan` → `plan.toJson(session.plan)`.
- `POST /api/edit` → body is one op; mutate session + recompute; respond
  with the updated Plan JSON. Ops:
  - `{"op":"set-role","group":G,"item":I,"role":"primary|skip|trash"}` —
    sets role + op (`primary`→move, `skip`→skip, `trash`→trash; `dst` null
    for skip/trash, recomputed for primary).
  - `{"op":"retitle","group":G,"title":"…"}` — sets `group.title` (and each
    item's `fields.series` for tv), recomputes every item's `dst` via
    `naming.dstFor`.
  - `{"op":"move-item","from":G,"item":I,"to":H}` — re-parents the item to
    group H (tv: adopt H's series; movie: stays), recomputes its `dst`;
    empties source group is dropped.
  - `{"op":"split","group":G,"items":[…],"title":"…"}` — new group from the
    selected items.
  Unknown op or out-of-range index → 400, plan unchanged.
- `GET /api/thumb?src=<abs path>` → poster JPEG. `exec.runCaptureStdout`
  with `ffmpeg -v error -ss 60 -i <src> -frames:v 1 -vf scale=320:-1 -f
  image2pipe -vcodec mjpeg -`; on ffmpeg-absent / failure → 404. `src` must
  be one of the plan's item paths (reject arbitrary paths).
- `POST /api/apply` → `apply.apply(session.plan, .skip, env)`; respond
  `{"moved":…,"trashed":…,"skipped":…,"journal":"…"}`.

### Frontend (`web/assets/review.{html,js,css}`, vanilla JS)

Groups rendered as folder-titled boxes; items as cards with a poster
(lazy `GET /api/thumb`), the destination filename, a `keep/skip/trash`
`<select>`, and a drag handle. Inline-editable group title (blur → retitle
op). HTML5 drag-and-drop moves a card between group boxes (→ move-item op).
A footer shows counts + warnings and an **Apply** button; after apply,
shows the result + "run `shelve undo` to revert". Every edit re-renders
from the server's returned Plan (server is source of truth).

## Error handling

- Bad edit indices / unknown op → HTTP 400, session unchanged.
- `/api/thumb` for a path not in the plan → 403; ffmpeg missing/failure →
  404 (page shows a placeholder, no crash).
- Apply failure → 500 with the error name; the journal records whatever
  succeeded so `shelve undo` still works.
- Malformed edit JSON → 400.

## Testing

- `naming.dstFor` — tv & movie fields → expected path (moves the existing
  dst assertions here); unchanged behavior for `buildPlan` golden test.
- Edit-op handlers (pure, on an in-memory `Plan`): `applyEdit(session,
  op_json)` — set-role flips op/dst; retitle recomputes every dst;
  move-item re-parents + recomputes; bad index → error. No HTTP needed.
- Shell smoke (`scripts/review-smoke.sh`): start `shelve review` on a
  fixture dir with `--port`, `curl /api/plan` (assert group/item JSON),
  `curl -XPOST /api/edit` a retitle (assert dst changed), `curl -XPOST
  /api/apply`, assert the resulting tree + journal, then `shelve undo`.
- Frontend JS not unit-tested (consistent with `app.js`); the smoke covers
  the API it relies on.

## Task sequencing (for the plan)

Land a working subset early, then layer:
1. `plan.Fields` + `naming.dstFor` (refactor `group.zig` to use it).
2. `buildPlan` populates `Item.fields`.
3. `applyEdit` handlers (set-role, retitle, move-item, split) — pure, tested.
4. `web/review.zig` server + `/api/plan` + `/api/apply` + static assets.
5. `shelve review` command + `shelve_cli` wiring + minimal frontend
   (render + role toggle + apply).
6. Retitle + drag-to-regroup in the frontend.
7. `/api/thumb` + poster lazy-load.
8. review smoke + docs/justfile.

## Open items

- Poster timestamp: fixed `-ss 60`; if duration < 60s ffmpeg yields the
  last frame (acceptable). Finalize in the plan.
