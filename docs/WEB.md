# Web UI

The web UI is a small single-page app served by a Zig HTTP server
embedded in `booktool`. It runs against the same SQLite catalog the
CLI manages, so a library you've scanned/enriched/renamed shows up
immediately in the browser.

## Run it

```sh
booktool serve                       # http://127.0.0.1:8787/
booktool serve --port 9090           # other port
booktool serve --bind 0.0.0.0        # listen on every interface
```

The catalog is opened read-write at the standard XDG location
(`$XDG_DATA_HOME/booktool/catalog.db`, default
`~/.local/share/booktool/catalog.db`). Run `booktool scan DIR` first if
the database is empty — `serve` will start either way and the UI will
just show a "0 books" stats line.

Stop the server with `Ctrl-C`.

Defaults bind to **127.0.0.1**, so no traffic leaks off your machine
unless you opt in with `--bind 0.0.0.0`. There is no auth — treat any
binding beyond localhost as careful, manual exposure.

## What's in the UI

The default landing view is a **gallery** of covers. Toggle to a
**list** layout (thumbnail + author + title + badges) from the header.

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  booktool   [search…]   [All][Missing][Duplicates]  [▦][▤]  12 b │
 ├──────────────────────────────────────────────────────────────────┤
 │  ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐ ┌───┐                 │
 │  │   │ │   │ │   │ │   │ │   │ │   │ │   │ │   │                 │
 │  │   │ │   │ │   │ │   │ │   │ │   │ │   │ │   │                 │
 │  └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘ └───┘                 │
 │  Title  Title  Title  Title  Title  Title  Title  Title          │
 │  Auth   Auth   Auth   Auth   Auth   Auth   Auth   Auth           │
 └──────────────────────────────────────────────────────────────────┘
