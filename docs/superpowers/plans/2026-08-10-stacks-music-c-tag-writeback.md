# Music C — Native Tag Write-back Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write corrected metadata — with **multi-value ARTIST** so a track lists under each artist — into FLAC (Vorbis comments) and MP3 (ID3v2.4) files. Opt-in, crash-safe (temp + atomic rename), reversible (backup + `shelve undo`). Consumes the shared `Plan.Fields` (works offline from A's `splitArtists`; richer with B's canonical data + MBIDs).

**Architecture:** New `kinds/music_tags.zig` builds tag bytes purely (`buildId3v24`, `buildFlac`, `buildMp3`) and writes via `writeTags` (temp + atomic rename, `std.c` file ops). `apply` gains an opt-in tag-write step that backs up each file and records a new `journal` `tagwrite` entry; `undo` restores from backup. `Fields` is the only data source.

**Tech Stack:** Zig 0.16, `std.c` file ops, `std.crypto`-free byte assembly. No new deps. (Depends on Music B for MBIDs, but works without B.)

## Global Constraints

- Zig 0.16 only. `writeTags`/backup use `std.c` (`fopen`/`fread`/`fwrite`/`rename`), matching `apply.zig`/`journal.zig`.
- **Never** an in-place mutation: always temp file + atomic `rename`; never write without a restorable backup.
- Off by default. Enabled only by `--write-tags` (flag) or config `write_tags = on`. Flag beats config.
- FLAC + MP3 only; other extensions skipped with a warning. Audio bytes are copied verbatim (no re-encode).
- Multi-value: FLAC = multiple `ARTIST=` comments; MP3 = ID3v2.4 `TPE1` with `0x00`-separated values, UTF-8 (`0x03`).
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Build `zig build`; test `zig build test`; smoke `./scripts/tag-smoke.sh`.

## File Structure

- `src/kinds/music_tags.zig` (new) — `TagSet`, `buildId3v24`, `buildMp3`, `buildFlac`, `writeTags`, test-only parsers. (T1–T3)
- `src/core/journal.zig` — `Action` gains `.tagwrite`. (T4)
- `src/core/config.zig` — `Config.write_tags`. (T4)
- `src/core/apply.zig` — opt-in backup+write+journal; `undo` restore. (T5)
- `src/commands/organize.zig`, `src/commands/review.zig`, `src/web/*` — `--write-tags`/config plumbing + apply output. (T6)
- `scripts/tag-smoke.sh`, docs, `todo.md`, memory. (T6)

---

## Task 1: music_tags — ID3v2.4 builder (multi-value TPE1)

**Files:**
- Create: `src/kinds/music_tags.zig`
- Test: `src/kinds/music_tags.zig`

**Interfaces:**
- Produces: `TagSet` struct; `pub fn buildId3v24(alloc, tags: TagSet) ![]u8`; test-only `pub fn readTextValues(alloc, tag: []const u8, frame_id: [4]u8) !?[]const []const u8`.

- [ ] **Step 1: Write failing tests**

Create `src/kinds/music_tags.zig`:

```zig
const std = @import("std");

// ... TagSet + builders (Steps 3+) ...

const t = std.testing;

test "buildId3v24 emits multi-value TPE1 that round-trips" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags = TagSet{
        .title = "Layla",
        .artists = &.{ "Eric Clapton", "Duane Allman" },
        .album_artist = "Derek and the Dominos",
        .album = "Layla",
        .track = 1, .disc = 1, .year = 1970,
        .release_mbid = "rel-x",
    };
    const tag = try buildId3v24(a, tags);
    // header
    try t.expectEqualStrings("ID3", tag[0..3]);
    try t.expectEqual(@as(u8, 4), tag[3]);
    // TPE1 multi-value
    const artists = (try readTextValues(a, tag, "TPE1".*)).?;
    try t.expectEqual(@as(usize, 2), artists.len);
    try t.expectEqualStrings("Eric Clapton", artists[0]);
    try t.expectEqualStrings("Duane Allman", artists[1]);
    // single-value frames
    try t.expectEqualStrings("Layla", (try readTextValues(a, tag, "TIT2".*)).?[0]);
    try t.expectEqualStrings("1970", (try readTextValues(a, tag, "TDRC".*)).?[0]);
    try t.expectEqualStrings("Derek and the Dominos", (try readTextValues(a, tag, "TPE2".*)).?[0]);
}

test "buildId3v24 with no artists omits TPE1" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tag = try buildId3v24(a, .{ .title = "X", .album = "Y" });
    try t.expect((try readTextValues(a, tag, "TPE1".*)) == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `TagSet`/`buildId3v24`/`readTextValues` undefined.

- [ ] **Step 3: TagSet + synchsafe + frame builders**

Add to `src/kinds/music_tags.zig`:

```zig
pub const TagSet = struct {
    title: ?[]const u8 = null,
    artists: []const []const u8 = &.{},
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
    year: ?u32 = null,
    release_mbid: ?[]const u8 = null,
    recording_mbid: ?[]const u8 = null,
};

pub const Error = error{ UnsupportedFormat, MalformedFile, OutOfMemory, IoError };

/// Encode `n` as a 4-byte synchsafe integer (7 bits per byte), big-endian.
fn synchsafe(n: u32) [4]u8 {
    return .{
        @intCast((n >> 21) & 0x7f),
        @intCast((n >> 14) & 0x7f),
        @intCast((n >> 7) & 0x7f),
        @intCast(n & 0x7f),
    };
}
fn desynchsafe(b: []const u8) u32 {
    return (@as(u32, b[0]) << 21) | (@as(u32, b[1]) << 14) | (@as(u32, b[2]) << 7) | @as(u32, b[3]);
}

