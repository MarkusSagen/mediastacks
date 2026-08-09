# stacks — roadmap & follow-ups

## Guiding principle: one shared interface, kind-specific only where it must be

Keep **as much shared across media kinds as possible, for as long as it makes
sense.** The whole tool should feel like *one* clear, intuitive interface —
not a pile of per-type commands.

- The **`Plan`** (`core/plan.zig`) is the shared contract every kind and every
  surface (CLI, TUI, Web) speaks. Add fields to it before inventing a
  parallel structure.
- The pipeline is shared: `scan → classify → parse → group → plan → apply`.
  Only the **parse** step (and its templates) is allowed to be kind-specific;
  everything else stays generic.
- New media kinds plug in as a `kinds/<kind>.zig` parser + a template default —
  they must **not** need changes to `group`, `apply`, `journal`, `plan`, or the
  CLI.
- One command surface: `shelve organize DIR [--dry-run] …` works for every
  kind. Resist per-kind subcommands unless a kind genuinely can't fit.
- When two kinds want the same thing (e.g. "best copy", "trash junk",
  "sidecars"), lift it into `core/`, don't copy it.

---

## Done — Phase 1 (TV + Movies)

- [x] Shared engine: `kind`, `classify`, `group`, `plan`, `config`, `journal`,
      `apply`; parsers `kinds/tv`, `kinds/movie`; `mediascore`.
- [x] `shelve organize DIR` (applies by default) + `--dry-run/-n` + `shelve undo`.
- [x] Move-into-library, trash-not-delete, reversible undo journal.
- [x] Readable plan output (sorted, folder-grouped, keep-vs-discard).
- [x] Junk detection incl. torrent-site promo litter.
- [x] Jellyfin naming as the default (`Shows/…`, `Movies/…`).
- [x] Rename to `stacks` (lib) + `biblio` (books) + `shelve` (organizer).
- [x] justfile recipes + zsh/bash completions.

---

## Phase 1.5 — richer, still-shared metadata

- [x] **ffprobe-backed enrichment (auto-on when installed, `--no-probe`).**
      Real resolution/codec/bitrate/duration from the file. Feeds
      `mediascore.videoScoreProbed` (true quality beats filename `1080p`);
      confidence-based fill/override of embedded tags (iTunes MP4
      `show`/`season_number`/`episode_sort` authoritative, generic tags fill);
      mislabel/corrupt/short-runtime warnings; media info shown in the plan
      (`· h264 1080p · 23m`). `core/probe.zig` + `core/enrich.zig` (both pure-
      testable), `plan.Item.media`. `ffprobe` optional, gracefully absent.
- [x] **Naming presets** — config-only `preset` / `tv_preset` / `movie_preset`
      (jellyfin default; plex/kodi built-in), resolved to template strings;
      explicit `tv_template`/`movie_template` win. Unknown preset → error.

- [x] **DRM detection (flag, don't remove).** Shared `core/drm.zig`: MP4
      box sniff (`pssh`→CENC, `sinf`/`drms`/`encv`/`enca`→FairPlay) + epub
      `META-INF/encryption.xml` (ADEPT) / `.acsm`. shelve flags protected
      videos (`DRM — <scheme>` warning, organized by filename, no probe);
      biblio reports in `info` + `scan` (`drm=N`). Detectors are total
      (odd input → none). **Removal stays out of scope.**
      Deferred: Matroska `ContentEncryption` (rare), Kindle KFX/AZW DRM.

Still open (own future specs):
- [ ] **Write-back / remux — DEFERRED (needs its own safety spec).** Embed
      corrected tags, strip leaking release/site tags (`ffmpeg -map 0 -c copy
      -map_metadata -1`), mux subtitles into the container. In-place file
      rewrite is riskier than a move — design before building.

---

## Phase 2 — more kinds — DEFERRED (do later)

- [ ] `kinds/game.zig` — multi-disc / multi-file installs, region/version tags,
      platform folders.
- [ ] `kinds/document.zig` — loose PDFs/papers/manuals beyond biblio's ebooks.
- [ ] Confirm each new kind needs *only* a parser + template (no core changes).

## Music epic (incremental A→B→C)

- [x] **A — read tags + organize album library.** `kinds/music.zig`
      (ffprobe tags → Track, multi-artist split into a list); classify audio →
      `.music`; album = `Group` keyed by (album-artist, album); layout
      `Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}`
      (`music_template` preset); `audioScore` dedup; album cover as a
      sidecar. Read-only, through `organize`/`review`. music-smoke.
- [ ] **B — MusicBrainz enrichment.** Fill missing/wrong album, year,
      canonical artist names, cover (needs the online-provider layer, Phase 4).
- [ ] **C — tag write-back (the multi-artist fix).** Write multi-value
      artist tags so a track lists under *each* artist; embed cover/album/year.
      Needs the file-mutation/write-back safety design.

## Phase 3 — review surfaces over the Plan JSON

- [x] **Web review (Phase 3a).** `shelve review DIR` serves a local page
      (`web/review.zig`, server-authoritative session): render grouped plan,
      keep/skip/trash, inline retitle (live path recompute), drag-to-regroup,
      ffmpeg posters (`/api/thumb`), Apply (real move + journal). Shared
      `core/naming.dstFor` + `Plan.Item.fields`. `just review`, review-smoke.
- [ ] **TUI review (Phase 3b).** Same edit-op model over the Plan in a
      libvaxis terminal UI (`tui/review.zig`) — load `--from`, edit, apply.

## Phase 4 — online enrichment (opt-in)

- [ ] Providers behind the existing `providers/` interface: TMDB/TVDB (video),
      IGDB (games). Canonical titles/years/episode names.
- [ ] Jellyfin/Plex ID suffixes once online: `Film (2009) [imdbid-tt…]`,
      `Series (2010) [tvdbid-…]` (needs a series year, which needs lookup).

---

## Polish / cosmetics (deferred from the rename)

- [ ] Rename the repo directory `booktool/` → `stacks/` and `lib/booktool_c/`.
- [ ] `biblio` per-command usage strings still print "booktool" (e.g.
      `biblio scan` → `usage: booktool scan …`). Sweep `src/commands/*.zig`.
- [ ] `docs/COMMANDS.md` / `WEB.md` / `TUI.md` still say "booktool".

## Known limitations / smaller improvements

- [ ] **Series-folder casing is walk-order dependent** — pick a canonical casing
      (e.g. prefer the Title-Cased variant) so output is deterministic.
- [ ] **Multi-episode files** (`S01E01-E02`) — parse a range; Jellyfin supports it.
- [ ] **Empty wrapper dirs** (e.g. `www.UIndex.org - …/`) are left behind after
      their contents move; optionally remove now-empty source dirs.
- [ ] **Series year** unknown offline → series folder has no `(Year)`; fine until
      Phase 4 adds lookup.