```

**View tabs** (top middle):
- **All** — every catalogued book
- **Missing** — books with one or more missing key fields (title,
  author, year, ISBN). Same query as `booktool missing`.
- **Duplicates** — exact SHA-256 dup groups. Each group is rendered as
  a labeled mini-list regardless of the active layout.

**Layout toggle** (▦ Gallery / ▤ List): defaults to gallery. Persists
in-memory for the session.

**Search** filters the visible books live by title or author substring.

**Detail panel** slides in from the right when you click a card. It
shows the cover from `/api/books/:id/cover`, all populated metadata
fields, and per-book actions:

- **Read** — in-browser reader overlay (EPUB). `Esc` to close,
  `←`/`→` to page.
- **Convert + read** — shown instead of Read for MOBI/AZW3. Triggers a
  libmobi-side conversion to EPUB, picks up the new file from the
  catalog, and opens it in the reader.
- **Download** — streams the original file from `/api/books/:id/file`.
- **Edit** — flips the panel into edit mode. Inputs for title, author,
  series, series index, year, publisher, language, ISBN, subjects
  (comma-separated), description (textarea), and an inline cover file
  picker. Save rewrites the EPUB's OPF and updates the catalog row;
  Cancel discards changes. The picked cover (if any) is pushed first
  so the row is never marked "manual" with a stale image.
- **Fetch info** — POSTs to `/api/books/:id/enrich`, merging Open
  Library results into the existing metadata.
- **Change cover** — file picker, base64-encodes the image client-side
  and POSTs to `/api/books/:id/cover`. EPUB only at the file level —
  libmobi doesn't expose a cover-write API, so MOBI/AZW3 returns a
  clear "convert to EPUB first" error.
- **Reset to embedded** — discards manual edits and Open Library
  enrichments by re-reading the file's embedded OPF / MOBI metadata
  and overwriting the catalog row.
- **Convert ▾** — dropdown of target formats. Calls
  `/api/books/:id/convert`; output lands next to the source file.
- **Delete** — confirmation modal; optionally also unlink the file.

Click **← back** to dismiss the panel.

### Multi-select

Hover over a card to reveal its checkbox in the top-left corner. Click
to toggle. While any cards are selected, a toolbar appears at the top
of the main area:

- **Enrich all** — bulk Open Library lookups.
- **Mark reading / Mark finished** — bulk read-status updates.
- **Delete…** — removes the catalog rows for the selected books (files
  are kept by default).
- **Clear** — deselect everything.

### Search, filter, and sort

**Search box** (top centre) accepts free text plus `key:value` tokens.
Plain words match title or author substring. Tokens narrow the result
set:

```
hobb                       free-text against title + author
author:"Hobb, Robin"       quoted values for multi-word authors
series:"Farseer Trilogy"
status:reading             unread | reading | finished
format:epub                epub | mobi | azw3 | pdf
year:2010                  exact year
year:2010-2020             year range
has:isbn                   only books with an ISBN
missing:cover              books without a cover
genre:Fantasy
```

Plain text and tokens combine: `hobb status:reading year:1995-2005`.

**Sort dropdown** (top right): author / title / year (newest|oldest) /
recently added / recently updated / series / file size.

**Facet sidebar** (left column):

- **Status** — Unread / Reading / Finished
- **Has** — ISBN / Cover / Series
- **Authors** — every author in the catalog with book counts, click to
  filter; click again to clear.
- **Series** — same for series.
- **Genres** — extracted from EPUB `<dc:subject>` or MOBI subject EXTH.

Active filters render as **chips** above the library — click a chip to
remove that filter, or **clear all** to reset everything.

### Reading status

Each card carries a coloured dot in the top-right corner:
- *(invisible)* — Unread
- 🟠 — Reading
- 🟢 — Finished

The dot is set/unset from the **status toggle** in the detail panel
(three-button group: Unread · Reading · Finished). Transitions stamp
`started_at` (first move to Reading) and `finished_at` (move to
Finished); both are exposed via `/api/books/:id`.

The reader is built on [epub.js](https://github.com/futurepress/epub.js/),
loaded from a CDN. Paginated mode by default; the reader fetches
chapter blobs from `/api/books/:id/file` so it works against any
catalogued EPUB without preprocessing.

## HTTP routes

### Read

| Method | Path | Body / Response |
|---|---|---|
| `GET` | `/` | SPA `index.html` |
| `GET` | `/app.js`, `/styles.css` | embedded static assets |
| `GET` | `/favicon.svg`, `/favicon.ico` | embedded favicon (both routes return the SVG) |
| `GET` | `/.well-known/...` | `204 No Content` (silences Chrome DevTools probes) |
| `GET` | `/api/books?...` | JSON array — see "Query parameters" below |
| `GET` | `/api/missing` | JSON array — only incomplete books |
| `GET` | `/api/unverified` | JSON array — only books still on embedded metadata with low confidence |
| `GET` | `/api/duplicates` | `[{ "sha256": "...", "books": [...] }, ...]` |
| `GET` | `/api/authors` | `[{ "name": "Hobb, Robin", "count": 5 }, ...]` |
| `GET` | `/api/series` | same shape, distinct series |
| `GET` | `/api/genres` | same shape, distinct subjects/genres |
| `GET` | `/api/books/:id` | JSON for one book (full metadata) |
| `GET` | `/api/books/:id/file` | raw bytes, `application/epub+zip` etc. |
| `GET` | `/api/books/:id/cover` | image bytes, `image/jpeg` or `image/png` |

#### Query parameters for `/api/books`

All optional, combinable. Filtering is server-side SQL.

| Param | Effect |
|---|---|
| `q=text` | substring match against title and author_sort |
| `author=Hobb,+Robin` | exact `author_sort` |
| `series=Farseer+Trilogy` | exact `series` |
| `genre=Fantasy` | substring match against subjects JSON |
| `format=epub` | one of `epub` / `mobi` / `azw3` / `pdf` |
| `year_from=2010`, `year_to=2020` | numeric range, inclusive |
| `status=reading` | `unread` / `reading` / `finished` |
| `source=openlibrary` | enrichment source name |
| `has_isbn=1`, `has_cover=1`, `has_series=1` | only books that have it; `0` for the inverse |
| `missing=1` | shorthand for "any of title/author/year/isbn missing" |
| `order=year_desc` | `author` (default) / `title` / `year_asc` / `year_desc` / `added_desc` / `updated_desc` / `series` / `size_desc` |
| `limit=50` | cap the result count |

### Write

| Method | Path | Body | Result |
|---|---|---|---|
| `PATCH` | `/api/books/:id` | `{title?, author?, series?, series_index?, year?}` | Rewrites embedded OPF (EPUB) + catalog row. Returns the updated book JSON. |
| `POST` | `/api/books/:id/enrich` | (empty) | Open Library lookup + merge. Returns `{enriched: bool, book: {...}}`. |
| `POST` | `/api/books/:id/convert` | `{to: "epub"\|"mobi"\|"azw3"\|"pdf"}` | Returns `{ok: true, path}`. Same engines as the CLI's `convert`. |
| `POST` | `/api/books/:id/cover` | `{data_base64}` **or** `{url}` | EPUB only. Replaces the cover-manifest entry bytes. With `{url}` the server fetches the image (used for Open Library alt covers, avoids browser CORS dance). |
| `POST` | `/api/books/:id/reset` | (empty) | Re-reads embedded metadata; discards manual edits and enrichments. Returns the refreshed book. |
| `DELETE` | `/api/books/:id[?file=1]` | (empty) | Removes catalog row. With `?file=1`, also unlinks the file. |
| `PATCH` | `/api/books/:id/status` | `{status: "unread"\|"reading"\|"finished"}` | Sets reading state; stamps `started_at` / `finished_at`. Returns the updated book. |
| `POST` | `/api/books/bulk/enrich` | `{ids: [...]}` | `{enriched, no_match, errors}` counts. |
| `POST` | `/api/books/bulk/delete` | `{ids: [...], remove_files?: bool}` | `{deleted}` count. |

Anything else returns `404 not found\n`. Errors from write endpoints
return `400 Bad Request` with `{error: "...", detail?: "..."}` JSON.

The JSON shape per book:

```json
{
  "id": 1,
  "path": "/path/to/book.epub",
  "sha256": "abc…",
  "format": "epub",
  "size": 1450648,
  "title": "Augustus",
  "author_sort": "Williams, John",
  "authors": ["Williams, John"],
  "year": 2014,
  "isbn": "9781590178225",
  "language": "en",
  "publisher": "New York Review Books",
  "cover_url_external": "https://covers.openlibrary.org/b/id/…",
  "confidence": 0.90,
  "source": "embedded"
}
```

All metadata fields are optional and omitted when missing — the
frontend treats absent keys as "unknown" and adjusts its layout.

## Try it with `curl`

```sh
# Start the server in another terminal first.
curl -s http://127.0.0.1:8787/api/books | jq 'length'
curl -s http://127.0.0.1:8787/api/duplicates | jq '.[].books | length'
curl -s -o cover.jpg http://127.0.0.1:8787/api/books/1/cover
curl -s -o book.epub http://127.0.0.1:8787/api/books/1/file