/// Append one ID3v2.4 text frame. `values` joined by 0x00 (multi-value),
/// encoding byte 0x03 (UTF-8). No-op when values is empty.
fn appendTextFrame(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: [4]u8, values: []const []const u8) !void {
    if (values.len == 0) return;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try payload.append(alloc, 0x03); // UTF-8
    for (values, 0..) |v, i| {
        if (i > 0) try payload.append(alloc, 0x00);
        try payload.appendSlice(alloc, v);
    }
    try out.appendSlice(alloc, &id);
    try out.appendSlice(alloc, &synchsafe(@intCast(payload.items.len)));
    try out.appendSlice(alloc, &[_]u8{ 0, 0 }); // flags
    try out.appendSlice(alloc, payload.items);
}

/// A TXXX frame: 0x03 + description + 0x00 + value.
fn appendTxxx(alloc: std.mem.Allocator, out: *std.ArrayList(u8), desc: []const u8, value: []const u8) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try payload.append(alloc, 0x03);
    try payload.appendSlice(alloc, desc);
    try payload.append(alloc, 0x00);
    try payload.appendSlice(alloc, value);
    try out.appendSlice(alloc, "TXXX");
    try out.appendSlice(alloc, &synchsafe(@intCast(payload.items.len)));
    try out.appendSlice(alloc, &[_]u8{ 0, 0 });
    try out.appendSlice(alloc, payload.items);
}
```

- [ ] **Step 4: buildId3v24 + readTextValues**

```zig
pub fn buildId3v24(alloc: std.mem.Allocator, tags: TagSet) ![]u8 {
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);

    try appendTextFrame(alloc, &frames, "TPE1".*, tags.artists);
    if (tags.title) |v| try appendTextFrame(alloc, &frames, "TIT2".*, &.{v});
    if (tags.album) |v| try appendTextFrame(alloc, &frames, "TALB".*, &.{v});
    if (tags.album_artist) |v| try appendTextFrame(alloc, &frames, "TPE2".*, &.{v});
    if (tags.year) |y| {
        const s = try std.fmt.allocPrint(alloc, "{d}", .{y});
        defer alloc.free(s);
        try appendTextFrame(alloc, &frames, "TDRC".*, &.{s});
    }
    if (tags.track) |n| {
        const s = try std.fmt.allocPrint(alloc, "{d}", .{n});
        defer alloc.free(s);
        try appendTextFrame(alloc, &frames, "TRCK".*, &.{s});
    }
    if (tags.disc) |n| {
        const s = try std.fmt.allocPrint(alloc, "{d}", .{n});
        defer alloc.free(s);
        try appendTextFrame(alloc, &frames, "TPOS".*, &.{s});
    }
    if (tags.release_mbid) |v| try appendTxxx(alloc, &frames, "MusicBrainz Album Id", v);
    if (tags.recording_mbid) |v| try appendTxxx(alloc, &frames, "MusicBrainz Release Track Id", v);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "ID3");
    try out.appendSlice(alloc, &[_]u8{ 0x04, 0x00, 0x00 }); // v2.4, no flags
    try out.appendSlice(alloc, &synchsafe(@intCast(frames.items.len)));
    try out.appendSlice(alloc, frames.items);
    return out.toOwnedSlice(alloc);
}

/// Test/util: return the values of the first frame `frame_id` in an ID3v2.4
/// tag, splitting a text payload on 0x00. Null when the frame is absent.
pub fn readTextValues(alloc: std.mem.Allocator, tag: []const u8, frame_id: [4]u8) !?[]const []const u8 {
    if (tag.len < 10 or !std.mem.eql(u8, tag[0..3], "ID3")) return null;
    const tag_size = desynchsafe(tag[6..10]);
    var i: usize = 10;
    const end = @min(tag.len, 10 + tag_size);
    while (i + 10 <= end) {
        const id = tag[i .. i + 4];
        const size = desynchsafe(tag[i + 4 .. i + 8]);
        const payload_start = i + 10;
        if (payload_start + size > end) break;
        if (std.mem.eql(u8, id, &frame_id)) {
            const payload = tag[payload_start .. payload_start + size];
            if (payload.len < 1) return &.{};
            const text = payload[1..]; // skip encoding byte
            var vals: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, text, 0x00);
            while (it.next()) |v| if (v.len > 0) try vals.append(alloc, try alloc.dupe(u8, v));
            return try vals.toOwnedSlice(alloc);
        }
        if (id[0] == 0) break; // padding
        i = payload_start + size;
    }
    return null;
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | tail -6`
Expected: PASS. Register the file in `src/root.zig`'s test aggregator (alongside `kinds/music.zig`).

- [ ] **Step 6: Commit**

```bash
git add src/kinds/music_tags.zig src/root.zig
git commit -m "feat(music-c): ID3v2.4 builder with multi-value TPE1

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: music_tags — FLAC Vorbis-comment rewrite

**Files:**
- Modify: `src/kinds/music_tags.zig`
- Test: `src/kinds/music_tags.zig`

**Interfaces:**
- Produces: `pub fn buildFlac(alloc, original: []const u8, tags: TagSet) Error![]u8`; test-only `pub fn readVorbisValues(alloc, flac: []const u8, key: []const u8) !?[]const []const u8`.

- [ ] **Step 1: Write failing test (build a synthetic FLAC, rewrite, re-read)**

Add:

