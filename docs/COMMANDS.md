# mediastacks CLI reference

Every subcommand exits with `0` on success, `1` on bad arguments or
empty result sets, `2` on I/O / external-tool failures.

The catalog database lives at `$XDG_DATA_HOME/mediastacks/catalog.db`
(default: `~/.local/share/mediastacks/catalog.db`). It's created on first
write.

---

## `mediastacks info FILE`

Print embedded metadata of a single ebook. No catalog interaction.

Works for every supported format: **EPUB / MOBI / AZW3 / PDF** and the
comic archives **CBZ / CBR / CB7 / CBT**. For comic archives the values
come from a sibling `ComicInfo.xml` inside the archive (when present).

```
$ mediastacks info "Sanderson, Brandon - The Way of Kings.epub"
Path:        Sanderson, Brandon - The Way of Kings.epub
Format:      epub
Title:       The Way of Kings
Authors:     Sanderson, Brandon
Year:        2010
ISBN:        9780765365279
Language:    en
```

---

## `mediastacks find PATH [options]`

Read-only ebook discovery. Walks `PATH` recursively, prints every
ebook by absolute path. Does not touch the catalog.

| Flag | Effect |
|---|---|
| `--glob PATTERN` | Filter by shell-style glob. Supports `*`, `**`, `?`, `[abc]`, `[a-z]`, `[!a-z]`. Path matching is relative to `PATH`. |
| `--format FMT` | One of `epub`, `mobi`, `azw3`, `pdf`, `cbz`, `cbr`, `cb7`, `cbt`. |
| `-0`, `--null` | NUL-separated output for safe `xargs -0`. |

Examples:

```sh
mediastacks find ~/Books
mediastacks find . --glob "**/Hobb*" --format mobi
mediastacks find . -0 | xargs -0 -n1 mediastacks info
```

Exit code is `1` if no matches.

---

## `mediastacks scan DIR`

Walk `DIR` recursively, hash every supported file (SHA-256), extract
embedded metadata, and upsert into the catalog. Picks up every format
mediastacks knows about: **EPUB / MOBI / AZW3 / PDF** and the comic
archives **CBZ / CBR / CB7 / CBT**. Re-scanning is idempotent — files
with unchanged SHA are reported as `[=]` and not re-processed.

```
$ mediastacks scan ~/Books
[+] id=1 epub /Users/me/Books/Sanderson, Brandon - The Way of Kings.epub
[=] id=2 /Users/me/Books/Hobb, Robin - Assassin's Apprentice.mobi
...
seen=247 ingested=12 unchanged=235 errors=0
```

---

## `mediastacks missing [PATH] [--glob PATTERN]`

List catalogued books that lack one or more of: **title**, **author**,
**published_year**, **isbn**. Optionally restricted to a path prefix
or glob.

```sh
mediastacks missing
mediastacks missing ~/Books/scifi
mediastacks missing --glob "**/Hobb*"
```

Each entry shows the missing-field set; use `mediastacks enrich` or
`mediastacks set-meta` to fill them in.

---

## `mediastacks cover FILE`

