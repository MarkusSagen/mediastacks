#!/usr/bin/env bash
# Write-back smoke: ffmpeg makes a FLAC + MP3 with two artists flattened into
# one tag; `organize --write-tags` writes real multi-value ARTIST tags; ffprobe
# confirms >=2 artist values; `shelve undo` restores byte-identical originals.
# Skips cleanly when ffmpeg is absent (like music-smoke.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SHELVE="$ROOT/zig-out/bin/shelve"
[[ -x "$SHELVE" ]] || { echo "build first: zig build" >&2; exit 2; }
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "ffmpeg/ffprobe absent — skipping tag smoke"; exit 0; }

TMP="$(mktemp -d -t stacks-tag.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/dl/album"; LIB="$TMP/lib"; mkdir -p "$SRC"

meta=(-metadata album=Blue -metadata album_artist="Derek and the Dominos" -metadata date=1970)
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Layla -metadata artist="Eric Clapton; Duane Allman" -metadata track=1 -y "$SRC/01.flac"
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Bell  -metadata artist="Eric Clapton; Duane Allman" -metadata track=2 -y "$SRC/02.mp3"
ffmpeg -v error -f lavfi -i color=c=red:s=64x64 -frames:v 1 -y "$SRC/cover.jpg"
cp "$SRC/01.flac" "$TMP/01.flac.orig"; cp "$SRC/02.mp3" "$TMP/02.mp3.orig"

# Count embedded cover-art streams (an attached picture is a video stream).
pics(){ ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$1" 2>/dev/null | grep -c . || true; }

PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

"$SHELVE" organize "$SRC" --to "$LIB" --write-tags --offline >/dev/null
FL="$(find "$LIB" -name '01 - Layla.flac' | head -1)"
chk "flac landed" '[[ -n "$FL" ]]'
# ffprobe prints one ARTIST line per value for FLAC multi-value tags.
N=$(ffprobe -v error -show_entries format_tags=ARTIST -of default=nw=1:nk=1 "$FL" 2>/dev/null | tr ';' '\n' | grep -c .)
chk "flac has >=2 artist values" '[[ "${N:-0}" -ge 2 ]]'
MP="$(find "$LIB" -name '02 - Bell.mp3' | head -1)"
chk "flac has embedded cover art" '[[ "$(pics "$FL")" -ge 1 ]]'
chk "mp3 has embedded cover art"  '[[ "$(pics "$MP")" -ge 1 ]]'
chk "external cover.jpg also written" 'find "$LIB" -name cover.jpg | grep -q .'

"$SHELVE" undo >/dev/null
chk "flac restored byte-identical" 'cmp -s "$SRC/01.flac" "$TMP/01.flac.orig"'
chk "mp3 restored byte-identical"  'cmp -s "$SRC/02.mp3" "$TMP/02.mp3.orig"'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
