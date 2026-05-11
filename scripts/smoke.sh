#!/usr/bin/env bash
# End-to-end smoke test for booktool.
#
# Builds the binary, runs every CLI command against tests/fixtures
# inside an isolated XDG_DATA_HOME, asserts on exit codes and output
# shape. Use it as a pre-flight before tagging a release.
#
# Network-touching commands (enrich) can be skipped with --offline.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OFFLINE=0
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --offline) OFFLINE=1 ;;
        --keep) KEEP=1 ;;
        *) echo "usage: $0 [--offline] [--keep]"; exit 2 ;;
    esac
done

if [[ ! -d tests/fixtures/epub && ! -d tests/fixtures/mobi ]]; then
    echo "tests/fixtures/ is empty — drop a few ebooks there first." >&2
    exit 2
fi

# Isolated state so the user's real catalog isn't touched.
SMOKE_HOME="$(mktemp -d -t booktool-smoke.XXXXXX)"
export XDG_DATA_HOME="$SMOKE_HOME"
trap 'if [[ $KEEP -eq 0 ]]; then rm -rf "$SMOKE_HOME"; fi' EXIT

BOOKTOOL="$ROOT/zig-out/bin/booktool"
PASS=0
FAIL=0

assert() {
    local description="$1"
    if "${@:2}"; then
        printf "  \033[32mPASS\033[0m  %s\n" "$description"
        PASS=$((PASS + 1))
    else
        printf "  \033[31mFAIL\033[0m  %s\n" "$description"
        FAIL=$((FAIL + 1))
    fi
}

section() {
    printf "\n\033[1m== %s ==\033[0m\n" "$1"
}

# ---- Build -------------------------------------------------------------

section "build"
mise install >/dev/null 2>&1 || true
zig build 2>&1 | tail -1
[[ -x "$BOOKTOOL" ]] || { echo "no booktool binary"; exit 2; }
echo "  binary: $BOOKTOOL"

# ---- Tests -------------------------------------------------------------

section "unit tests"
zig build test --summary all 2>&1 | grep "tests passed" || true

# ---- find --------------------------------------------------------------

section "find"
find_all_count=$("$BOOKTOOL" find tests/fixtures 2>/dev/null | wc -l | tr -d ' ')
assert "find without filter returns >= 5 results" test "$find_all_count" -ge 5

hobb_count=$("$BOOKTOOL" find tests/fixtures --glob "**/Hobb*" 2>/dev/null | wc -l | tr -d ' ')
assert "find --glob '**/Hobb*' finds at least 5 books" test "$hobb_count" -ge 5

epub_count=$("$BOOKTOOL" find tests/fixtures --format epub 2>/dev/null | wc -l | tr -d ' ')
assert "find --format epub returns at least 3 books" test "$epub_count" -ge 3

assert "find on empty dir returns exit 1" bash -c "
    tmp=\$(mktemp -d)
    set +e
    '$BOOKTOOL' find \"\$tmp\" >/dev/null 2>&1
    code=\$?
    rmdir \"\$tmp\"
    [[ \$code -eq 1 ]]
"

# ---- info --------------------------------------------------------------

section "info"
sample=$("$BOOKTOOL" find tests/fixtures --format epub 2>/dev/null | head -1)
info_out=$("$BOOKTOOL" info "$sample" 2>&1)
assert "info prints Title" grep -q "^Title:" <<<"$info_out"
assert "info prints Format" grep -q "^Format:" <<<"$info_out"

# ---- scan --------------------------------------------------------------

section "scan"
scan_out=$("$BOOKTOOL" scan tests/fixtures 2>&1)
assert "scan reports ingestion summary" grep -q "ingested=" <<<"$scan_out"

scan_again=$("$BOOKTOOL" scan tests/fixtures 2>&1)
assert "scan re-run reports unchanged > 0" grep -E "unchanged=[1-9]" -q <<<"$scan_again"

# ---- missing -----------------------------------------------------------

section "missing"
missing_out=$("$BOOKTOOL" missing 2>&1)
assert "missing produces a count summary" grep -q "incomplete metadata" <<<"$missing_out"