```zig
// Minimal synthetic FLAC: "fLaC" + STREAMINFO(last=0) + VORBIS_COMMENT(last=1) + fake audio.
fn synthFlac(alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "fLaC");
    // STREAMINFO: type 0, not last, length 34 (content zeroed).
    try out.append(alloc, 0x00);
    try out.appendSlice(alloc, &.{ 0x00, 0x00, 0x22 });
    try out.appendNTimes(alloc, 0x00, 34);
    // VORBIS_COMMENT: type 4, last-block, one ARTIST=Old comment.
    var vc: std.ArrayList(u8) = .empty;
    defer vc.deinit(alloc);
    const vendor = "old";
    try vc.appendSlice(alloc, &le32(vendor.len));
    try vc.appendSlice(alloc, vendor);
    try vc.appendSlice(alloc, &le32(1));
    const c0 = "ARTIST=Old";
    try vc.appendSlice(alloc, &le32(c0.len));
    try vc.appendSlice(alloc, c0);
    try out.append(alloc, 0x84); // last-block flag (0x80) | type 4
    try out.appendSlice(alloc, &.{ @intCast((vc.items.len >> 16) & 0xff), @intCast((vc.items.len >> 8) & 0xff), @intCast(vc.items.len & 0xff) });
    try out.appendSlice(alloc, vc.items);
    try out.appendSlice(alloc, "AUDIOFRAMESHERE");
    return out.toOwnedSlice(alloc);
}

test "buildFlac replaces VORBIS_COMMENT with multi ARTIST, keeps audio" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const orig = try synthFlac(a);
    const out = try buildFlac(a, orig, .{ .artists = &.{ "A", "B" }, .album = "Alb", .title = "T", .track = 3, .year = 2001 });
    try t.expectEqualStrings("fLaC", out[0..4]);
    const artists = (try readVorbisValues(a, out, "ARTIST")).?;
    try t.expectEqual(@as(usize, 2), artists.len);
    try t.expectEqualStrings("A", artists[0]);
    try t.expectEqualStrings("B", artists[1]);
    try t.expectEqualStrings("Alb", (try readVorbisValues(a, out, "ALBUM")).?[0]);
    // audio frames preserved verbatim at the tail
    try t.expect(std.mem.endsWith(u8, out, "AUDIOFRAMESHERE"));
}
```

Add the `le32` helper near the top:

```zig
fn le32(n: usize) [4]u8 {
    return .{ @intCast(n & 0xff), @intCast((n >> 8) & 0xff), @intCast((n >> 16) & 0xff), @intCast((n >> 24) & 0xff) };
}
fn rd_le32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `buildFlac`/`readVorbisValues` undefined.

- [ ] **Step 3: Implement buildFlac**

```zig
/// Build a new FLAC file: keep every metadata block except VORBIS_COMMENT,
/// append a fresh VORBIS_COMMENT built from `tags`, then the original audio
/// frames verbatim. Returns Error.MalformedFile on a bad marker/blocks.
pub fn buildFlac(alloc: std.mem.Allocator, original: []const u8, tags: TagSet) Error![]u8 {
    if (original.len < 4 or !std.mem.eql(u8, original[0..4], "fLaC")) return Error.MalformedFile;

    // Collect kept blocks (type,data) and find where audio starts.
    const KeptBlock = struct { btype: u8, data: []const u8 };
    var kept: std.ArrayList(KeptBlock) = .empty;
    defer kept.deinit(alloc);

    var i: usize = 4;
    while (true) {
        if (i + 4 > original.len) return Error.MalformedFile;
        const header = original[i];
        const is_last = (header & 0x80) != 0;
        const btype = header & 0x7f;
        const len = (@as(usize, original[i + 1]) << 16) | (@as(usize, original[i + 2]) << 8) | @as(usize, original[i + 3]);
        const data_start = i + 4;
        if (data_start + len > original.len) return Error.MalformedFile;
        if (btype != 4) { // drop existing VORBIS_COMMENT (type 4)
            kept.append(alloc, .{ .btype = btype, .data = original[data_start .. data_start + len] }) catch return Error.OutOfMemory;
        }
        i = data_start + len;
        if (is_last) break;
    }
    const audio = original[i..];

    // Build the VORBIS_COMMENT payload.
    var vc: std.ArrayList(u8) = .empty;
    defer vc.deinit(alloc);
    const vendor = "stacks";
    vc.appendSlice(alloc, &le32(vendor.len)) catch return Error.OutOfMemory;
    vc.appendSlice(alloc, vendor) catch return Error.OutOfMemory;

    var comments: std.ArrayList([]const u8) = .empty;
    defer {
        for (comments.items) |c| alloc.free(c);
        comments.deinit(alloc);
    }
    const addC = struct {
        fn f(al: std.mem.Allocator, list: *std.ArrayList([]const u8), key: []const u8, val: []const u8) !void {
            try list.append(al, try std.fmt.allocPrint(al, "{s}={s}", .{ key, val }));
        }
    }.f;
    for (tags.artists) |ar| addC(alloc, &comments, "ARTIST", ar) catch return Error.OutOfMemory;
    if (tags.album_artist) |v| addC(alloc, &comments, "ALBUMARTIST", v) catch return Error.OutOfMemory;
    if (tags.album) |v| addC(alloc, &comments, "ALBUM", v) catch return Error.OutOfMemory;
    if (tags.title) |v| addC(alloc, &comments, "TITLE", v) catch return Error.OutOfMemory;
    if (tags.year) |y| {
        const s = std.fmt.allocPrint(alloc, "{d}", .{y}) catch return Error.OutOfMemory;
        defer alloc.free(s);
        addC(alloc, &comments, "DATE", s) catch return Error.OutOfMemory;
    }
    if (tags.track) |n| {
        const s = std.fmt.allocPrint(alloc, "{d}", .{n}) catch return Error.OutOfMemory;
        defer alloc.free(s);
        addC(alloc, &comments, "TRACKNUMBER", s) catch return Error.OutOfMemory;
    }
    if (tags.disc) |n| {
        const s = std.fmt.allocPrint(alloc, "{d}", .{n}) catch return Error.OutOfMemory;
        defer alloc.free(s);
        addC(alloc, &comments, "DISCNUMBER", s) catch return Error.OutOfMemory;
    }
    if (tags.release_mbid) |v| addC(alloc, &comments, "MUSICBRAINZ_ALBUMID", v) catch return Error.OutOfMemory;
    if (tags.recording_mbid) |v| addC(alloc, &comments, "MUSICBRAINZ_TRACKID", v) catch return Error.OutOfMemory;

    vc.appendSlice(alloc, &le32(comments.items.len)) catch return Error.OutOfMemory;
    for (comments.items) |c| {
        vc.appendSlice(alloc, &le32(c.len)) catch return Error.OutOfMemory;
        vc.appendSlice(alloc, c) catch return Error.OutOfMemory;
    }

    // Emit: marker + kept blocks (all non-last) + VORBIS_COMMENT (last) + audio.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    out.appendSlice(alloc, "fLaC") catch return Error.OutOfMemory;
    for (kept.items) |b| {
        out.append(alloc, b.btype & 0x7f) catch return Error.OutOfMemory; // not last
        out.appendSlice(alloc, &.{ @intCast((b.data.len >> 16) & 0xff), @intCast((b.data.len >> 8) & 0xff), @intCast(b.data.len & 0xff) }) catch return Error.OutOfMemory;
        out.appendSlice(alloc, b.data) catch return Error.OutOfMemory;
    }
    out.append(alloc, 0x84) catch return Error.OutOfMemory; // last-block | type 4
    out.appendSlice(alloc, &.{ @intCast((vc.items.len >> 16) & 0xff), @intCast((vc.items.len >> 8) & 0xff), @intCast(vc.items.len & 0xff) }) catch return Error.OutOfMemory;
    out.appendSlice(alloc, vc.items) catch return Error.OutOfMemory;
    out.appendSlice(alloc, audio) catch return Error.OutOfMemory;
    return out.toOwnedSlice(alloc);
}

