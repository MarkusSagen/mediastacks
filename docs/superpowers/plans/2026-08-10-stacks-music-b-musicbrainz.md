# Music B — MusicBrainz Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When enabled, correct/complete music album metadata (album, artist, year, canonical track titles, per-track multi-artist credits, MusicBrainz IDs) from MusicBrainz, folded into the `Plan` so `organize`/`review` surface it. Read-only network, config-gated, disk-cached, graceful on any failure.

**Architecture:** New `providers/musicbrainz.zig` mirrors `providers/openlibrary.zig` (injected `http.HttpClient`, `MockClient`-tested). New `util/httpcache.zig` caches responses on disk and throttles to MusicBrainz's 1 req/sec. A pure `enrich.mergeMusic` merges a release into per-track `Fields` (confidence rules like `mergeTv`). `group.buildPlan` gains an optional `Enricher`.

**Tech Stack:** Zig 0.16, `std.http.Client` via the existing `util/http.zig`, `std.json.Value`, `std.crypto.hash.sha2.Sha256`. No new deps.

## Global Constraints

- Zig 0.16 only. Arena-allocated organizer code; caller owns the arena.
- Offline is the default: enrichment runs only when `cfg.musicbrainz_enabled` and not `--offline`. Any network/parse failure or low-confidence match → offline plan stands.
- Reuse `util/http.zig` `HttpClient`/`MockClient`; **no real network in unit tests**.
- File I/O in new non-arena code uses `std.c` (`fopen`/`fread`/`fwrite`) to match `config.zig`/`journal.zig` (avoids threading `std.Io`).
- MusicBrainz etiquette: 1 request/sec, descriptive `User-Agent`.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Build `zig build`; test `zig build test`.

## File Structure

- `src/core/plan.zig` — `Fields` gains `release_mbid`/`recording_mbid`. (T1)
- `src/core/config.zig` — `Config` gains `musicbrainz_enabled`/`musicbrainz_contact`; parse keys. (T1)
- `src/util/httpcache.zig` (new) — `CachingHttpClient`. (T2)
- `src/providers/musicbrainz.zig` (new) — `MusicBrainz` provider + `Enricher`. (T3, T5)
- `src/core/enrich.zig` — `mergeMusic` pure merge. (T4)
- `src/core/group.zig` — `buildPlan` enricher param + wiring. (T5)
- `src/commands/organize.zig`, `src/commands/review.zig` — build enricher, `--offline`, plan output. (T5)
- `docs/COMMANDS.md`, `justfile`, `todo.md`, memory. (T6)

---

## Task 1: Data model — Fields MBIDs + config keys

**Files:**
- Modify: `src/core/plan.zig` (`Fields`)
- Modify: `src/core/config.zig` (`Config`, `parseLines`)
- Test: `src/core/config.zig`

**Interfaces:**
- Produces: `Fields.release_mbid: ?[]const u8`, `Fields.recording_mbid: ?[]const u8`; `Config.musicbrainz_enabled: bool = false`, `Config.musicbrainz_contact: ?[]const u8 = null`.

- [ ] **Step 1: Write the failing config test**

Add to `src/core/config.zig`:

```zig
test "parseLines reads musicbrainz toggle and contact" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\musicbrainz = on
        \\musicbrainz_contact = me@example.com
    );
    defer freeConfig(a, cfg);
    try t.expect(cfg.musicbrainz_enabled);
    try t.expectEqualStrings("me@example.com", cfg.musicbrainz_contact.?);
}

test "parseLines musicbrainz defaults off" {
    const a = t.allocator;
    const cfg = try parseLines(a, "");
    defer freeConfig(a, cfg);
    try t.expect(!cfg.musicbrainz_enabled);
    try t.expectEqual(@as(?[]const u8, null), cfg.musicbrainz_contact);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `Config` has no `musicbrainz_enabled`.

- [ ] **Step 3: Add the fields to `plan.Fields`**

In `src/core/plan.zig`, after the music fields (`disc`, `artists`):

```zig
    disc: ?u32 = null,
    artists: []const []const u8 = &.{},
    release_mbid: ?[]const u8 = null,
    recording_mbid: ?[]const u8 = null,
```

- [ ] **Step 4: Add config fields + parsing**

In `src/core/config.zig` `Config`:

```zig
pub const Config = struct {
    library_root: []const u8,
    tv_template: []const u8,
    movie_template: []const u8,
    music_template: []const u8,
    musicbrainz_enabled: bool = false,
    musicbrainz_contact: ?[]const u8 = null,
};
```

In `freeConfig`, free the optional contact:

```zig
pub fn freeConfig(alloc: std.mem.Allocator, cfg: Config) void {
    alloc.free(cfg.library_root);
    alloc.free(cfg.tv_template);
    alloc.free(cfg.movie_template);
    alloc.free(cfg.music_template);
    if (cfg.musicbrainz_contact) |c| alloc.free(c);
}
```

In `parseLines`, add locals + key handling and thread into the returned struct. Add near the other `var` locals:

```zig
    var musicbrainz: ?[]const u8 = null;
    var musicbrainz_contact: ?[]const u8 = null;
