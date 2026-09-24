#!/usr/bin/env bash
# makem4b smoke: ffmpeg makes 3 tagged chapter mp3s + a cover; `medias makem4b`
# merges them into one chaptered .m4b; ffprobe confirms 3 chapters + audio +
# attached cover; sources are kept; `medias undo` removes the .m4b.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
MEDIAS="$ROOT/zig-out/bin/medias"
[[ -x "$MEDIAS" ]] || { echo "build first: zig build" >&2; exit 2; }
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "ffmpeg/ffprobe absent — skipping m4b smoke"; exit 0; }

TMP="$(mktemp -d -t mediastacks-m4b.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/dl/1984"; LIB="$TMP/lib"; mkdir -p "$SRC"

meta=(-metadata album=1984 -metadata album_artist="George Orwell")
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Prologue  -metadata track=1 -y "$SRC/01 Prologue.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title="Part One" -metadata track=2 -y "$SRC/02 Part One.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title="Part Two" -metadata track=3 -y "$SRC/03 Part Two.mp3"
ffmpeg -v error -f lavfi -i color=c=green:s=64x64 -frames:v 1 -y "$SRC/cover.jpg"

PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

OUT="$("$MEDIAS" makem4b "$SRC" --to "$LIB")"; echo "$OUT" | sed 's/^/  > /'
M4B="$(find "$LIB" -name '*.m4b' | head -1)"
chk "m4b created" '[[ -n "$M4B" ]]'
chk "landed under Audiobooks/Orwell, George" '[[ "$M4B" == *"/Audiobooks/Orwell, George/1984/"* ]]'
NCH=$(ffprobe -v error -show_entries chapter=id -of csv=p=0 "$M4B" 2>/dev/null | grep -c .)
chk "has 3 chapters" '[[ "${NCH:-0}" -eq 3 ]]'
NAUD=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$M4B" 2>/dev/null | grep -c .)
chk "has an audio stream" '[[ "${NAUD:-0}" -ge 1 ]]'
NPIC=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$M4B" 2>/dev/null | grep -c .)
chk "has embedded cover" '[[ "${NPIC:-0}" -ge 1 ]]'
chk "source chapters kept" '[[ -f "$SRC/01 Prologue.mp3" && -f "$SRC/03 Part Two.mp3" ]]'

"$MEDIAS" undo >/dev/null
chk "undo removed the m4b" '[[ ! -f "$M4B" ]]'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
