# stacks — task runner (biblio = books, shelve = media organizer). Run `just` (no args) for the recipe list.
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

# Debug build → `./zig-out/bin/biblio`.
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
    ./zig-out/bin/biblio serve --port {{PORT}}

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
    ./zig-out/bin/biblio serve --port {{PORT}}

# Same as `serve` but with STACKS_DEBUG=1 — emits scoped debug logs.
serve-debug PORT=PORT: build
    STACKS_DEBUG=1 ./zig-out/bin/biblio serve --port {{PORT}}

# Release-built server — what you'd ship; slower compile, snappier runtime.
serve-release PORT=PORT: build-release
    ./zig-out/bin/biblio serve --port {{PORT}}

# Terminal UI — list + reader, no browser.
tui: build
    ./zig-out/bin/biblio tui

# Kill any lingering `biblio serve` process.
kill-serve:
    -pkill -f 'biblio serve'

# ───────── catalog operations ──────────────────────────────────────

# Walk DIR and ingest every recognised ebook into the catalog.
scan DIR="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just scan DIR"; exit 1; fi
    ./zig-out/bin/biblio scan {{DIR}}

# Show embedded metadata for one file (epub/mobi/azw3/cbz/cb*/pdf).
info FILE="": build
    @if [ -z "{{FILE}}" ]; then echo "usage: just info FILE"; exit 1; fi
    ./zig-out/bin/biblio info {{FILE}}

# Pull metadata from Open Library for every unverified row.
enrich *FLAGS: build
    ./zig-out/bin/biblio enrich {{FLAGS}}

# List catalog rows missing important metadata (title/author/year/isbn).
missing: build
    ./zig-out/bin/biblio missing

# Find duplicates (exact-sha + fuzzy title). Add --apply to delete dupes.
dedup *FLAGS: build
    ./zig-out/bin/biblio dedup {{FLAGS}}

# Show / execute canonical renames. Add --apply to actually move files.
rename *FLAGS: build
    ./zig-out/bin/biblio rename {{FLAGS}}

# Library-tidy pipeline: scan → enrich → dedup → rename → optimize.
standardize DIR="" *FLAGS="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just standardize DIR [--apply]"; exit 1; fi
    ./zig-out/bin/biblio standardize {{DIR}} {{FLAGS}}

# Recompress an EPUB at max deflate (10-30% smaller, same content).
optimize FILE="": build
    @if [ -z "{{FILE}}" ]; then echo "usage: just optimize FILE"; exit 1; fi
    ./zig-out/bin/biblio optimize {{FILE}}

# Edit embedded metadata of one file (--title / --author / --series / ...).
set-meta FILE="" *FLAGS="": build
    @if [ -z "{{FILE}}" ]; then echo "usage: just set-meta FILE [flags]"; exit 1; fi
    ./zig-out/bin/biblio set-meta {{FILE}} {{FLAGS}}

# Replace the embedded cover with a JPG/PNG.
set-cover FILE="" IMG="": build
    @if [ -z "{{FILE}}" ] || [ -z "{{IMG}}" ]; then echo "usage: just set-cover FILE IMG"; exit 1; fi
    ./zig-out/bin/biblio set-cover {{FILE}} {{IMG}}

# Convert SRC to FMT (epub/mobi/azw3/pdf).
convert SRC="" FMT="": build
    @if [ -z "{{SRC}}" ] || [ -z "{{FMT}}" ]; then echo "usage: just convert SRC FMT"; exit 1; fi
    ./zig-out/bin/biblio convert {{SRC}} --to {{FMT}}

# Manage watched library folders (list / add / remove / rescan).
sources *SUB: build
    ./zig-out/bin/biblio sources {{SUB}}

# Open the catalog DB in the sqlite3 REPL (read/write — careful).
catalog-sql:
    sqlite3 "${XDG_DATA_HOME:-$HOME/.local/share}/stacks/catalog.db"

# Print the catalog DB path + its current size on disk.
catalog-info:
    @path="${XDG_DATA_HOME:-$HOME/.local/share}/stacks/catalog.db"; \
      echo "$path"; \
      if [ -f "$path" ]; then ls -lh "$path"; fi

