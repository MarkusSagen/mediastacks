# booktool documentation

Three surfaces, one catalog:

| File | What it covers |
|---|---|
| [COMMANDS.md](./COMMANDS.md) | Every CLI subcommand: synopsis, flags, examples, exit codes |
| [WEB.md](./WEB.md) | `booktool serve` — HTTP API, frontend, customisation, limitations |
| [TUI.md](./TUI.md) | `booktool tui` — list + reader views, keybindings, EPUB pipeline |

All three read from the same SQLite catalog at
`$XDG_DATA_HOME/booktool/catalog.db` (default
`~/.local/share/booktool/catalog.db`). Mutations made by the CLI show
up in the web UI and TUI on the next request / event.

## Quick tour

```sh
# Populate the catalog from a directory tree of ebooks.
booktool scan ~/Books

# Enrich with Open Library data.
booktool enrich --missing

# See what's wrong with what's there.
booktool missing

# Find duplicates across formats / editions; --apply removes them.
booktool dedup

# Preview rename, then apply it. Templates are configurable.
booktool rename --preset series-dir
booktool rename --apply

# Browse / read in the terminal.
booktool tui

# Browse / read in a browser.
booktool serve
```

## End-to-end smoke test

`scripts/smoke.sh` exercises every command against the fixtures under
`tests/fixtures/`. Use it as a pre-flight before a release:

```sh
./scripts/smoke.sh           # full run, including Open Library
./scripts/smoke.sh --offline # skip the network step
./scripts/smoke.sh --keep    # keep the temp XDG_DATA_HOME for inspection
```
