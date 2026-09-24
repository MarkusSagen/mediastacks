#!/usr/bin/env bash
# Fill the nuspec version + the install script's checksum from a release.
#   packaging/chocolatey/update-package.sh 0.1.0 ./dist
# then (on Windows, with choco installed):
#   choco pack packaging/chocolatey/mediastacks.nuspec
#   choco push mediastacks.0.1.0.nupkg --source https://push.chocolatey.org/ --api-key $CHOCO_API_KEY
set -euo pipefail
VERSION="${1:?usage: update-package.sh <version> <dist-dir>}"
DIST="${2:?usage: update-package.sh <version> <dist-dir>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
SUM="$(awk '{print $1}' "$DIST/mediastacks-windows-x86_64.zip.sha256")"
perl -pi -e "s#<version>[^<]*</version>#<version>$VERSION</version>#" "$DIR/mediastacks.nuspec"
# replace only the quoted checksum value (either the placeholder or a prior hash)
perl -pi -e "s/'(REPLACE_WITH_SHA256|[0-9a-f]{64})'/'$SUM'/" "$DIR/tools/chocolateyinstall.ps1"
echo "updated choco package → v$VERSION (checksum $SUM)"
