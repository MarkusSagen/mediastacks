# Test fixtures

Real-world ebooks used for manual smoke tests and (eventually) golden-file
regression tests in Part 3. The bytes are intentionally `.gitignore`d
because the files are copyrighted — only the directory structure and
this README live in git.

## Layout

```
tests/fixtures/
├── epub/
│   ├── standalone/   # one-off titles (no series)
│   └── series/       # multiple books from one author/series
├── mobi/
│   ├── standalone/
│   └── series/       # numbered series — useful for rename tests
└── azw3/
```

## Reproducing locally

If you don't have these specific books, any ebook works — the test
coverage matrix matters more than the titles:

- **`epub/standalone/`** — two distinct authors, no series metadata
- **`epub/series/`** — three books from the same author (series field
  optional)
- **`mobi/series/`** — five books across two numbered series (tests
  `01..03`, `01..02` ordering and the `Series ## - Title` rename
  template)
- **`mobi/standalone/`** — one MOBI without series data
- **`azw3/`** — one AZW3 (libmobi handles MOBI and AZW3 identically;
  one sample is enough)

## How the suite uses these

| Command | Fixture                | Verifies                        |
|---------|------------------------|---------------------------------|
| `info`  | every file             | format detection + metadata extraction |
| `scan`  | the whole tree         | catalog upsert, idempotent re-scan |
| `cover` | one of each format     | EPUB OPF + miniz path, libmobi/mobitool path |
| `convert` | mobi/series/*.mobi   | libmobi → EPUB conversion |
| `dedup` | duplicate a known file | exact SHA match |
| `rename`| mobi/series/*.mobi     | `{author_sort} - {series} ## - {title}` template |
| `enrich`| any with a real title  | Open Library round-trip |

## Scripted helpers

`scripts/smoke.sh` runs the full pipeline against this directory and
prints a summary. It expects a working `mise` / Zig 0.16 setup.
