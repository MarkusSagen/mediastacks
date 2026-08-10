//! Native music tag writers: FLAC (Vorbis comments) and MP3 (ID3v2.4), with
//! true multi-value ARTIST so a track lists under each artist. Byte assembly
//! is pure (`buildId3v24`/`buildFlac`/`buildMp3`); `writeTags` reads the file,
//! rebuilds it, and swaps it in via a temp file + atomic rename (never an
//! in-place mutation). File I/O uses `std.c` to match apply.zig/journal.zig.

const std = @import("std");

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

// ---- little-endian + synchsafe helpers --------------------------------

fn le32(n: usize) [4]u8 {
    return .{ @intCast(n & 0xff), @intCast((n >> 8) & 0xff), @intCast((n >> 16) & 0xff), @intCast((n >> 24) & 0xff) };
}
fn rd_le32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

/// 4-byte synchsafe integer (7 bits per byte), big-endian — the ID3v2 size form.
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

// ---- ID3v2.4 frame assembly -------------------------------------------

/// Append one ID3v2.4 text frame; `values` joined by 0x00 (multi-value),
/// encoding byte 0x03 (UTF-8). No-op when `values` is empty.
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
    try out.appendSlice(alloc, &[_]u8{ 0, 0 }); // frame flags
    try out.appendSlice(alloc, payload.items);
}

/// A TXXX frame: 0x03 (UTF-8) + description + 0x00 + value.
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

fn appendNumFrame(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: [4]u8, n: u32) !void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    try appendTextFrame(alloc, out, id, &.{s});
}

