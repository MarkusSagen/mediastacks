# Terminal UI

The TUI is an in-terminal browser-and-reader for your library. It runs
against the same catalog as the CLI and the web UI, so anything you've
scanned/enriched/renamed shows up here.

Built on [libvaxis 0.6](https://github.com/rockorager/libvaxis) over
Zig 0.16's `std.Io`.

## Run it

```sh
booktool tui
```

The TUI takes over the terminal until you quit. Requires a real TTY —
piping input or running under `script(1)` with a tiny pty won't work
(libvaxis spawns an input thread that reads `/dev/tty` directly).

Works in Kitty, WezTerm, Ghostty, iTerm2, Alacritty, foot, and any
xterm-compatible emulator. Best experience on a terminal at least
80×24.

If the catalog is empty, the TUI prints a hint and exits — run
`booktool scan DIR` first.

## Two views

### List view

The library, one book per row. Each row shows author (clipped to 24
cols), title, and a format badge.

```
 booktool — j/k move · enter open · q quit

 ▶ Gaiman, Neil            Don't Panic                       epub
   Hobb, Robin             Assassin's Apprentice             mobi
   Hobb, Robin             Royal Assassin                    mobi
   Lee, Fonda              Jade City                         mobi
   McCarthy, Cormac        Blood Meridian                    epub
   Williams, John          Augustus                          epub

 1/12
```

| Key | Action |
|---|---|
| `j`, `↓` | move down |
| `k`, `↑` | move up |
| `g` | jump to top |
| `G` | jump to bottom |
| `enter` | open the selected book in the reader |
| `q`, `Esc` | quit |
| `Ctrl-C` | quit (works in any view) |

The cursor row stays in view automatically — scrolling tracks the
selection.

The status bar at the bottom shows `current/total` while you navigate,
and switches to a contextual message after some actions (e.g. "convert
this to EPUB first" for MOBI selections).

### Reader view

Plaintext rendering of the selected EPUB, paginated to the terminal
height and centered to 76 columns for comfortable line lengths.

```
 Augustus — space/← → page · q back

                The wind moved over the gardens. The dust rose.
                The senators waited in the colonnade. ...

 page 3/247
```

| Key | Action |
|---|---|
| `space`, `→`, `l`, `PgDn` | next page |
| `b`, `←`, `h`, `PgUp` | previous page |
| `q`, `Esc` | back to list view |
| `Ctrl-C` | quit booktool entirely |

The status bar shows `page n/m`.

Non-EPUB books print a message in the status bar and refuse to open —
run `booktool convert FILE --to epub` first if you want to read them
in the TUI.

## How EPUB rendering works

```
src/formats/epub_chapters.zig   open() → Book { title, author, chapters: [...] }
src/tui/reflow.zig              wrap()    plaintext → wrapped lines
src/tui/app.zig                 event loop + draw
```

### Chapter extraction

1. Open the EPUB as a ZIP archive (vendored miniz).
2. Read `META-INF/container.xml`, extract the OPF path.
3. Parse the OPF (libxml2 XPath), walk the `<spine>` to get the
   ordered list of `<itemref>` ids.
4. For each spine entry: resolve to its manifest `href`, extract the
   chapter XHTML.
5. Strip the chapter to plaintext: drop tags, decode 14 common named
   entities (`&amp;`, `&mdash;`, etc.) plus numeric `&#nn;` /
   `&#xhh;`, collapse runs of whitespace.
6. Treat block-level tags (`p`, `div`, `h1..h6`, `li`, `blockquote`,
   `br`, `hr`) as paragraph breaks.
7. Discard near-empty chapters (cover pages, nav docs) — anything with
   under 20 non-whitespace bytes.

The result is a `Book` struct with all chapter bodies as Zig-owned
strings concatenated into one document.

### Reflow and pagination

`reflow.wrap(text, width)` does word-wrap to a target column width
(76 by default), hard-breaking tokens that exceed it. Paragraphs are
separated by blank lines. Pagination is a simple line-count split:
`page n` is `lines[n*height .. (n+1)*height]`.

### Rendering

`src/tui/app.zig` is a `vaxis.Loop(vaxis.Event)` over the standard
event union (`key_press`, `winsize`, ...). On every tick:

1. Get the next event (blocking).
2. Mutate `App` state (cursor, view, page index).
3. Clear the root window and redraw the current view.
4. `vx.render()` diffs against the previous frame and writes the
   minimal cell updates to the TTY.

State for a loaded book lives in a per-book `ArenaAllocator` so memory
doesn't grow as you open and close books.

## Architecture notes

- **No mouse support yet.** Library navigation is keyboard-only.
  Adding mouse is a few `vaxis.Event.mouse` branches if you want it.
- **No images.** The reader strips tags; inline images aren't
  rendered. Kitty graphics-protocol embedding via libvaxis's `Image`
  API is a planned iteration.
- **No bookmarks / progress.** Closing and reopening a book restarts
  on page 1. The catalog has no reading-progress column yet.
- **Single book at a time.** No multi-tab navigation; pressing `q`
  from the reader returns to the list.

## Known quirks

- **Terminal width below 20 cols** — the renderer refuses to draw and
  shows nothing. Resize your terminal.
- **Wide CJK / RTL** is supported by libvaxis's grapheme width logic,
  but the 76-col text column may not align ideally for those scripts.
  Tune the reader width in `src/tui/app.zig` (`text_col_width`).
- **Reader is XHTML-only.** Anything inside `<script>` or `<style>`
  blocks is dropped — there's no JavaScript engine in the terminal.
- **Resize while reading** re-renders on the next event, but the
  current page index doesn't recompute against the new line count
  until you flip the page. If something looks chopped, press `space`
  then `b` to reflow at the current location.

## Why these tradeoffs

The TUI is intended to be the *quick lookup + casual reading* surface
for the library. A full reading experience (annotations, search,
images, progress sync) is what the web UI's epub.js embed delivers.
The TUI deliberately picks a smaller scope: catalog browse + linear
plaintext reading + perfect keyboard discipline + zero browser
dependencies.

If you want it more featureful — bookmarks, search-within-book, inline
covers via Kitty graphics — those are clearly-shaped additions in
`src/tui/app.zig`. The chapter extraction (`epub_chapters.zig`) and
reflow (`reflow.zig`) are reusable as-is.