# ───────── media organizer (shelve) ────────────────────────────────

# Reorganize DIR's TV / movies / music into the library. Applies by default;
# pass --dry-run (-n) to preview. Undo any run with `just undo`.
# FLAGS (all optional): --dry-run  --to LIB  --offline  --write-tags
#   --on-conflict skip|suffix|overwrite  --plan FILE  --from FILE
# e.g. `just organize ~/Downloads/down/Show --dry-run`
#      `just organize ~/Downloads/down/Show --to ~/Media`
# --offline skips MusicBrainz even when enabled in config (musicbrainz = on).
# --write-tags rewrites FLAC/MP3 tags (multi-artist) on apply (backed up; undoable).
organize DIR="" *FLAGS="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just organize DIR [--dry-run] [--to LIB] [--offline] [--write-tags] [--on-conflict skip|suffix|overwrite] [--plan FILE] [--from FILE]"; exit 1; fi
    ./zig-out/bin/shelve organize "{{DIR}}" {{FLAGS}}

# Review & edit a reorg in the browser, then apply on click (undo with `just undo`).
# e.g. `just review ~/Downloads/down/Show --to ~/Media`
review DIR="" *FLAGS="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just review DIR [--to LIB] [--port N] [--no-probe] [--offline]"; exit 1; fi
    ./zig-out/bin/shelve review "{{DIR}}" {{FLAGS}}

# Reverse the most recent `just organize` (from its undo journal).
undo: build
    ./zig-out/bin/shelve undo

# End-to-end organize → apply → undo smoke on a synthetic messy folder.
organize-smoke: build
    ./scripts/organize-smoke.sh

# API-contract smoke for `shelve review` (plan → edit → apply → undo).
review-smoke: build
    ./scripts/review-smoke.sh

# End-to-end music smoke: tagged album → album-artist library → undo.
music-smoke: build
    ./scripts/music-smoke.sh

# Live MusicBrainz smoke (hits the network at 1 req/sec; MB_SMOKE-gated).
mb-smoke: build
    MB_SMOKE=1 ./scripts/mb-smoke.sh

# Live TMDB smoke (needs TMDB_KEY in the environment; TMDB_SMOKE-gated).
tmdb-smoke: build
    TMDB_SMOKE=1 ./scripts/tmdb-smoke.sh

# Tag write-back smoke: --write-tags writes multi-artist FLAC/MP3; undo restores.
tag-smoke: build
    ./scripts/tag-smoke.sh

# NFO sidecar smoke: --nfo writes movie.nfo; undo removes it.
nfo-smoke: build
    ./scripts/nfo-smoke.sh

# makem4b smoke: merge chapter mp3s → one chaptered .m4b; undo removes it.
m4b-smoke: build
    ./scripts/m4b-smoke.sh

# Comic smoke: organize a .cbz + embed ComicInfo.xml; undo restores it.
comicinfo-smoke: build
    ./scripts/comicinfo-smoke.sh

# Merge a folder of chapter files into one chaptered .m4b audiobook.
# e.g. `just makem4b ~/Downloads/Orwell/1984 --to ~/Media`
makem4b DIR="" *FLAGS="": build
    @if [ -z "{{DIR}}" ]; then echo "usage: just makem4b DIR [--to LIB] [--out FILE.m4b] [--bitrate 128k]"; exit 1; fi
    ./zig-out/bin/shelve makem4b "{{DIR}}" {{FLAGS}}

# Print where shelve keeps organizer state (config + undo journals).
shelve-info:
    @echo "config:  ${XDG_CONFIG_HOME:-$HOME/.config}/stacks/config.toml"; \
      echo "undo:    ${XDG_DATA_HOME:-$HOME/.local/share}/stacks/undo/"

# ───────── shell completions ────────────────────────────────────────

# Install tab-completion for `just` (recipe- + flag-value aware) into your shell.
# e.g. `just setup-completions` (zsh) or `just setup-completions bash`.
setup-completions shell="zsh":
    bash ./scripts/setup-completions.sh "{{shell}}" "{{justfile_directory()}}"

# List valid values for a completion dimension (used by the completion scripts).
[private]
list-values dim="":
    @bash ./scripts/list-values.sh "{{dim}}"
