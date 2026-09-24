#!/usr/bin/env bash
# Web-layer smoke test for mediastacks.
#
# Spins up `mediastacks serve` against an isolated XDG_DATA_HOME and
# exercises the JSON API + static assets via curl. Doesn't need a
# browser — the goal is to catch route regressions and JSON-shape
# drift, not pixel-perfect rendering.
#
# Companion to scripts/smoke.sh, which covers the CLI commands. Run
# both before tagging a release.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d tests/fixtures/epub && ! -d tests/fixtures/mobi ]]; then
    echo "tests/fixtures/ has no ebooks — skipping biblio smoke." >&2
    exit 0
fi

# --- Isolated state -----------------------------------------------------
TMP_BASE="$(mktemp -d -t mediastacks-web-smoke.XXXXXX)"
export XDG_DATA_HOME="$TMP_BASE/data"
mkdir -p "$XDG_DATA_HOME"
PORT=${MEDIASTACKS_TEST_PORT:-8898}

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -INT "$SERVER_PID" 2>/dev/null || true
        sleep 0.5
        kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

# --- Build + seed catalog ----------------------------------------------
echo "==> build"
zig build install >/dev/null 2>&1
BIN="$ROOT/zig-out/bin/mediastacks"

echo "==> seed catalog from fixtures"
"$BIN" scan tests/fixtures >/dev/null 2>&1 || true

# --- Start server ------------------------------------------------------
echo "==> launching mediastacks serve on :$PORT"
"$BIN" serve --port "$PORT" >"$TMP_BASE/serve.log" 2>&1 &
SERVER_PID=$!

# Wait for the listening line
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if grep -q "listening" "$TMP_BASE/serve.log" 2>/dev/null; then break; fi
done
if ! grep -q "listening" "$TMP_BASE/serve.log"; then
    echo "server failed to start"
    cat "$TMP_BASE/serve.log"
    exit 1
fi

PASS=0
FAIL=0
ROOT_URL="http://127.0.0.1:$PORT"

# --- Helpers -----------------------------------------------------------
record_pass() {
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m  %s\n" "$1"
}
record_fail() {
    FAIL=$((FAIL + 1))
    printf "  \033[31mFAIL\033[0m  %s\n" "$1"
}

check() {
    # check "label" expected-status URL [body]
    # Method is inferred from the label's first word ("POST", "DELETE",
    # "GET", "PUT"); defaults to GET / POST-with-body.
    local label="$1"; local want_status="$2"; local url="$3"; local body="${4:-}"
    local method="GET"
    case "$label" in
        DELETE*) method="DELETE" ;;
        POST*) method="POST" ;;
        PUT*) method="PUT" ;;
        *) [[ -n "$body" ]] && method="POST" ;;
    esac
    local resp
    if [[ -n "$body" ]]; then
        resp=$(curl -s -o /tmp/mediastacks-web-resp -w '%{http_code}' \
            -X "$method" -H 'content-type: application/json' -d "$body" "$url")
    else
        resp=$(curl -s -o /tmp/mediastacks-web-resp -w '%{http_code}' \
            -X "$method" "$url")
    fi
    if [[ "$resp" == "$want_status" ]]; then
        record_pass "$label ($resp)"
    else
        record_fail "$label  want=$want_status got=$resp"
        head -c 200 /tmp/mediastacks-web-resp
        echo
    fi
}

# --- Static assets -----------------------------------------------------
echo
printf "\033[1m== static ==\033[0m\n"
check "GET /"           200 "$ROOT_URL/"
check "GET /app.js"     200 "$ROOT_URL/app.js"
check "GET /styles.css" 200 "$ROOT_URL/styles.css"

# --- Core read endpoints -----------------------------------------------
echo
printf "\033[1m== read api ==\033[0m\n"
check "GET /api/books"     200 "$ROOT_URL/api/books?limit=5"
check "GET /api/authors"   200 "$ROOT_URL/api/authors"
check "GET /api/series"    200 "$ROOT_URL/api/series"
check "GET /api/genres"    200 "$ROOT_URL/api/genres"
check "GET /api/formats"   200 "$ROOT_URL/api/formats"
check "GET /api/sources"   200 "$ROOT_URL/api/sources"
check "GET /api/tags"      200 "$ROOT_URL/api/tags"

# --- Books JSON shape sanity check -------------------------------------
echo
printf "\033[1m== shape ==\033[0m\n"
BOOK_ID=$(curl -s "$ROOT_URL/api/books?limit=1" \
    | python3 -c 'import json,sys; b=json.load(sys.stdin); print(b[0]["id"] if b else 0)')
if [[ "$BOOK_ID" -gt 0 ]]; then
    record_pass "books list has a valid id ($BOOK_ID)"
    check "GET /api/books/$BOOK_ID"         200 "$ROOT_URL/api/books/$BOOK_ID"
    check "GET /api/books/$BOOK_ID/cover"   200 "$ROOT_URL/api/books/$BOOK_ID/cover"
    check "GET /api/books/$BOOK_ID/changes" 200 "$ROOT_URL/api/books/$BOOK_ID/changes"
    check "GET /api/books/$BOOK_ID/stats"   200 "$ROOT_URL/api/books/$BOOK_ID/stats"
    check "GET /api/books/$BOOK_ID/tags"    200 "$ROOT_URL/api/books/$BOOK_ID/tags"
else
    record_fail "no books in fixtures — cannot test per-book endpoints"
fi

# --- Tag CRUD roundtrip ------------------------------------------------
echo
printf "\033[1m== tags ==\033[0m\n"
TAG_NAME="smoke-$(date +%s)"
check "POST /api/tags" 200 "$ROOT_URL/api/tags" "{\"name\":\"$TAG_NAME\"}"
TAG_ID=$(python3 -c "import json; print(json.load(open('/tmp/mediastacks-web-resp'))['id'])" 2>/dev/null || echo 0)
if [[ "$TAG_ID" -gt 0 ]] && [[ "$BOOK_ID" -gt 0 ]]; then
    record_pass "tag creation returned id ($TAG_ID)"
    check "POST attach tag"   200 "$ROOT_URL/api/books/$BOOK_ID/tags" "{\"tag_id\":$TAG_ID}"
    BOOK_TAGS=$(curl -s "$ROOT_URL/api/books/$BOOK_ID/tags")
    if echo "$BOOK_TAGS" | grep -q "\"name\":\"$TAG_NAME\""; then
        record_pass "tag visible on book"
    else
        record_fail "tag missing from book tags: $BOOK_TAGS"
    fi
    check "DELETE /api/tags/$TAG_ID" 200 "$ROOT_URL/api/tags/$TAG_ID"
fi

# --- Enrich batch endpoint ---------------------------------------------
echo
printf "\033[1m== enrich batch ==\033[0m\n"
check "GET /api/enrich/batch" 200 "$ROOT_URL/api/enrich/batch"
INITIAL_STATE=$(python3 -c "import json; print(json.load(open('/tmp/mediastacks-web-resp'))['state'])")
if [[ "$INITIAL_STATE" == "idle" ]]; then
    record_pass "enrich job starts in 'idle' state"
else
    record_fail "expected initial state=idle, got $INITIAL_STATE"
fi

# --- Summary -----------------------------------------------------------
echo
printf "\033[1m== summary ==\033[0m\n"
TOTAL=$((PASS + FAIL))
printf "  %d passed, %d failed (%d total)\n" "$PASS" "$FAIL" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
