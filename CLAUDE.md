# CLAUDE.md

Project notes for Claude Code sessions in this repo.

## Build

```sh
zig build                            # debug → ./zig-out/bin/booktool
zig build -Doptimize=ReleaseFast     # optimized build
zig build run -- <args>              # build + run
zig build test                       # unit tests (66)
./scripts/smoke.sh                   # end-to-end smoke (19 cases)
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

- `src/` — Zig sources; `src/main.zig` is the CLI entrypoint, `src/root.zig`
  is the library module, `src/web/` is the web UI, `src/tui/` is the TUI.
- `lib/miniz/`, `lib/booktool_c/` — vendored C compiled in-tree.
- `build.zig` — links libmobi, libxml2, sqlite3 from Homebrew/system paths.
- `tests/fixtures/` — sample ebooks used by `scripts/smoke.sh`.
- `docs/` — user-facing docs (COMMANDS, WEB, TUI).

## Conventions

- Zig 0.16 (managed by mise). Don't introduce 0.17-only APIs.
- System deps: libmobi, libxml2, sqlite3. Avoid adding new C deps; the
  Part 3 roadmap is to remove them.
- One SQLite file is the source of truth for catalog state.