```

Add to the key `if`-chain (before the final `;`):

```zig
        else if (std.mem.eql(u8, key, "musicbrainz")) musicbrainz = val
        else if (std.mem.eql(u8, key, "musicbrainz_contact")) musicbrainz_contact = val;
```

Before the final `return`, compute + dupe:

```zig
    const mb_on = if (musicbrainz) |v|
        (std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1"))
    else
        false;
    const mb_contact = if (musicbrainz_contact) |v| try alloc.dupe(u8, v) else null;
```

Change the final return to include them:

```zig
    return .{ .library_root = lr, .tv_template = tt, .movie_template = mt, .music_template = mu, .musicbrainz_enabled = mb_on, .musicbrainz_contact = mb_contact };
```

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS. (Existing `Config{...}` literals in naming/group/review still compile — new fields default.)

- [ ] **Step 6: Commit**

```bash
git add src/core/plan.zig src/core/config.zig
git commit -m "feat(music-b): Fields MBIDs + config musicbrainz toggle/contact

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: util/httpcache.zig — caching + throttling HttpClient

**Files:**
- Create: `src/util/httpcache.zig`
- Test: `src/util/httpcache.zig`

**Interfaces:**
- Consumes: `http.HttpClient`, `http.Response` (`util/http.zig`).
- Produces: `CachingHttpClient{ inner: http.HttpClient, dir: []const u8, throttle_ms: u64 = 1100 }` with `.client() http.HttpClient`.

- [ ] **Step 1: Write the failing test**

Create `src/util/httpcache.zig` with the test at the bottom (impl added next step). Use a counting mock inner:

```zig
const std = @import("std");
const http = @import("http.zig");

// ... implementation goes here (Step 3) ...

const t = std.testing;

test "second fetch is served from disk (no inner call)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pid = std.c.getpid();
    var db: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&db, "/tmp/stacks-hc-{d}", .{pid});
    _ = std.c.mkdir((try std.fmt.bufPrintZ(db[128..], "{s}", .{dir})).ptr, 0o755);

    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://mb/x", 200, "BODY");

    var caching = CachingHttpClient{ .inner = mock.client(), .dir = dir, .throttle_ms = 0 };
    const c = caching.client();

    var r1 = try c.fetchGet(a, "https://mb/x", .{});
    try t.expectEqualStrings("BODY", r1.body);
    var r2 = try c.fetchGet(a, "https://mb/x", .{});
    try t.expectEqualStrings("BODY", r2.body);
    // inner was hit exactly once; second came from disk.
    try t.expectEqual(@as(usize, 1), mock.calls.items.len);

    // cleanup: remove the one cache file + dir
    cleanupDir(dir);
}

test "non-2xx/4xx (5xx) is not cached" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pid = std.c.getpid();
    var db: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&db, "/tmp/stacks-hc5-{d}", .{pid});
    _ = std.c.mkdir((try std.fmt.bufPrintZ(db[128..], "{s}", .{dir})).ptr, 0o755);

    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://mb/e", 500, "ERR");
    try mock.add("https://mb/e", 500, "ERR"); // queued twice: both calls hit inner

    var caching = CachingHttpClient{ .inner = mock.client(), .dir = dir, .throttle_ms = 0 };
    const c = caching.client();
    _ = try c.fetchGet(a, "https://mb/e", .{});
    _ = try c.fetchGet(a, "https://mb/e", .{});
    try t.expectEqual(@as(usize, 2), mock.calls.items.len); // not cached
    cleanupDir(dir);
}
```

Note: `MockClient.add` overwrites the same key, so the 5xx test's two `add`s leave one entry; that's fine — the mock returns it for both calls and records both. Keep both `add` lines for clarity.

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `CachingHttpClient`/`cleanupDir` undefined.

- [ ] **Step 3: Implement**

Add above the tests in `src/util/httpcache.zig`:

```zig
/// A HttpClient that caches raw responses on disk (keyed by SHA-256 of the
/// URL) and throttles network misses to respect MusicBrainz's 1 req/sec.
/// Cache files: `{dir}/{hex-sha256}.cache`, first line `status`, then body.
/// Best-effort: any FS error degrades to a plain passthrough.
pub const CachingHttpClient = struct {
    inner: http.HttpClient,
    dir: []const u8,
    throttle_ms: u64 = 1100,
    last_net_ms: i64 = 0,

    pub fn client(self: *CachingHttpClient) http.HttpClient {
        return .{ .ctx = self, .get_fn = getShim };
    }

    fn getShim(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, opts: http.ClientOptions) anyerror!http.Response {
        const self: *CachingHttpClient = @ptrCast(@alignCast(ctx));
        return self.get(allocator, url, opts);
    }

    fn get(self: *CachingHttpClient, allocator: std.mem.Allocator, url: []const u8, opts: http.ClientOptions) !http.Response {
        var key_buf: [64]u8 = undefined;
        const key = hexKey(url, &key_buf);
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.cache", .{ self.dir, key }) catch null;

        if (path) |p| {
            if (readCache(allocator, p)) |hit| return hit;
        }

        // Throttle network misses.
        if (self.throttle_ms > 0) {
            const now = std.time.milliTimestamp();
            const wait = self.throttle_ms -| @as(u64, @intCast(@max(0, now - self.last_net_ms)));
            if (self.last_net_ms != 0 and wait > 0) std.Thread.sleep(wait * std.time.ns_per_ms);
            self.last_net_ms = std.time.milliTimestamp();
        }

        var resp = try self.inner.fetchGet(allocator, url, opts);
        // Cache 2xx and 4xx (definitive); skip 5xx (transient).
        const cacheable = (resp.status >= 200 and resp.status < 300) or (resp.status >= 400 and resp.status < 500);
        if (cacheable) {
            if (path) |p| writeCache(p, resp.status, resp.body);
        }
        return resp;
    }
};

fn hexKey(url: []const u8, out: *[64]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..64];
}

fn readCache(allocator: std.mem.Allocator, path: []const u8) ?http.Response {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return null;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        buf.appendSlice(allocator, chunk[0..n]) catch return null;
    }
    const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse return null;
    const status = std.fmt.parseInt(u16, buf.items[0..nl], 10) catch return null;
    const body = allocator.dupe(u8, buf.items[nl + 1 ..]) catch return null;
    return .{ .status = status, .body = body };
}

fn writeCache(path: []const u8, status: u16, body: []const u8) void {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    var hdr: [8]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "{d}\n", .{status}) catch return;
    _ = std.c.fwrite(h.ptr, 1, h.len, fp);
    if (body.len > 0) _ = std.c.fwrite(body.ptr, 1, body.len, fp);
}

// Test helper: remove all `*.cache` files in dir then rmdir. Best-effort.
fn cleanupDir(dir: []const u8) void {
    var pz: [4096]u8 = undefined;
    // We don't enumerate; tests write at most one key each, but to be safe
    // just rmdir after unlinking is skipped — the OS tmp reaper handles leftovers.
    const dz = std.fmt.bufPrintZ(&pz, "{s}", .{dir}) catch return;
    _ = std.c.rmdir(dz.ptr); // no-op if non-empty; leftover cache files are tmp
}
```

Wire the module into the build graph by importing it where used (Task 5). It compiles standalone once `root.zig`/tests reference it; add `_ = @import("util/httpcache.zig");` to the test aggregator in `src/root.zig` if that's how sibling tests are discovered (check `root.zig` for the existing `_ = @import(...)` test list and add this file alongside `util/http.zig`).

- [ ] **Step 4: Run tests**

Run: `zig build test 2>&1 | tail -6`
Expected: PASS (both httpcache tests; disk round-trip served the 2nd call).

- [ ] **Step 5: Commit**

```bash
git add src/util/httpcache.zig src/root.zig
git commit -m "feat(music-b): CachingHttpClient (disk cache + 1req/s throttle)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: providers/musicbrainz.zig — search + release parsing

**Files:**
- Create: `src/providers/musicbrainz.zig`
- Test: `src/providers/musicbrainz.zig`

**Interfaces:**
- Consumes: `http.HttpClient`.
- Produces: `TrackInfo`, `Release`, `MusicBrainz{ http_client, contact }` with `pub fn lookupRelease(alloc, album, album_artist, track_count, hint_year) !?Release`.

- [ ] **Step 1: Write failing tests (MockClient)**

Create `src/providers/musicbrainz.zig`. Tests exercise the two-call ladder with canned JSON:

```zig
const std = @import("std");
const http = @import("../util/http.zig");

// ... types + impl (Steps 3-4) ...

const t = std.testing;

test "lookupRelease: search then detail parses tracks + multi-artist" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add(
        "https://musicbrainz.org/ws/2/release?query=release:%22Blue%22%20AND%20artist:%22Eric%20Clapton%22%20AND%20tracks:2&fmt=json&limit=5",
        200,
        \\{"releases":[{"id":"rel-1","title":"Blue","score":100,"track-count":2,"date":"1998","artist-credit":[{"name":"Eric Clapton"}],"release-group":{"first-release-date":"1998-03-01"}}]}
        ,
    );
    try mock.add(
        "https://musicbrainz.org/ws/2/release/rel-1?inc=recordings+artist-credits+release-groups&fmt=json",
        200,
        \\{"id":"rel-1","title":"Blue","date":"1998","artist-credit":[{"name":"Eric Clapton"}],"media":[{"tracks":[{"position":1,"title":"Layla","recording":{"id":"rec-1","artist-credit":[{"name":"Eric Clapton","joinphrase":" & "},{"name":"Duane Allman"}]}},{"position":2,"title":"Cocaine","recording":{"id":"rec-2","artist-credit":[{"name":"Eric Clapton"}]}}]}]}
        ,
    );

    var mb = MusicBrainz{ .http_client = mock.client() };
    const rel = (try mb.lookupRelease(a, "Blue", "Eric Clapton", 2, 1998)).?;
    try t.expectEqualStrings("rel-1", rel.mbid);
    try t.expectEqualStrings("Blue", rel.title);
    try t.expectEqual(@as(u32, 1998), rel.year.?);
    try t.expectEqual(@as(usize, 2), rel.tracks.len);
    try t.expectEqualStrings("Layla", rel.tracks[0].title);
    try t.expectEqualStrings("rec-1", rel.tracks[0].recording_mbid.?);
    try t.expectEqual(@as(usize, 2), rel.tracks[0].artists.len);
    try t.expectEqualStrings("Duane Allman", rel.tracks[0].artists[1]);
    try t.expectEqual(@as(usize, 2), mock.calls.items.len); // search + detail
}