/// Build a complete ID3v2.4 tag (header + frames) from `tags`.
pub fn buildId3v24(alloc: std.mem.Allocator, tags: TagSet) ![]u8 {
    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(alloc);

    try appendTextFrame(alloc, &frames, "TPE1".*, tags.artists);
    if (tags.title) |v| try appendTextFrame(alloc, &frames, "TIT2".*, &.{v});
    if (tags.album) |v| try appendTextFrame(alloc, &frames, "TALB".*, &.{v});
    if (tags.album_artist) |v| try appendTextFrame(alloc, &frames, "TPE2".*, &.{v});
    if (tags.year) |y| try appendNumFrame(alloc, &frames, "TDRC".*, y);
    if (tags.track) |n| try appendNumFrame(alloc, &frames, "TRCK".*, n);
    if (tags.disc) |n| try appendNumFrame(alloc, &frames, "TPOS".*, n);
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

/// Test/util: values of the first frame `frame_id` in an ID3v2.4 tag, split on
/// 0x00. Null when the frame is absent.
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

// ---- FLAC Vorbis-comment rewrite --------------------------------------

/// Build a new FLAC file: keep every metadata block except VORBIS_COMMENT,
/// append a fresh VORBIS_COMMENT from `tags`, then the original audio frames
/// verbatim. Returns Error.MalformedFile on a bad marker/blocks.
pub fn buildFlac(alloc: std.mem.Allocator, original: []const u8, tags: TagSet) Error![]u8 {
    if (original.len < 4 or !std.mem.eql(u8, original[0..4], "fLaC")) return Error.MalformedFile;

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
        if (btype != 4) { // drop the existing VORBIS_COMMENT (type 4)
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
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{y}) catch return Error.OutOfMemory;
        addC(alloc, &comments, "DATE", s) catch return Error.OutOfMemory;
    }
    if (tags.track) |n| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return Error.OutOfMemory;
        addC(alloc, &comments, "TRACKNUMBER", s) catch return Error.OutOfMemory;
    }
    if (tags.disc) |n| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return Error.OutOfMemory;
        addC(alloc, &comments, "DISCNUMBER", s) catch return Error.OutOfMemory;
    }
    if (tags.release_mbid) |v| addC(alloc, &comments, "MUSICBRAINZ_ALBUMID", v) catch return Error.OutOfMemory;
    if (tags.recording_mbid) |v| addC(alloc, &comments, "MUSICBRAINZ_TRACKID", v) catch return Error.OutOfMemory;

    vc.appendSlice(alloc, &le32(comments.items.len)) catch return Error.OutOfMemory;
    for (comments.items) |c| {
        vc.appendSlice(alloc, &le32(c.len)) catch return Error.OutOfMemory;
        vc.appendSlice(alloc, c) catch return Error.OutOfMemory;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    out.appendSlice(alloc, "fLaC") catch return Error.OutOfMemory;
    for (kept.items) |b| {
        out.append(alloc, b.btype & 0x7f) catch return Error.OutOfMemory; // clear last-block
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

// ---- MP3 (ID3v2.4) rebuild + dispatch ---------------------------------

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

/// Write `tags` into `path` by extension (.flac / .mp3). Reads the whole file,
/// rebuilds it, writes to `path.tmp`, then atomically renames over the
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

/// Read a whole file via libc. Owned by `alloc`; null on open failure.
fn readWhole(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return null;
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

fn writeWholeChecked(path: []const u8, bytes: []const u8) bool {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return false;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return false;
    const fp = std.c.fopen(pzp.ptr, "wb") orelse return false;
    defer _ = std.c.fclose(fp);
    if (bytes.len == 0) return true;
    return std.c.fwrite(bytes.ptr, 1, bytes.len, fp) == bytes.len;
}

const t = std.testing;

fn writeWhole(path: []const u8, bytes: []const u8) void {
    _ = writeWholeChecked(path, bytes);
}

test "buildMp3 prepends a new ID3 tag and keeps audio" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
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
    const orig = try synthFlacForTest(a);
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

/// Test/util: minimal synthetic FLAC — marker + STREAMINFO + VORBIS_COMMENT +
/// fake audio. Exposed so apply.zig tests can seed a file.
pub fn synthFlacForTest(alloc: std.mem.Allocator) ![]u8 {
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
    try out.append(alloc, 0x84);
    try out.appendSlice(alloc, &.{ @intCast((vc.items.len >> 16) & 0xff), @intCast((vc.items.len >> 8) & 0xff), @intCast(vc.items.len & 0xff) });
    try out.appendSlice(alloc, vc.items);
    try out.appendSlice(alloc, "AUDIOFRAMESHERE");
    return out.toOwnedSlice(alloc);
}

test "buildFlac replaces VORBIS_COMMENT with multi ARTIST, keeps audio" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const orig = try synthFlacForTest(a);
    const out = try buildFlac(a, orig, .{ .artists = &.{ "A", "B" }, .album = "Alb", .title = "T", .track = 3, .year = 2001 });
    try t.expectEqualStrings("fLaC", out[0..4]);
    const artists = (try readVorbisValues(a, out, "ARTIST")).?;
    try t.expectEqual(@as(usize, 2), artists.len);
    try t.expectEqualStrings("A", artists[0]);
    try t.expectEqualStrings("B", artists[1]);
    try t.expectEqualStrings("Alb", (try readVorbisValues(a, out, "ALBUM")).?[0]);
    try t.expect(std.mem.endsWith(u8, out, "AUDIOFRAMESHERE"));
}

test "buildId3v24 emits multi-value TPE1 that round-trips" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags = TagSet{
        .title = "Layla",
        .artists = &.{ "Eric Clapton", "Duane Allman" },
        .album_artist = "Derek and the Dominos",
        .album = "Layla",
        .track = 1,
        .disc = 1,
        .year = 1970,
        .release_mbid = "rel-x",
    };
    const tag = try buildId3v24(a, tags);
    try t.expectEqualStrings("ID3", tag[0..3]);
    try t.expectEqual(@as(u8, 4), tag[3]);
    const artists = (try readTextValues(a, tag, "TPE1".*)).?;
    try t.expectEqual(@as(usize, 2), artists.len);
    try t.expectEqualStrings("Eric Clapton", artists[0]);
    try t.expectEqualStrings("Duane Allman", artists[1]);
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
