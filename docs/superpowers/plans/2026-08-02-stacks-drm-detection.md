# stacks — DRM detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect (never remove) DRM in videos and ebooks via a shared `core/drm.zig` container sniff; `shelve` flags protected videos in `organize` (organized by filename, no ffprobe), `biblio` reports DRM in `info` and `scan`.

**Architecture:** `core/drm.zig` exposes a pure `scanForDrmMarkers([]u8) → Scheme` and two thin file-reading detectors (`detectVideo`, `detectEbook`). MP4 detection walks the box structure (C stdio, skipping `mdat`) to reach `moov` and scans only that for encryption 4CCs. Ebook detection checks the epub zip for `META-INF/encryption.xml` (reusing the vendored miniz `ZipReader`) and treats `.acsm` as a token. Wiring is additive.

**Tech Stack:** Zig 0.16, `std.c` stdio (fopen/fread/fseek), vendored miniz `ffi/miniz.zig`, existing `core/group`, `commands/info`, `commands/scan`.

## Global Constraints

- Zig **0.16.0**. No 0.17-only APIs. No new dependencies.
- **Detect only — never remove or circumvent DRM.**
- Detectors are **total**: any error/odd input → `.none`, never a crash, never a false positive.
- `std.ArrayList(T)` starts `.empty`, allocator passed per call. CLI uses `ctx.arena`. Tests are inline `test "…" {}` with `std.testing.allocator`; temp files under `/tmp` keyed by `std.c.getpid()` + `@import("../util/clock.zig").nowSeconds()`.
- New module added to `src/root.zig` (`pub const` + `_ = drm;` in `test {}`).
- Detector signatures take `(alloc, path)` — **no `std.Io`** (they use C stdio / miniz directly, like `config.readFileZ` and `epub.zig`).
- **Gate:** DRM detection runs when `probe_enabled` (i.e. NOT `--no-probe`). ffprobe *availability* gates only the ffprobe call, not DRM detection.
- Scheme→CENC-vs-FairPlay rule: a `pssh` marker ⇒ `.cenc`; else `sinf`/`drms`/`encv`/`enca` ⇒ `.fairplay`.
- MP4-family extensions for `detectVideo`: `.mp4`, `.m4v`, `.mov`. Others → `.none` (Matroska deferred). Ebook: `.epub` (ADEPT), `.acsm` (token). Others → `.none` (Kindle deferred).

## File Structure

Created:
- `src/core/drm.zig` — `Scheme`, `label`, `scanForDrmMarkers` (pure), `detectVideo`, `detectEbook`.

Modified:
- `src/core/group.zig` — DRM check before ffprobe; DRM video → warning, no probe.
- `src/commands/info.zig` — `DRM:` line.
- `src/commands/scan.zig` — `drm` counter in the summary.
- `src/root.zig` — export `drm`.
- `scripts/organize-smoke.sh` — comment noting DRM is unit-tested (no smoke).

---

### Task 1: `core/drm.zig` — Scheme + label + `scanForDrmMarkers`

**Files:**
- Create: `src/core/drm.zig`
- Modify: `src/root.zig` (`pub const drm = @import("core/drm.zig");` + `_ = drm;`)

**Interfaces:**
- Produces:
```zig
pub const Scheme = enum { none, fairplay, cenc, adept, acsm };
pub fn label(s: Scheme) []const u8;
/// Scan a `moov` (or any) byte slice for MP4 encryption markers.
pub fn scanForDrmMarkers(bytes: []const u8) Scheme;
```

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const t = std.testing;

