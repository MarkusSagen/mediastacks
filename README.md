# booktool

A CLI for managing an ebook library: convert formats, enrich metadata,
detect duplicates, and rename files into a canonical layout.

Written in Zig. Single binary, deliberately small.

## Status

Part 1 (CLI + API) — in progress.

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
zig build test          # runs the test suite
```

## Roadmap

- **Part 1:** CLI + library API (current)
- **Part 1.post:** TUI ebook reader
- **Part 2:** Web UI
- **Part 3:** Drop external C dependencies, pure Zig implementations + extensive parity test suite
