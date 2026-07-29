# Mobile app architecture — design

Status: draft, awaiting review
Date: 2026-07-28
Topic: bringing booktool to iOS and Android with no separate server

## Overview

Ship booktool as a mobile app that runs entirely on the phone. No deployed server anywhere: the phone holds the whole library — catalog, books, and code — in a user-picked folder that may or may not be inside iCloud Drive / Google Drive / Syncthing. Everything the desktop web UI does is the *end-state* goal, but v1 ships one narrow slice: **"I can read my synced library on my phone."**

## Context

Today's booktool ships as a single Zig binary that exposes three surfaces:

- **CLI** — `booktool <subcommand>` operating directly on the SQLite catalog.
- **TUI** — vaxis-based, direct catalog access.
- **Web** — `booktool serve` runs an HTTP server + an SPA (~5500 LOC of vanilla JS/HTML/CSS) served from `@embedFile`-bundled assets. All library operations, format handlers, and the OpenLibrary enrichment path live in the same Zig module tree; the HTTP layer is the *only* thing specific to the web surface.

Cleanly separated already:

- `src/core/catalog.zig` — SQLite schema, queries, all catalog mutation.
- `src/formats/*` — per-format `FormatHandler` vtable (EPUB / MOBI / AZW3 / PDF / CBZ / CBR / CB7 / CBT).
- `src/providers/openlibrary.zig` — network-only path, takes an `HttpClient` (mockable).
- `src/util/http.zig` — `HttpClient` vtable with `RealHttpClient` (production) and `MockClient` (tests).
- `src/web/api.zig` — thin JSON handlers that mostly wrap `Catalog` methods.
- `src/web/server.zig` — HTTP transport (only this file is coupled to `std.http.Server`).

The library work is already portable in principle. What's missing is a mobile packaging strategy and the platform glue.

## Goals

1. **Zero external server.** Nothing runs off the device. No relay, no NAS, no VPS. Optional cloud file sync is the *user's* choice via where they point the app (iCloud Drive, Google Drive, Syncthing, or a plain local folder).
2. **Full feature parity with the web UI** as the end-state — everything `booktool serve` can do, the phone can do.
3. **Small, iterative v1.** Ship "read my synced library" first; earn triage / enrichment / conversion / write-metadata as later slices.
4. **Reuse the working SPA.** Do not throw away ~5500 lines of hand-tuned JS/HTML/CSS.
5. **One Zig source tree.** All targets (macOS/Linux CLI, `serve`, iOS, Android, and — eventually — WASM demo) compile from the same `src/`. Only `build.zig` and the outer platform shell differ per target.

## Non-goals

- Multi-device real-time sync protocol. Users who want it can already get 90 % via iCloud / Syncthing at the folder level; a bespoke sync engine is out of scope for at least v1 and v2.
- App-store monetization, IAP, subscriptions.
- Cloud storage of the catalog. The catalog file lives in the user's picked folder, period.
- A phone-native replacement for the web UI. The SPA is the phone's UI, wrapped in a native shell.

## v1 scope: "I can read my synced library"

**In v1:**

- Point the app at a folder (local, iCloud Drive, Google Drive, Syncthing).
- Load an existing catalog `<folder>/.booktool/catalog.db` from that folder — or create one on first launch and scan the folder for books.
- List the library, search, sort, filter by facet, open a book, read it.
- Foliate-js reader for EPUB / MOBI / AZW3 / FB2 / CBZ. pdf.js for PDF. Existing custom comic reader for CBZ.
- Reading position tracked in `read_locations` table (small writes).
- Read-status toggle from card and detail panel (small write).
- App backgrounds and foregrounds cleanly, flushes WAL on background.

**Deferred to later slices (not v1):**

- Enrichment (OpenLibrary fetches) — needs HTTPS/TLS on iOS, punt for now.
- Scheduled jobs — needs background execution rules on iOS, punt for now.
- Bulk operations (bulk edit, bulk enrich, bulk delete, bulk status).
- Metadata write-back to files (libmobi writes, EPUB OPF rewrites).
- Format conversion (calibre / kindlegen equivalents).
- Cover search / cover replace via provider.
- CBR / CB7 / CBT — requires 7zz subprocess which iOS forbids. See "risks".
- Stats dashboard.
- Triage flows.

**Not planned even long-term:**