test "scanForDrmMarkers detects pssh as cenc" {
    try t.expectEqual(Scheme.cenc, scanForDrmMarkers("....pssh....widevine"));
}
test "scanForDrmMarkers detects sinf/drms as fairplay" {
    try t.expectEqual(Scheme.fairplay, scanForDrmMarkers("trak....sinf....drms"));
}
test "scanForDrmMarkers on a plain moov is none" {
    try t.expectEqual(Scheme.none, scanForDrmMarkers("trakmdiaminfstblstsdavc1mp4a"));
}
test "label is human readable" {
    try t.expectEqualStrings("CENC (Widevine/PlayReady)", label(.cenc));
    try t.expectEqualStrings("FairPlay", label(.fairplay));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `scanForDrmMarkers` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
const std = @import("std");

pub const Scheme = enum { none, fairplay, cenc, adept, acsm };

pub fn label(s: Scheme) []const u8 {
    return switch (s) {
        .none => "none",
        .fairplay => "FairPlay",
        .cenc => "CENC (Widevine/PlayReady)",
        .adept => "Adobe ADEPT",
        .acsm => "Adobe ACSM token",
    };
}

fn has(bytes: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, bytes, needle) != null;
}

/// These 4CCs are box/scheme types that only occur in protected MP4
/// `moov`s — scanning `moov` (never `mdat`) makes false positives ~impossible.
pub fn scanForDrmMarkers(bytes: []const u8) Scheme {
    if (has(bytes, "pssh")) return .cenc;
    if (has(bytes, "sinf") or has(bytes, "drms") or has(bytes, "encv") or has(bytes, "enca")) return .fairplay;
    return .none;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/drm.zig src/root.zig
git commit -m "feat(drm): Scheme + label + scanForDrmMarkers"
```

---

### Task 2: `drm.detectVideo` — MP4 box walk

**Files:**
- Modify: `src/core/drm.zig`

**Interfaces:**
- Consumes: `scanForDrmMarkers`.
- Produces: `pub fn detectVideo(alloc: std.mem.Allocator, path: []const u8) Scheme;`

Walk top-level MP4 boxes via C stdio, skipping each box's body with `fseek`
until `moov`; read `moov` (capped) and scan it. Non-MP4 extension → `.none`.

- [ ] **Step 1: Write the failing test**

```zig
fn beU32(v: u32) [4]u8 {
    return .{ @intCast((v >> 24) & 0xff), @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

fn writeMp4(path_z: [:0]const u8, moov_payload: []const u8) void {
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    // ftyp box: size=16, "ftyp", "isom", minor 0
    const ftyp = beU32(16) ++ [_]u8{ 'f', 't', 'y', 'p' } ++ [_]u8{ 'i', 's', 'o', 'm' } ++ beU32(0);
    _ = std.c.fwrite(&ftyp, 1, ftyp.len, fp);
    // moov box: size = 8 + payload
    const hdr = beU32(@intCast(8 + moov_payload.len)) ++ [_]u8{ 'm', 'o', 'o', 'v' };
    _ = std.c.fwrite(&hdr, 1, hdr.len, fp);
    _ = std.c.fwrite(moov_payload.ptr, 1, moov_payload.len, fp);
}

test "detectVideo finds pssh in moov" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var pb: [128]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "/tmp/drm-cenc-{d}.mp4", .{pid}) catch unreachable;
    defer _ = std.c.unlink(pz.ptr);
    writeMp4(pz, "trak....pssh....");
    try t.expectEqual(Scheme.cenc, detectVideo(a, pz));
}

test "detectVideo on a clean mp4 is none" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var pb: [128]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "/tmp/drm-clean-{d}.mp4", .{pid}) catch unreachable;
    defer _ = std.c.unlink(pz.ptr);
    writeMp4(pz, "trakmdiaminfstblstsdavc1");
    try t.expectEqual(Scheme.none, detectVideo(a, pz));
}

