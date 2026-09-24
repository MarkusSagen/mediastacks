# mediastacks

A kind-aware media organizer. One shared Zig core library, two binaries:

- **`biblio`** — the book/comic tool. Three surfaces over one library:
  - **CLI** — scan, enrich, dedup, rename, convert, optimize, set
    metadata/covers, standardize a directory in one command.
  - **Web UI** (`biblio serve`) — browse, search, triage, edit, and
    read books in the browser. Supports EPUB, MOBI, AZW3, PDF, and the
    comic archive formats (CBZ / CBR / CB7 / CBT).
  - **TUI** (`biblio tui`) — same library, plaintext reader, full
    keyboard control.
- **`medias`** — the general media organizer. Point it at a messy
  download folder and it groups, dedups, and relabels TV & movies into
  a clean, templated library: `medias organize DIR` (applies by default;
  add `--dry-run` to preview), `medias undo`. Offline-first; deletes go
  to a trash dir; every run is reversible via an undo journal.

Written in Zig 0.16. Small, deliberately. Book state lives in one
SQLite file; the organizer works directly on the filesystem.

## Install

**Prebuilt (macOS / Linux):**

```sh
curl -fsSL https://raw.githubusercontent.com/markussagen/mediastacks/main/scripts/install.sh | bash
```

This downloads the latest release for your platform, verifies its checksum, and
installs `biblio` + `medias` (to `/usr/local/bin`, or `~/.local/bin`). Pin a
version with `MEDIASTACKS_VERSION=v1.2.3` or choose a dir with `--dir ~/bin`.
You'll still need the runtime libraries once:

```sh
brew install libmobi libxml2 sqlite                 # macOS
sudo apt install libmobi-dev libxml2 libsqlite3-0   # Debian/Ubuntu
```