- Cross-device sync protocol (see non-goals).
- Phone as a thin client to a desktop server (contradicts "no deployed server").
- Rewriting the SPA in Dart/Swift/Kotlin widgets (see framework decision).

## Framework decision — native shells + WebView

Evaluated four options for the mobile shell:

| | Native shells (Swift + Kotlin) | Flutter | Tauri 2.0 | Capacitor |
|---|---|---|---|---|
| Reuses the SPA verbatim | via WebView | only if Flutter WebView (defeats Flutter's benefit) | via WebView | designed for this |
| One codebase for both mobile shells | no (Swift + Kotlin) | yes (Dart) | yes (Rust) | yes (JS/TS) |
| Direct Zig FFI | yes | excellent (dart:ffi) | via Rust ↔ C | via plugins |
| New toolchain to learn | minimal | Dart + Flutter SDK + pubspec + version mgr | Rust + Cargo + Tauri | Node + npm + Capacitor CLI |
| Desktop story for later | none (add Tauri/Electron later) | good | good | wrapper-y |
| Mobile maturity | proven | proven | 2024-beta-ish on mobile | proven |
| App binary size | smallest | +~10 MB engine | small | web-app sized |

**Decision: native shells.**

Rationale:

- **Flutter's payoff — "write one UI for both platforms" — only materializes if we throw away the SPA and rewrite it in Dart widgets.** That's months of work reimplementing the ⌘K palette, multi-select gallery, search-history dropdown, comic reader, stats dashboard, etc. And it forks the code away from `booktool serve`, which desktop users still want.
- **Keeping the SPA inside Flutter's WebView gives us the entire Flutter toolchain for essentially no UI reuse.** Same WebView, same JS, +Dart, +Flutter SDK, +Flutter version manager. Net negative vs. ~300 lines of Swift + ~300 lines of Kotlin.
- **Tauri 2.0** mobile support is too new to bet a v1 on. Interesting as a *desktop* path later (replacing `booktool serve --browser` with a real native window).
- **Capacitor** is the closest competitor for our specific case. Passes for v1 to avoid pulling Node/npm into the project. Revisit only if the native shells balloon past ~500 LOC each.

**When we would revisit Flutter:** if we ever decide to *replace* the web UI with a native-widget experience on every platform (mobile + desktop). Not planned.

## Architecture

### Shared Zig core, platform-specific shells

```
┌─────────────────────────────────────────────────────────────┐
│ booktool source tree (single repo, single src/)             │
│   src/core/, src/formats/, src/web/, src/cli.zig, ...       │
└─────────────────────────────────────────────────────────────┘
            │              │             │              │
   ┌────────▼────┐ ┌───────▼─────┐ ┌─────▼─────┐ ┌──────▼─────┐
   │ Desktop CLI │ │ booktool    │ │ iOS app   │ │ Android    │
   │  + TUI      │ │ serve       │ │ (Swift +  │ │ (Kotlin +  │
   │             │ │ (desktop)   │ │  WKWebView│ │  WebView)  │
   └─────────────┘ └─────────────┘ └─────┬─────┘ └──────┬─────┘
                                          │              │
                                   ┌──────▼──────────────▼─────┐
                                   │ Same Zig core compiled    │
                                   │ as static lib:            │
                                   │ aarch64-ios /             │
                                   │ aarch64-linux-android     │
                                   └───────────────────────────┘
```

### Transport: custom URL scheme, not loopback HTTP

Rejected the initial loopback-HTTP idea in favor of a **custom URL scheme** (`booktool://`) intercepted by the native shell and routed to a C-ABI Zig entry point.

**Why:**

- Zero listening socket, no port to bind, no firewall edge cases on Android.
- No App Store reviewer question about a "server running inside the app."
- Zero HTTP framing overhead per request (~ms saved per fetch, matters for many small requests during gallery scroll).
- SPA change is a single base-URL rewrite (`<base href="booktool://app/">` in `index.html`) or a small `fetch` shim.

**Mechanics:**

- iOS: `WKURLSchemeHandler` on the `WKWebView`'s configuration. Every `booktool://` request lands in Swift, which forwards it to Zig via FFI, streams the response back into the WebView's URL-loading system.
- Android: `WebViewAssetLoader` + `WebViewClient.shouldInterceptRequest()`. Same shape.
- Zig HTTP handler logic in `src/web/api.zig` is not modified — only the transport above it changes. `web/server.zig` remains for the desktop `booktool serve` use case.

### Process model

Single process, single Zig static lib. No background thread in v1 (no scheduler).

- Launch → shell calls `booktool_open(folder_url)` → Zig opens SQLite in WAL mode, mounts the folder, initializes format handlers.
- Every WebView request → shell calls `booktool_handle_request(method, path, body)` → Zig returns response bytes → shell wraps in URLResponse → WebView renders.
- Background (app moves to background) → shell calls `booktool_flush()` → Zig runs `PRAGMA wal_checkpoint(TRUNCATE)`, drops caches.
- Foreground → resume; nothing special to do.
- Terminate → shell calls `booktool_close()` → Zig closes SQLite, releases the security-scoped file resource.

### Persistence & sync contract

Catalog and books both live in a user-picked folder. That folder can be anywhere the OS lets you pick — local sandbox, iCloud Documents, Google Drive folder, Syncthing folder.

**Layout (unchanged from desktop):**

```
<folder>/
  Books/                    # user's ebook files (unchanged)
  .booktool/
    catalog.db              # SQLite, WAL mode
    catalog.db-wal
    catalog.db-shm
    covers/                 # extracted cover cache
    owner.json              # NEW: single-writer coordination stamp
```

**Sync contract: single writer at a time.** `.booktool/owner.json` is a tiny file containing `{device_id, hostname, last_touched_at}`. On launch, if a different device claims it within the last 5 min, the app shows a "Another device is using this library — open anyway?" banner. Doesn't *prevent* corruption but makes concurrent-use obvious. See "risks" — SQLite over cloud drives is the biggest unresolved item.

### Reader

Same reader stack as desktop, verbatim:

- foliate-js loaded from a bundled copy in the app assets (not CDN — offline requirement).
- pdf.js same.
- Custom comic reader (`src/web/assets/comic.js` or wherever it lives) same.
- Reading-position debounced saves via `PATCH booktool://api/books/:id/location`, sync-flushed on reader close (existing behavior).

**Bundling foliate-js and pdf.js locally is a v1 change.** Currently loaded from CDN — for mobile we need them in the app bundle for offline reading.

## Zig FFI surface (v1)

Ten functions, all `extern "C"`, exported from a new `src/ffi/mobile.zig`:

```zig
export fn booktool_version() [*:0]const u8;

// Lifecycle
export fn booktool_open(folder_path: [*c]const u8, len: usize) i32;
export fn booktool_close() void;
export fn booktool_flush() void;

// Request dispatch (transport-agnostic HTTP-shaped API)
export fn booktool_handle_request(
    method: [*c]const u8, method_len: usize,
    path: [*c]const u8, path_len: usize,
    body: [*c]const u8, body_len: usize,
    out_status: *u16,
    out_body: *[*c]u8,
    out_body_len: *usize,
    out_content_type: *[*c]const u8,
) i32;

// Memory management for returned buffers
export fn booktool_free(ptr: [*c]u8) void;

// Optional: streaming reads (for large book file responses)
export fn booktool_open_stream(path: [*c]const u8, path_len: usize) i64;  // returns handle or -1
export fn booktool_read_stream(handle: i64, buf: [*c]u8, cap: usize) i64;  // returns bytes read
export fn booktool_close_stream(handle: i64) void;
```

The `handle_request` entry point is what the URL scheme handler in Swift/Kotlin actually calls. It returns response bytes owned by Zig; the shell copies into the WebView URL loading system and calls `booktool_free`.

Streaming variants exist because a 500 MB PDF shouldn't be materialized in a single response buffer. `web/api.zig` already streams book file responses; we mirror that at the FFI boundary.

## Native shell — iOS (v1 focus)

Estimated ~300 LOC of Swift + a 30-line C header.

Files:

- `Booktool-iOS/App/BooktoolApp.swift` — SwiftUI app entry, launches root view controller.
- `Booktool-iOS/App/RootViewController.swift` — hosts the WKWebView, wires the URL scheme handler.
- `Booktool-iOS/App/URLSchemeHandler.swift` — `WKURLSchemeHandler` implementation, calls `booktool_handle_request`.
- `Booktool-iOS/App/FolderPicker.swift` — `UIDocumentPickerViewController` flow, converts picked URL to security-scoped bookmark data, calls `booktool_open`.
- `Booktool-iOS/App/Lifecycle.swift` — `willResignActive` → `booktool_flush`, `willTerminate` → `booktool_close`.
- `Booktool-iOS/Bridge/booktool.h` — C ABI declarations mirroring the Zig FFI surface.
- `Booktool-iOS/Vendor/libbooktool.a` — the cross-compiled static lib (produced by `zig build ios`).

Info.plist entries:
- `NSDocumentPickerUsageDescription` — explain folder access.
- `LSSupportsOpeningDocumentsInPlace = YES`.
- No `NSAppTransportSecurity` exception needed (we don't hit any HTTP endpoint from the WebView; all traffic is `booktool://`).

## Native shell — Android (v1.5)

Ship after iOS proves out. Kotlin, `~300 LOC`. Similar shape:

- `MainActivity.kt` — hosts the WebView, sets up `WebViewClient` with `shouldInterceptRequest`.
- `SchemeInterceptor.kt` — calls JNI functions that wrap the Zig FFI.
- `FolderPicker.kt` — Storage Access Framework `ACTION_OPEN_DOCUMENT_TREE`, persistable URI permission.
- `BooktoolBridge.kt` + JNI `.cpp` shim — Kotlin ↔ C bridge; Kotlin can't directly call C, we go via a tiny C++ shim compiled with the NDK.

**Open Android storage question:** SAF returns content URIs, not file paths. SQLite needs a file path. Two options — copy files into app-private storage (loses "your own folder") or use `openFileDescriptor()` and teach Zig to operate on `int fd` instead of paths for storage I/O. **We'll decide when we get to Android; v1 is iOS-only.** Flagging early so the FFI surface doesn't get locked in a way that prevents fd-based access.

## Build & cross-compile

### Dependencies audit

| Dep | v1 needs? | iOS status | Android status |
|---|---|---|---|
| sqlite3 | yes (read + tiny writes) | ships in iOS SDK at `/usr/lib/libsqlite3.tbd` — link against it | vendor sqlite-amalgamation (NDK's version may be old) |
| libxml2 | yes (EPUB OPF parse) | ships in iOS SDK at `/usr/lib/libxml2.tbd` — link against it | vendor or use NDK-provided |
| miniz | yes (EPUB / CBZ ZIP) | vendored, compiles anywhere | vendored, compiles anywhere |
| libmobi | yes (MOBI/AZW3 read) | must cross-compile; MIT, plain C, ~10 KLOC | must cross-compile |
| booktool_c/ (in-tree helpers) | yes | in-tree, compiles anywhere | in-tree, compiles anywhere |
| 7zz subprocess | **no in v1** (CBR/CB7/CBT deferred) | forbidden on iOS anyway | possible but gnarly |
| Zig `std.http` + TLS | **no in v1** (no enrichment) | punted to v2 | punted to v2 |

### `build.zig` changes

New build targets:

```
zig build ios        # aarch64-ios static lib → zig-out/lib/libbooktool.a
zig build android    # aarch64-linux-android static lib → zig-out/lib/libbooktool.a
```

Both produce a static archive containing the Zig code + vendored miniz + cross-compiled libmobi. libxml2 and sqlite3 are marked as *link-time system libraries* on iOS (SDK provides them); on Android they're vendored into the archive.

**The Xcode / Android Studio project consumes `libbooktool.a` as a normal static dependency.** The native shell is built by its platform toolchain, not by Zig.

### Directory additions

```
booktool/
  ios/                        # NEW: Xcode project
    Booktool.xcodeproj/
    Booktool/
      Info.plist
      Sources/... (Swift files listed above)
      Bridge/booktool.h
      Vendor/                 # populated by `zig build ios`
        libbooktool.a
        libmobi.a             # or bundled into libbooktool.a
  android/                    # LATER: Gradle project
    ...
  src/
    ffi/
      mobile.zig              # NEW: the export "C" surface
    ...
```

## Risks & open questions

Ordered by severity:

### R1 — SQLite over cloud drives (HIGH)

SQLite assumes process-exclusive file locking and multi-file consistency (db + wal + shm). iCloud Drive / Google Drive / Syncthing do *file-level* sync, don't understand SQLite locking, and the WAL file is the most likely conflict victim.

**Mitigations for v1:**

- WAL mode + `PRAGMA synchronous=NORMAL`.
- Explicit `wal_checkpoint(TRUNCATE)` on every app-background transition (leaves no dirty WAL for the cloud drive to sync mid-write).
- `.booktool/owner.json` single-writer contract with visible banner on conflict.
- On-launch backup: copy `catalog.db` to `catalog.db.bak.<epoch>` if the last backup is >24 h old.

**What we're not solving in v1:** true concurrent multi-device writes. If the user runs desktop and phone at the same time, corruption is possible.

**Real solution for later:** move catalog off SQLite to an append-only event log + periodic snapshot (CRDT-friendly), or introduce an optional booktool-native sync protocol between devices. Both are big; both are v3+ material.

### R2 — Bundling foliate-js and pdf.js in the app (MEDIUM)

Currently CDN-loaded. For offline mobile reading we need them in-app. Foliate-js is MIT and self-contained (~few hundred KB). pdf.js is Apache 2.0, larger (~2 MB gzipped). Both are `@embedFile`-able. Bundle sizes are trivial.

**Action:** vendor both into `src/web/assets/vendor/` and update the SPA to load locally.

### R3 — App Store review posture (LOW)

The concerns to preempt in review notes:

- **4.7 mini-apps / HTML5**: our SPA is bundled at compile time via `@embedFile`, never downloaded at runtime. 4.7 doesn't apply.
- **No embedded server**: with the custom-scheme design there is literally no listening socket. Nothing to explain.
- **Local content**: books are user-imported, no distribution service.

### R4 — Android storage model (MEDIUM, blocks v1.5 only)

SAF gives content URIs; SQLite needs paths. Decide at Android bring-up time. Options documented in "Native shell — Android" above.

### R5 — Cross-compiling libmobi to arm64-ios (MEDIUM, one-time)

libmobi is plain C, MIT, no exotic build requirements. Zig can build it. Concrete steps:

1. Vendor `lib/libmobi/` (source drop).
2. Add a `build.zig` snippet that compiles it as a static library for the current target.
3. Verify against known-good MOBI files.

Risk is small but non-zero — bring-up may reveal a header/config that Homebrew's libmobi hides.

### R6 — Zig `std.http` on iOS for v2 (LOW for v1, HIGH for v2)

v1 doesn't need HTTP. When enrichment lands in v2, TLS on iOS is a known Zig weak spot. **v2 plan:** route HTTP through Swift's `URLSession` via a small FFI helper (`shell_http_get(url, cb)` callback pattern), keeping the Zig-side `HttpClient` vtable unchanged.

### R7 — WKWebView memory pressure with big books (LOW)

foliate-js loads the whole EPUB into JS memory. Fine for typical novels (5–10 MB), possibly problematic for large art books. Same issue exists on desktop web. Not a v1 blocker; monitor.

## v2+ roadmap preview (informational, not part of this design)

Rough sequence once v1 lands and has real users:

- **v1.5**: Android bring-up. Same code, second shell. First real test of the FFI surface's portability.
- **v2**: Enrichment on device. Requires Swift `URLSession` FFI helper. Unlocks OpenLibrary metadata + cover fetch on phone.
- **v3**: Bulk / triage / write-metadata. Requires libmobi write path on mobile and reliable file-write-through-security-scoped-URL. Real test of "full parity."
- **v4**: CBR / CB7 / CBT support without 7zz. Either write Zig parsers (probably worth doing — small, well-known formats) or feature-degrade permanently.
- **v5**: Scheduled jobs on mobile. iOS BackgroundTasks integration.
- **future**: A dedicated peer-to-peer or self-hosted-relay sync protocol if the single-writer contract stops being enough.

## Verification plan (v1)

Automated:

- New `zig build ios` produces `libbooktool.a` without warnings.
- `zig build test` — all existing tests plus new ones for the FFI dispatch layer (`booktool_handle_request` in-process, mock-only).
- New iOS UI-test suite using XCUITest — pick folder, list books, open EPUB, page-forward, close, reopen, verify position resumed.

Manual (once):

- Point at a folder in iCloud Drive on macOS. Verify iOS picks it up via document picker. Verify reads work.
- Point at a folder in Syncthing. Same.
- Point at a purely-local folder. Same.
- Concurrent access test: open on desktop while phone has folder claimed → banner shows on next phone launch.
- Terminate app mid-write to force WAL recovery on next open.

App Store submission checklist (before submission, not before implementation):

- Privacy label: "No data collected."
- Test on physical device (simulator differs on file-scheme + document picker).
- Review notes explaining `booktool://` scheme (defensive; probably unnecessary).