test "detectVideo ignores non-mp4 extensions" {
    try t.expectEqual(Scheme.none, detectVideo(t.allocator, "/tmp/whatever.mkv"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `detectVideo` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
const MOOV_CAP: usize = 16 * 1024 * 1024;

fn isMp4Ext(path: []const u8) bool {
    const e = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(e, ".mp4") or std.ascii.eqlIgnoreCase(e, ".m4v") or std.ascii.eqlIgnoreCase(e, ".mov");
}

fn rdU32(b: [*]const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

pub fn detectVideo(alloc: std.mem.Allocator, path: []const u8) Scheme {
    if (!isMp4Ext(path)) return .none;
    var pb: [4096]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "{s}", .{path}) catch return .none;
    const fp = std.c.fopen(pz.ptr, "rb") orelse return .none;
    defer _ = std.c.fclose(fp);

    while (true) {
        var hdr: [16]u8 = undefined;
        if (std.c.fread(&hdr, 1, 8, fp) != 8) break;
        var box_size: u64 = rdU32(&hdr);
        var header_len: u64 = 8;
        if (box_size == 1) {
            if (std.c.fread(hdr[8..].ptr, 1, 8, fp) != 8) break;
            box_size = std.mem.readInt(u64, hdr[8..16], .big);
            header_len = 16;
        }
        const is_moov = std.mem.eql(u8, hdr[4..8], "moov");
        if (is_moov) {
            const want: usize = if (box_size == 0) MOOV_CAP else @intCast(@min(box_size - header_len, MOOV_CAP));
            const buf = alloc.alloc(u8, want) catch return .none;
            defer alloc.free(buf);
            const got = std.c.fread(buf.ptr, 1, buf.len, fp);
            return scanForDrmMarkers(buf[0..got]);
        }
        if (box_size == 0) break; // last box, not moov
        // skip this box's body
        const skip: i64 = @intCast(box_size - header_len);
        if (std.c.fseek(fp, skip, 1) != 0) break; // SEEK_CUR
    }
    return .none;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/drm.zig
git commit -m "feat(drm): detectVideo — MP4 box sniff for FairPlay/CENC"
```

---

### Task 3: `drm.detectEbook` — epub `encryption.xml` + `.acsm`

**Files:**
- Modify: `src/core/drm.zig`

**Interfaces:**
- Consumes: vendored `ffi/miniz.zig` `ZipReader`.
- Produces: `pub fn detectEbook(alloc: std.mem.Allocator, path: []const u8) Scheme;`

- [ ] **Step 1: Write the failing test**

```zig
const zip = @import("../ffi/miniz.zig");

fn makeEpub(path_z: [:0]const u8, with_enc: bool) void {
    var w: zip.ZipWriter = .{};
    w.create(std.mem.span(path_z.ptr)) catch return;
    w.addBytes("mimetype", "application/epub+zip", .none) catch {};
    if (with_enc) w.addBytes("META-INF/encryption.xml", "<encryption/>", .none) catch {};
    w.finalizeAndClose() catch {};
}

test "detectEbook flags an epub with encryption.xml as adept" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var pb: [128]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "/tmp/drm-adept-{d}.epub", .{pid}) catch unreachable;
    defer _ = std.c.unlink(pz.ptr);
    makeEpub(pz, true);
    try t.expectEqual(Scheme.adept, detectEbook(a, std.mem.span(pz.ptr)));
}

test "detectEbook on a plain epub is none" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var pb: [128]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "/tmp/drm-plain-{d}.epub", .{pid}) catch unreachable;
    defer _ = std.c.unlink(pz.ptr);
    makeEpub(pz, false);
    try t.expectEqual(Scheme.none, detectEbook(a, std.mem.span(pz.ptr)));
}

