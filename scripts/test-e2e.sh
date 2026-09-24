#!/usr/bin/env bash
# Browser end-to-end test. Boots a fresh `mediastacks serve` against an
# isolated catalog, seeds it from tests/fixtures (CBZ + ebooks), runs
# the Playwright test (scripts/test-e2e.mjs) against it, then tears
# down.
#
# Requires:
#   - node + a Playwright install (`npm install playwright` in this
#     repo or globally, OR `npx playwright install chromium`)
#   - Built mediastacks binary in zig-out/bin
#
# Skip in CI when Playwright isn't available by setting MEDIASTACKS_SKIP_E2E=1.
# (The legacy MEDIASTACKS_SKIP_UI is still honoured for one release.)

set -euo pipefail

if [[ "${MEDIASTACKS_SKIP_E2E:-${MEDIASTACKS_SKIP_UI:-0}}" == "1" ]]; then
    echo "test-e2e: MEDIASTACKS_SKIP_E2E=1 — skipping"
    exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d tests/fixtures/epub && ! -d tests/fixtures/mobi ]]; then
    echo "tests/fixtures/ is empty — drop a few ebooks there first." >&2
    exit 2
fi

# Build any binary fixtures (sample.cbz) first.
"$ROOT/scripts/build-fixtures.sh"

TMP_BASE="$(mktemp -d -t mediastacks-ui-smoke.XXXXXX)"
export XDG_DATA_HOME="$TMP_BASE/data"
mkdir -p "$XDG_DATA_HOME"
PORT=${MEDIASTACKS_TEST_PORT:-8899}

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill -INT "$SERVER_PID" 2>/dev/null || true
        sleep 0.5
        kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

echo "==> build"
zig build install >/dev/null 2>&1
BIN="$ROOT/zig-out/bin/mediastacks"

echo "==> seed catalog"
"$BIN" scan tests/fixtures >/dev/null 2>&1 || true

echo "==> launch mediastacks serve on :$PORT"
"$BIN" serve --port "$PORT" >"$TMP_BASE/serve.log" 2>&1 &
SERVER_PID=$!

# Wait for the server to bind.
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fs "http://127.0.0.1:$PORT/api/books" >/dev/null 2>&1; then break; fi
    sleep 0.3
done

# Resolve Playwright. We accept either a local install (./node_modules)
# or a `pnpm dlx`/`npx` shim. CI does `npx playwright install chromium`
# before running this; local devs typically have either node_modules or
# the global Playwright cache populated.
export MEDIASTACKS_TEST_URL="http://127.0.0.1:$PORT"
if [[ -d "$ROOT/node_modules/playwright" ]]; then
    node "$ROOT/scripts/test-e2e.mjs"
else
    # `npx --no-install` errors out if Playwright is missing; that's
    # the right behaviour — we don't want CI silently skipping.
    npx --no-install playwright --version >/dev/null 2>&1 || {
        echo "test-e2e: Playwright not installed. Run:" >&2
        echo "  npm i -D playwright && npx playwright install chromium" >&2
        echo "Or set MEDIASTACKS_SKIP_E2E=1 to skip." >&2
        exit 2
    }
    node "$ROOT/scripts/test-e2e.mjs"
fi
