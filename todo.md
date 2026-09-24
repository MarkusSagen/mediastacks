# mediastacks — roadmap & follow-ups

## Recently done (2026-08-23)

- [x] **Text normalization** — `core/textnorm.zig` (pure): folds apostrophe/quote
      lookalikes (`´` `` ` `` `'` `"` → ASCII), repairs mojibake (`Ã©`→`é`,
      cp1252 `â€™`→`'`), decodes HTML entities, strips zero-width/control chars,
      collapses whitespace. Wired at parse (`music.fromTags`, `tv.parse`,
      `movie.parse`, `cleanAlbumFolder`) → flows to grouping keys, filenames,
      tags, NFO. Always-on.
- [x] **Embedded cover art + player compat** — `music_tags` embeds the album
      cover (FLAC `PICTURE`, MP3 `APIC`) on `--write-tags`, so Apple Music /
      Sonos / Samsung / Sony show art; external `cover.jpg` + NFO still written.
      `plan.Item.cover_src` stamped on music primaries; `apply` reads bytes+mime.
      `tag-smoke.sh` verifies embedded art via ffprobe.

## Audiobooks (in progress)

- [x] **Audiobook kind** (done 2026-08-23). `MediaKind.audiobook` + own
      `Audiobooks/` root; conservative detection (`.m4b` by ext; audiobook
      keyword in path; genre Audiobook/Speech/Spoken — genre added to music
      tags). Grouped by source folder; author = consensus album_artist/artist,
      book = album tag or folder name. Configurable `audiobook_template`
      (default `Audiobooks/{author_sort}/{album}/{track:02} - {title}.{ext}`;
      author last-name-first via `naming.authorSort`); single .m4b collapses to
      `{book}.{ext}`. Embedded cover + tag write-back + external cover.jpg reused.
      Verified on the real LOTR audiobook → `Audiobooks/Tolkien, J.R.R/…`
      (was misfiled as music — A.1 gap resolved).
- [x] **m4b creation** (done 2026-08-23) — `medias makem4b DIR [--to LIB]
      [--out FILE] [--bitrate B]` (its own subcommand, keeps `apply` io-free):
      `kinds/audiobook.zig` probes each chapter's duration, builds an ffmetadata
      `[CHAPTER]` list + concat list, runs ffmpeg (AAC, embedded cover, chapters)
      → one `{book}.m4b` in `Audiobooks/{author_sort}/{book}/`. Sources kept; the
      new file is journaled (`.create`) so `medias undo` removes it.
      `scripts/m4b-smoke.sh` (7 checks, real ffmpeg).

## Comics (done 2026-08-23)

- [x] **Comic kind** — `kinds/comic.zig` parses series/issue/volume/year
      (Komga/Jellyfin style: "Saga #12 (2018)", "Batman v2 001", "v01"…) →
      `Comics/{series}/{series} #NNN (year).{ext}` (configurable `comic_template`;
      `{number}` = `#012`/`Vol.01`). Grouped by series; cbz/cbr/cb7/cbt.