/// Test/util: values of `key` (e.g. "ARTIST") in a FLAC's VORBIS_COMMENT.
pub fn readVorbisValues(alloc: std.mem.Allocator, flac: []const u8, key: []const u8) !?[]const []const u8 {
    if (flac.len < 4 or !std.mem.eql(u8, flac[0..4], "fLaC")) return null;
    var i: usize = 4;
    while (true) {
        if (i + 4 > flac.len) return null;
        const header = flac[i];
        const is_last = (header & 0x80) != 0;
        const btype = header & 0x7f;
        const len = (@as(usize, flac[i + 1]) << 16) | (@as(usize, flac[i + 2]) << 8) | @as(usize, flac[i + 3]);
        const ds = i + 4;
        if (ds + len > flac.len) return null;
        if (btype == 4) {
            const blk = flac[ds .. ds + len];
            var p: usize = 0;
            const vlen = rd_le32(blk[p .. p + 4]);
            p += 4 + vlen;
            const count = rd_le32(blk[p .. p + 4]);
            p += 4;
            var vals: std.ArrayList([]const u8) = .empty;
            var n: u32 = 0;
            while (n < count) : (n += 1) {
                const clen = rd_le32(blk[p .. p + 4]);
                p += 4;
                const comment = blk[p .. p + clen];
                p += clen;
                if (std.mem.indexOfScalar(u8, comment, '=')) |eq| {
                    if (std.ascii.eqlIgnoreCase(comment[0..eq], key)) {
                        try vals.append(alloc, try alloc.dupe(u8, comment[eq + 1 ..]));
                    }
                }
            }
            return try vals.toOwnedSlice(alloc);
        }
        i = ds + len;
        if (is_last) break;
    }
    return null;
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test 2>&1 | tail -6`
Expected: PASS (multi-ARTIST + audio preserved).

- [ ] **Step 5: Commit**

```bash
git add src/kinds/music_tags.zig
git commit -m "feat(music-c): FLAC VORBIS_COMMENT rewrite (multi ARTIST, audio verbatim)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: music_tags — buildMp3 + writeTags dispatch

**Files:**
- Modify: `src/kinds/music_tags.zig`
- Test: `src/kinds/music_tags.zig`

**Interfaces:**
- Produces: `pub fn buildMp3(alloc, original: []const u8, tags: TagSet) Error![]u8`; `pub fn writeTags(alloc, path: []const u8, tags: TagSet) Error!void`.

- [ ] **Step 1: Write failing tests**

```zig
test "buildMp3 prepends a new ID3 tag and keeps audio" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // original with no ID3 tag: just fake audio.
    const orig = "\xff\xfbFAKEMP3AUDIO";
    const out = try buildMp3(a, orig, .{ .artists = &.{ "A", "B" }, .title = "T" });
    try t.expectEqualStrings("ID3", out[0..3]);
    const artists = (try readTextValues(a, out, "TPE1".*)).?;
    try t.expectEqual(@as(usize, 2), artists.len);
    try t.expect(std.mem.endsWith(u8, out, "FAKEMP3AUDIO"));
}

test "buildMp3 replaces an existing ID3 tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try buildId3v24(a, .{ .title = "Old" });
    const orig = try std.mem.concat(a, u8, &.{ old, "\xff\xfbAUDIO" });
    const out = try buildMp3(a, orig, .{ .title = "New" });
    try t.expectEqualStrings("New", (try readTextValues(a, out, "TIT2".*)).?[0]);
    try t.expect(std.mem.endsWith(u8, out, "AUDIO"));
}

test "writeTags round-trips a temp file and rejects unsupported ext" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pid = std.c.getpid();
    var pb: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "/tmp/stacks-tags-{d}.flac", .{pid});
    // seed a synthetic flac on disk
    const orig = try synthFlac(a);
    writeWhole(path, orig);
    try writeTags(a, path, .{ .artists = &.{ "A", "B" }, .album = "Z" });
    const back = readWhole(a, path).?;
    const artists = (try readVorbisValues(a, back, "ARTIST")).?;
    try t.expectEqual(@as(usize, 2), artists.len);
    var pz: [256]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch unreachable).ptr);

    var xb: [256]u8 = undefined;
    const xpath = try std.fmt.bufPrint(&xb, "/tmp/stacks-tags-{d}.m4a", .{pid});
    writeWhole(xpath, "junk");
    try t.expectError(Error.UnsupportedFormat, writeTags(a, xpath, .{}));
    _ = std.c.unlink((std.fmt.bufPrintZ(&pz, "{s}", .{xpath}) catch unreachable).ptr);
}
```

Add test IO helpers (used only in tests):

```zig
fn writeWhole(path: []const u8, bytes: []const u8) void {
    var pz: [4096]u8 = undefined;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    const fp = std.c.fopen(pzp.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    if (bytes.len > 0) _ = std.c.fwrite(bytes.ptr, 1, bytes.len, fp);
}
fn readWhole(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pz: [4096]u8 = undefined;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
    const fp = std.c.fopen(pzp.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        buf.appendSlice(alloc, chunk[0..n]) catch return null;
    }
    return buf.toOwnedSlice(alloc) catch null;
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `buildMp3`/`writeTags` undefined.

- [ ] **Step 3: buildMp3**

```zig
/// Build a new MP3: fresh ID3v2.4 tag (from `tags`) + original audio (after
/// any existing leading ID3 tag).
pub fn buildMp3(alloc: std.mem.Allocator, original: []const u8, tags: TagSet) Error![]u8 {
    var audio_start: usize = 0;
    if (original.len >= 10 and std.mem.eql(u8, original[0..3], "ID3")) {
        const size = desynchsafe(original[6..10]);
        audio_start = @min(original.len, 10 + size);
    }
    const new_tag = buildId3v24(alloc, tags) catch return Error.OutOfMemory;
    defer alloc.free(new_tag);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    out.appendSlice(alloc, new_tag) catch return Error.OutOfMemory;
    out.appendSlice(alloc, original[audio_start..]) catch return Error.OutOfMemory;
    return out.toOwnedSlice(alloc);
}
```

- [ ] **Step 4: writeTags (dispatch + temp + atomic rename)**

```zig
/// Write `tags` into `path` by extension (.flac / .mp3). Reads the whole
/// file, rebuilds it, writes to `path.tmp`, then atomically renames over the
/// original. Never mutates in place. Unsupported ext → Error.UnsupportedFormat.
pub fn writeTags(alloc: std.mem.Allocator, path: []const u8, tags: TagSet) Error!void {
    const ext = std.fs.path.extension(path);
    const is_flac = std.ascii.eqlIgnoreCase(ext, ".flac");
    const is_mp3 = std.ascii.eqlIgnoreCase(ext, ".mp3");
    if (!is_flac and !is_mp3) return Error.UnsupportedFormat;

    const original = readWhole(alloc, path) orelse return Error.IoError;
    defer alloc.free(original);
    const rebuilt = if (is_flac) try buildFlac(alloc, original, tags) else try buildMp3(alloc, original, tags);
    defer alloc.free(rebuilt);

    const tmp = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return Error.OutOfMemory;
    defer alloc.free(tmp);
    if (!writeWholeChecked(tmp, rebuilt)) return Error.IoError;

    var tz: [4096]u8 = undefined;
    var pz: [4096]u8 = undefined;
    if (tmp.len >= tz.len or path.len >= pz.len) return Error.IoError;
    const tzp = std.fmt.bufPrintZ(&tz, "{s}", .{tmp}) catch return Error.IoError;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return Error.IoError;
    if (std.c.rename(tzp.ptr, pzp.ptr) != 0) {
        _ = std.c.unlink(tzp.ptr);
        return Error.IoError;
    }
}

fn writeWholeChecked(path: []const u8, bytes: []const u8) bool {
    var pz: [4096]u8 = undefined;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return false;
    const fp = std.c.fopen(pzp.ptr, "wb") orelse return false;
    defer _ = std.c.fclose(fp);
    if (bytes.len == 0) return true;
    return std.c.fwrite(bytes.ptr, 1, bytes.len, fp) == bytes.len;
}
```

Promote the test helper `readWhole` to a non-test `fn` (used by `writeTags`); keep `writeWhole` for tests. (Both are file-local.)

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | tail -6`
Expected: PASS (mp3 build both branches; writeTags flac round-trip; unsupported ext error).

- [ ] **Step 6: Commit**

```bash
git add src/kinds/music_tags.zig
git commit -m "feat(music-c): buildMp3 + writeTags (temp file + atomic rename)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: journal tagwrite entry + config write_tags

**Files:**
- Modify: `src/core/journal.zig` (`Action`)
- Modify: `src/core/config.zig` (`Config.write_tags`)
- Test: `src/core/journal.zig`, `src/core/config.zig`

**Interfaces:**
- Produces: `journal.Action` gains `.tagwrite` (Entry `from`=target path, `to`=backup path); `Config.write_tags: bool = false`.

- [ ] **Step 1: Write failing tests**

Add to `src/core/journal.zig`:

```zig
test "journal round-trips a tagwrite entry" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var db: [256]u8 = undefined;
    const d = try std.fmt.bufPrint(&db, "/tmp/stacks-jtw-{d}", .{pid});
    var entries = [_]Entry{.{ .action = .tagwrite, .from = "/lib/a.flac", .to = "/backup/1/a.flac" }};
    const j = Journal{ .created = 7, .entries = entries[0..] };
    const jpath = try writeTo(a, d, j);
    defer a.free(jpath);
    const loaded = try load(a, jpath);
    defer freeOwned(a, loaded);
    try t.expectEqual(Action.tagwrite, loaded.entries[0].action);
    try t.expectEqualStrings("/backup/1/a.flac", loaded.entries[0].to);
    var pz: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&pz, "{s}", .{jpath}) catch unreachable).ptr);
    _ = std.c.unlink((std.fmt.bufPrintZ(&pz, "{s}/latest", .{d}) catch unreachable).ptr);
    _ = std.c.rmdir((std.fmt.bufPrintZ(&pz, "{s}", .{d}) catch unreachable).ptr);
}
```

Add to `src/core/config.zig`:

```zig
test "parseLines reads write_tags toggle" {
    const a = t.allocator;
    const cfg = try parseLines(a, "write_tags = on");
    defer freeConfig(a, cfg);
    try t.expect(cfg.write_tags);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — no `.tagwrite`; `Config` has no `write_tags`.

- [ ] **Step 3: Add `.tagwrite`**

In `src/core/journal.zig`:

```zig
pub const Action = enum { move, trash, tagwrite };
```

- [ ] **Step 4: Add `write_tags` config**

In `src/core/config.zig`: add `write_tags: bool = false` to `Config` (after the musicbrainz fields if Music B landed, else after the templates); add a `var write_tags: ?[]const u8 = null;` local, the key branch `else if (std.mem.eql(u8, key, "write_tags")) write_tags = val;`, compute `const wt = if (write_tags) |v| (std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) else false;`, and add `.write_tags = wt` to the return literal. (`freeConfig` needs no change — bool.)

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | tail -6`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/core/journal.zig src/core/config.zig
git commit -m "feat(music-c): journal tagwrite action + config write_tags

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: apply — opt-in backup + write + undo restore

**Files:**
- Modify: `src/core/apply.zig`
- Test: `src/core/apply.zig`

**Interfaces:**
- Consumes: `music_tags.writeTags`, `journal.Action.tagwrite`, `plan.Fields`.
- Produces: `applyInMemory(alloc, p, on_conflict, tag_opts: TagOpts)`; `TagOpts{ write: bool = false, backup_dir: ?[]const u8 = null }`; `apply(...)` derives `backup_dir` from XDG; `undo` handles `.tagwrite`.

- [ ] **Step 1: Write failing test (apply writes tags, undo restores bytes)**

Add to `src/core/apply.zig`:

```zig
test "apply writes tags with backup and undo restores original bytes" {
    const a = t.allocator;
    const pid = std.c.getpid();
    const mt = @import("../kinds/music_tags.zig");

    var srcb: [256]u8 = undefined;
    const src = try std.fmt.bufPrint(&srcb, "/tmp/stacks-tw-{d}-src.flac", .{pid});
    var outdirb: [256]u8 = undefined;
    const outdir = try std.fmt.bufPrint(&outdirb, "/tmp/stacks-tw-{d}-out", .{pid});
    var dstb: [320]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dstb, "{s}/A - Album/01 - T.flac", .{outdir});
    var bkb: [256]u8 = undefined;
    const backup_dir = try std.fmt.bufPrint(&bkb, "/tmp/stacks-tw-{d}-bak", .{pid});

    // seed a synthetic flac with a single ARTIST
    const orig = try mt.buildFlac(a, try mt.synthFlacForTest(a), .{ .artists = &.{"Solo"}, .album = "Old" });
    defer a.free(orig);
    var sz: [256]u8 = undefined;
    writeFile(try std.fmt.bufPrintZ(&sz, "{s}", .{src}), orig);

    var items = [_]plan.Item{.{
        .src = src, .role = .primary, .op = .move, .dst = dst, .reason = "",
        .fields = .{ .album_artist = "A", .album = "Album", .title = "T", .track = 1, .artists = &.{ "A", "B" }, .ext = "flac" },
    }};
    var groups = [_]plan.Group{.{ .kind = .music, .title = "Album", .items = items[0..] }};
    const p = plan.Plan{ .library_root = "/tmp", .source = "/tmp", .groups = groups[0..] };

    const out = try applyInMemory(a, p, .skip, .{ .write = true, .backup_dir = backup_dir });
    defer journal.freeOwned(a, out.journal);
    try t.expect(exists(dst));
    // dst now has two ARTIST values
    const back = readBytes(a, dst).?;
    defer a.free(back);
    const artists = (try mt.readVorbisValues(a, back, "ARTIST")).?;
    try t.expectEqual(@as(usize, 2), artists.len);

    try undo(a, out.journal);
    try t.expect(exists(src));
    const restored = readBytes(a, src).?;
    defer a.free(restored);
    try t.expectEqualSlices(u8, orig, restored); // byte-identical original

    // cleanup (best-effort)
    var z: [512]u8 = undefined;
    _ = std.c.unlink((std.fmt.bufPrintZ(&z, "{s}", .{src}) catch unreachable).ptr);
}
```

Add a small `readBytes` helper in the test area of `apply.zig` (like `writeFile`), and expose a tiny `synthFlacForTest` from `music_tags.zig` (make the existing `synthFlac` test helper `pub` and rename to `synthFlacForTest`).

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | head -25`
Expected: FAIL — `applyInMemory` takes 3 args; no tag path.

