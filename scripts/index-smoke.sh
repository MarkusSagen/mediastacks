#!/usr/bin/env bash
# medias index smoke: build a synthetic library, index it, assert catalog rows.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
MEDIAS="$ROOT/zig-out/bin/medias"
[[ -x "$MEDIAS" ]] || { echo "build first: zig build" >&2; exit 2; }

TMP="$(mktemp -d -t mediastacks-index.XXXXXX)"
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/cfg"
LIB="$TMP/lib"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$LIB/Movies/Dune (2021) [tmdbid-438631]" \
         "$LIB/Shows/Severance/Season 01" \
         "$LIB/Music/Daft Punk/Discovery (2001)"
: > "$LIB/Movies/Dune (2021) [tmdbid-438631]/Dune (2021).mkv"
: > "$LIB/Movies/Dune (2021) [tmdbid-438631]/poster.jpg"
: > "$LIB/Shows/Severance/Season 01/Severance - S01E01.mkv"
: > "$LIB/Shows/Severance/Season 01/Severance - S01E02.mkv"
: > "$LIB/Music/Daft Punk/Discovery (2001)/01 One More Time.flac"

PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

OUT="$("$MEDIAS" index --rebuild --to "$LIB")"
echo "$OUT"
chk "reports 3 items" 'grep -q "indexed 3 item" <<<"$OUT"'

DB="$XDG_DATA_HOME/mediastacks/media.db"
chk "catalog file created" '[[ -f "$DB" ]]'
if command -v sqlite3 >/dev/null; then
  chk "movie row has tmdb + cover" \
    '[[ "$(sqlite3 "$DB" "SELECT provider||\",\"||has_cover FROM items WHERE kind=\"movie\";")" == "tmdb,1" ]]'
  chk "severance has 2 files" \
    '[[ "$(sqlite3 "$DB" "SELECT file_count FROM items WHERE kind=\"tv\";")" == "2" ]]'
  chk "album subtitle is artist" \
    '[[ "$(sqlite3 "$DB" "SELECT subtitle FROM items WHERE kind=\"music\";")" == "Daft Punk" ]]'
else
  echo "  (sqlite3 CLI absent — skipping row assertions)"
fi

# Re-index after removing Music → removed count reflects it.
rm -rf "$LIB/Music"
OUT2="$("$MEDIAS" index --to "$LIB")"
echo "$OUT2"
chk "re-index removes the deleted album" 'grep -q "removed 1" <<<"$OUT2"'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
