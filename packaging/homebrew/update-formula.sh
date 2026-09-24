#!/usr/bin/env bash
# Fill the version + the three sha256 placeholders in mediastacks.rb from a
# release's checksum sidecars. Run after a release is built:
#
#   packaging/homebrew/update-formula.sh 0.1.0 ./dist
#
# then copy the updated Formula/mediastacks.rb into your homebrew-mediastacks tap.
set -euo pipefail
VERSION="${1:?usage: update-formula.sh <version> <dist-dir>}"
DIST="${2:?usage: update-formula.sh <version> <dist-dir>}"
F="$(cd "$(dirname "$0")" && pwd)/mediastacks.rb"

sha() { awk '{print $1}' "$DIST/mediastacks-$1.tar.gz.sha256"; }

perl -pi -e "s/version \"[^\"]*\"/version \"$VERSION\"/" "$F"
python3 - "$F" "$(sha macos-arm64)" "$(sha macos-x86_64)" "$(sha linux-x86_64)" <<'PY'
import sys
f, a, x, l = sys.argv[1:5]
s = open(f).read()
zeros = "0" * 64
for val in (a, x, l):
    s = s.replace(zeros, val, 1)
open(f, "w").write(s)
PY
echo "updated $F → v$VERSION"
