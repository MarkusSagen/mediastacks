# stacks — a kind-aware media organizer

**Date:** 2026-07-28
**Status:** Design approved, pending spec review

## Summary

Grow today's `booktool` codebase into `stacks`: a shared, kind-aware
engine that reorganizes and relabels messy media folders into a clean,
templated library structure. The engine covers TV series, movies, games,
documents, and the ebooks/comics `booktool` already handles. It is
**offline-first** (parse everything possible from filenames and sidecars;
online metadata providers are opt-in), **CLI-first** (a serializable
reorganization *Plan* is the contract), and **safe** (move-into-library
with a reversible undo journal; deletes go to the system trash, never
`rm`).

The work is structured as a shared **core library** with **two focused
front-end binaries** — see "Project structure" below.

## Goals

- Point the tool at a messy download folder and get a clean, correct
  reorganization with minimal fuss.
- Handle heterogeneity within one folder: mixed naming conventions,
  nested per-item subfolders, junk files, and duplicate copies.
- Keep every step reviewable and reversible.
- Reuse `booktool`'s existing, working machinery rather than reinventing
  it, without adding surface area to `booktool` itself.

## Non-goals

- Streaming/serving media (that is a media server's job).
- A metadata-scraping GUI. Online enrichment is a later, optional phase.
- Music. Not in scope for v1 (a dedicated tool like beets already exists;
  can be added later as another kind).

## The motivating example

`~/Downloads/down/Witch Hat Atelier/` contains, for one season:

- Loose files: `witch.hat.atelier.s01e12.1080p.web.h264-skyanime[EZTVx.to].mkv`
- Nested per-episode folders:
  `www.UIndex.org    -    Witch Hat Atelier S01E04 … -Kitsune/…mkv` (+ `.nfo`)
- `.DS_Store` files scattered throughout
- **Two copies of most episodes** (one loose, one nested), from different
  release groups.

Desired result (TV template):

```
<library>/TV/Witch Hat Atelier/Season 01/Witch Hat Atelier - S01E12 - The Shadow of Romonon.mkv
```

…with the best copy of each episode chosen, duplicates flagged, `.nfo`
sidecars carried along and renamed to match, and junk trashed.

## Project structure

Chosen model: **shared core library + two focused binaries** (no combined
umbrella wrapper — YAGNI).

- **`stacks`** — the project/repo name and the shared core library
  (`src/root.zig`). Kind-aware engine: books are one kind among many.
- **`biblio`** — the renamed book/comic binary. Its surface, feel, and UX
  (reading, covers, EPUB pipeline, TUI, Web) are **unchanged**; it simply
  links the shared library instead of owning all the code.
  *(Name adjustable in review: `codex`, `quire`, or keep `booktool`.)*
- **`shelve`** — the new general-organizer binary. Exposes `organize` /
  `undo` across all kinds. Because the engine is kind-aware, `shelve` can
  organize books too, but `biblio` remains the focused reading experience.

Both binaries link the same `stacks` core library. Nothing is added to
`biblio`'s command surface.

## Architecture

### Pipeline

```
scan+hash → classify → parse → group → plan → review → apply+journal
 (reuse)    (new)      (new)   (new)   (new)  (surfaces)   (new)
```

### Modules

New (alongside existing `src/core/`):

- `core/kind.zig` — the `MediaKind` enum (`ebook`, `comic`, `movie`, `tv`,
  `game`, `document`, `unknown`) and shared **release-token stripping**
  (drop `www.*` prefixes, `[bracket tags]`, quality/codec/release-group
  noise). Used by every parser.
- `core/classify.zig` — deterministic rules mapping an entry (extension +
  filename signals + surrounding folder) to a `MediaKind`, or `unknown`.
- `kinds/tv.zig`, `kinds/movie.zig`, `kinds/game.zig`,
  `kinds/document.zig` — per-kind field parsers. Ebooks/comics reuse the
  existing `formats/` handlers rather than a new parser.
- `core/group.zig` — cluster loose files and nested folders into logical
  items (a series with its episodes; a movie with its subs/nfo/sample).
  Reuses `util/fuzzy`.
- `core/plan.zig` — build and (de)serialize the `Plan` (see below).
- `core/apply.zig` + `core/journal.zig` — execute a Plan's operations and
  write the undo journal.

Reused unchanged: `formats/`, `core/dedup`, `core/quality`, `core/score`,
`core/template`, `core/job_runner`, `core/catalog` (extended — see Data),
`util/*`.

### The Plan — the CLI contract

One serializable structure (JSON) flows through the whole system. The CLI
emits it; the TUI and Web render and edit it; apply executes it. This is
what keeps the CLI the source of truth.

```
Plan {
  library_root, source, generated_at,
  groups: [ Group {
    kind, title, year, confidence,
    fields { …kind-specific… },
    items: [ Item {
      src, role: primary | sidecar | duplicate | junk,
      op:   move | copy | trash | skip,
      dst,  reason
    } ],
    warnings: [ … ]
  } ],
  unclassified: [ paths ]
}
```

Editing a plan = mutating this structure: retitle a group and its `dst`
paths recompute from the template; toggle an item's `role`; merge or
split groups. The TUI and Web are editors over this JSON.

### Data

`core/catalog` gains a `kind` column and a generic metadata blob (JSON
text) so any kind's parsed fields persist without a schema-per-kind. The
existing book columns stay for `biblio`'s use. Catalog remains one SQLite
file (`$XDG_DATA_HOME/stacks/catalog.db`).

## Classification, parsing, junk & dedup (worked example)

Applied to the Witch Hat Atelier folder:

1. **Classify** → `tv` (an `SxxExx` pattern plus a video extension).
2. **Parse** (`kinds/tv.zig`) → `series="Witch Hat Atelier"`, `season=1`,
   `episode=12`; quality/codec/group tokens stripped via `core/kind`.
   Episode titles come from the descriptive filename or the `.nfo`.
3. **Group** (`core/group.zig`) → one series/season; each episode has two
   candidate video files (loose `skyanime`, nested `Kitsune`).
4. **Dedup** (reuse `core/quality` + `core/score`) → the best copy per
   episode becomes `primary`; the other is tagged `duplicate` (kept by
   default; trashable on request).
5. **Junk** → `.DS_Store`, `sample` files, and emptied
   `www.UIndex.org - …` wrapper folders → `trash` op (system trash, so
   reversible). `.nfo` and subtitle files → `sidecar`, renamed to match
   their episode's new name.

The same engine handles other kinds by swapping the parser:
- **Movies** — single file or folder-per-movie; extract title + year +
  edition/quality; strip release-group noise.
- **Games** — group multi-disc / multi-file installs; region/version
  tags; platform-based folders.
- **Documents** — loose PDFs/papers/manuals beyond `biblio`'s ebook
  handling.

## Templates & library config

A config file (`$XDG_CONFIG_HOME/stacks/config.toml`) holds a library
root and a naming template per kind. Templates extend the existing
`core/template` engine.

```
TV:     {root}/TV/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}
Movies: {root}/Movies/{title} ({year})/{title} ({year}).{ext}
Books:  (biblio's existing template)
```

→ `…/TV/Witch Hat Atelier/Season 01/Witch Hat Atelier - S01E12 - The Shadow of Romonon.mkv`

## Apply, undo & safety

- Bare `shelve organize <dir>` is **always a dry-run** that prints (or
  writes) the Plan. Nothing mutates without `--apply`.
- Apply executes a Plan's ops in order. **Deletes go to the system trash,
  never a hard `rm`.**
- Each apply writes a journal
  (`$XDG_DATA_HOME/stacks/undo/<timestamp>.json`) recording every
  `from → to` move and every trashed path.
- `shelve undo` reverses the most recent apply from its journal.
- Destination collision handling: `--on-conflict=skip|suffix|overwrite`
  (default `skip`, with a warning).

## CLI surface (primary)

```
shelve organize <dir> [--kind auto|tv|movie|game|document] [--to <lib>]
    Dry-run: build and print the Plan.

shelve organize <dir> --apply
    Execute the Plan (move into library, write undo journal).

shelve organize <dir> --plan out.json      # write Plan JSON (feed TUI/Web)
shelve organize --from plan.json --apply    # apply a reviewed/edited Plan

shelve undo
    Reverse the most recent apply.
```

The TUI and Web surfaces load a Plan (via `--plan` / `--from`), let the
user edit it, and apply — they never bypass the Plan contract.

## Phasing

1. **Framework + TV + Movies.** `kind`, `classify`, per-kind parse,
   `group`, `plan`, `apply`, `undo`, config, and the `shelve organize`
   CLI. Rename `booktool` → `biblio` and extract the shared `stacks`
   core library. (Highest value: the download folders are mostly video.)
2. **Games + Documents** parsers and classifier rules.
3. **TUI review** screen, then **Web review** page over the Plan JSON.
4. **Optional online providers** (TMDB/TVDB for video, IGDB for games)
   behind the existing `providers/` interface, as an opt-in enrichment
   step.

## Testing

Follows `booktool`'s existing style (unit tests + smoke script):

- **Parser unit tests** — filename/sidecar → expected fields, per kind,
  including the three Witch Hat naming variants.
- **Classifier truth-table** — representative paths → expected
  `MediaKind`.
- **Planner golden tests** — a fixture directory → an expected Plan JSON.
- **End-to-end smoke** — organize a synthetic messy folder, assert the
  resulting tree, then `undo` and assert the original tree is restored.

## Open items

- Final names: `stacks` (project/lib), `shelve` (organizer),
  `biblio` (book binary). All adjustable here.
- Whether duplicates default to kept-and-flagged or trashed. Design
  assumes kept-and-flagged (safer).
