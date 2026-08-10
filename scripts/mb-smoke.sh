#!/usr/bin/env bash
# Live MusicBrainz smoke — OFF unless MB_SMOKE=1 (hits the real network at
# 1 req/sec). Verifies enrichment runs and surfaces a MusicBrainz match line.
set -euo pipefail
[[ "${MB_SMOKE:-0}" == "1" ]] || { echo "MB_SMOKE!=1 — skipping live MusicBrainz smoke"; exit 0; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SHELVE="$ROOT/zig-out/bin/shelve"
[[ -x "$SHELVE" ]] || { echo "build first: zig build" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "need ffmpeg"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" XDG_CACHE_HOME="$TMP/cache" XDG_DATA_HOME="$TMP/data"
mkdir -p "$XDG_CONFIG_HOME/stacks" "$TMP/dl/album"
printf 'musicbrainz = on\n' > "$XDG_CONFIG_HOME/stacks/config.toml"

# A small, stable 2-track album MusicBrainz knows. Adjust if the release moves.
meta=(-metadata album="Communiqué" -metadata album_artist="Dire Straits")
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title="Once Upon a Time in the West" -metadata track=1 -y "$TMP/dl/album/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title="News" -metadata track=2 -y "$TMP/dl/album/02.mp3"

OUT="$("$SHELVE" organize "$TMP/dl/album" --to "$TMP/lib" --dry-run)"
echo "$OUT" | grep -E "Music/|MusicBrainz" || true
if echo "$OUT" | grep -qi "MusicBrainz"; then
    echo "ok: MusicBrainz enrichment ran"
else
    echo "FAIL: no MusicBrainz line in output"; exit 1
fi
