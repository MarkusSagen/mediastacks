#!/usr/bin/env bash
# End-to-end smoke test for `shelve organize` + `shelve undo`.
#
# Builds a synthetic messy TV folder (two naming styles, a duplicate
# episode, a subtitle sidecar, a .DS_Store), plans it, applies it into an
# isolated library, asserts the resulting tree, then undoes and asserts
# the source is restored. All state is isolated under a temp XDG home.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SHELVE="$ROOT/zig-out/bin/shelve"
if [[ ! -x "$SHELVE" ]]; then
    echo "shelve binary missing — run 'zig build' first" >&2
    exit 2
fi

TMP="$(mktemp -d -t stacks-organize.XXXXXX)"
export XDG_DATA_HOME="$TMP/data"
export XDG_CONFIG_HOME="$TMP/config"
trap 'rm -rf "$TMP"' EXIT

SRC="$TMP/down/Witch Hat Atelier"
LIB="$TMP/lib"
mkdir -p "$SRC/wrap"

# S01E04: two copies (different naming styles) -> one is a duplicate.
printf 'aaaa' > "$SRC/witch.hat.atelier.s01e04.1080p.web.h264-skyanime.mkv"
printf 'bbbbbbbb' > "$SRC/wrap/Witch Hat Atelier S01E04 Meetings in Kalhn 1080p CR WEB-DL-Kitsune.mkv"
# S01E05: single copy + a subtitle sidecar.
printf 'ccc' > "$SRC/witch.hat.atelier.s01e05.1080p.web.h264-skyanime.mkv"
printf 'sub' > "$SRC/witch.hat.atelier.s01e05.en.srt"
# junk.
printf 'junk' > "$SRC/.DS_Store"

PASS=0
FAIL=0
check() {
    if eval "$2"; then
        echo "  ok: $1"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $1"
        FAIL=$((FAIL + 1))
    fi
}

echo "== dry-run =="
OUT="$("$SHELVE" organize "$SRC" --to "$LIB" --dry-run)"
echo "$OUT"
check "plan: 3 files organized" 'grep -q "3 file(s) into" <<<"$OUT"'
check "plan: 1 junk trashed" 'grep -q "1 junk trashed" <<<"$OUT"'
check "plan: 1 duplicate left" 'grep -q "1 duplicate(s) left" <<<"$OUT"'
check "plan: groups under a folder header" 'grep -qE "Season 01/$" <<<"$OUT"'
check "dry-run did not create the library" '[[ ! -d "$LIB" ]]'
check "dry-run did not move .DS_Store" '[[ -f "$SRC/.DS_Store" ]]'

echo "== apply (default, no flag) =="
"$SHELVE" organize "$SRC" --to "$LIB" >/dev/null
check "S01E05 episode landed in library" 'find "$LIB/Shows" -iname "*S01E05*.mkv" | grep -q .'
check "S01E04 episode landed in library" 'find "$LIB/Shows" -iname "*S01E04*.mkv" | grep -q .'
check "subtitle sidecar landed alongside" 'find "$LIB/Shows" -iname "*S01E05*.srt" | grep -q .'
check "Season 01 directory created" 'find "$LIB/Shows" -type d -iname "Season 01" | grep -q .'
check ".DS_Store moved to trash (gone from source)" '[[ ! -f "$SRC/.DS_Store" ]]'
check "trash directory populated" 'find "$LIB/.stacks-trash" -name ".DS_Store" | grep -q .'
# The larger copy (Kitsune, 8 bytes) wins as primary and moves; the smaller
# skyanime copy is the duplicate and stays put.
check "duplicate copy left in place" '[[ -f "$SRC/witch.hat.atelier.s01e04.1080p.web.h264-skyanime.mkv" ]]'

echo "== undo =="
"$SHELVE" undo >/dev/null
check "S01E05 restored to source" '[[ -f "$SRC/witch.hat.atelier.s01e05.1080p.web.h264-skyanime.mkv" ]]'
check "subtitle restored to source" '[[ -f "$SRC/witch.hat.atelier.s01e05.en.srt" ]]'
check ".DS_Store restored to source" '[[ -f "$SRC/.DS_Store" ]]'

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
