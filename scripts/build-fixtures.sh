#!/usr/bin/env bash
# Builds binary test fixtures that are too churn-prone to check into git
# (zip timestamps, etc.). Idempotent: skips work when the output already
# exists. Currently produces only tests/fixtures/sample.cbz; extend here
# when new archive-shaped fixtures show up.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tests/fixtures/sample.cbz"

if [[ -f "$OUT" ]]; then
    exit 0
fi

WORK="$(mktemp -d -t mediastacks-fixtures.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Three tiny "pages" with valid JFIF magic so format sniffing accepts them.
# Mediastacks's ComicArchive reader only needs the bytes to exist, not to decode.
JPEG_HEADER='\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9'
for n in 001 002 003; do
    printf "$JPEG_HEADER" > "$WORK/page-$n.jpg"
done

cat > "$WORK/ComicInfo.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<ComicInfo>
  <Title>Sample Issue</Title>
  <Series>Test Series</Series>
  <Year>2024</Year>
  <PageCount>3</PageCount>
</ComicInfo>
XML

(cd "$WORK" && zip -q "$OUT" page-001.jpg page-002.jpg page-003.jpg ComicInfo.xml)
echo "built $OUT"
