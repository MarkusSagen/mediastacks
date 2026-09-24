#!/usr/bin/env bash
# API-contract smoke for `medias review`: build a messy folder, start the
# server, exercise /api/plan + /api/edit (retitle) + /api/apply, assert the
# resulting library tree, then `medias undo` and assert it's reverted.
# The browser JS isn't tested here — this covers the API it depends on.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MEDIAS="$ROOT/zig-out/bin/medias"
[[ -x "$MEDIAS" ]] || { echo "build first: zig build" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }

PORT=8899
TMP="$(mktemp -d -t mediastacks-review.XXXXXX)"
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/down/The Show"
LIB="$TMP/lib"
mkdir -p "$SRC"
printf a > "$SRC/The.Show.S01E01.720p.mkv"
printf bb > "$SRC/The.Show.S01E02.720p.mkv"
printf junk > "$SRC/.DS_Store"

SVPID=""
cleanup() { [[ -n "$SVPID" ]] && kill "$SVPID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

"$MEDIAS" review "$SRC" --to "$LIB" --port "$PORT" --no-probe >/dev/null 2>&1 &
SVPID=$!
sleep 1

PASS=0; FAIL=0
check() { if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

echo "== /api/plan =="
PLAN="$(curl -s "localhost:$PORT/api/plan")"
check "plan has a tv group" 'python3 -c "import json,sys;d=json.loads(sys.argv[1]);assert any(g[\"kind\"]==\"tv\" for g in d[\"groups\"])" "$PLAN"'
check "an item has a dst" 'python3 -c "import json,sys;d=json.loads(sys.argv[1]);assert any(it.get(\"dst\") for g in d[\"groups\"] for it in g[\"items\"])" "$PLAN"'

echo "== /api/edit retitle =="
EDITED="$(curl -s -XPOST "localhost:$PORT/api/edit" -H 'content-type: application/json' -d '{"op":"retitle","group":0,"title":"Renamed Show"}')"
check "retitle recomputes dst with new title" 'python3 -c "import json,sys;d=json.loads(sys.argv[1]);assert any(\"Renamed Show\" in (it.get(\"dst\") or \"\") for it in d[\"groups\"][0][\"items\"])" "$EDITED"'

echo "== /api/apply =="
RES="$(curl -s -XPOST "localhost:$PORT/api/apply")"
check "apply moved >0" 'python3 -c "import json,sys;assert json.loads(sys.argv[1])[\"moved\"]>0" "$RES"'
check "episode landed under renamed folder" 'find "$LIB/Shows/Renamed Show" -iname "*S01E01*.mkv" | grep -q .'
check ".DS_Store trashed (gone from source)" '[[ ! -f "$SRC/.DS_Store" ]]'

echo "== undo =="
"$MEDIAS" undo >/dev/null
check "library episode reverted" '! find "$LIB/Shows" -iname "*S01E01*.mkv" 2>/dev/null | grep -q .'
check "source restored" '[[ -f "$SRC/The.Show.S01E01.720p.mkv" ]]'

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