- [ ] **Step 3: Add TagOpts + thread through applyInMemory**

In `src/core/apply.zig` add imports + type:

```zig
const music_tags = @import("../kinds/music_tags.zig");

pub const TagOpts = struct { write: bool = false, backup_dir: ?[]const u8 = null };
```

Change `applyInMemory` signature to `applyInMemory(alloc, p, on_conflict, tag_opts: TagOpts)` and `apply` to accept `tag_opts` and derive `backup_dir` when null (see Step 5). Update the existing `apply` test call to pass `.{}`.

After a successful `.move` for a **music primary**, when `tag_opts.write`, add backup + write + journal:

```zig
                    try moveFile(item.src, final);
                    try entries.append(alloc, .{ .action = .move, .from = try alloc.dupe(u8, item.src), .to = final });
                    moved += 1;

                    if (tag_opts.write and g.kind == .music and item.role == .primary) {
                        try maybeWriteTags(alloc, &entries, tag_opts.backup_dir, final, item, created, &moved);
                    }
```

- [ ] **Step 4: Implement maybeWriteTags + undo restore**

```zig
fn tagSetFromFields(f: plan.Fields) music_tags.TagSet {
    return .{
        .title = f.title,
        .artists = f.artists,
        .album_artist = f.album_artist,
        .album = f.album,
        .track = f.track,
        .disc = f.disc,
        .year = f.year,
        .release_mbid = f.release_mbid,
        .recording_mbid = f.recording_mbid,
    };
}

/// Back up `target` then write tags into it, journaling a `.tagwrite` entry.
/// Skips (no mutation) on any unsupported/failed step. `_moved` unused now but
/// kept for a future "wrote N" count.
fn maybeWriteTags(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(journal.Entry),
    backup_dir: ?[]const u8,
    target: []const u8,
    item: plan.Item,
    created: i64,
    _moved: *u32,
) !void {
    _ = _moved;
    const fields = item.fields orelse return;
    const ext = std.fs.path.extension(target);
    if (!std.ascii.eqlIgnoreCase(ext, ".flac") and !std.ascii.eqlIgnoreCase(ext, ".mp3")) return;

    const bdir = backup_dir orelse return;
    const base = std.fs.path.basename(target);
    const backup = try std.fmt.allocPrint(alloc, "{s}/{d}/{s}", .{ bdir, created, base });
    if (std.fs.path.dirname(backup)) |bp| try standardize.mkdirParents(bp);

    // Copy target → backup (byte copy; reuse the cross-device copier).
    var fz: [4096]u8 = undefined;
    var bz: [4096]u8 = undefined;
    if (target.len >= fz.len or backup.len >= bz.len) return;
    const fzp = try std.fmt.bufPrintZ(&fz, "{s}", .{target});
    const bzp = try std.fmt.bufPrintZ(&bz, "{s}", .{backup});
    standardize.copyAcrossDevices(fzp, bzp) catch return; // no backup → no write

    music_tags.writeTags(alloc, target, tagSetFromFields(fields)) catch return;
    try entries.append(alloc, .{ .action = .tagwrite, .from = try alloc.dupe(u8, target), .to = backup });
}
```