test "detectEbook treats .acsm as a token" {
    try t.expectEqual(Scheme.acsm, detectEbook(t.allocator, "/tmp/book.acsm"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `detectEbook` not defined.

- [ ] **Step 3: Write minimal implementation**

```zig
const zip = @import("../ffi/miniz.zig");

pub fn detectEbook(alloc: std.mem.Allocator, path: []const u8) Scheme {
    const e = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(e, ".acsm")) return .acsm;
    if (std.ascii.eqlIgnoreCase(e, ".epub")) {
        var r: zip.ZipReader = .{};
        r.open(path) catch return .none;
        defer r.close();
        const bytes = r.readMember(alloc, "META-INF/encryption.xml") catch return .none;
        alloc.free(bytes);
        return .adept;
    }
    return .none;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/drm.zig
git commit -m "feat(drm): detectEbook — epub encryption.xml + .acsm"
```

---

### Task 4: `group.zig` — flag DRM videos

**Files:**
- Modify: `src/core/group.zig`

**Interfaces:**
- Consumes: `drm.detectVideo`, `drm.label`.

Currently the per-candidate block is:
```zig
if (do_probe) {
    c.probe = probe.run(arena, io, abs);
    if (mk == .tv) { … mergeTv … } else { … mergeMovie … }
}
```
where `const do_probe = probe_enabled and probe.available(arena, io);`.

Change so DRM detection runs under `probe_enabled` (not ffprobe availability):

```zig
// near the top, replace the single do_probe:
const inspect = probe_enabled;
const ffprobe_ok = probe_enabled and probe.available(arena, io);
```
```zig
// per candidate:
if (inspect) {
    const scheme = drm.detectVideo(arena, abs);
    if (scheme != .none) {
        const wl = try arena.alloc([]const u8, 1);
        wl[0] = try std.fmt.allocPrint(arena, "DRM — {s}", .{drm.label(scheme)});
        c.warnings = wl; // organized by filename fields, no probe, flagged
    } else if (ffprobe_ok) {
        c.probe = probe.run(arena, io, abs);
        if (mk == .tv) { … existing mergeTv … } else { … existing mergeMovie … }
    }
}
```

Add `const drm = @import("drm.zig");` to the imports.

- [ ] **Step 1: Write the failing test**

Add to `group.zig`'s tests (reuse the `mkdirAt`/`unlinkAt` helpers + a raw MP4 writer):

```zig
test "buildPlan flags a DRM video and skips probing" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pid = std.c.getpid();
    var rb: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/stacks-drm-{d}", .{pid});
    mkdirAt("{s}", .{root});

    // minimal MP4 with a pssh marker in moov, named like an episode
    var fb: [400]u8 = undefined;
    const fpath = try std.fmt.bufPrintZ(&fb, "{s}/The.Show.S01E01.mp4", .{root});
    writeDrmMp4(fpath); // helper: ftyp + moov("....pssh....")
    defer _ = std.c.unlink(fpath.ptr);

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE };
    const p = try buildPlan(a, threaded.io(), root, cfg, true); // probe_enabled

    var warned = false;
    var media_present = false;
    for (p.groups) |g| {
        for (g.warnings) |w| if (std.mem.indexOf(u8, w, "DRM") != null) { warned = true; };
        for (g.items) |it| if (it.media != null) { media_present = true; };
    }
    try t.expect(warned);
    try t.expect(!media_present); // DRM file wasn't probed

    rmdirAt("{s}", .{root});
}
```

Add a `writeDrmMp4(path_z)` helper next to the existing fixture helpers that writes `ftyp` + a `moov` box containing `"pssh"` (mirror the Task 2 `writeMp4` shape).

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — arity (`buildPlan` still fine) or no DRM warning (imports/wiring absent).

- [ ] **Step 3: Write minimal implementation**

Apply the import + `inspect`/`ffprobe_ok` + per-candidate changes above.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/core/group.zig
git commit -m "feat(shelve): flag DRM videos in organize (no probe, warned)"
```

---

### Task 5: `biblio` — surface ebook DRM in `info` + `scan`

**Files:**
- Modify: `src/commands/info.zig`, `src/commands/scan.zig`

**Interfaces:**
- Consumes: `drm.detectEbook`, `drm.label`.

- [ ] **Step 1: Wire `info.zig`**

Add `const drm = @import("../core/drm.zig");`. In `run`, after `try printMetadata(...)`:

```zig
    const scheme = drm.detectEbook(ctx.arena, path);
    if (scheme != .none) try ctx.stdout.print("DRM:         {s}\n", .{drm.label(scheme)});
    return 0;
```

- [ ] **Step 2: Wire `scan.zig`**

Add `const drm = @import("../core/drm.zig");`. Extend the counters struct with `drm: u32 = 0`. In the walk loop, after `const fmt = meta.Format.fromExtension(ext[1..]);` and the `fmt == .unknown` skip, add:

```zig
        if (drm.detectEbook(ctx.arena, full_path) != .none) counters.drm += 1;
```

(Place it after `full_path` is computed.) Add `drm={d}` to the summary print:

```zig
    try ctx.stdout.print(
        "\nseen={d} ingested={d} unchanged={d} drm={d} errors={d}\n",
        .{ counters.seen, counters.ingested, counters.skipped, counters.drm, counters.errors },
    );
```

- [ ] **Step 3: Build + verify by hand**

Run:
```bash
zig build
# a plain epub fixture reports no DRM line:
./zig-out/bin/biblio info tests/fixtures/epub/*.epub 2>/dev/null | grep -c "DRM:" || true   # expect 0
```
Expected: builds; a normal epub shows no `DRM:` line (0).

- [ ] **Step 4: Run the suite**

Run: `zig build test && ./scripts/smoke.sh --offline`
Expected: unit + biblio smoke green (scan summary now includes `drm=0`).

- [ ] **Step 5: Commit**

```bash
git add src/commands/info.zig src/commands/scan.zig
git commit -m "feat(biblio): report ebook DRM in info + scan"
```

---

### Task 6: Verification + smoke note

**Files:**
- Modify: `scripts/organize-smoke.sh` (comment only)

- [ ] **Step 1: Add a note in the smoke script**

Near the probe block, add a comment:

```bash
# DRM detection has no smoke here: a real protected file can't be generated
# portably. It's covered by unit tests (core/drm.zig) with synthetic MP4/zip
# fixtures and a group-level DRM test.
```

- [ ] **Step 2: Full verification**

Run:
```bash
rm -rf .zig-cache zig-out && zig build && zig build test && ./scripts/smoke.sh --offline && ./scripts/organize-smoke.sh
```
Expected: clean build (biblio + shelve), unit tests, both smokes all green.

- [ ] **Step 3: Commit**

```bash
git add scripts/organize-smoke.sh
git commit -m "docs(test): note DRM detection is unit-tested, not smoked"
```

---

## Self-Review

**Spec coverage:**
- Shared `core/drm.zig` with `Scheme`/`label`/`scanForDrmMarkers`/`detectVideo`/`detectEbook` → Tasks 1–3. ✓
- MP4 FairPlay/CENC via box sniff (pssh→cenc, sinf/drms/encv/enca→fairplay) → Tasks 1–2. ✓
- Ebook ADEPT (epub `encryption.xml`) + `.acsm` → Task 3. ✓
- shelve: DRM video organized-but-flagged, no probe → Task 4. ✓
- biblio: `info` line + `scan` count → Task 5. ✓
- `--no-probe` skips DRM detection (shared `probe_enabled` gate); ffprobe absence does not → Task 4. ✓
- Total detectors, no false positive / crash on odd files → Tasks 1–3 (extension gate, `catch return .none`, scan only `moov`). ✓
- Testing via synthetic MP4/zip fixtures, no smoke → Tasks 2–4, 6. ✓
- **Deferred per spec:** Matroska (`detectVideo` → `.none` for non-MP4), Kindle (`detectEbook` → `.none`), DRM removal.

**Placeholder scan:** Task 4/5 reference "existing mergeTv/mergeMovie" and "reuse mkdirAt/unlinkAt/rmdirAt helpers" — those are concrete, currently-present code in the same files the implementer edits (in view), not hidden work. No "TBD"/"handle edge cases".

**Type consistency:** `Scheme` (Task 1) used by `scanForDrmMarkers`/`detectVideo`/`detectEbook` (1–3) and `label` throughout; `detectVideo(alloc, path)` / `detectEbook(alloc, path)` signatures consistent between definition (2–3) and callers (group Task 4, info/scan Task 5). `buildPlan(..., probe_enabled)` unchanged from Phase 1.5. `counters.drm` defined and printed in the same task (5).