- [x] **ComicInfo.xml embed** — on organize (default, gated by `write_nfo`),
      **cbz** archives are repacked (miniz ZipReader→ZipWriter) with a fresh
      `ComicInfo.xml` (Series/Number/Volume/Year); backed up + journaled
      (`.tagwrite`) so `medias undo` restores the pre-embed archive. cbr/cb7
      skipped (can't rewrite without external tools). `comicinfo-smoke.sh`.

## Web UI — medias app (biblio-styled, separate app)

- [x] **Slice 1 — shell + Organize** (done 2026-08-23). `medias serve` →
      `web/app.zig` server + `web/assets/medias.{html,js,css}` (biblio design
      tokens: warm-paper default + graphite toggle, Inter/JetBrains-Mono, tabs,
      cards, kind badges). Organize view: enter a folder → `/api/organize` builds
      the Plan → grouped-by-kind cards w/ covers/thumbs + keep/skip/trash +
      inline retitle (reuses `/api/edit`,`/api/apply`,`/api/thumb`) → Apply with
      write-tags/nfo toggles. `scripts/app-smoke.sh` (7 checks, headless HTTP).
- [x] Slice 2 — Library browse (done 2026-08-23). `/api/library` scans
      `library_root` per kind (depth-1 Movies/Shows/Comics; depth-2 Music/
      Audiobooks) → items with cover + media count; `/api/cover` serves images
      (path-allowlisted to the library root). Library tab: gallery grid of cards
      (cover/title/subtitle/count), lazy covers, Rescan button. app-smoke +3.
- [x] Slice 3 — Undo history (done 2026-08-23). `/api/undo/list` enumerates
      journals (id/created/moved/trashed/wrote, newest first); `/api/undo/revert
      ?id=` reverts via `apply.undo` then renames the journal `.undone`. Undo tab:
      row per run (timestamp + summary + Revert). Fixed a server panic on empty
      POST bodies (consume body before `respond`). app-smoke +3.
- [x] Slice 4 — Settings editor (done 2026-08-23). GET `/api/config` returns all
      editable fields; POST merges into `config.toml` preserving comments/custom
      keys/templates (`config.save`), then reloads `base_cfg` so the next Preview
      uses it. Settings tab: text inputs + toggles + Save. app-smoke +2.
      TODO(deferred): online-enrichment toggle in the Organize view (app.zig still
      passes `Online{}` — offline-only).

## Next: language/subtitle policy + remux

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
- One command surface: `medias organize DIR [--dry-run] …` works for every
  kind. Resist per-kind subcommands unless a kind genuinely can't fit.
- When two kinds want the same thing (e.g. "best copy", "trash junk",
  "sidecars"), lift it into `core/`, don't copy it.

---

## Done — Phase 1 (TV + Movies)

- [x] Shared engine: `kind`, `classify`, `group`, `plan`, `config`, `journal`,
      `apply`; parsers `kinds/tv`, `kinds/movie`; `mediascore`.
- [x] `medias organize DIR` (applies by default) + `--dry-run/-n` + `medias undo`.
- [x] Move-into-library, trash-not-delete, reversible undo journal.
- [x] Readable plan output (sorted, folder-grouped, keep-vs-discard).
- [x] Junk detection incl. torrent-site promo litter.
- [x] Jellyfin naming as the default (`Shows/…`, `Movies/…`).
- [x] Rename to `mediastacks` (lib) + `biblio` (books) + `medias` (organizer).
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
      `META-INF/encryption.xml` (ADEPT) / `.acsm`. medias flags protected
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

DECISION (2026-08-10): **each media kind = its own top-level library folder,
independently configurable — NOT nested under one shared `Books/` tree.** Matches
how Jellyfin libraries are set up (one library per content type → its own folder)
and reflects that these are genuinely different media (sizes/formats/metadata).
Target roots: `Movies/ Shows/ Music/ Books/`(ebooks)` Audiobooks/ Comics/ Games/
Documents/`. **Audiobooks go through the audio pipeline** (embedded tags, chapters,
transcripts — kin to music/podcasts), NOT lumped with ebooks. Config gains
**per-kind library roots** (today it has per-kind templates only).

- [ ] Per-kind library roots in config (each kind → own root + template).
- [ ] `kinds/game.zig` — multi-disc / multi-file installs, region/version tags,
      platform folders → `Games/`.
- [ ] `kinds/document.zig` — loose PDFs/papers/manuals → `Documents/`; ebooks →
      `Books/`, comics → `Comics/` (cbz/cbr, `ComicInfo.xml`), each own root.
- [ ] `kinds/audiobook.zig` — audio pipeline (chapters, `.m4b`, transcripts) →
      `Audiobooks/`; resolves the A.1 "audiobook misclassified as music" gap.
- [ ] Books/comics `.opf` / `ComicInfo.xml` sidecars (Jellyfin Bookshelf).
- [ ] Confirm each new kind needs *only* a parser + template + root (no core changes).

## Music epic (incremental A→B→C)

- [x] **A — read tags + organize album library.** `kinds/music.zig`
      (ffprobe tags → Track, multi-artist split into a list); classify audio →
      `.music`; album = `Group` keyed by (album-artist, album); layout
      `Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}`
      (`music_template` preset); `audioScore` dedup; album cover as a
      sidecar. Read-only, through `organize`/`review`. music-smoke.
- [x] **A.1 — real-world hardening** (done 2026-08-09):
  - [x] **Multi-disc sets** — music grouped by source folder; `CD N`/`Disc N`
        subfolders (or a `disc` tag) roll up into one album; layout gains a
        `CD{disc}/` segment so track numbers never collide.
  - [x] **Empty/zero year** — template drops the ` ()` suffix (also helps movies).
  - [x] **Various-Artists inference** — consensus album-artist; differing
        artists with no `album_artist` → "Various Artists" (no artists at all →
        "Unknown Artist").
  - [x] **Latin-1 / non-UTF-8 tags** — `music.toUtf8` transcodes raw Latin-1
        tag bytes to UTF-8; when ffprobe has already substituted U+FFFD (data
        lost), the **album** name falls back to the cleaned source folder
        (`music.cleanAlbumFolder`, strips leading year + `<artist> -`). Remaining
        gap: mojibake **track titles** (U+FFFD in the title tag) — would need
        release-style filename parsing to recover; deferred.
  - [ ] **Audiobooks misclassified as music** (`.mp3` chapters) — still
        deferred to the audiobook kind (long duration, chapter naming, `.m4b`).
- [x] **B — MusicBrainz enrichment** (done 2026-08-10). `providers/musicbrainz.zig`
      (search release by album+artist+track-count → detail with recordings +
      artist-credits; canonical title/year, per-track titles + multi-artist,
      release/recording MBIDs). `util/httpcache.zig` disk cache + 1 req/sec
      throttle. Pure `enrich.mergeMusic` (fill-missing, keep tag-authoritative,
      warn on difference). Config `musicbrainz = on` (default off) +
      `musicbrainz_contact`; `--offline` bypass. Cover URL recorded (download
      deferred). Unit-tested with `http.MockClient`; live check `just mb-smoke`
      (`MB_SMOKE=1`). Enrichment also recovers mojibake album/title tags that
      ffprobe lost offline.
- [x] **C — tag write-back (the multi-artist fix)** (done 2026-08-10).
      `kinds/music_tags.zig` native writers: FLAC (multiple `ARTIST=` Vorbis
      comments) + MP3 (ID3v2.4 `TPE1` null-separated multi-value), plus album/
      album-artist/title/year/track/disc + MusicBrainz IDs. Pure byte assembly
      (`buildId3v24`/`buildFlac`/`buildMp3`), `writeTags` = temp file + atomic
      rename (never in place). Opt-in: `--write-tags`/`--no-write-tags` or config
      `write_tags = on` (default off). `apply` backs up each file to
      `$XDG_DATA_HOME/mediastacks/backup/<ts>/` + journals a `tagwrite` entry; `medias
      undo` restores the original bytes. Unit round-trip tests + `scripts/tag-smoke.sh`
      (real ffmpeg: multi-artist confirmed, byte-identical undo).
      Deferred: cover-art embedding (APIC / FLAC PICTURE), formats beyond FLAC/MP3
      (`.m4a` skipped w/ warning), a web "write tags" checkbox (config-driven for now).

## Phase 3 — review surfaces over the Plan JSON

- [x] **Web review (Phase 3a).** `medias review DIR` serves a local page
      (`web/review.zig`, server-authoritative session): render grouped plan,
      keep/skip/trash, inline retitle (live path recompute), drag-to-regroup,
      ffmpeg posters (`/api/thumb`), Apply (real move + journal). Shared
      `core/naming.dstFor` + `Plan.Item.fields`. `just review`, review-smoke.
- [ ] **TUI review (Phase 3b).** Same edit-op model over the Plan in a
      libvaxis terminal UI (`tui/review.zig`) — load `--from`, edit, apply.

## Jellyfin-native library

- [x] **Jellyfin-native library** (done 2026-08-10). `core/extras.zig` recognizers
      (extras subfolders + `-trailer`/`-behindthescenes`… suffixes; full image
      aliases; version/part labels). group.zig: extras → their Jellyfin subfolder
      (`behind the scenes/`, `trailers/`…) as `Role.extra`; full image-name set
      on output (`poster/backdrop/logo/thumb/banner`, music stays `cover.jpg`,
      numbered backdrops); **size-aware sample trashing** (tiny promo → junk,
      real sample → extra). `Fields.edition/part` → `Movie (Year) - 1080p.mkv` /
      `-cd2.mkv`. `apply` drops a Jellyfin **`.ignore`** in `.mediastacks-trash/`
      (config `emit_ignore`, default on), journaled + undoable via `Action.create`.
- [x] **NFO sidecar writing** (done 2026-08-10). `core/nfo.zig` pure builders
      (movie/episode/tvshow/season/album/artist) with title/year/language +
      provider IDs (`<tmdbid>`+`<uniqueid>`), XML-escaped. `apply` writes them per
      primary + once per series/season/album/artist container (derived from item
      + group kind), journaled `Action.create` (undo unlinks); on-conflict-skip
      respects a user's existing NFO. Config `write_nfo` (default on) + `--nfo`/
      `--no-nfo`. `scripts/nfo-smoke.sh`. Books `.opf`/`ComicInfo.xml` → Phase 2.

## Phase 4 — online enrichment (opt-in)

- [x] **TMDB (movies + TV)** (done 2026-08-10). `providers/tmdb.zig`
      (search+detail+episode, external_ids → tmdb/imdb/tvdb ids +
      original_language; memoizing `Enricher`). Pure `enrich.mergeMovieOnline`/
      `mergeTvOnline`. `group.Online{music,video}` bundle. Jellyfin **ID suffixes
      in folder + filename** via a `{id}` token + template ` []` collapse;
      `{series_year}` added (fills the long-missing series-folder year). Config
      `tmdb_key` (enables when set + not `--offline`) + `id_suffix` (default on).
      Unit-tested via `http.MockClient`; live `just tmdb-smoke` (TMDB_KEY).
      Captures `original_language` for the language/subtitle policy epic.
- [ ] TVDB / IGDB / OMDb providers — deferred (TMDB covers movies+TV; IGDB waits
      for the games kind).

---

## Polish / cosmetics (deferred from the rename)

- [ ] Rename the repo directory `mediastacks/` → `mediastacks/` and `lib/mediastacks_c/`.
- [ ] `biblio` per-command usage strings still print "mediastacks" (e.g.
      `biblio scan` → `usage: mediastacks scan …`). Sweep `src/commands/*.zig`.
- [ ] `docs/COMMANDS.md` / `WEB.md` / `TUI.md` still say "mediastacks".

## Known limitations / smaller improvements

- [ ] **Series-folder casing is walk-order dependent** — pick a canonical casing
      (e.g. prefer the Title-Cased variant) so output is deterministic.
- [ ] **Multi-episode files** (`S01E01-E02`) — parse a range; Jellyfin supports it.
- [ ] **Empty wrapper dirs** (e.g. `www.UIndex.org - …/`) are left behind after
      their contents move; optionally remove now-empty source dirs.
- [ ] **Series year** unknown offline → series folder has no `(Year)`; fine until
      Phase 4 adds lookup.
