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

## Phase 1.5 — richer, still-shared metadata (next)

Brainstorm → spec → plan before building (like Phase 1).

- [ ] **ffprobe-backed enrichment (opt-in, offline).** Read real
      resolution/codec/bitrate/duration/audio+sub tracks from the file.
      - Feeds `mediascore` (true quality beats filename-guessed `1080p`).
      - Flags corrupt / mislabeled files (won't probe, or duration wildly off).
      - Prefer embedded library tags when present (MP4/M4V `show`/`season_number`/
        `episode_id`; Matroska `TITLE`/`SEASON`/`EPISODE`) over filename guesses.
      - Shared: add optional `probe` fields to the parsed item; `ffprobe` is an
        optional dependency, gracefully skipped when absent.
- [ ] **Naming presets** — `tv_template = jellyfin|plex|kodi|<custom>` in config,
      resolved to a template string. Keep the raw `{…}` template as the
      lowest-common-denominator; presets are just named strings.
- [ ] **DRM *detection* (flag, don't remove).** Per kind: MP4 FairPlay
      (`sinf`/`drms`), CENC (Widevine/PlayReady), Matroska `ContentEncryption`;
      ebooks (biblio) ADEPT `encryption.xml` / `.acsm` / Kindle DRM. Label the
      item "DRM — skipped", organize the file as-is, never try to read its media.
      **Removal is out of scope** (circumvention; legal + policy line).
- [ ] Optional `--clean-tags` lossless remux (`ffmpeg -map 0 -c copy
      -map_metadata -1`) to strip leaking release/site tags. Opt-in only.

---

## Phase 2 — more kinds (same shared engine)

- [ ] `kinds/game.zig` — multi-disc / multi-file installs, region/version tags,
      platform folders.
- [ ] `kinds/document.zig` — loose PDFs/papers/manuals beyond biblio's ebooks.
- [ ] Confirm each new kind needs *only* a parser + template (no core changes).

## Phase 3 — review surfaces over the Plan JSON

- [ ] TUI review screen: load a `Plan` (`--from`), edit groupings/titles, toggle
      items, apply. Editor over the same JSON — no bypassing the contract.
- [ ] Web review page (in `biblio serve` or a shared server): same, with
      thumbnails/posters and drag-to-regroup.

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