Or grab a tarball straight from the [releases page](https://github.com/markussagen/mediastacks/releases).
Windows is not yet supported (the tools are POSIX-only for now).

**Nix:** `nix develop` gives a reproducible build shell (Zig 0.16 + the C deps);
see [`flake.nix`](./flake.nix).

**From source:** see [Requirements](#requirements) + [Build](#build) below.

## Documentation

- [`docs/README.md`](./docs/README.md) — quick tour and index
- [`docs/COMMANDS.md`](./docs/COMMANDS.md) — every CLI subcommand
- [`docs/WEB.md`](./docs/WEB.md) — web UI: routes, frontend, customisation
- [`docs/TUI.md`](./docs/TUI.md) — terminal UI: keybindings, EPUB pipeline

## Requirements

- Zig 0.16.0 (managed via [mise](https://mise.jdx.dev))
- libmobi (`brew install libmobi`)
- libxml2 (ships with macOS SDK; `apt install libxml2-dev` on Linux)
- sqlite3 (`brew install sqlite`)
- chafa, optional, for `cover` command (`brew install chafa`)
- Calibre, optional, for conversion directions libmobi can't handle
- sevenzip, optional, for **CBR / CB7 / CBT** covers and metadata
  (`brew install sevenzip` on macOS, `apt install p7zip-full` on Linux).
  CBZ doesn't need it — miniz is vendored.

## Build

```sh
mise install            # installs Zig 0.16 + zls
zig build               # produces ./zig-out/bin/mediastacks (also re-links on rebuild)
zig build -Doptimize=ReleaseFast   # optimized build
zig build run -- info SOMEFILE.epub
zig build test          # runs the unit-test suite (109 tests)
./scripts/smoke.sh      # end-to-end checks against tests/fixtures (25)
./scripts/smoke-web.sh  # web-layer smoke against a live server (23)
./scripts/test-e2e.sh   # Playwright browser end-to-end (15; needs `npm i playwright`)
```

To force a clean rebuild: `rm -rf .zig-cache zig-out && zig build`.

### Dev loop (watch + incremental)

```sh
zig build --watch -fincremental -Doptimize=ReleaseFast --summary none
```

Rebuilds on file change, reuses the incremental cache between runs, and
suppresses the per-step summary so only errors surface. Incremental is
still flagged experimental in Zig 0.16 — if you hit a weird cache state,
wipe `.zig-cache` and re-run.

## Common commands

Full reference: [`docs/COMMANDS.md`](./docs/COMMANDS.md). Quick map of
what you reach for day-to-day:

### Getting a library into shape

```sh
mediastacks scan ~/Books              # walk + hash + ingest into the catalog
mediastacks enrich --missing          # fill gaps from Open Library
mediastacks dedup                     # show duplicates (cross-format aware)
mediastacks dedup --apply             # delete the lower-quality copies
mediastacks rename                    # preview canonical names
mediastacks rename --apply            # actually move files
mediastacks standardize ~/Books --apply  # all of the above in one pipeline
```

### Asking the catalog questions

```sh
mediastacks find ~/Books --glob "**/Hobb*"     # list files, no catalog write
mediastacks find ~/Books --format mobi         # filter by format
mediastacks missing                            # books with incomplete metadata
mediastacks missing --glob "**/scifi/**"       # restrict by path
mediastacks info path/to/book.epub             # embedded metadata for one file
```

### Editing a single book

```sh
mediastacks set-meta book.epub --title "Better Title" --series "Stormlight" --series-index 1
mediastacks set-cover book.epub ~/Pictures/new-cover.jpg
mediastacks convert book.mobi --to epub        # via libmobi (MOBI/AZW3→EPUB) or Calibre
mediastacks optimize book.epub                 # recompress, save a few percent
```

### Reading and browsing

```sh
mediastacks tui                                # in-terminal list + reader
mediastacks serve                              # web UI on http://127.0.0.1:8787
mediastacks cover book.epub                    # render cover via chafa (Kitty/Sixel/Unicode)
```

### Renaming with custom templates

```sh
mediastacks rename --list-presets              # default | flat | series-dir
mediastacks rename --preset series-dir         # nest into Author/Series/01 - Title.epub
mediastacks rename --template "{year} - {author_sort} - {title}.{ext}"
mediastacks rename --template "{author}/{title} [{isbn}].{ext}"
```

Template fields: `{author_sort}`, `{author}`, `{title}`, `{series}`,
`{series_index:02}`, `{year}`, `{isbn}`, `{format}`, `{ext}`. Paths
may contain `/` to nest into subdirectories.

### Putting it together

A typical "I just downloaded a pile of ebooks" workflow:

```sh
mediastacks scan ~/Downloads/books            # tell mediastacks about them
mediastacks enrich --missing                  # pull missing series / year / cover URLs
mediastacks dedup                             # eyeball duplicates
mediastacks rename                            # dry-run, sanity-check the names
mediastacks rename --apply                    # commit
mediastacks optimize ~/Downloads/books/*.epub # shave a percent or two
```

…or do all of the above in one command:

```sh
mediastacks standardize ~/Downloads/books --apply
```

### Hands-off maintenance

Once a library is set up, schedule the recurring chores instead of
running them manually:

```sh
mediastacks schedule add nightly-rescan @daily rescan-all
mediastacks schedule add catch-new-meta "every 6h" enrich-missing
mediastacks schedule list                     # show what's configured
mediastacks schedule run 1                    # fire job 1 now
mediastacks schedule daemon                   # run the scheduler without the web UI
```

The same schedule definitions are picked up by `mediastacks serve` (an
in-process thread checks every minute) or by `mediastacks schedule
daemon` when you don't want the HTTP server running. Definitions
live in the catalog DB, so both modes share the same list.

## Roadmap

- **Part 1:** CLI + library API ✅
- **Part 1.post:** TUI ebook reader ✅
- **Part 2:** Web UI ✅
- **Part 3:** Drop external C dependencies — pure-Zig MOBI / EPUB
  parsers, plus a parity test suite golden-comparing against the
  current C-backed outputs.
