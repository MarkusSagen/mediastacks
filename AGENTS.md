# AGENTS.md

Project notes for Codex sessions in this repo.

## Build

```sh
zig build                            # debug → ./zig-out/bin/biblio + ./zig-out/bin/shelve
zig build -Doptimize=ReleaseFast     # optimized build
zig build run -- <args>              # build + run biblio
zig build run-shelve -- <args>       # build + run shelve
zig build test                       # unit tests
./scripts/smoke.sh                   # biblio end-to-end smoke
./scripts/organize-smoke.sh          # shelve organize/undo smoke
```

Force a clean rebuild: `rm -rf .zig-cache zig-out && zig build`.

### Dev loop

```sh
zig build --watch -fincremental --summary none
```

Watches sources, reuses the incremental cache, suppresses step summaries
so only errors surface. Incremental is experimental in Zig 0.16 — wipe
`.zig-cache` if it ends up in a bad state.

## Layout

- `src/` — Zig sources. `src/root.zig` is the shared `stacks` library
  module. `src/main.zig` → `biblio` (book CLI); `src/shelve_main.zig` +
  `src/shelve_cli.zig` → `shelve` (media organizer). `src/web/` is the web
  UI, `src/tui/` is the TUI.
- `src/kinds/` — per-media-kind parsers (tv, movie). `src/core/kind.zig`,
  `classify.zig`, `group.zig`, `plan.zig`, `apply.zig`, `journal.zig`,
  `config.zig` — the organizer pipeline.
- `lib/miniz/`, `lib/booktool_c/` — vendored C compiled in-tree.
- `build.zig` — one `stacks` module linked into both binaries; links
  libmobi, libxml2, sqlite3 from Homebrew/system paths.
- `tests/fixtures/` — sample ebooks used by `scripts/smoke.sh`.
- `docs/` — user-facing docs (COMMANDS, WEB, TUI).

## Conventions

- Zig 0.16 (managed by mise). Don't introduce 0.17-only APIs.
- System deps: libmobi, libxml2, sqlite3. Avoid adding new C deps; the
  Part 3 roadmap is to remove them.
- One SQLite file is the source of truth for `biblio` catalog state; state
  lives under `$XDG_DATA_HOME/stacks/`. The `shelve` organizer is
  filesystem-based (no catalog) and records undo journals there too.