Update `undo` to branch on `.tagwrite` (copy backup over target) vs move:

```zig
pub fn undo(alloc: std.mem.Allocator, j: journal.Journal) !void {
    _ = alloc;
    var i = j.entries.len;
    while (i > 0) {
        i -= 1;
        const e = j.entries[i];
        switch (e.action) {
            .tagwrite => {
                // restore pre-tag bytes: copy backup (e.to) over target (e.from)
                var fz: [4096]u8 = undefined;
                var bz: [4096]u8 = undefined;
                if (e.from.len < fz.len and e.to.len < bz.len) {
                    const fzp = std.fmt.bufPrintZ(&fz, "{s}", .{e.from}) catch continue;
                    const bzp = std.fmt.bufPrintZ(&bz, "{s}", .{e.to}) catch continue;
                    standardize.copyAcrossDevices(bzp, fzp) catch {};
                }
            },
            .move, .trash => moveFile(e.to, e.from) catch {},
        }
    }
}
```

Order guarantee: the `.move` entry is appended before the `.tagwrite` entry, so `undo` (reverse) restores pre-tag bytes at `dst` first, then moves `dst`→`src` — net original bytes at the source.

- [ ] **Step 5: Derive backup_dir in the env-driven `apply`**

```zig
pub fn apply(alloc: std.mem.Allocator, p: plan.Plan, on_conflict: OnConflict, env: *std.process.Environ.Map, tag_opts: TagOpts) !Result {
    var opts = tag_opts;
    if (opts.write and opts.backup_dir == null) {
        const d = try journal.dir(alloc, env); // $XDG_DATA_HOME/stacks/undo
        defer alloc.free(d);
        // backups live beside undo journals
        opts.backup_dir = try std.fmt.allocPrint(alloc, "{s}/../backup", .{d});
    }
    const out = try applyInMemory(alloc, p, on_conflict, opts);
    const jpath = try journal.write(alloc, env, out.journal);
    return .{ .moved = out.moved, .trashed = out.trashed, .skipped = out.skipped, .journal_path = jpath };
}
```