test "lookupRelease: track-count mismatch → null (no wrong match)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add(
        "https://musicbrainz.org/ws/2/release?query=release:%22X%22%20AND%20artist:%22Y%22%20AND%20tracks:5&fmt=json&limit=5",
        200,
        \\{"releases":[{"id":"r","title":"X","score":90,"track-count":9,"artist-credit":[{"name":"Y"}]}]}
        ,
    );
    var mb = MusicBrainz{ .http_client = mock.client() };
    try t.expect((try mb.lookupRelease(a, "X", "Y", 5, null)) == null);
    try t.expectEqual(@as(usize, 1), mock.calls.items.len); // no detail call
}

test "lookupRelease: HTTP failure → null" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    var mb = MusicBrainz{ .http_client = mock.client() };
    try t.expect((try mb.lookupRelease(a, "No", "Body", 1, null)) == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `MusicBrainz`/`Release` undefined.

- [ ] **Step 3: Types + query building + selection**

Add to the top of `src/providers/musicbrainz.zig`:

```zig
pub const TrackInfo = struct {
    position: u32,
    title: []const u8,
    recording_mbid: ?[]const u8 = null,
    artists: []const []const u8 = &.{},
};

pub const Release = struct {
    mbid: []const u8,
    title: []const u8,
    album_artist: []const u8,
    year: ?u32 = null,
    cover_url: ?[]const u8 = null,
    tracks: []const TrackInfo = &.{},
};

pub const MusicBrainz = struct {
    http_client: http.HttpClient,
    contact: ?[]const u8 = null,

    pub fn lookupRelease(
        self: *MusicBrainz,
        alloc: std.mem.Allocator,
        album: []const u8,
        album_artist: []const u8,
        track_count: usize,
        hint_year: ?u32,
    ) !?Release {
        const ea = try urlEncode(alloc, album);
        const eaa = try urlEncode(alloc, album_artist);
        const search_url = try std.fmt.allocPrint(
            alloc,
            "https://musicbrainz.org/ws/2/release?query=release:%22{s}%22%20AND%20artist:%22{s}%22%20AND%20tracks:{d}&fmt=json&limit=5",
            .{ ea, eaa, track_count },
        );
        const search_body = httpGetOk(self.http_client, alloc, search_url) orelse return null;
        const mbid = chooseRelease(alloc, search_body, track_count, hint_year) orelse return null;

        const detail_url = try std.fmt.allocPrint(
            alloc,
            "https://musicbrainz.org/ws/2/release/{s}?inc=recordings+artist-credits+release-groups&fmt=json",
            .{mbid},
        );
        const detail_body = httpGetOk(self.http_client, alloc, detail_url) orelse return null;
        return parseRelease(alloc, mbid, detail_body);
    }
};
```

Note: `urlEncode` percent-encodes spaces as `%20` here (not `+`) so the query matches the test URLs. Add a local variant:

```zig
/// Percent-encode for a MusicBrainz query value; space → %20.
fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (safe) {
            try buf.append(alloc, ch);
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(alloc, '%');
            try buf.append(alloc, hex[ch >> 4]);
            try buf.append(alloc, hex[ch & 0x0f]);
        }
    }
    return buf.toOwnedSlice(alloc);
}
```

- [ ] **Step 4: JSON parsing (selection + release) + httpGetOk**

Add:

```zig
/// Pick the best release MBID from a search body: highest `score` among
/// releases whose `track-count` equals `want`. Returns null if none match.
fn chooseRelease(alloc: std.mem.Allocator, body: []const u8, want: usize, hint_year: ?u32) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const rels = parsed.value.object.get("releases") orelse return null;
    if (rels != .array) return null;

    var best_id: ?[]const u8 = null;
    var best_score: i64 = std.math.minInt(i64);
    for (rels.array.items) |rv| {
        if (rv != .object) continue;
        const tc = rv.object.get("track-count") orelse continue;
        if (tc != .integer or @as(usize, @intCast(tc.integer)) != want) continue;
        var score: i64 = 0;
        if (rv.object.get("score")) |s| if (s == .integer) {
            score = s.integer;
        };
        if (hint_year) |hy| {
            if (rv.object.get("date")) |d| if (d == .string) {
                if (findYear(d.string)) |y| {
                    const diff = if (y > hy) y - hy else hy - y;
                    if (diff <= 1) score += 50;
                }
            };
        }
        if (score > best_score) {
            best_score = score;
            if (rv.object.get("id")) |idv| if (idv == .string) {
                best_id = alloc.dupe(u8, idv.string) catch return null;
            };
        }
    }
    return best_id;
}

fn creditNames(alloc: std.mem.Allocator, credit: std.json.Value) ![]const []const u8 {
    if (credit != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (credit.array.items) |c| {
        if (c != .object) continue;
        const n = c.object.get("name") orelse continue;
        if (n != .string or n.string.len == 0) continue;
        try out.append(alloc, try alloc.dupe(u8, n.string));
    }
    return out.toOwnedSlice(alloc);
}

fn joinNames(alloc: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    if (names.len == 0) return alloc.dupe(u8, "");
    if (names.len == 1) return alloc.dupe(u8, names[0]);
    var buf: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, n);
    }
    return buf.toOwnedSlice(alloc);
}

/// Parse a release detail body into a Release. Flattens media[].tracks[].
fn parseRelease(alloc: std.mem.Allocator, mbid: []const u8, body: []const u8) !?Release {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    const title = if (root.get("title")) |tv| (if (tv == .string) try alloc.dupe(u8, tv.string) else "") else "";

    // Year: prefer release-group first-release-date, else release date.
    var year: ?u32 = null;
    if (root.get("release-group")) |rg| if (rg == .object) {
        if (rg.object.get("first-release-date")) |d| if (d == .string) {
            year = findYear(d.string);
        };
    };
    if (year == null) if (root.get("date")) |d| if (d == .string) {
        year = findYear(d.string);
    };

    const aa_names = if (root.get("artist-credit")) |ac| try creditNames(alloc, ac) else &.{};
    const album_artist = try joinNames(alloc, aa_names);

    var tracks: std.ArrayList(TrackInfo) = .empty;
    if (root.get("media")) |media| if (media == .array) {
        for (media.array.items) |m| {
            if (m != .object) continue;
            const tks = m.object.get("tracks") orelse continue;
            if (tks != .array) continue;
            for (tks.array.items) |tk| {
                if (tk != .object) continue;
                var ti: TrackInfo = .{ .position = 0, .title = "" };
                if (tk.object.get("position")) |p| if (p == .integer) {
                    ti.position = @intCast(p.integer);
                };
                if (tk.object.get("title")) |tt| if (tt == .string) {
                    ti.title = try alloc.dupe(u8, tt.string);
                };
                if (tk.object.get("recording")) |rec| if (rec == .object) {
                    if (rec.object.get("id")) |rid| if (rid == .string) {
                        ti.recording_mbid = try alloc.dupe(u8, rid.string);
                    };
                    if (rec.object.get("artist-credit")) |rac| {
                        ti.artists = try creditNames(alloc, rac);
                    }
                };
                try tracks.append(alloc, ti);
            }
        }
    };

    const cover = try std.fmt.allocPrint(alloc, "https://coverartarchive.org/release/{s}/front-500", .{mbid});
    return Release{
        .mbid = try alloc.dupe(u8, mbid),
        .title = title,
        .album_artist = album_artist,
        .year = year,
        .cover_url = cover,
        .tracks = try tracks.toOwnedSlice(alloc),
    };
}

/// GET with simple retry; null on 4xx or terminal failure. (Throttling and
/// caching live in CachingHttpClient; this just tolerates transient errors.)
fn httpGetOk(client: http.HttpClient, alloc: std.mem.Allocator, url: []const u8) ?[]u8 {
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        var resp = client.fetchGet(alloc, url, .{}) catch continue;
        if (resp.status >= 200 and resp.status < 300) return resp.body;
        if (resp.status >= 400 and resp.status < 500) {
            resp.deinit(alloc);
            return null;
        }
        resp.deinit(alloc);
    }
    return null;
}

fn findYear(s: []const u8) ?u32 {
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        const slice = s[i .. i + 4];
        var all_digit = true;
        for (slice) |c| if (!std.ascii.isDigit(c)) {
            all_digit = false;
            break;
        };
        if (all_digit) {
            const y = std.fmt.parseInt(u32, slice, 10) catch continue;
            if (y >= 1000 and y < 3000) return y;
        }
    }
    return null;
}
```

Register the file in `src/root.zig`'s test aggregator (alongside `providers/openlibrary.zig`).

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | tail -6`
Expected: PASS (three provider tests: parse, mismatch, failure).

- [ ] **Step 6: Commit**

```bash
git add src/providers/musicbrainz.zig src/root.zig
git commit -m "feat(music-b): MusicBrainz provider (search+detail, multi-artist credits)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: enrich.mergeMusic — pure confidence merge

**Files:**
- Modify: `src/core/enrich.zig` (add `mergeMusic`, import `plan` + `musicbrainz`)
- Test: `src/core/enrich.zig`

**Interfaces:**
- Consumes: `plan.Fields`, `musicbrainz.Release`.
- Produces: `MusicEnrichResult{ fields: plan.Fields, warnings: []const []const u8 }`; `pub fn mergeMusic(alloc, base: plan.Fields, position: u32, release: musicbrainz.Release, album_from_folder: bool) !MusicEnrichResult`.

- [ ] **Step 1: Write failing tests**

Add to `src/core/enrich.zig`:

```zig
const plan = @import("plan.zig");
const musicbrainz = @import("../providers/musicbrainz.zig");

// (tests near the bottom, after existing ones)
test "mergeMusic fills year, canonical title, multi-artist, mbids" {
    const a = t.allocator;
    const rel = musicbrainz.Release{
        .mbid = "rel-1", .title = "Blue", .album_artist = "Eric Clapton", .year = 1998,
        .tracks = &.{ .{ .position = 1, .title = "Layla", .recording_mbid = "rec-1", .artists = &.{ "Eric Clapton", "Duane Allman" } } },
    };
    const base = plan.Fields{ .album_artist = "Eric Clapton", .album = "blue album folder", .title = "01 layla", .track = 1, .ext = "flac" };
    const r = try mergeMusic(a, base, 1, rel, true); // album came from folder
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("Blue", r.fields.album);          // folder → canonical
    try t.expectEqual(@as(u32, 1998), r.fields.year.?);         // filled
    try t.expectEqualStrings("Layla", r.fields.title.?);        // canonical title
    try t.expectEqual(@as(usize, 2), r.fields.artists.len);     // multi-artist
    try t.expectEqualStrings("rel-1", r.fields.release_mbid.?);
    try t.expectEqualStrings("rec-1", r.fields.recording_mbid.?);
}

test "mergeMusic keeps a tag-authoritative album but warns on MB difference" {
    const a = t.allocator;
    const rel = musicbrainz.Release{ .mbid = "r", .title = "Canonical Name", .album_artist = "X", .year = 2000, .tracks = &.{} };
    const base = plan.Fields{ .album_artist = "X", .album = "Tagged Name", .title = "Song", .track = 1, .ext = "flac" };
    const r = try mergeMusic(a, base, 1, rel, false); // album from a real tag
    defer freeWarnings(a, r.warnings);
    try t.expectEqualStrings("Tagged Name", r.fields.album); // not overwritten
    var warned = false;
    for (r.warnings) |w| if (std.mem.indexOf(u8, w, "MusicBrainz") != null) { warned = true; };
    try t.expect(warned);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `mergeMusic` undefined.

- [ ] **Step 3: Implement `mergeMusic`**

Add to `src/core/enrich.zig`:

```zig
pub const MusicEnrichResult = struct { fields: plan.Fields, warnings: []const []const u8 };

fn findTrack(release: musicbrainz.Release, position: u32) ?musicbrainz.TrackInfo {
    for (release.tracks) |tk| if (tk.position == position) return tk;
    return null;
}

/// Merge a MusicBrainz release into one track's fields. `album_from_folder`
/// marks that `base.album` was derived from the source folder (A.1 fallback),
/// in which case MB's canonical album wins; otherwise a tag-authoritative
/// album is kept and any MB difference is only a warning.
pub fn mergeMusic(
    alloc: std.mem.Allocator,
    base: plan.Fields,
    position: u32,
    release: musicbrainz.Release,
    album_from_folder: bool,
) !MusicEnrichResult {
    var f = base;
    var warns: std.ArrayList([]const u8) = .empty;
    errdefer freeAll(alloc, &warns);

    // Album name
    if (release.title.len > 0) {
        if (album_from_folder or f.album == null) {
            f.album = release.title;
        } else if (f.album) |cur| {
            if (!std.ascii.eqlIgnoreCase(cur, release.title)) {
                try warns.append(alloc, try std.fmt.allocPrint(alloc, "MusicBrainz suggests album \"{s}\"", .{release.title}));
            }
        }
    }
    // Album artist: fill when missing.
    if ((f.album_artist == null or f.album_artist.?.len == 0) and release.album_artist.len > 0) {
        f.album_artist = release.album_artist;
    }
    // Year: fill when missing.
    if (f.year == null and release.year != null) f.year = release.year;
    // MBIDs (release-level always; recording per track below).
    f.release_mbid = release.mbid;

    if (findTrack(release, position)) |tk| {
        if (tk.title.len > 0) {
            const looks_filename = f.title == null or titleLooksFilename(f.title.?);
            if (looks_filename) f.title = tk.title;
        }
        if (tk.artists.len > 0) f.artists = tk.artists;
        if (tk.recording_mbid) |rid| f.recording_mbid = rid;
    }

    return .{ .fields = f, .warnings = try warns.toOwnedSlice(alloc) };
}

/// Heuristic: a title that starts with a track-number prefix (e.g. "01 ",
/// "03 - ") is filename-derived and safe to replace with a canonical title.
fn titleLooksFilename(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    return i >= 1 and i <= 3 and i < s.len and (s[i] == ' ' or s[i] == '-' or s[i] == '_' or s[i] == '.');
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test 2>&1 | tail -6`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/enrich.zig
git commit -m "feat(music-b): enrich.mergeMusic pure confidence merge

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire the enricher into buildPlan + CLI

**Files:**
- Modify: `src/providers/musicbrainz.zig` (add `Enricher`)
- Modify: `src/core/group.zig` (`buildPlan` param + music enrichment)
- Modify: `src/commands/organize.zig`, `src/commands/review.zig` (build enricher, `--offline`, output)
- Test: `src/core/group.zig` (buildPlan compiles with `null`; existing tests updated)

**Interfaces:**
- Consumes: `MusicBrainz`, `CachingHttpClient`, `RealHttpClient`, `enrich.mergeMusic`.
- Produces: `Enricher{ mb: *MusicBrainz, memo }` with `pub fn lookupAlbum(alloc, album, album_artist, track_count, hint_year) !?Release`; `buildPlan(arena, io, dir_path, cfg, probe_enabled, mb: ?*Enricher)`.

- [ ] **Step 1: Add `Enricher` to musicbrainz.zig**

```zig
/// Per-run wrapper: memoizes album lookups so a re-encountered album (or a
/// multi-disc album seen once per source folder) hits the network at most once.
pub const Enricher = struct {
    mb: *MusicBrainz,
    memo: std.StringHashMap(?Release),

    pub fn init(alloc: std.mem.Allocator, mb: *MusicBrainz) Enricher {
        return .{ .mb = mb, .memo = std.StringHashMap(?Release).init(alloc) };
    }

    pub fn lookupAlbum(
        self: *Enricher,
        alloc: std.mem.Allocator,
        album: []const u8,
        album_artist: []const u8,
        track_count: usize,
        hint_year: ?u32,
    ) !?Release {
        const key = try std.fmt.allocPrint(alloc, "{s}|{s}|{d}", .{ album, album_artist, track_count });
        if (self.memo.get(key)) |cached| return cached;
        const rel = self.mb.lookupRelease(alloc, album, album_artist, track_count, hint_year) catch null;
        try self.memo.put(key, rel);
        return rel;
    }
};
```

- [ ] **Step 2: Thread the param through `buildPlan` (compile-first)**

Change the signature in `src/core/group.zig`:

```zig
pub fn buildPlan(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    cfg: config.Config,
    probe_enabled: bool,
    mb: ?*musicbrainz.Enricher,
) !plan.Plan {
```

Add the import near the other imports:

```zig
const musicbrainz = @import("../providers/musicbrainz.zig");
```

Update the three in-file tests' `buildPlan(...)` calls to pass a trailing `null`. Update the two command call sites (organize/review) in Step 4. Run `zig build test` — expect compile errors only at the call sites you haven't updated yet; fix each to pass `null` (tests) then proceed.

- [ ] **Step 3: Enrich music groups**

In `src/core/group.zig`, in the music dedup `else` block, AFTER the per-track `Fields`/`dst` are computed and BEFORE emitting items, insert enrichment. Locate the block that ends the `while (it.next()) |cp|` field-assignment loop; append:

```zig
            // MusicBrainz enrichment (opt-in). Corrects fields in place and
            // recomputes dst; offline plan is untouched when disabled/miss.
            if (mb) |enr| {
                const album_from_folder = !hadUsableAlbumTag(cands.items);
                const rel = enr.lookupAlbum(arena, meta.album, meta.album_artist, distinctTrackCount(cands.items, multi), meta.year) catch null;
                if (rel) |release| {
                    for (cands.items) |c| {
                        if (c.role == .duplicate) continue;
                        const pos = c.track.?.track orelse 0;
                        const merged = try enrich.mergeMusic(arena, c.fields.?, pos, release, album_from_folder);
                        c.fields = merged.fields;
                        c.dst = try naming.dstFor(arena, cfg, .music, merged.fields);
                        c.primary_dst = c.dst;
                        for (merged.warnings) |w| try gb.warnings.append(arena, w);
                    }
                    if (release.title.len > 0) gb.title = release.title;
                    if (release.year != null) gb.year = release.year;
                    try gb.warnings.append(arena, try std.fmt.allocPrint(arena, "MusicBrainz: matched \"{s}\"", .{release.title}));
                } else {
                    try gb.warnings.append(arena, "MusicBrainz: no confident match");
                }
            }
```

Add the two small helpers near the other music helpers in `group.zig`:

```zig
fn hadUsableAlbumTag(cands: []const *Cand) bool {
    for (cands) |c| if (c.track.?.album) |al| {
        if (al.len > 0 and std.mem.indexOf(u8, al, "\u{FFFD}") == null) return true;
    };
    return false;
}
fn distinctTrackCount(cands: []const *Cand, multi: bool) usize {
    // For a single-disc album the MB release track count equals the number of
    // distinct primary tracks. For multi-disc, fall back to total tracks.
    _ = multi;
    return cands.len;
}
```

Note: the enrichment loop runs over `cands.items` but must use the *deduped winners*' fields; since `c.fields` was set for every cand (winner + duplicate share the winner's fields) and duplicates are skipped, iterating primaries is correct. If a subtlety arises (fields null on a cand), guard with `if (c.fields == null) continue;`.

- [ ] **Step 4: CLI wiring (`organize.zig`, `review.zig`)**

In `commands/organize.zig`: add `offline: bool = false` to `Opts`; parse `--offline` in `parseArgs`. Before calling `buildPlan`, construct the enricher when enabled:

```zig
    var real = http.RealHttpClient{ .io = ctx.io };
    var caching = httpcache.CachingHttpClient{ .inner = real.client(), .dir = mbCacheDir(ctx.arena, ctx.env) };
    var mb = musicbrainz.MusicBrainz{ .http_client = caching.client(), .contact = cfg.musicbrainz_contact };
    var enricher = musicbrainz.Enricher.init(ctx.arena, &mb);
    const mb_ptr: ?*musicbrainz.Enricher =
        if (cfg.musicbrainz_enabled and !opts.offline) &enricher else null;
    const p = try group.buildPlan(ctx.arena, ctx.io, opts.dir, cfg, !opts.no_probe, mb_ptr);
```

Add imports (`http`, `httpcache`, `musicbrainz`) and a `mbCacheDir` helper returning `$XDG_CACHE_HOME/stacks/mb` (or `$HOME/.cache/stacks/mb`), creating it via `standardize.mkdirParents`. Mirror the same wiring in `commands/review.zig`'s plan build (`mkSession`/serve path). Add `--offline` to both help strings and the justfile `organize`/`review` help lines.

Plan output already prints group warnings (the `MusicBrainz: matched …` line rides along) — no change needed to `printPlan` beyond confirming warnings render.

- [ ] **Step 5: Build + test**

Run: `zig build 2>&1 | tail -3 && zig build test 2>&1 | tail -6`
Expected: builds; all tests pass (group tests pass `null` for `mb`, so behavior is unchanged offline).

- [ ] **Step 6: Manual offline sanity (no network)**

Run: `./zig-out/bin/shelve organize <any music dir> --to /tmp/nolib --dry-run` — confirm identical output to before (enricher off by default).

- [ ] **Step 7: Commit**

```bash
git add src/providers/musicbrainz.zig src/core/group.zig src/commands/organize.zig src/commands/review.zig justfile
git commit -m "feat(music-b): wire MusicBrainz enricher into buildPlan + --offline

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Docs, config sample, optional live smoke

**Files:**
- Modify: `docs/COMMANDS.md` (or create a short `docs/MUSICBRAINZ.md`), `todo.md`, memory file
- Create: `scripts/mb-smoke.sh` (guarded by `MB_SMOKE=1`)

- [ ] **Step 1: Document the config keys**

Add to the config docs: `musicbrainz = on` (default off) enables MusicBrainz enrichment for `organize`/`review`; `musicbrainz_contact = <email/url>` sets the User-Agent contact; `--offline` bypasses for one run. Note the 1 req/sec throttle and the on-disk cache at `$XDG_CACHE_HOME/stacks/mb/`.

- [ ] **Step 2: Optional live smoke (skipped by default)**

Create `scripts/mb-smoke.sh`:

```bash
#!/usr/bin/env bash
# Live MusicBrainz smoke — OFF unless MB_SMOKE=1 (hits the real network,
# 1 req/sec). Verifies a known release enriches (canonical title recovered).
set -euo pipefail
[[ "${MB_SMOKE:-0}" == "1" ]] || { echo "MB_SMOKE!=1 — skipping live MusicBrainz smoke"; exit 0; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
command -v ffmpeg >/dev/null || { echo "need ffmpeg"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config" XDG_CACHE_HOME="$TMP/cache" XDG_DATA_HOME="$TMP/data"
mkdir -p "$XDG_CONFIG_HOME/stacks" "$TMP/dl/album"
printf 'musicbrainz = on\n' > "$XDG_CONFIG_HOME/stacks/config.toml"
# Minimal 2-track album that MB knows (adjust title/artist to a stable release).
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=Communiqué -metadata artist="Dire Straits" -metadata track=1 -y "$TMP/dl/album/01.mp3"
ffmpeg -v error -f lavfi -i sine=d=1 -metadata album=Communiqué -metadata artist="Dire Straits" -metadata track=2 -y "$TMP/dl/album/02.mp3"
OUT="$("$ROOT/zig-out/bin/shelve" organize "$TMP/dl/album" --to "$TMP/lib" --dry-run)"
echo "$OUT" | grep -i "MusicBrainz" || { echo "FAIL: no MusicBrainz line"; exit 1; }
echo "ok: MusicBrainz enrichment ran"
```

Add a `just mb-smoke` recipe (`MB_SMOKE=1 ./scripts/mb-smoke.sh`).

- [ ] **Step 3: Update todo.md + memory**

Mark Music B done in `todo.md` (the `- [ ] **B — MusicBrainz enrichment**` line) with a one-line result; append a status line to the memory file (`providers/musicbrainz.zig`, `util/httpcache.zig`, `enrich.mergeMusic`, config `musicbrainz=on`, cache path, `--offline`).

- [ ] **Step 4: Commit**

```bash
git add docs todo.md scripts/mb-smoke.sh justfile
git commit -m "docs(music-b): document MusicBrainz config + live smoke; mark B done

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** provider search+detail (T3) ✓; disk cache + throttle (T2) ✓; pure merge with confidence + multi-artist + MBIDs (T4) ✓; MBIDs in Fields + config gate + `--offline` (T1,T5) ✓; memoized per-album lookup (T5) ✓; offline-untouched-on-failure (T5 `null` path) ✓; docs + optional live smoke (T6) ✓. Cover download intentionally out of scope (URL only, recorded on `Release.cover_url`).

**Placeholder scan:** concrete code/tests in every step; the one heuristic (`distinctTrackCount`) is defined, with a noted multi-disc caveat carried from the spec's open items.

**Type consistency:** `Release`/`TrackInfo` (T3) used identically in T4/T5; `Enricher.lookupAlbum` ↔ `MusicBrainz.lookupRelease` (T5); `buildPlan(...., mb: ?*Enricher)` call sites updated in T5; `Fields.release_mbid/recording_mbid` (T1) set in T4. `CachingHttpClient` (T2) constructed in T5.
