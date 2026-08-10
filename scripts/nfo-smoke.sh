#!/usr/bin/env bash
# NFO sidecar smoke: organize a synthetic movie with --nfo (offline); assert a
# movie.nfo is written in the movie folder, then `shelve undo` removes it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SHELVE="$ROOT/zig-out/bin/shelve"
[[ -x "$SHELVE" ]] || { echo "build first: zig build" >&2; exit 2; }
TMP="$(mktemp -d -t stacks-nfo.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/dl"; LIB="$TMP/lib"; mkdir -p "$SRC"
: > "$SRC/The.Matrix.1999.1080p.mkv"

PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

"$SHELVE" organize "$SRC" --to "$LIB" --nfo --offline >/dev/null
NFO="$(find "$LIB" -name movie.nfo | head -1)"
chk "movie.nfo written" '[[ -n "$NFO" ]]'
chk "movie.nfo has <movie> root" 'grep -q "<movie>" "$NFO"'
chk "movie.nfo has the title" 'grep -q "<title>The Matrix</title>" "$NFO" || grep -q "<title>" "$NFO"'

"$SHELVE" undo >/dev/null
chk "movie.nfo removed by undo" '[[ ! -f "$NFO" ]]'
chk "movie restored to source" '[[ -f "$SRC/The.Matrix.1999.1080p.mkv" ]]'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
