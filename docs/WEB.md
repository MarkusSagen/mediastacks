# Web UI

The web UI is a small single-page app served by a Zig HTTP server
embedded in `mediastacks`. It runs against the same SQLite catalog the
CLI manages, so a library you've scanned/enriched/renamed shows up
immediately in the browser.

## Run it

```sh
mediastacks serve                       # http://127.0.0.1:8787/
mediastacks serve --port 9090           # other port
mediastacks serve --bind 0.0.0.0        # listen on every interface
```

The catalog is opened read-write at the standard XDG location
(`$XDG_DATA_HOME/mediastacks/catalog.db`, default
`~/.local/share/mediastacks/catalog.db`). Run `mediastacks scan DIR` first if
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
 │  mediastacks   [search…]   [All][Missing][Duplicates]  [▦][▤]  12 b │
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
- **Series** — grouped by series, in reading order
- **Variants** — same work, multiple file formats side-by-side
- **Missing** — books with one or more missing key fields (title,
  author, year, ISBN). Same query as `mediastacks missing`.
- **Unverified** — books still on embedded-only metadata
- **Duplicates** — exact SHA-256 + fuzzy / cross-format groups, each
  rendered as a labeled mini-list regardless of the active layout
- **Rename** — preview of the canonical filename plan for every book
- **Triage** — one-by-one fix flow for unverified / missing books

**Layout toggle** (▦ Gallery / ▪ Compact / ▤ List): defaults to gallery.
Persists in `localStorage`.

### Format coverage

| Format | Read metadata | Cover thumbnail | In-browser reader | Edit metadata in file |
|---|---|---|---|---|
| EPUB | yes (OPF) | yes | yes (foliate-js) | yes |
| MOBI | yes (libmobi) | yes | yes (foliate-js) | via CLI `set-meta` (mobimeta) |
| AZW3 | yes (libmobi) | yes | yes (foliate-js) | via CLI `set-meta` (mobimeta) |
| PDF  | yes (PDF info dict) | yes (first page) | yes (pdf.js) | no (catalog row only) |
| CBZ  | yes (ComicInfo.xml) | yes (first image) | yes (foliate-js) | no (catalog row only) |
| CBR  | yes (ComicInfo.xml via `7zz`) | yes (via `7zz`) | open externally | no |
| CB7  | yes (ComicInfo.xml via `7zz`) | yes (via `7zz`) | open externally | no |
| CBT  | yes (ComicInfo.xml via `7zz`) | yes (via `7zz`) | open externally | no |

CBR/CB7/CBT require `sevenzip` on `PATH` (`brew install sevenzip` on
macOS, `apt install p7zip-full` on Linux). The UI surfaces a one-time
install hint when comic archives are in the catalog but the binary is
missing.

**Search** filters the visible books live by title or author substring.

**Detail panel** slides in from the right when you click a card. It
shows the cover from `/api/books/:id/cover`, all populated metadata
fields, and per-book actions:

- **Read** — in-browser reader overlay. Works for every readable
  format: **EPUB / MOBI / AZW3 / FB2 / CBZ** are rendered by
  [foliate-js](https://github.com/johnfactotum/foliate-js) (no
  server-side conversion); **PDF** is rendered by
  [pdf.js](https://mozilla.github.io/pdf.js/). Both libraries are
  lazy-imported from a CDN the first time you click Read. `Esc`
  closes, `←`/`→` or `Space` / `PageDown` step pages. The button
  label becomes **Resume (NN%)** whenever a saved reading position
  exists for the book — clicking lands you on the same page.
- **Convert to EPUB + open** *(MOBI/AZW3, in the overflow ⋮ menu)* —
  legacy path. Triggers a libmobi-side conversion to EPUB, picks up
  the new file from the catalog, and opens it in the reader. Mostly
  for "I want the .epub on disk" workflows; the Read button itself
  no longer needs this for in-browser reading.
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
  and POSTs to `/api/books/:id/cover`. Works for every format: the
  bytes are stored as a library-side override at
  `$XDG_DATA_HOME/mediastacks/covers/<id>.<jpg|png>` and served wherever a
  `/cover` URL appears (gallery thumb, detail panel, alt-cover
  lightbox). For **EPUB** the cover is *also* written back into the
  book file (so it travels with the file). For **MOBI/AZW3/PDF** the
  source file is left untouched — libmobi has no cover-write API — and
  the detail panel surfaces a "cover override · file unchanged" badge.
- **Cover discovery is paginated.** Fetch info returns only **3** alt
  covers up front so the strip stays one tidy row. A **Show more
  covers** button below the strip pages through the OpenLibrary
  editions list in batches of 6 (walking up to 75 editions per click).
  Each batch renders shimmer-placeholder thumbs immediately and swaps
  them for real `<img>` as the response lands. Clicking **Use this as
  cover** on the preview lightbox aborts any in-flight pagination via
  fetch AbortController — already-rendered thumbnails are kept.
- **Convert + apply** *(MOBI/AZW3 with an active override)* — converts
  the source to EPUB and bakes the override cover into the resulting
  file. Available alongside Change cover when the row has a saved
  override. The original `.mobi` stays in the catalog; `mediastacks
  dedup` cleans it up later if you want.
- **Reset to embedded** — discards manual edits and Open Library
  enrichments by re-reading the file's embedded OPF / MOBI metadata
  and overwriting the catalog row. Also deletes any library-side cover
  override, so the next `/cover` request falls back to the embedded
  cover.
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

### Reading position

Every page turn updates a per-book row in the `read_locations` table
(opaque CFI for foliate; page number for pdf.js) via a debounced
`PUT /api/books/:id/location` (800 ms). Closing the reader flushes
the latest position synchronously. Subsequent opens fetch the saved
position and `goTo` it before the first paint.

The **Resume (NN%)** label on the Read button, and the thin accent
bar across the bottom of the gallery cover, both read from
`b.read_percent` (mirrored onto the standard book JSON via a
correlated subquery — no extra request per card). To clear a saved
position, use **Start over** in the overflow ⋮ menu.

### Adding books from the UI

Three entry points all open the same **Add books from your folders**
modal:

- the **Add books** pill in the top-right stats row,
- the **Add books from a folder…** button in the sidebar's *Library
  tools* group, and
- the ⌘K command palette (`Add books from a folder`).

Inside the modal, **Browse…** triggers the native macOS folder picker
(`osascript`); paste-a-path falls back on every platform. **Add**
registers the folder, kicks off a background recursive scan that
ingests every supported format (EPUB / MOBI / AZW3 / PDF / CBZ / CBR /
CB7 / CBT), and remembers the location so subsequent rescans pick up
changes. **Rescan all** loops every tracked source.

### Command palette (⌘K)

`⌘K` (macOS) / `Ctrl+K` (Linux) opens a flat, fuzzy-filtered command
list: switch views, sort, focus search, start the batch-enrich job,
open the sources modal, add books, manage scheduled jobs,
import/export the library. Arrow keys navigate, **Enter** runs,
**Esc** dismisses.

### Search

The search box accepts free text plus `key:value` tokens (see the
placeholder for the syntax). Free-text matches are re-ranked
client-side: **title hits beat author hits beat series hits beat
description hits**, and earlier positions beat later ones.
Case-insensitive throughout; an exact whole-string match gets a
hefty bonus and starts-with gets a smaller one.

Recent committed search strings are remembered in `localStorage`
(last 10). When the input is focused and empty, a dropdown shows
them — click to re-run. **Clear** wipes the history.

Token-only searches (`author:hobb year:2010-2020`) keep the server's
ordering since the user already named what they want; re-ranking
only kicks in when there's free text.

### Sidebar facets

Every facet group (Library, Status, Has, Format, Authors, Series,
Genres, Tags) is a `<details>` element. Default state is closed for
compactness; per-section open/closed state is remembered in
`localStorage` (`mediastacks.facet.<key>`).

The Library section's collapsed summary shows the at-a-glance
"N folders · M books" so the user stays oriented without expanding.
The tracked-folders list inside the section is capped at 200px with
internal scrolling — 20+ folders won't push other facets below the
fold.

### Scheduled jobs

The Library card's **Scheduled jobs…** link (also reachable via
⌘K → "Scheduled maintenance jobs") opens a modal that lists every
job from the catalog's `scheduled_jobs` table and lets you add new
ones via a small form (name + type + spec dropdown).

