#!/usr/bin/env bash
# medias web-app smoke: start `medias serve`, drive the Organize→apply flow over
# HTTP, assert the shell + API + a real move into the library. Uses a
# space-free source path so no URL-encoding is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
MEDIAS="$ROOT/zig-out/bin/medias"
[[ -x "$MEDIAS" ]] || { echo "build first: zig build" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl absent — skipping app smoke"; exit 0; }

TMP="$(mktemp -d -t mediastacks-app.XXXXXX)"
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
# Open-externally recorder (slice C): MEDIASTACKS_OPEN_CMD points the server at this
# script instead of the real `open`, so /api/open never launches a GUI app —
# it just appends its argv to OPENLOG for the checks below to inspect.
OPENLOG="$TMP/opened.txt"
OPENREC="$TMP/openrec.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >> "%s"\n' "$OPENLOG" > "$OPENREC"
chmod +x "$OPENREC"
export MEDIASTACKS_OPEN_CMD="$OPENREC"
SRC="$TMP/dl/show"; LIB="$TMP/lib"; mkdir -p "$SRC"
: > "$SRC/witch.hat.atelier.s01e01.1080p.web.h264-x.mkv"
: > "$SRC/witch.hat.atelier.s01e02.1080p.web.h264-x.mkv"
PORT=$(( (RANDOM % 20000) + 20000 ))
SRV=""
cleanup(){ [[ -n "$SRV" ]] && kill -9 "$SRV" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

"$MEDIAS" serve --port "$PORT" --to "$LIB" >"$TMP/serve.log" 2>&1 &
SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf "http://127.0.0.1:$PORT/api/config" >/dev/null 2>&1 && break; sleep 0.3; done

PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

chk "shell served"        'curl -s "http://127.0.0.1:$PORT/" | grep -q "<title>medias</title>"'
chk "medias.js served"    'curl -s "http://127.0.0.1:$PORT/medias.js" | grep -q "Organize"'
chk "config endpoint"     'curl -s "http://127.0.0.1:$PORT/api/config" | grep -q library_root'
# Onboarding (slice: welcome + demo): empty server (no config.toml, empty catalog) is a first run.
chk "first-run flag on empty server" 'curl -s "http://127.0.0.1:$PORT/api/config" | grep -q "\"first_run\":true"'
ORG="$(curl -s "http://127.0.0.1:$PORT/api/organize?dir=$SRC&no_probe=1")"
chk "organize grouped a Show" 'grep -q "/Shows/" <<<"$ORG"'
chk "organize found 2 episodes" '[[ "$(grep -o S01E0 <<<"$ORG" | wc -l | tr -d " ")" == 2 ]]'
APP="$(curl -s -X POST "http://127.0.0.1:$PORT/api/apply?write_tags=0&write_nfo=0")"
chk "apply moved 2" 'grep -q "\"moved\":2" <<<"$APP"'
chk "files landed in library" '[[ "$(find "$LIB" -name "*.mkv" | wc -l | tr -d " ")" == 2 ]]'

# Library browse should now report the organized show.
LIBJSON="$(curl -s "http://127.0.0.1:$PORT/api/library")"
chk "library lists the Shows kind" 'grep -q "\"kind\":\"tv\"" <<<"$LIBJSON"'
chk "library found the series item" 'grep -q "witch hat atelier" <<<"$LIBJSON"'
# Cover endpoint rejects paths outside the library root.
chk "cover endpoint blocks traversal" '[[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/cover?path=/etc/hosts")" == "403" ]]'
chk "cover rejects sibling-prefix path" '[[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/cover?path=$LIB-evil/x.jpg")" == "403" ]]'

# Catalog Library (slice B): apply auto-reconciled the catalog, so the Shows item
# is queryable without an explicit reindex.
chk "catalog library lists the show" 'grep -q "witch hat atelier" <<<"$LIBJSON"'
chk "catalog library has counts" 'grep -q "\"counts\":{" <<<"$LIBJSON"'
chk "catalog kind filter works" '[[ -n "$(curl -s "http://127.0.0.1:$PORT/api/library?kind=tv" | grep -o witch)" ]]'
chk "catalog kind filter excludes others" '[[ -z "$(curl -s "http://127.0.0.1:$PORT/api/library?kind=movie" | grep -o witch)" ]]'
chk "catalog search matches" '[[ -n "$(curl -s "http://127.0.0.1:$PORT/api/library?q=witch" | grep -o witch)" ]]'
chk "catalog search excludes non-matches" '[[ -z "$(curl -s "http://127.0.0.1:$PORT/api/library?q=zzzznope" | grep -o witch)" ]]'
# Explicit rescan endpoint works too.
chk "reindex endpoint returns total" 'curl -s -X POST "http://127.0.0.1:$PORT/api/reindex" | grep -q "\"total\":"'

# Item detail (slice C): pick the show's id from /api/library, fetch its detail.
ITEMID="$(curl -s "http://127.0.0.1:$PORT/api/library?kind=tv" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)"
ITEM="$(curl -s "http://127.0.0.1:$PORT/api/item?id=$ITEMID")"
chk "item detail returns the title" 'grep -qi "witch hat atelier" <<<"$ITEM"'
chk "item detail lists files" 'grep -q "\"files\":\[{" <<<"$ITEM"'
chk "item detail 404 on bad id" '[[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/item?id=99999")" == "404" ]]'

# Open externally (slice C): MEDIASTACKS_OPEN_CMD recorder — never launches a real app.
# (The recorder + env are set at server start; see the export near the top.)
chk "open reveal returns ok" 'curl -s -X POST "http://127.0.0.1:$PORT/api/open?id=$ITEMID&mode=reveal" | grep -q "\"ok\":true"'
chk "open recorded the -R reveal" 'grep -q -- "-R" "$OPENLOG"'
chk "open rejects non-numeric id" '[[ "$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/api/open?id=abc")" == "400" ]]'

# Inline streaming (slice D): known-bytes fixture → Range request returns 206 + slice.
mkdir -p "$LIB/Movies/Stream Test (2020)"
printf 'ABCDEFGHIJ' > "$LIB/Movies/Stream Test (2020)/Stream Test (2020).mp4"
curl -s -X POST "http://127.0.0.1:$PORT/api/reindex" >/dev/null
SID="$(curl -s "http://127.0.0.1:$PORT/api/library?kind=movie" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)"
SHDR="$(curl -s -D - -o /dev/null -H "Range: bytes=2-4" "http://127.0.0.1:$PORT/api/stream?id=$SID")"
chk "stream returns 206 for a range"    'grep -qi "206" <<<"$SHDR"'
chk "stream sets content-range"         'grep -qi "content-range: bytes 2-4/10" <<<"$SHDR"'
chk "stream advertises accept-ranges"   'grep -qi "accept-ranges: bytes" <<<"$SHDR"'
chk "stream range body is the slice"    '[[ "$(curl -s -H "Range: bytes=2-4" "http://127.0.0.1:$PORT/api/stream?id=$SID")" == "CDE" ]]'
chk "stream no-range is 200"            '[[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/stream?id=$SID")" == "200" ]]'
chk "stream 404 on bad id"              '[[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/api/stream?id=99999")" == "404" ]]'

# Cover art (enrichment writes poster.jpg; here we verify the on-disk -> catalog ->
# /api/cover serve chain that enriched covers feed into).
printf '\xFF\xD8\xFFPOSTER\xFF\xD9' > "$LIB/Movies/Stream Test (2020)/poster.jpg"
curl -s -X POST "http://127.0.0.1:$PORT/api/reindex" >/dev/null
LIBC="$(curl -s "http://127.0.0.1:$PORT/api/library?kind=movie")"
chk "catalog marks the item has_cover" 'grep -q "\"has_cover\":true" <<<"$LIBC"'
chk "library emits an /api/cover url"  'grep -q "/api/cover?path=" <<<"$LIBC"'
COVURL="$(grep -o "/api/cover?path=[^\"]*" <<<"$LIBC" | head -1)"
chk "/api/cover serves the poster as an image" '[[ "$(curl -s -o /dev/null -w "%{content_type}" "http://127.0.0.1:$PORT$COVURL")" == image/* ]]'

# Enrichment job (slice E): no tmdb_key configured → job runs, finds no match,
# but the thread + status endpoint work end-to-end (no network hit).
ENID="$(curl -s "http://127.0.0.1:$PORT/api/library?kind=movie" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)"
chk "enrich start accepted" 'curl -s -X POST "http://127.0.0.1:$PORT/api/enrich?id=$ENID" | grep -q "\"started\":true"'
# poll up to ~5s for the job to finish
EOK=0; for _ in $(seq 1 25); do
  ST="$(curl -s "http://127.0.0.1:$PORT/api/enrich/status")"
  grep -q '"state":"finished"' <<<"$ST" && { EOK=1; break; }
  sleep 0.2
done
chk "enrich job reaches finished" '[[ "$EOK" == "1" ]]'
chk "enrich status reports totals" 'grep -q "\"processed\":1" <<<"$ST"'

# Undo history (slice 3): the apply above wrote a journal → list shows it → revert restores.
UNDO="$(curl -s "http://127.0.0.1:$PORT/api/undo/list")"
chk "undo lists the applied run" 'grep -q "\"moved\":2" <<<"$UNDO"'
RUNID="$(grep -o "\"id\":\"[^\"]*\"" <<<"$UNDO" | head -1 | sed "s/.*:\"//;s/\"//")"
curl -s -X POST "http://127.0.0.1:$PORT/api/undo/revert?id=$RUNID" >/dev/null
chk "revert emptied the library" '[[ "$(find "$LIB" -name "*.mkv" | wc -l | tr -d " ")" == 0 ]]'
chk "revert restored the source" '[[ -f "$SRC/witch.hat.atelier.s01e01.1080p.web.h264-x.mkv" ]]'
chk "catalog drops the reverted item" '[[ -z "$(curl -s "http://127.0.0.1:$PORT/api/library" | grep -o witch)" ]]'

# Settings editor (slice 4): POST merges into config.toml + reloads.
curl -s -X POST "http://127.0.0.1:$PORT/api/config" -d '{"write_tags":true,"musicbrainz":true,"tmdb_key":"KEY123"}' >/dev/null
chk "settings persisted to config.toml" 'grep -q "write_tags = on" "$XDG_CONFIG_HOME/mediastacks/config.toml"'
chk "settings reload reflects POST" 'curl -s "http://127.0.0.1:$PORT/api/config" | grep -q "\"tmdb_key\":\"KEY123\""'

# Onboarding demo sandbox: enter (seeds throwaway media + points env at it), then
# leave (restores the real env). Runs last so the XDG switch can't affect earlier checks.
DEMO="$(curl -s -X POST "http://127.0.0.1:$PORT/api/demo")"
chk "demo starts" 'grep -q "\"demo\":true" <<<"$DEMO"'
chk "demo library populated" '[[ -n "$(curl -s "http://127.0.0.1:$PORT/api/library" | grep -o "Blade Runner")" ]]'
chk "demo_active flag set" 'curl -s "http://127.0.0.1:$PORT/api/config" | grep -q "\"demo_active\":true"'
chk "leave demo restores" 'curl -s -X POST "http://127.0.0.1:$PORT/api/demo?exit=1" | grep -q "\"demo\":false"'
chk "demo_active cleared" 'curl -s "http://127.0.0.1:$PORT/api/config" | grep -q "\"demo_active\":false"'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
