# mediastacks documentation

Three surfaces, one catalog:

| File | What it covers |
|---|---|
| [COMMANDS.md](./COMMANDS.md) | Every CLI subcommand: synopsis, flags, examples, exit codes |
| [WEB.md](./WEB.md) | `mediastacks serve` — HTTP API, frontend, customisation, limitations |
| [TUI.md](./TUI.md) | `mediastacks tui` — list + reader views, keybindings, EPUB pipeline |

All three read from the same SQLite catalog at
`$XDG_DATA_HOME/mediastacks/catalog.db` (default
`~/.local/share/mediastacks/catalog.db`). Mutations made by the CLI show
up in the web UI and TUI on the next request / event.

## Quick tour

```sh
# Populate the catalog from a directory tree of ebooks.
mediastacks scan ~/Books

# Enrich with Open Library data.
mediastacks enrich --missing

# See what's wrong with what's there.
mediastacks missing

# Find duplicates across formats / editions; --apply removes them.
mediastacks dedup

# Preview rename, then apply it. Templates are configurable.
mediastacks rename --preset series-dir
mediastacks rename --apply

# Browse / read in the terminal.
mediastacks tui

# Browse / read in a browser.
mediastacks serve
```

## End-to-end smoke test

`scripts/smoke.sh` exercises every command against the fixtures under
`tests/fixtures/`. Use it as a pre-flight before a release:

```sh
./scripts/smoke.sh           # full run, including Open Library
./scripts/smoke.sh --offline # skip the network step
./scripts/smoke.sh --keep    # keep the temp XDG_DATA_HOME for inspection
```
