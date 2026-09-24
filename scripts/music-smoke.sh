#!/usr/bin/env bash
# End-to-end music smoke: ffmpeg-generate a tagged mini-album + cover, then
# `medias organize --apply` into a temp library and assert the album layout,
# then `medias undo`. This is the authoritative tag-driven music test (the
# group unit test is deliberately no-probe/deterministic).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MEDIAS="$ROOT/zig-out/bin/medias"
[[ -x "$MEDIAS" ]] || { echo "build first: zig build" >&2; exit 2; }
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    echo "ffmpeg/ffprobe not installed — skipping music smoke"; exit 0
fi

TMP="$(mktemp -d -t mediastacks-music.XXXXXX)"
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/dl/album"; LIB="$TMP/lib"
mkdir -p "$SRC"
trap 'rm -rf "$TMP"' EXIT

meta=(-metadata album=Blue -metadata album_artist="Eric Clapton" -metadata date=1998)
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Layla   -metadata track=1 -y "$SRC/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Cocaine -metadata track=2 -y "$SRC/02.mp3"
ffmpeg -v error -f lavfi -i color=c=blue:s=64x64 -frames:v 1 -y "$SRC/cover.jpg"

# --- multi-disc set: CD 1 / CD 2 subfolders roll up to one album ---
MD="$TMP/dl/nights"; mkdir -p "$MD/CD 1" "$MD/CD 2"
dmeta=(-metadata album="Night of the Kings" -metadata album_artist="Various Artists" -metadata date=1992)
ffmpeg -v error -f lavfi -i sine=d=1 "${dmeta[@]}" -metadata title=Opening -metadata track=1 -metadata disc=1 -y "$MD/CD 1/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 "${dmeta[@]}" -metadata title=Finale  -metadata track=1 -metadata disc=2 -y "$MD/CD 2/01.mp3"

# --- compilation with differing artists and NO album_artist -> Various Artists ---
VA="$TMP/dl/comp"; mkdir -p "$VA"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=Comp -metadata artist=Alice -metadata title=First  -metadata track=1 -y "$VA/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=Comp -metadata artist=Bob   -metadata title=Second -metadata track=2 -y "$VA/02.mp3"

# --- album with no date tag -> no (year) suffix ---
NY="$TMP/dl/noyear"; mkdir -p "$NY"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=NoYear -metadata artist=Solo -metadata title=Alone -metadata track=1 -y "$NY/01.mp3"

PASS=0; FAIL=0
check() { if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

echo "== dry-run =="
OUT="$("$MEDIAS" organize "$SRC" --to "$LIB" --dry-run)"
echo "$OUT" | grep -E "Music/|summary" || true
check "grouped under album-artist Eric Clapton" 'grep -q "Music/Eric Clapton/Blue (1998)/" <<<"$OUT"'

echo "== apply =="
"$MEDIAS" organize "$SRC" --to "$LIB" >/dev/null
check "track 01 landed with title" '[[ -f "$LIB/Music/Eric Clapton/Blue (1998)/01 - Layla.mp3" ]]'
check "track 02 landed with title" '[[ -f "$LIB/Music/Eric Clapton/Blue (1998)/02 - Cocaine.mp3" ]]'
check "cover landed in album folder" '[[ -f "$LIB/Music/Eric Clapton/Blue (1998)/cover.jpg" ]]'

echo "== undo =="
"$MEDIAS" undo >/dev/null
check "library reverted" '[[ ! -d "$LIB/Music" ]] || [[ -z "$(find "$LIB/Music" -type f 2>/dev/null)" ]]'
check "sources restored" '[[ -f "$SRC/01.mp3" && -f "$SRC/cover.jpg" ]]'

# --- A.1 correctness, verified via dry-run (naming/grouping, no apply needed) ---
echo "== A.1 dry-run =="
MDOUT="$("$MEDIAS" organize "$MD" --to "$LIB" --dry-run)"
check "multi-disc rolls into one album with CD1" 'grep -q "Night of the Kings (1992)/CD1/" <<<"$MDOUT"'
check "multi-disc CD2 subfolder"                 'grep -q "Night of the Kings (1992)/CD2/" <<<"$MDOUT"'

VAOUT="$("$MEDIAS" organize "$VA" --to "$LIB" --dry-run)"
check "compilation filed under Various Artists"  'grep -q "Music/Various Artists/Comp/" <<<"$VAOUT"'

NYOUT="$("$MEDIAS" organize "$NY" --to "$LIB" --dry-run)"
check "no-year album has no () suffix"           'grep -q "Music/Solo/NoYear/" <<<"$NYOUT"'
check "no-year album shows no empty parens"      '! grep -q "NoYear ()" <<<"$NYOUT"'

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