Update every `apply(...)` / `applyInMemory(...)` call site (organize/review/undo commands, web apply) to pass the new `tag_opts` arg — Task 6 sets it from flags/config; pass `.{}` anywhere tags aren't wanted.

- [ ] **Step 6: Build + test**

Run: `zig build test 2>&1 | tail -8`
Expected: PASS — tag-write + byte-identical undo restore green; existing apply/undo tests still pass.

- [ ] **Step 7: Commit**

```bash
git add src/core/apply.zig src/kinds/music_tags.zig
git commit -m "feat(music-c): apply backup+write-tags step + undo restore

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: CLI/web plumbing + tag-smoke + docs

**Files:**
- Modify: `src/commands/organize.zig`, `src/commands/review.zig`, `src/commands/undo.zig`, `src/web/review.zig`/`api.zig`
- Create: `scripts/tag-smoke.sh`; Modify: `justfile`, docs, `todo.md`, memory

- [ ] **Step 1: organize flags → apply**

In `commands/organize.zig`: add `write_tags: bool = false` to `Opts`; parse `--write-tags` (sets true) and `--no-write-tags` (sets false, wins). Resolve effective value = flag if present else `cfg.write_tags`. Pass `.{ .write = effective }` to `apply(...)`. Add both flags to the help + justfile `organize` help line.

- [ ] **Step 2: review/web + undo call sites**

`commands/review.zig` + `src/web/review.zig`: thread a `write_tags` bool into the apply path; add a "Write tags on apply" checkbox to the review page that posts the flag to `/api/apply` (default unchecked; server-authoritative). `commands/undo.zig` already calls `apply.undo` (journal handles `.tagwrite`) — no change beyond confirming it compiles with the new journal action.

- [ ] **Step 3: tag-smoke.sh (real ffmpeg/ffprobe)**

Create `scripts/tag-smoke.sh`:

```bash
#!/usr/bin/env bash
# Write-back smoke: ffmpeg makes a FLAC + MP3 with two artists flattened into
# one tag; organize --write-tags; ffprobe confirms TWO artist values; undo
# restores byte-identical originals. Skips cleanly without ffmpeg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SHELVE="$ROOT/zig-out/bin/shelve"
[[ -x "$SHELVE" ]] || { echo "build first: zig build" >&2; exit 2; }
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "ffmpeg/ffprobe absent — skipping"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/config"
SRC="$TMP/dl/album"; LIB="$TMP/lib"; mkdir -p "$SRC"
meta=(-metadata album=Blue -metadata album_artist="Derek and the Dominos" -metadata date=1970)
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Layla -metadata artist="Eric Clapton; Duane Allman" -metadata track=1 -y "$SRC/01.flac"
ffmpeg -v error -f lavfi -i sine=d=1 "${meta[@]}" -metadata title=Bell   -metadata artist="Eric Clapton; Duane Allman" -metadata track=2 -y "$SRC/02.mp3"
cp "$SRC/01.flac" "$TMP/01.flac.orig"; cp "$SRC/02.mp3" "$TMP/02.mp3.orig"

