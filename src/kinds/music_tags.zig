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
