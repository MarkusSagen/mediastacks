#!/usr/bin/env bash
# End-to-end music smoke: ffmpeg-generate a tagged mini-album + cover, then
# `shelve organize --apply` into a temp library and assert the album layout,
# then `shelve undo`. This is the authoritative tag-driven music test (the
# group unit test is deliberately no-probe/deterministic).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SHELVE="$ROOT/zig-out/bin/shelve"
[[ -x "$SHELVE" ]] || { echo "build first: zig build" >&2; exit 2; }
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    echo "ffmpeg/ffprobe not installed — skipping music smoke"; exit 0
fi

TMP="$(mktemp -d -t stacks-music.XXXXXX)"
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/dl/album"; LIB="$TMP/lib"
mkdir -p "$SRC"
trap 'rm -rf "$TMP"' EXIT

meta=(-metadata album=Blue -metadata album_artist="Eric Clapton" -metadata date=1998)
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Layla   -metadata track=1 -y "$SRC/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Cocaine -metadata track=2 -y "$SRC/02.mp3"
ffmpeg -v error -f lavfi -i color=c=blue:s=64x64 -frames:v 1 -y "$SRC/cover.jpg"

PASS=0; FAIL=0
check() { if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

echo "== dry-run =="
OUT="$("$SHELVE" organize "$SRC" --to "$LIB" --dry-run)"
echo "$OUT" | grep -E "Music/|summary" || true
check "grouped under album-artist Eric Clapton" 'grep -q "Music/Eric Clapton/Blue (1998)/" <<<"$OUT"'

echo "== apply =="
"$SHELVE" organize "$SRC" --to "$LIB" >/dev/null
check "track 01 landed with title" '[[ -f "$LIB/Music/Eric Clapton/Blue (1998)/01 - Layla.mp3" ]]'
check "track 02 landed with title" '[[ -f "$LIB/Music/Eric Clapton/Blue (1998)/02 - Cocaine.mp3" ]]'
check "cover landed in album folder" '[[ -f "$LIB/Music/Eric Clapton/Blue (1998)/cover.jpg" ]]'

echo "== undo =="
"$SHELVE" undo >/dev/null
check "library reverted" '[[ ! -d "$LIB/Music" ]] || [[ -z "$(find "$LIB/Music" -type f 2>/dev/null)" ]]'
check "sources restored" '[[ -f "$SRC/01.mp3" && -f "$SRC/cover.jpg" ]]'

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
