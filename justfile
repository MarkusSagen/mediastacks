# booktool — task runner. Run `just` (no args) for the recipe list.
#
# Convention: the comment line directly above each recipe is what
# `just --list` shows, so it has to be a single-line summary. Longer
# rationale lives as additional `#` lines further up.
#
# Recipes that produce or run the binary depend on `build`, so a stale
# tree never silently runs an old binary. Override the default port
# with `just serve PORT=9000`.

set shell := ["bash", "-cu"]
set positional-arguments := true

PORT := "8787"

# Show the recipe list (default when `just` is called bare).
default:
    @just --list --unsorted

# ───────── build / verify ───────────────────────────────────────────

# Debug build → `./zig-out/bin/booktool`.
build:
    zig build

# Optimised release build — slower compile, faster runtime.
build-release:
    zig build -Doptimize=ReleaseFast

# Incremental watch loop (Zig 0.16 experimental — wipe cache on hang).
watch:
    zig build --watch -fincremental --summary none

# Run the full unit-test suite (in-process; no network, no fixtures).
test:
    zig build test

# Integration tests — CLI smoke (~24 cases) + web-layer smoke against
# a live server + browser end-to-end. Slower than `just test`; assumes
# the build is current (chains `build` itself) and that real fixtures
# exist. The e2e step is skipped when Playwright isn't installed
# (see scripts/test-e2e.sh).
test-integration: build smoke smoke-web test-e2e
    @echo ""
    @echo "✓ integration — CLI smoke + web smoke + e2e all green"

# Every test we have, in order: unit → CLI smoke → web smoke → e2e.
test-all: test test-integration

# End-to-end smoke against real fixtures (~24 cases).
smoke:
    ./scripts/smoke.sh

# Web-layer smoke (spins server, hits endpoints, asserts JSON shapes).
smoke-web:
    ./scripts/smoke-web.sh

# Browser end-to-end — Playwright walks the live UI. Requires
# `npm i playwright` locally (or `npx playwright install chromium`).
# Set HEADLESS=0 to watch.
test-e2e:
    ./scripts/test-e2e.sh

# Full verification sweep — debug build + release build + tests + smoke.
verify: build build-release test smoke
    @echo ""
    @echo "✓ verified — debug build, release build, tests, smoke all green"

# Wipe the Zig cache when incremental gets confused.
clean:
    rm -rf .zig-cache zig-out

# ───────── running the app ─────────────────────────────────────────

# Start the web UI on $PORT (default 8787). Ctrl+C stops it.
serve PORT=PORT: build
    ./zig-out/bin/booktool serve --port {{PORT}}

# 1s sleep gives `serve` time to bind the socket; bump it on a slow
# box. The open is backgrounded with `&` so it's fire-and-forget and
# the foreground stays with the server (Ctrl+C still stops cleanly).
#
# Start the web UI and open it in your default browser.
dev PORT=PORT: build
    (sleep 1; \
       if command -v open >/dev/null 2>&1; then open "http://127.0.0.1:{{PORT}}/"; \
       elif command -v xdg-open >/dev/null 2>&1; then xdg-open "http://127.0.0.1:{{PORT}}/"; \
       else echo "(no 'open' or 'xdg-open' — visit http://127.0.0.1:{{PORT}}/ manually)"; \
       fi) &
    ./zig-out/bin/booktool serve --port {{PORT}}

# Same as `serve` but with BOOKTOOL_DEBUG=1 — emits scoped debug logs.
serve-debug PORT=PORT: build
    BOOKTOOL_DEBUG=1 ./zig-out/bin/booktool serve --port {{PORT}}

# Release-built server — what you'd ship; slower compile, snappier runtime.
serve-release PORT=PORT: build-release
    ./zig-out/bin/booktool serve --port {{PORT}}

# Terminal UI — list + reader, no browser.
tui: build
    ./zig-out/bin/booktool tui

# Kill any lingering `booktool serve` process.
kill-serve:
    -pkill -f 'booktool serve'

# ───────── catalog operations ──────────────────────────────────────

# Walk DIR and ingest every recognised ebook into the catalog.
scan DIR="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just scan DIR"; exit 1; fi
    ./zig-out/bin/booktool scan {{DIR}}

# Show embedded metadata for one file (epub/mobi/azw3/cbz/cb*/pdf).
info FILE="": build
    @if [ -z "{{FILE}}" ]; then echo "usage: just info FILE"; exit 1; fi
    ./zig-out/bin/booktool info {{FILE}}

# Pull metadata from Open Library for every unverified row.
enrich *FLAGS: build
    ./zig-out/bin/booktool enrich {{FLAGS}}

# List catalog rows missing important metadata (title/author/year/isbn).
missing: build
    ./zig-out/bin/booktool missing

# Find duplicates (exact-sha + fuzzy title). Add --apply to delete dupes.
dedup *FLAGS: build
    ./zig-out/bin/booktool dedup {{FLAGS}}

# Show / execute canonical renames. Add --apply to actually move files.
rename *FLAGS: build
    ./zig-out/bin/booktool rename {{FLAGS}}

# Library-tidy pipeline: scan → enrich → dedup → rename → optimize.
standardize DIR="" *FLAGS="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just standardize DIR [--apply]"; exit 1; fi
    ./zig-out/bin/booktool standardize {{DIR}} {{FLAGS}}

# Recompress an EPUB at max deflate (10-30% smaller, same content).
optimize FILE="": build
    @if [ -z "{{FILE}}" ]; then echo "usage: just optimize FILE"; exit 1; fi
    ./zig-out/bin/booktool optimize {{FILE}}

# Edit embedded metadata of one file (--title / --author / --series / ...).
set-meta FILE="" *FLAGS="": build
    @if [ -z "{{FILE}}" ]; then echo "usage: just set-meta FILE [flags]"; exit 1; fi
    ./zig-out/bin/booktool set-meta {{FILE}} {{FLAGS}}

# Replace the embedded cover with a JPG/PNG.
set-cover FILE="" IMG="": build
    @if [ -z "{{FILE}}" ] || [ -z "{{IMG}}" ]; then echo "usage: just set-cover FILE IMG"; exit 1; fi
    ./zig-out/bin/booktool set-cover {{FILE}} {{IMG}}

# Convert SRC to FMT (epub/mobi/azw3/pdf).
convert SRC="" FMT="": build
    @if [ -z "{{SRC}}" ] || [ -z "{{FMT}}" ]; then echo "usage: just convert SRC FMT"; exit 1; fi
    ./zig-out/bin/booktool convert {{SRC}} --to {{FMT}}

# Manage watched library folders (list / add / remove / rescan).
sources *SUB: build
    ./zig-out/bin/booktool sources {{SUB}}

# Open the catalog DB in the sqlite3 REPL (read/write — careful).
catalog-sql:
    sqlite3 "${XDG_DATA_HOME:-$HOME/.local/share}/booktool/catalog.db"

# Print the catalog DB path + its current size on disk.
catalog-info:
    @path="${XDG_DATA_HOME:-$HOME/.local/share}/booktool/catalog.db"; \
      echo "$path"; \
      if [ -f "$path" ]; then ls -lh "$path"; fi