# Write side
curl -sX PATCH -H 'content-type: application/json' \
  -d '{"series":"Stormlight","series_index":"1"}' \
  http://127.0.0.1:8787/api/books/1
curl -sX POST http://127.0.0.1:8787/api/books/1/enrich
curl -sX POST -H 'content-type: application/json' \
  -d '{"to":"mobi"}' http://127.0.0.1:8787/api/books/1/convert
curl -sX POST -H 'content-type: application/json' \
  -d "$(jq -n --arg b "$(base64 cover.jpg)" '{data_base64:$b}')" \
  http://127.0.0.1:8787/api/books/1/cover
curl -sX DELETE 'http://127.0.0.1:8787/api/books/1?file=1'

# Bulk
curl -sX POST -H 'content-type: application/json' \
  -d '{"ids":[1,2,3]}' \
  http://127.0.0.1:8787/api/books/bulk/enrich
```

## Architecture

```
src/web/
├── server.zig     std.http.Server over std.Io.net.Stream
├── api.zig        JSON serialisation + file streaming
├── static.zig     @embedFile wrappers for the 3 frontend files
└── assets/
    ├── index.html
    ├── app.js
    └── styles.css
```

- **One acceptor loop, one request at a time.** Fine for a localhost
  personal-library tool. Swap the loop body for `io.concurrent` if you
  ever care about parallel clients.
- **Static assets are embedded** at compile time via `@embedFile`.
  Edit any of `index.html`, `app.js`, `styles.css` and `zig build`
  re-bakes them into the binary. No runtime asset directory.
- **Hand-rolled JSON.** `src/web/api.zig` writes responses directly to
  an `ArrayList(u8)` — about 200 LOC, no `std.json.Stringify` plumbing.
  The shape stays decoupled from the catalog/`BookMetadata` types.
- **No auth, no CORS.** Everything is same-origin.

## Customising the frontend

The three files in `src/web/assets/` are vanilla HTML/CSS/JS. To
iterate:

1. Edit the file.
2. `zig build` (the `@embedFile` rebakes the bytes — cached otherwise).
3. Restart the server.

Live-reload isn't wired up. If you want to hack on the JS specifically,
you can also serve the assets out of a static dir during development —
just point your browser at the file via `python -m http.server` in
`src/web/assets/` and configure the `fetch()` calls to hit the running
booktool server's origin (it's same-origin from `127.0.0.1`).

The reader uses **epub.js 0.3.93** from jsdelivr. Swapping in
[foliate-js](https://github.com/johnfactotum/foliate-js) (more modern,
better typography) is a drop-in replacement — same `renderTo`/`display`
contract.

## Known limitations

- **EPUB only in the embedded reader.** MOBI/AZW3/PDF surface metadata
  and Download, but the in-browser reader doesn't render them. Convert
  to EPUB first (Convert ▾ menu) if you want to read them in the
  browser.
- **Cover upload is EPUB-only.** MOBI/AZW3 cover replacement happens
  via `mobimeta` in the CLI's `set-cover` command and isn't exposed
  on the web yet.
- **PATCH is best-effort for non-EPUB.** The catalog row is updated,
  but the file's embedded metadata is only rewritten for EPUB. For
  MOBI/AZW3 use the CLI's `set-meta` (which shells out to `mobimeta`).
- **No bulk convert / bulk rename.** These would tie up the server
  for many seconds; do them from the CLI.
- **No realtime updates.** Refresh the page after a CLI session that
  changes the catalog out from under an open browser.
- **No auth, no HTTPS.** Defaults bind to `127.0.0.1`. To expose
  remotely, run behind a reverse proxy that terminates TLS and does
  auth.
- **Single-threaded acceptor.** Multiple browsers connecting at once
  will queue. Personal-use scale is fine; for anything else, replace
  the loop body with `io.concurrent`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Page is empty, server logs `GET /api/books` | catalog has no books | `booktool scan DIR` first |
| Cover image broken | book has no embedded cover, or `mobitool` missing for MOBI/AZW3 | `brew install libmobi` |
| Reader stuck on "loading…" | non-EPUB book selected, or epub.js failed to fetch | open browser devtools and check the network tab |
| `listening on …` then immediate exit | port already in use | `--port` to a different one |
