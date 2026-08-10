#!/usr/bin/env bash
# Live TMDB smoke — OFF unless TMDB_SMOKE=1 and TMDB_KEY is set (hits the real
# network). Verifies movie enrichment produces a provider-id folder.
set -euo pipefail
[[ "${TMDB_SMOKE:-0}" == "1" && -n "${TMDB_KEY:-}" ]] || { echo "TMDB_SMOKE!=1 or TMDB_KEY unset — skipping"; exit 0; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SHELVE="$ROOT/zig-out/bin/shelve"
[[ -x "$SHELVE" ]] || { echo "build first: zig build" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$XDG_CONFIG_HOME/stacks" "$TMP/dl"
printf 'tmdb_key = %s\n' "$TMDB_KEY" > "$XDG_CONFIG_HOME/stacks/config.toml"
: > "$TMP/dl/The.Matrix.1999.1080p.BluRay.mkv"
OUT="$("$SHELVE" organize "$TMP/dl" --to "$TMP/lib" --dry-run)"
echo "$OUT" | grep -E "tmdbid-|TMDB" || true
echo "$OUT" | grep -qE "tmdbid-|imdbid-" && echo "ok: TMDB produced a provider id" || { echo "FAIL: no id in output"; exit 1; }
