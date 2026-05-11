# booktool CLI reference

Every subcommand exits with `0` on success, `1` on bad arguments or
empty result sets, `2` on I/O / external-tool failures.

The catalog database lives at `$XDG_DATA_HOME/booktool/catalog.db`
(default: `~/.local/share/booktool/catalog.db`). It's created on first
write.

---

## `booktool info FILE`

Print embedded metadata of a single ebook. No catalog interaction.

```
$ booktool info "Sanderson, Brandon - The Way of Kings.epub"
Path:        Sanderson, Brandon - The Way of Kings.epub
Format:      epub
Title:       The Way of Kings
Authors:     Sanderson, Brandon
Year:        2010
ISBN:        9780765365279
Language:    en
```

---

## `booktool find PATH [options]`

Read-only ebook discovery. Walks `PATH` recursively, prints every
ebook by absolute path. Does not touch the catalog.

| Flag | Effect |
|---|---|
| `--glob PATTERN` | Filter by shell-style glob. Supports `*`, `**`, `?`, `[abc]`, `[a-z]`, `[!a-z]`. Path matching is relative to `PATH`. |
| `--format FMT` | One of `epub`, `mobi`, `azw3`, `pdf`. |
| `-0`, `--null` | NUL-separated output for safe `xargs -0`. |

Examples:

```sh
booktool find ~/Books
booktool find . --glob "**/Hobb*" --format mobi
booktool find . -0 | xargs -0 -n1 booktool info
```

Exit code is `1` if no matches.

---

## `booktool scan DIR`

Walk `DIR` recursively, hash every ebook file (SHA-256), extract
embedded metadata, and upsert into the catalog. Re-scanning is
idempotent — files with unchanged SHA are reported as `[=]` and not
re-processed.

```
$ booktool scan ~/Books
[+] id=1 epub /Users/me/Books/Sanderson, Brandon - The Way of Kings.epub
[=] id=2 /Users/me/Books/Hobb, Robin - Assassin's Apprentice.mobi
...
seen=247 ingested=12 unchanged=235 errors=0
```

---

## `booktool missing [PATH] [--glob PATTERN]`

List catalogued books that lack one or more of: **title**, **author**,
**published_year**, **isbn**. Optionally restricted to a path prefix
or glob.

```sh
booktool missing
booktool missing ~/Books/scifi
booktool missing --glob "**/Hobb*"
```

Each entry shows the missing-field set; use `booktool enrich` or
`booktool set-meta` to fill them in.

---

## `booktool cover FILE`

Extract the cover image from `FILE` and render it inline via
[`chafa`](https://hpjansson.org/chafa/). Auto-detects Kitty graphics
protocol / Sixel / Unicode fallback.

Requires `chafa` on `PATH` (`brew install chafa`).

For MOBI/AZW3, additionally requires `mobitool` (ships with `libmobi`).

---

## `booktool convert SRC --to FMT`

Convert `SRC` into format `FMT` (epub/mobi/azw3/pdf). Output is
written next to the source.

| Source → Target | Engine |
|---|---|
| MOBI / AZW3 → EPUB | libmobi via `mobitool -e` |
| anything else | Calibre's `ebook-convert` (must be installed) |

```sh
booktool convert dracula.mobi --to epub
booktool convert dracula.epub --to mobi
```

Returns the path of the new file on stdout.

---

## `booktool enrich [--missing] [--limit N]`

Query Open Library for every (or just incomplete) book in the catalog
and merge results into the existing metadata. The merge respects
source confidence: embedded values are not clobbered by lower-quality
network results.

| Flag | Effect |
|---|---|
| `--missing` | Only books currently flagged by `missing`. |
| `--limit N` | Stop after N books (spot-test). |

```sh
booktool enrich --limit 5
booktool enrich --missing
```

---

## `booktool dedup [--apply] [--exact-only] [--fuzzy-only]`

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

## `booktool rename [options]`

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

## `booktool set-meta FILE [options]`

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
booktool set-meta "Hobb*.mobi" --title "Assassin's Apprentice"
booktool set-meta book.epub --series "Stormlight" --series-index 1
```

---

## `booktool set-cover FILE IMAGE`

Replace the embedded cover image. The image bytes are dropped into the
existing cover manifest entry (EPUB) or set via `mobimeta`
(MOBI/AZW3). Content type is auto-detected from magic bytes.

```sh
booktool set-cover book.epub ~/Pictures/new-cover.jpg
```

EPUB requires the existing archive to declare a `cover-image` item;
booktool refuses to fabricate a cover entry from scratch (use a tool
like Calibre or Sigil to set one initially).

---

## `booktool optimize FILE...`

Recompress EPUB archives with the highest deflate level. Saves typically
0–10 % depending on how the source was packed. The `mimetype` entry is
preserved as stored (uncompressed) per the OCF spec.

Refuses to overwrite if the result is no smaller. Atomic rename only on
strict improvement.

```sh
booktool optimize ~/Books/*.epub
```

Image recompression and HTML/CSS minification are **not** in this
command yet — see `epub-optimizer` and `epuboptim` for those. They are
the next iteration here.

---

## `booktool standardize DIR [options]`

Meta-command that pipelines:

1. `scan DIR`
2. `enrich`
3. `dedup` (with `--apply` if requested)
4. `rename` (with `--apply` if requested)
5. `optimize` of every catalogued EPUB (only when `--apply`)

Dry-run by default. Skip individual steps with `--no-enrich`,
`--no-dedup`, `--no-rename`, `--no-optimize`.

```sh
booktool standardize ~/Books              # preview everything
booktool standardize ~/Books --apply      # do it
booktool standardize ~/Books --apply --no-optimize --template "{year} - {author_sort} - {title}.{ext}"
```

Execution is sequential. Parallelizing with `std.Io.concurrent` is
planned but not yet wired up.

---

## `booktool serve [--port N] [--bind IP]`

Run the web UI on the given address (default `http://127.0.0.1:8787`).
The SPA serves the same catalog the CLI sees: list, search, missing,
duplicates, in-browser reader for EPUBs via epub.js.

---

## `booktool tui`

Open the terminal UI. Two views:

| View | Bindings |
|---|---|
| List | `j`/`k`/`↑`/`↓` move, `g`/`G` top/bottom, `enter` open, `q` quit |
| Reader | `space`/`→`/`l` next page, `b`/`h`/`←` prev, `q` back |

EPUB only for now — MOBI/AZW3 books prompt to convert first.

---

## `booktool help` / `version`

Standard. `version` is also `-V` and `--version`. Help is `-h`,
`--help`, or the subcommand `help`.
