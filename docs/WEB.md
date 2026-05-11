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

```
 ┌───────────────────────────────────────────────────────────────┐
 │  booktool   [search…]    [All] [Missing] [Duplicates]   12 b  │
 ├───────────────┬───────────────────────────────────────────────┤
 │  thumb  title │   ┌───────┐  Title                            │
 │  thumb  title │   │ cover │  Author · Year · Series · ISBN    │
 │  thumb  title │   └───────┘  [Read] [Download]                │
 │  ▶ ...        │   description…                                │
 │               │                                               │
 │               │   /path/to/the/book.epub                      │
 └───────────────┴───────────────────────────────────────────────┘
```

**Tabs** (top right):
- **All** — every catalogued book
- **Missing** — books with one or more missing key fields (title,
  author, year, ISBN). Same query as `booktool missing`.
- **Duplicates** — exact SHA-256 dup groups. Each group is shown with
  its sha256 prefix and the books that share it.

**Search** filters the sidebar live by title or author substring.

**Detail pane** (selecting a book on the left) shows the cover from
`/api/books/:id/cover`, all populated metadata fields, and two actions:
- **Read** — opens an in-browser reader overlay (EPUB only — see
  below). `Esc` to close, `←`/`→` to page.
- **Download** — streams the original file from `/api/books/:id/file`
  with the correct `Content-Type`.

The reader is built on [epub.js](https://github.com/futurepress/epub.js/),
loaded from a CDN. Paginated mode by default; the reader fetches
chapter blobs from `/api/books/:id/file` so it works against any
catalogued EPUB without preprocessing.

## HTTP routes

| Method | Path | Body / Response |
|---|---|---|
| `GET` | `/` | SPA `index.html` |
| `GET` | `/app.js`, `/styles.css` | embedded static assets |
| `GET` | `/api/books` | JSON array of every book |
| `GET` | `/api/missing` | JSON array — same shape, only incomplete |
| `GET` | `/api/duplicates` | `[{ "sha256": "...", "books": [...] }, ...]` |
| `GET` | `/api/books/:id` | JSON for one book (full metadata) |
| `GET` | `/api/books/:id/file` | raw bytes, `application/epub+zip` etc. |
| `GET` | `/api/books/:id/cover` | image bytes, `image/jpeg` or `image/png` |

Anything else returns `404 not found\n`.

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
  to EPUB first (`booktool convert FILE --to epub`) if you want to
  read them in the browser.
- **No mutations.** All API endpoints are `GET`. To edit metadata,
  delete duplicates, or rename, use the CLI for now. Adding `POST`
  routes that call into the same core modules is straightforward — see
  `src/web/api.zig` for the pattern.
- **No realtime updates.** Refresh the browser after running CLI
  commands that change the catalog.
- **TLS bundle bloats the binary.** `std.http.Client` (used by the
  `enrich` command) embeds a CA bundle that's pulled into the same
  binary as the server. The server doesn't speak HTTPS — bind it to
  localhost and terminate TLS at a reverse proxy if you need remote
  access.
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