# ---- rename (dry-run) --------------------------------------------------

section "rename"
rename_out=$("$BOOKTOOL" rename 2>&1)
assert "rename dry-run notes itself" grep -q "dry run" <<<"$rename_out"

template_out=$("$BOOKTOOL" rename --template "{year} - {author_sort} - {title}.{ext}" 2>&1)
assert "custom template renders {year} segment" grep -qE "/[0-9]{4} - " <<<"$template_out"

# ---- dedup (no apply) --------------------------------------------------

section "dedup"
dup_out=$("$BOOKTOOL" dedup 2>&1)
assert "dedup runs to completion" test $? -eq 0

# ---- convert -----------------------------------------------------------

section "convert"
src_mobi=$("$BOOKTOOL" find tests/fixtures --format mobi 2>/dev/null | head -1)
if [[ -n "$src_mobi" ]]; then
    out_dir=$(mktemp -d)
    cp "$src_mobi" "$out_dir/"
    cp_file="$out_dir/$(basename "$src_mobi")"
    converted=$("$BOOKTOOL" convert "$cp_file" --to epub 2>&1 | tail -1)
    assert "convert MOBI→EPUB produced a file" test -f "$converted"
    file_type=$(file -b "$converted")
    assert "converted output is EPUB" grep -q "EPUB" <<<"$file_type"
    rm -rf "$out_dir"
fi

# ---- optimize ----------------------------------------------------------

section "optimize"
src_epub=$("$BOOKTOOL" find tests/fixtures --format epub 2>/dev/null | head -1)
if [[ -n "$src_epub" ]]; then
    cp "$src_epub" /tmp/booktool-opt.epub
    before=$(stat -f%z /tmp/booktool-opt.epub 2>/dev/null || stat -c%s /tmp/booktool-opt.epub)
    "$BOOKTOOL" optimize /tmp/booktool-opt.epub >/dev/null
    after=$(stat -f%z /tmp/booktool-opt.epub 2>/dev/null || stat -c%s /tmp/booktool-opt.epub)
    assert "optimize did not grow the file" test "$after" -le "$before"
    rm -f /tmp/booktool-opt.epub
fi

# ---- set-meta ----------------------------------------------------------

section "set-meta"
if [[ -n "$src_epub" ]]; then
    cp "$src_epub" /tmp/booktool-meta.epub
    "$BOOKTOOL" set-meta /tmp/booktool-meta.epub --series "TestSeries" --series-index "7" >/dev/null
    series_check=$(unzip -p /tmp/booktool-meta.epub 2>/dev/null | grep -ao "calibre:series\".*\"TestSeries" | head -1 || true)
    assert "set-meta wrote calibre:series meta" test -n "$series_check"
    rm -f /tmp/booktool-meta.epub
fi

# ---- enrich (network) --------------------------------------------------

if [[ $OFFLINE -eq 0 ]]; then
    section "enrich (network)"
    enrich_out=$("$BOOKTOOL" enrich --limit 1 2>&1 | tail -3)
    assert "enrich --limit 1 prints summary" grep -qE "queried=[0-9]" <<<"$enrich_out"
fi

# ---- standardize (dry-run) ---------------------------------------------

section "standardize"
std_out=$("$BOOKTOOL" standardize tests/fixtures --no-enrich --no-optimize 2>&1)
assert "standardize prints dry-run summary" grep -q "dry-run complete" <<<"$std_out"

# ---- help / version ---------------------------------------------------

section "meta"
assert "version returns 0" "$BOOKTOOL" version >/dev/null
assert "help mentions every command" bash -c "
    help=\$('$BOOKTOOL' help)
    for cmd in info find scan cover convert enrich missing dedup rename serve tui optimize set-cover set-meta standardize; do
        grep -q \"\$cmd\" <<< \"\$help\" || { echo missing \$cmd; exit 1; }
    done
"

# ---- summary -----------------------------------------------------------

section "summary"
total=$((PASS + FAIL))
printf "  %d passed, %d failed (%d total)\n" "$PASS" "$FAIL" "$total"
[[ $FAIL -eq 0 ]]