Extract the cover image from `FILE` and render it inline via
[`chafa`](https://hpjansson.org/chafa/). Auto-detects Kitty graphics
protocol / Sixel / Unicode fallback.

Requires `chafa` on `PATH` (`brew install chafa`).

For MOBI/AZW3, additionally requires `mobitool` (ships with `libmobi`).

---

## `mediastacks convert SRC --to FMT`

Convert `SRC` into format `FMT` (epub/mobi/azw3/pdf). Output is
written next to the source.

| Source → Target | Engine |
|---|---|
| MOBI / AZW3 → EPUB | libmobi via `mobitool -e` |
| anything else | Calibre's `ebook-convert` (must be installed) |

```sh
mediastacks convert dracula.mobi --to epub
mediastacks convert dracula.epub --to mobi
```

Returns the path of the new file on stdout.

---

## `mediastacks enrich [--missing] [--limit N]`

Query Open Library for every (or just incomplete) book in the catalog
and merge results into the existing metadata. The merge respects
source confidence: embedded values are not clobbered by lower-quality
network results.

| Flag | Effect |
|---|---|
| `--missing` | Only books currently flagged by `missing`. |
| `--limit N` | Stop after N books (spot-test). |

```sh
mediastacks enrich --limit 5
mediastacks enrich --missing
```

---

## `mediastacks dedup [--apply] [--exact-only] [--fuzzy-only]`

Two-tier duplicate detection:

1. **Exact** — identical SHA-256.
2. **Fuzzy / cross-format** — same author + Jaro-Winkler title
   similarity above threshold. Catches EPUB + MOBI of the same book,
   different editions, etc.

For each group, the highest-scoring copy is the "keep" candidate. The
score weighs format (EPUB > AZW3 > MOBI > PDF), metadata completeness
(ISBN, year, series, cover), and file size.

```
== Cross-format / fuzzy duplicates ==

Hobb, Robin — Assassin's Apprentice
  [keep] id=8  /…/Assassin's Apprentice.epub  (epub, 402k, score 65.1)
  [ dup] id=3  /…/Assassin's Apprentice.mobi  (mobi, 620k, score 55.7)
```

With `--apply`, duplicates are deleted from disk and the catalog.

---

## `mediastacks rename [options]`

Rewrite filenames into a canonical, template-driven layout. **Dry-run by
default; pass `--apply` to move files.**

| Flag | Effect |
|---|---|
| `--template "TPL"` | Custom template string. |
| `--preset NAME` | One of `default`, `flat`, `series-dir`. |
| `--list-presets` | Print the built-in templates and exit. |
| `--apply` | Actually move files. |

Template fields:

| Field | Source |
|---|---|
| `{author_sort}` | "Last, First" of first author |
| `{author}` | "First Last" |
| `{title}` | Book title |
| `{series}` | Series name (empty if absent) |
| `{series_index:02}` | Position in series, zero-padded |
| `{year}` | 4-digit published year |
| `{isbn}` | ISBN-13 |
| `{format}`, `{ext}` | `epub`, `mobi`, `azw3`, `pdf` |

Built-in templates:

```
default     {author_sort} - {series} {series_index:02} - {title}.{ext}
flat        {author_sort} - {title}.{ext}
series-dir  {author_sort}/{series}/{series_index:02} - {title}.{ext}
```

The renderer collapses empty segments cleanly:

```
no series   "Williams, John - Augustus.epub"
series-dir
  with series   "Sanderson, Brandon/Stormlight/01 - The Way of Kings.epub"
  no series     "Williams, John/Augustus.epub"
```

`series-dir` and any template with `/` will create subdirectories as
needed.

---

## `mediastacks set-meta FILE [options]`

Edit the **embedded** metadata of a single book (the title shown by
readers, not the filename). Re-packs the archive in place.

| Flag | Effect |
|---|---|
| `--title TEXT` | Replace `<dc:title>` |
| `--author "Last, First"` | Replace `<dc:creator>` |
| `--series TEXT` | Calibre-compatible `calibre:series` meta |
| `--series-index N` | Calibre-compatible `calibre:series_index` meta |
| `--year YYYY` | Replace `<dc:date>` |

EPUB: in-place OPF rewrite + ZIP repack.
MOBI/AZW3: shells out to `mobimeta` (libmobi). `--series` flags are
EPUB-only.

```sh
mediastacks set-meta "Hobb*.mobi" --title "Assassin's Apprentice"
mediastacks set-meta book.epub --series "Stormlight" --series-index 1
```

---

## `mediastacks set-cover FILE IMAGE`

Replace the cover image. Behaviour depends on format:

- **EPUB** — image bytes are dropped into the existing `cover-image`
  manifest entry and the archive is repacked. The same bytes are also
  mirrored into `$XDG_DATA_HOME/mediastacks/covers/<id>.<ext>` so the web
  UI / TUI render the chosen cover instantly without re-extracting
  from the archive.
- **MOBI / AZW3** — libmobi exposes no cover-write API, so the source
  file is left untouched. The image is written *only* as a library-side
  override at `$XDG_DATA_HOME/mediastacks/covers/<id>.<ext>`, where every
  mediastacks surface picks it up. The command prints the override path
  and reminds you to run `mediastacks convert --to epub` if you want the
  change baked into the file itself. **Requires the book to already
  be in the catalog** (`mediastacks scan` it first) so the override file
  has a stable id to key off of.

```sh
mediastacks set-cover book.epub ~/Pictures/new-cover.jpg
mediastacks set-cover book.mobi ~/Pictures/new-cover.jpg   # override only
```

For EPUBs the archive must already declare a `cover-image` item;
mediastacks refuses to fabricate a cover entry from scratch (use a tool
like Calibre or Sigil to set one initially).

Content type (`image/jpeg` vs `image/png`) is auto-detected from magic
bytes; the override file is named accordingly.

---

## `mediastacks optimize FILE...`

Recompress EPUB archives with the highest deflate level. Saves typically
0–10 % depending on how the source was packed. The `mimetype` entry is
preserved as stored (uncompressed) per the OCF spec.

Refuses to overwrite if the result is no smaller. Atomic rename only on
strict improvement.

```sh
mediastacks optimize ~/Books/*.epub
```

Image recompression and HTML/CSS minification are **not** in this
command yet — see `epub-optimizer` and `epuboptim` for those. They are
the next iteration here.

---

## `mediastacks standardize DIR [options]`

Meta-command that pipelines:

1. `scan DIR`
2. `enrich`
3. `dedup` (with `--apply` if requested)
4. `rename` (with `--apply` if requested)
5. `optimize` of every catalogued EPUB (only when `--apply`)

Dry-run by default. Skip individual steps with `--no-enrich`,
`--no-dedup`, `--no-rename`, `--no-optimize`.

```sh
mediastacks standardize ~/Books              # preview everything
mediastacks standardize ~/Books --apply      # do it
mediastacks standardize ~/Books --apply --no-optimize --template "{year} - {author_sort} - {title}.{ext}"
```

Execution is sequential. Parallelizing with `std.Io.concurrent` is
planned but not yet wired up.

---

## `mediastacks serve [--port N] [--bind IP]`

Run the web UI on the given address (default `http://127.0.0.1:8787`).
The SPA serves the same catalog the CLI sees: list, search, facets,
triage queue, rename / standardize lenses, batch enrich, command
palette (⌘K), and an in-browser reader for **EPUB / MOBI / AZW3 / FB2
/ CBZ** via foliate-js and **PDF** via pdf.js.

See [`WEB.md`](./WEB.md) for the full feature tour and HTTP route
table.

---

## `mediastacks schedule <sub>`

Manage scheduled maintenance jobs. Definitions live in the catalog
DB so both `mediastacks serve` (in-process scheduler thread) and
`mediastacks schedule daemon` (standalone) execute the same list.

| Subcommand | Effect |
|---|---|
| `list` | Show every scheduled job: id, name, spec, type, enabled, next run |
| `add NAME SPEC TYPE` | Create a job |
| `rm ID` | Delete a job |
| `enable ID` / `disable ID` | Toggle whether the job fires on its tick |
| `run ID` | Run a job NOW (synchronous, ignores schedule) |
| `daemon` | Run the scheduler loop without the HTTP server (Ctrl+C to stop) |

Specs supported:

| Spec | Fires |
|---|---|
| `@hourly` | Top of every hour |
| `@daily` | Every day at 03:00 UTC |
| `@weekly` | Every Monday at 03:00 UTC |
| `@monthly` | First of every month at 03:00 UTC |
| `every Nm` | Every N minutes from last run (N ≥ 1) |
| `every Nh` | Every N hours from last run (N ≥ 1) |

Job types:

| Type | What it does |
|---|---|
| `rescan-all` | Walk every tracked library source for new / removed files |
| `enrich-missing` | Open Library lookup for every catalog row with `enrich_status` null or `error`. Idempotent — already-OK rows are skipped |
| `backfill-paths` | Parse series / index from filenames; write back where the catalog row has none |
| `standardize-dry` | Build the canonical-rename plan and report counts only (no file mutations) |

Examples:

```sh
mediastacks schedule add nightly-rescan @daily rescan-all
mediastacks schedule add backfill-6h "every 6h" backfill-paths
mediastacks schedule run 1            # fire now, regardless of schedule
mediastacks schedule daemon           # run the loop without the web server
```

Concurrency: only one job runs at a time, guarded by a process-local
mutex inside the executor. Both `mediastacks serve` and
`mediastacks schedule daemon` can be running simultaneously without
double-firing if they share a catalog — the second one's tick will
skip jobs the first already claimed via `last_run_status='running'`.

---

## `mediastacks tui`

Open the terminal UI. Two views:

| View | Bindings |
|---|---|
| List | `j`/`k`/`↑`/`↓` move, `g`/`G` top/bottom, `enter` open, `q` quit |
| Reader | `space`/`→`/`l` next page, `b`/`h`/`←` prev, `q` back |

EPUB only for now — MOBI/AZW3 books prompt to convert first.

---

## `mediastacks help` / `version`

Standard. `version` is also `-V` and `--version`. Help is `-h`,
`--help`, or the subcommand `help`.