PASS=0; FAIL=0
chk(){ if eval "$2"; then echo "  ok: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

"$SHELVE" organize "$SRC" --to "$LIB" --write-tags --offline >/dev/null
FL="$(find "$LIB" -name '01 - Layla.flac' | head -1)"
# count ARTIST values ffprobe sees (Vorbis returns one line per value or a ';'/multiple)
N=$(ffprobe -v error -show_entries format_tags=ARTIST -of default=nw=1:nk=1 "$FL" | tr ';' '\n' | grep -c .)
chk "flac has >=2 artists" '[[ "$N" -ge 2 ]]'

"$SHELVE" undo >/dev/null
chk "flac restored byte-identical" 'cmp -s "$SRC/01.flac" "$TMP/01.flac.orig"'
chk "mp3 restored byte-identical"  'cmp -s "$SRC/02.mp3" "$TMP/02.mp3.orig"'

echo; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
```

Add `just tag-smoke` (`./scripts/tag-smoke.sh`).

- [ ] **Step 4: Build + run smoke**

Run: `zig build && ./scripts/tag-smoke.sh`
Expected: `PASS=3 FAIL=0` (or a clean skip if ffmpeg absent).

- [ ] **Step 5: Docs + todo + memory**

Document `--write-tags`/`--no-write-tags` + config `write_tags = on` (default off; mutation, backed up + undoable). Mark Music C done in `todo.md` (the `- [ ] **C — tag write-back**` line). Append a memory status line (`kinds/music_tags.zig` native FLAC/MP3 multi-value writer; apply backup + `tagwrite` journal + undo restore; opt-in flag/config; `tag-smoke.sh`).

- [ ] **Step 6: Commit**

```bash
git add src/commands src/web justfile scripts/tag-smoke.sh docs todo.md
git commit -m "feat(music-c): --write-tags plumbing, web checkbox, tag-smoke; mark C done

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** native ID3v2.4 multi-value TPE1 (T1) ✓; FLAC multi-ARTIST + audio verbatim (T2) ✓; MP3 build + `writeTags` temp/atomic-rename + unsupported-ext skip (T3) ✓; opt-in flag/config (T4,T6) ✓; backup + `tagwrite` journal + `undo` byte-restore (T4,T5) ✓; consumes `plan.Fields` incl. MBIDs (T5 `tagSetFromFields`) ✓; smoke proves multi-artist + byte-identical undo (T6) ✓. Cover-art embedding and `.m4a`+ deferred (spec non-goals; unsupported ext warns/skips).

**Placeholder scan:** concrete code/tests throughout. The one cross-file test dependency (`music_tags.synthFlacForTest`) is created in T2 and made `pub` in T5-Step 1.

**Type consistency:** `TagSet` (T1) used by `buildFlac`/`buildMp3`/`writeTags` (T2,T3) and built from `plan.Fields` via `tagSetFromFields` (T5); `journal.Action.tagwrite` (T4) written in T5 and consumed by `undo` (T5); `TagOpts`/`applyInMemory(...,tag_opts)`/`apply(...,tag_opts)` signatures updated at all call sites (T5-Step 5, T6). Backup entry reuses `Entry{from=target,to=backup}` — no journal schema change beyond the enum.
