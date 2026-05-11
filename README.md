# booktool

Three surfaces, one library:

- **CLI** — scan, enrich, dedup, rename, convert, optimize, set
  metadata/covers, standardize a directory in one command.
- **Web UI** (`booktool serve`) — browse, search, read EPUBs in the
  browser.
- **TUI** (`booktool tui`) — same library, plaintext reader, full
  keyboard control.

Written in Zig 0.16. Single binary, deliberately small. State lives
in one SQLite file.

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

## Build

```sh
mise install            # installs Zig 0.16 + zls
zig build               # produces ./zig-out/bin/booktool
zig build run -- info SOMEFILE.epub
zig build test          # runs the unit-test suite (66 tests)
./scripts/smoke.sh      # end-to-end checks against tests/fixtures (19)
```

## Common commands

Full reference: [`docs/COMMANDS.md`](./docs/COMMANDS.md). Quick map of
what you reach for day-to-day:

### Getting a library into shape

```sh
booktool scan ~/Books              # walk + hash + ingest into the catalog
booktool enrich --missing          # fill gaps from Open Library
booktool dedup                     # show duplicates (cross-format aware)
booktool dedup --apply             # delete the lower-quality copies
booktool rename                    # preview canonical names
booktool rename --apply            # actually move files
booktool standardize ~/Books --apply  # all of the above in one pipeline
```

### Asking the catalog questions

```sh
booktool find ~/Books --glob "**/Hobb*"     # list files, no catalog write
booktool find ~/Books --format mobi         # filter by format
booktool missing                            # books with incomplete metadata
booktool missing --glob "**/scifi/**"       # restrict by path
booktool info path/to/book.epub             # embedded metadata for one file
```

### Editing a single book

```sh
booktool set-meta book.epub --title "Better Title" --series "Stormlight" --series-index 1
booktool set-cover book.epub ~/Pictures/new-cover.jpg
booktool convert book.mobi --to epub        # via libmobi (MOBI/AZW3→EPUB) or Calibre
booktool optimize book.epub                 # recompress, save a few percent
```

### Reading and browsing

```sh
booktool tui                                # in-terminal list + reader
booktool serve                              # web UI on http://127.0.0.1:8787
booktool cover book.epub                    # render cover via chafa (Kitty/Sixel/Unicode)
```

### Renaming with custom templates

```sh
booktool rename --list-presets              # default | flat | series-dir
booktool rename --preset series-dir         # nest into Author/Series/01 - Title.epub
booktool rename --template "{year} - {author_sort} - {title}.{ext}"
booktool rename --template "{author}/{title} [{isbn}].{ext}"
```

Template fields: `{author_sort}`, `{author}`, `{title}`, `{series}`,
`{series_index:02}`, `{year}`, `{isbn}`, `{format}`, `{ext}`. Paths
may contain `/` to nest into subdirectories.

### Putting it together

A typical "I just downloaded a pile of ebooks" workflow:

```sh
booktool scan ~/Downloads/books            # tell booktool about them
booktool enrich --missing                  # pull missing series / year / cover URLs
booktool dedup                             # eyeball duplicates
booktool rename                            # dry-run, sanity-check the names
booktool rename --apply                    # commit
booktool optimize ~/Downloads/books/*.epub # shave a percent or two
```

…or do all of the above in one command:

```sh
booktool standardize ~/Downloads/books --apply
```

## Roadmap

- **Part 1:** CLI + library API ✅
- **Part 1.post:** TUI ebook reader ✅
- **Part 2:** Web UI ✅
- **Part 3:** Drop external C dependencies — pure-Zig MOBI / EPUB
  parsers, plus a parity test suite golden-comparing against the
  current C-backed outputs.
