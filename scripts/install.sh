#!/usr/bin/env bash
# mediastacks installer — downloads the latest (or a pinned) release tarball for
# this machine's OS/arch, verifies its checksum, and installs the `biblio` +
# `medias` binaries. macOS + Linux only (Windows is not yet supported).
#
#   curl -fsSL https://raw.githubusercontent.com/markussagen/mediastacks/main/scripts/install.sh | bash
#
# Env / flags:
#   MEDIASTACKS_REPO   GitHub "owner/name"     (default: markussagen/mediastacks)
#   MEDIASTACKS_VERSION release tag to install (default: latest)
#   --dir DIR / PREFIX  install directory      (default: /usr/local/bin, else ~/.local/bin)
set -euo pipefail

REPO="${MEDIASTACKS_REPO:-markussagen/mediastacks}"
VERSION="${MEDIASTACKS_VERSION:-latest}"
BINDIR="${PREFIX:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) BINDIR="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

err() { echo "error: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── platform → release asset name (matches release.yml's matrix targets) ──
os="$(uname -s)"; arch="$(uname -m)"
case "$os" in
  Darwin) plat=macos ;;
  Linux)  plat=linux ;;
  *) err "unsupported OS '$os' (macOS + Linux only; Windows is not yet supported)" ;;
esac
case "$arch" in
  arm64|aarch64) a=arm64 ;;
  x86_64|amd64)  a=x86_64 ;;
  *) err "unsupported architecture '$arch'" ;;
esac
# Linux release currently ships x86_64 only.
if [[ "$plat" == linux && "$a" != x86_64 ]]; then
  err "no prebuilt Linux $a build yet — build from source (see README)"
fi
target="${plat}-${a}"
asset="mediastacks-${target}.tar.gz"

# ── resolve download URL (MEDIASTACKS_BASE_URL overrides for mirrors/tests) ──
base="${MEDIASTACKS_BASE_URL:-https://github.com/${REPO}/releases}"
if [[ "$VERSION" == latest ]]; then
  url="${base}/latest/download/${asset}"
else
  url="${base}/download/${VERSION}/${asset}"
fi

# ── install dir: prefer a writable /usr/local/bin, else ~/.local/bin ──
if [[ -z "$BINDIR" ]]; then
  if [[ -w /usr/local/bin ]]; then BINDIR=/usr/local/bin; else BINDIR="$HOME/.local/bin"; fi
fi
mkdir -p "$BINDIR"

have curl || err "curl is required"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "→ downloading $asset ($VERSION) for $target"
curl -fSL --proto '=https' "$url" -o "$tmp/$asset" \
  || err "download failed: $url  (does a release for $target exist?)"

# ── verify checksum when the .sha256 sidecar is present ──
if curl -fsSL "${url}.sha256" -o "$tmp/$asset.sha256" 2>/dev/null; then
  echo "→ verifying checksum"
  ( cd "$tmp"
    want="$(awk '{print $1}' "$asset.sha256")"
    if have shasum; then got="$(shasum -a 256 "$asset" | awk '{print $1}')"; else got="$(sha256sum "$asset" | awk '{print $1}')"; fi
    [[ "$want" == "$got" ]] || { echo "checksum mismatch: want $want got $got" >&2; exit 1; } )
else
  echo "! no checksum sidecar published — skipping verification"
fi

echo "→ installing to $BINDIR"
tar -xzf "$tmp/$asset" -C "$tmp"
install -m 0755 "$tmp/biblio" "$tmp/medias" "$BINDIR/"

# ── runtime deps check (best-effort, non-fatal) ──
missing=()
if [[ "$plat" == macos ]]; then
  for lib in libmobi libxml2 sqlite3; do
    ls /opt/homebrew/opt/$lib/lib/* /usr/local/opt/$lib/lib/* >/dev/null 2>&1 || missing+=("$lib")
  done
  [[ ${#missing[@]} -gt 0 ]] && echo "! runtime deps not found: ${missing[*]} — run: brew install libmobi libxml2 sqlite"
else
  ldconfig -p 2>/dev/null | grep -qi 'libmobi'  || missing+=(libmobi-dev)
  ldconfig -p 2>/dev/null | grep -qi 'libxml2'  || missing+=(libxml2)
  ldconfig -p 2>/dev/null | grep -qi 'libsqlite3'|| missing+=(libsqlite3)
  [[ ${#missing[@]} -gt 0 ]] && echo "! runtime deps not found: ${missing[*]} — run: sudo apt install libmobi-dev libxml2 libsqlite3-0"
fi

echo "✓ installed biblio + medias to $BINDIR"
case ":$PATH:" in *":$BINDIR:"*) ;; *) echo "  note: add $BINDIR to your PATH" ;; esac
echo "  try:  medias --help   |   medias serve --demo"
