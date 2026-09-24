#!/usr/bin/env bash
# Comic smoke: make a .cbz (no ComicInfo), organize it (default writes metadata),
# assert it landed as Comics/{series}/{series} #NNN (year).cbz with an embedded
# ComicInfo.xml, then `medias undo` restores the original (no ComicInfo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
MEDIAS="$ROOT/zig-out/bin/medias"
[[ -x "$MEDIAS" ]] || { echo "build first: zig build" >&2; exit 2; }
command -v zip >/dev/null && command -v unzip >/dev/null || { echo "zip/unzip absent — skipping comic smoke"; exit 0; }

TMP="$(mktemp -d -t mediastacks-comic.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/dl"; LIB="$TMP/lib"; mkdir -p "$SRC/pages"
printf '\xff\xd8\xffJPEGPAGE' > "$SRC/pages/001.jpg"
( cd "$SRC/pages" && zip -q "../Saga #12 (2018).cbz" 001.jpg )
rm -rf "$SRC/pages"

PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

"$MEDIAS" organize "$SRC" --to "$LIB" >/dev/null
CBZ="$(find "$LIB" -name '*.cbz' | head -1)"
chk "cbz landed" '[[ -n "$CBZ" ]]'
chk "renamed Comics/Saga/Saga #012 (2018).cbz" '[[ "$CBZ" == *"/Comics/Saga/Saga #012 (2018).cbz" ]]'
chk "ComicInfo.xml embedded" 'unzip -l "$CBZ" 2>/dev/null | grep -q ComicInfo.xml'
chk "ComicInfo has <Series>Saga</Series>" 'unzip -p "$CBZ" ComicInfo.xml 2>/dev/null | grep -q "<Series>Saga</Series>"'
chk "ComicInfo has <Number>12</Number>" 'unzip -p "$CBZ" ComicInfo.xml 2>/dev/null | grep -q "<Number>12</Number>"'
chk "page preserved in archive" 'unzip -l "$CBZ" 2>/dev/null | grep -q 001.jpg'

"$MEDIAS" undo >/dev/null
SRCCBZ="$SRC/Saga #12 (2018).cbz"
chk "source cbz restored" '[[ -f "$SRCCBZ" ]]'
chk "restored cbz has NO ComicInfo (pre-embed bytes)" '! unzip -l "$SRCCBZ" 2>/dev/null | grep -q ComicInfo.xml'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