Each row exposes inline **Run now** (fires synchronously through
`POST /api/jobs/:id/run` regardless of next-run time), an
enable/disable toggle, and a delete button.

Specs supported: `@hourly`, `@daily`, `@weekly`, `@monthly`, plus
`every Nm` / `every Nh`. Job types: `rescan-all`, `enrich-missing`,
`backfill-paths`, `standardize-dry`. See
[`COMMANDS.md`](./COMMANDS.md#mediastacks-schedule-sub) for full
semantics.

The in-process scheduler runs whenever `mediastacks serve` is running.
For always-on scheduling without the HTTP server, run
`mediastacks schedule daemon` separately.

### Comic reader (CBZ/CBR/CB7/CBT)

Server unpacks each requested page on demand from the source
archive — no client-side ZIP parsing, no full-comic download. Each
page is fetched only when displayed, with an opportunistic prefetch
of the next so forward navigation feels instant.

Toolbar in the top-right toggles **RTL** (right-to-left page
progression for manga) and **Spread** (two-page facing layout).
Per-book preferences persist in `localStorage`.

J/K + arrow keys + space step pages. Click-zones on the left/right
halves of the stage page back/forward (RTL flips the mapping).
Reading position is saved to the same `read_locations` table foliate
and pdf.js use; the page number is stored as a decimal string in
`location`.

### Reader libraries

- **foliate-js** for EPUB / MOBI / AZW3 / FB2 / CBZ — native
  in-browser rendering of every common ebook format. Loaded via
  `https://esm.sh/gh/johnfactotum/foliate-js/view.js?bundle` on first
  use.
- **pdf.js** for PDFs — Cloudflare CDN, version pinned. Worker URL
  always tracks the lib URL (the classic pdf.js gotcha when they
  drift).

Both libraries fetch their book bytes from `/api/books/:id/file` so
any catalogued file works without preprocessing. If the CDN is
unreachable (or the book file is corrupt), the overlay shows a
visible "Couldn't open this book" error instead of staying blank —
the previous behaviour, which made `Read` feel broken when something
went wrong.

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
| `GET` | `/api/books/:id/covers?work_key=&offset=&limit=&seen=` | `{urls, next_offset, exhausted}` — next batch of alt-cover URLs walked from OpenLibrary editions; cancellable client-side via fetch AbortController |
| `GET` | `/api/books/:id/location` | `{location, percent, updated_at}` or `null` |
| `GET` | `/api/sources` | `[{id, path, name, last_scanned_at, ...}, ...]` — tracked library folders |
| `GET` | `/api/sevenzip-status` | `{available: bool, binary: "7zz" \| "7z" \| null}` — drives the install-hint banner |
| `GET` | `/api/library-stats` | rolled-up counts (totals, by format, triage queue size, …) |
| `GET` | `/api/standardize` | preview of the canonical-rename plan (the **Rename** lens) |
| `GET` | `/api/tags` | `[{id, name, count}, ...]` — every tag in the catalog |
| `POST` | `/api/pick-folder` | (macOS) pops the native folder picker, returns `{ok, path}` |
| `POST` | `/api/sources` | `{path, name?}` — register a folder and kick off a background scan |
| `POST` | `/api/sources/:id/rescan` | re-walk one source |
| `POST` | `/api/enrich/batch` | start / poll the singleton batch-enrich job |
| `POST` | `/api/derive-paths` | backfill series / index from every book's filename |
| `GET` | `/api/jobs` | `[{id, name, spec, job_type, enabled, last_run_*, next_run_at}, ...]` — every scheduled maintenance job |
| `POST` | `/api/jobs` | `{name, spec, job_type, enabled?}` — create. Returns the new job |
| `PATCH` | `/api/jobs/:id` | `{enabled?: bool}` — toggle |
| `DELETE` | `/api/jobs/:id` | `{ok: true}` |
| `POST` | `/api/jobs/:id/run` | fire NOW (synchronous, ignores schedule). Returns `{ok, job}` or `{ok: false, reason}` when another job is already running |
| `GET` | `/api/books/:id/comic-pages` | `{count: N, format: "cbz"\|"cbr"\|"cb7"\|"cbt"}` — page count for the comic reader |
| `GET` | `/api/books/:id/comic-page/:n` | Image bytes for the Nth page (content-type sniffed). Year-long immutable cache. |
| `GET` | `/api/export?format=json\|csv` | Download the catalog. Sets `content-disposition: attachment; filename="mediastacks-library-YYYY-MM-DD.{json\|csv}"` |
| `POST` | `/api/import` | `[{path, title?, author?, ...}, ...]` — merge metadata into matching catalog rows by path. Returns `{matched, updated, skipped, errors}` |

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
| `POST` | `/api/books/:id/cover` | `{data_base64}` **or** `{url}` | Writes a library-side override at `$XDG_DATA_HOME/mediastacks/covers/<id>.<ext>` so the cover is rendered everywhere `/cover` is used. For EPUB the OPF-declared cover-image entry is also rewritten in place. For MOBI/AZW3/PDF the source file is left untouched (libmobi has no cover-write API). With `{url}` the server fetches the image (used for Open Library alt covers, avoids browser CORS dance). Response: `{ok: true, override: true, file_updated: bool}`. |
| `POST` | `/api/books/:id/reset` | (empty) | Re-reads embedded metadata; discards manual edits and enrichments. Returns the refreshed book. |
| `DELETE` | `/api/books/:id[?file=1]` | (empty) | Removes catalog row. With `?file=1`, also unlinks the file. |
| `PATCH` | `/api/books/:id/status` | `{status: "unread"\|"reading"\|"finished"}` | Sets reading state; stamps `started_at` / `finished_at`. Returns the updated book. |
| `PUT` | `/api/books/:id/location` | `{location, percent?}` | Upsert the reading position. `location` is an opaque string (EPUB CFI for foliate; decimal page-number for pdf.js); `percent` is `0.0`–`1.0`. Returns `{ok: true}`. |
| `DELETE` | `/api/books/:id/location` | (empty) | Drop the saved position (powers the **Start over** overflow item). |
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
  "source": "embedded",
  "has_cover_override": true,
  "read_percent": 0.37,
  "last_read_at": 1747066800
}
```

All metadata fields are optional and omitted when missing — the
frontend treats absent keys as "unknown" and adjusts its layout.
`has_cover_override` is omitted (rather than `false`) when no override
file exists, so the absence of the key means "no override".

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

- **Detached-thread per request.** The acceptor loop spawns a fresh
  thread for each incoming connection, so a slow Open Library enrich
  doesn't block subsequent requests. The catalog is opened in SQLite's
  serialized threading mode and protected by a single connection mutex.
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
mediastacks server's origin (it's same-origin from `127.0.0.1`).

The reader uses **foliate-js** (loaded from esm.sh via the
johnfactotum/foliate-js GitHub mirror) for EPUB / MOBI / AZW3 / FB2 /
CBZ, and **pdf.js** (Cloudflare CDN) for PDFs. Both are lazy-imported
on the first **Read** click — the gallery view pays no network cost
until then.

## Known limitations

- **Reader libraries are CDN-loaded.** foliate-js (via esm.sh) and
  pdf.js (via cdnjs) are imported on first Read click. The mediastacks
  binary embeds no reader code; an offline machine can't open books
  in the browser until the libraries are cached. Mitigation: open at
  least one book of each format while online, after which the browser
  cache serves them.
- **In-file cover edits are EPUB-only.** MOBI/AZW3/PDF cover edits are
  served via a library-side override (see Change cover) — they are not
  written back into the book file because libmobi has no cover-write
  API. The override is rendered uniformly across the UI, and a
  "Convert + apply" button bakes it into a fresh EPUB when you want
  the change to live in the file itself.
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
- **Thread-per-request, not pooled.** A pathological burst (hundreds
  of parallel sockets) will spawn that many short-lived threads. For a
  personal localhost tool that's fine; for anything else, swap the
  detached-thread `Thread.spawn` for a fixed-size worker pool.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Page is empty, server logs `GET /api/books` | catalog has no books | `mediastacks scan DIR` first |
| Cover image broken | book has no embedded cover, or `mobitool` missing for MOBI/AZW3 | `brew install libmobi` |
| Reader stuck on "loading…" | non-EPUB book selected, or epub.js failed to fetch | open browser devtools and check the network tab |
| `listening on …` then immediate exit | port already in use | `--port` to a different one |
