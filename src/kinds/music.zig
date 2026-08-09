//! Music track parsing. Tags are authoritative (filenames are unreliable),
//! so `parse` reads them via ffprobe; `fromTags`/`splitArtists` are pure so
//! they're tested without spawning anything. Multi-artist tags arrive
//! flattened ("A; B feat. C") and are split into a list — the list is
//! modeled now; writing per-artist tags is sub-phase C.

const std = @import("std");
const exec = @import("../util/exec.zig");

pub const Tags = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?[]const u8 = null,
    disc: ?[]const u8 = null,
    date: ?[]const u8 = null,
};

pub const Track = struct {
    title: ?[]const u8 = null,
    artists: []const []const u8 = &.{},
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
    year: ?u32 = null,
    ext: []const u8,
};

const DELIMS = [_][]const u8{ "; ", ";", " / ", "/", ", ", ",", " & ", " x ", " feat. ", " Feat. ", " ft. ", " Ft. ", " featuring " };

fn appendArtist(alloc: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8) !void {
    const a = std.mem.trim(u8, raw, " \t");
    if (a.len == 0) return;
    for (out.items) |e| if (std.ascii.eqlIgnoreCase(e, a)) return; // dedupe
    try out.append(alloc, try alloc.dupe(u8, a));
}

/// Split a flattened artist tag into individual artists (owned by `alloc`).
pub fn splitArtists(alloc: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    outer: while (i < s.len) {
        for (DELIMS) |d| {
            if (i + d.len <= s.len and std.mem.eql(u8, s[i .. i + d.len], d)) {
                try appendArtist(alloc, &out, s[start..i]);
                i += d.len;
                start = i;
                continue :outer;
            }
        }
        i += 1;
    }
    try appendArtist(alloc, &out, s[start..]);
    return out.toOwnedSlice(alloc);
}

/// First run of digits as an integer: "3/12" → 3, "1998-05-20" → 1998.
fn firstInt(s: []const u8) ?u32 {
    var v: ?u32 = null;
    for (s) |c| {
        if (std.ascii.isDigit(c)) {
            v = (v orelse 0) * 10 + (c - '0');
        } else if (v != null) break;
    }
    return v;
}

/// Transcode a tag value to UTF-8. Valid UTF-8 is duped unchanged; otherwise
/// the bytes are treated as Latin-1 (each byte → a codepoint) and re-encoded,
/// so a mis-encoded tag never yields invalid UTF-8. Owned by `alloc`.
pub fn toUtf8(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return alloc.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    for (s) |b| {
        if (b < 0x80) {
            try out.append(alloc, b);
        } else {
            try out.append(alloc, 0xC0 | (b >> 6));
            try out.append(alloc, 0x80 | (b & 0x3F));
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Disc number from a source subfolder name: "CD 1"/"CD1"/"Disc 2"/"Disk 3"
/// (case-insensitive) → n; anything else → null.
pub fn discFromDirName(name: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (name.len == 0 or name.len >= buf.len) return null;
    const lo = std.ascii.lowerString(buf[0..name.len], name);
    const prefixes = [_][]const u8{ "disc", "disk", "cd" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, lo, p)) {
            const rest = std.mem.trim(u8, lo[p.len..], " _-");
            if (rest.len == 0) return null;
            for (rest) |c| if (!std.ascii.isDigit(c)) return null;
            return std.fmt.parseInt(u32, rest, 10) catch null;
        }
    }
    return null;
}

/// Build a Track from a tag set + basename (filename stem is the title
/// fallback). All strings owned by `alloc`.
pub fn fromTags(alloc: std.mem.Allocator, tags: Tags, basename: []const u8) !Track {
    const ext_dot = std.fs.path.extension(basename);
    const ext = try alloc.dupe(u8, if (ext_dot.len > 0) ext_dot[1..] else ext_dot);
    const stem = basename[0 .. basename.len - ext_dot.len];
    return .{
        .title = try toUtf8(alloc, tags.title orelse stem),
        .artists = if (tags.artist) |ar| try splitArtists(alloc, try toUtf8(alloc, ar)) else &.{},
        .album_artist = if (tags.album_artist) |x| try toUtf8(alloc, x) else null,
        .album = if (tags.album) |x| try toUtf8(alloc, x) else null,
        .track = if (tags.track) |x| firstInt(x) else null,
        .disc = if (tags.disc) |x| firstInt(x) else null,
        .year = blk: {
            const v = if (tags.date) |x| firstInt(x) else null;
            break :blk if (v) |n| (if (n == 0) null else n) else null;
        },
        .ext = ext,
    };
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn tagStr(tagsv: std.json.Value, key: []const u8) ?[]const u8 {
    if (tagsv != .object) return null;
    var it = tagsv.object.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, key)) {
            const v = e.value_ptr.*;
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return null;
}

/// Run ffprobe on `path` and build a Track. ffprobe absent/failed/tagless →
/// a filename-only Track (title = stem). Owned by `alloc`.
pub fn parse(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !Track {
    const base = std.fs.path.basename(path);
    const argv = [_][]const u8{ "ffprobe", "-v", "error", "-print_format", "json", "-show_format", path };
    const r = exec.runCaptureStdout(alloc, io, &argv, 1 * 1024 * 1024) catch return fromTags(alloc, .{}, base);
    defer alloc.free(r.stdout);
    if (r.exit_code != 0 or r.stdout.len == 0) return fromTags(alloc, .{}, base);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), r.stdout, .{}) catch
        return fromTags(alloc, .{}, base);
    const tagsv = if (objGet(root, "format")) |fmt| (objGet(fmt, "tags") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
    const tags = Tags{
        .title = tagStr(tagsv, "title"),
        .artist = tagStr(tagsv, "artist"),
        .album_artist = tagStr(tagsv, "album_artist"),
        .album = tagStr(tagsv, "album"),
        .track = tagStr(tagsv, "track"),
        .disc = tagStr(tagsv, "disc") orelse tagStr(tagsv, "discnumber"),
        .date = tagStr(tagsv, "date"),
    };
    return fromTags(alloc, tags, base); // tags slices live in the arena; fromTags dupes into alloc
}

const t = std.testing;

test "splitArtists splits common delimiters, trims, dedups" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try splitArtists(a, "Eric Clapton; B.B. King");
    try t.expectEqual(@as(usize, 2), r.len);
    try t.expectEqualStrings("Eric Clapton", r[0]);
    try t.expectEqualStrings("B.B. King", r[1]);
    const r2 = try splitArtists(a, "A feat. B & C");
    try t.expectEqual(@as(usize, 3), r2.len);
    const r3 = try splitArtists(a, "Solo");
    try t.expectEqual(@as(usize, 1), r3.len);
}

test "fromTags models album grouping fields" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = try fromTags(a, .{ .title = "Layla", .artist = "Eric Clapton", .album_artist = "Eric Clapton", .album = "Best of Blues", .track = "3/12", .date = "1998" }, "03 layla.mp3");
    try t.expectEqualStrings("Layla", tr.title.?);
    try t.expectEqualStrings("Eric Clapton", tr.album_artist.?);
    try t.expectEqualStrings("Best of Blues", tr.album.?);
    try t.expectEqual(@as(u32, 3), tr.track.?);
    try t.expectEqual(@as(u32, 1998), tr.year.?);
    try t.expectEqualStrings("mp3", tr.ext);
}

test "fromTags falls back to filename stem for title" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tr = try fromTags(a, .{}, "some song.flac");
    try t.expectEqualStrings("some song", tr.title.?);
    try t.expectEqual(@as(usize, 0), tr.artists.len);
}

test "toUtf8 passes through valid UTF-8 and transcodes Latin-1" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Already-valid UTF-8 is returned unchanged.
    try t.expectEqualStrings("Café", try toUtf8(a, "Café"));
    // Latin-1 0xE9 ('é') → UTF-8 C3 A9.
    const latin1 = [_]u8{ 'C', 'o', 'm', 'm', 'u', 'n', 'i', 'q', 'u', 0xE9 };
    try t.expectEqualStrings("Communiqué", try toUtf8(a, &latin1));
}

test "discFromDirName parses disc subfolder names" {
    try t.expectEqual(@as(?u32, 1), discFromDirName("CD 1"));
    try t.expectEqual(@as(?u32, 1), discFromDirName("CD1"));
    try t.expectEqual(@as(?u32, 1), discFromDirName("cd 01"));
    try t.expectEqual(@as(?u32, 2), discFromDirName("Disc 2"));
    try t.expectEqual(@as(?u32, 3), discFromDirName("Disk 3"));
    try t.expectEqual(@as(?u32, null), discFromDirName("Season 1"));
    try t.expectEqual(@as(?u32, null), discFromDirName("Discography"));
    try t.expectEqual(@as(?u32, null), discFromDirName("Blue"));
}

test "fromTags reads disc, drops zero year, transcodes latin-1 tags" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const latin1_album = [_]u8{ 'C', 'o', 'm', 'm', 'u', 'n', 'i', 'q', 'u', 0xE9 };
    const tr = try fromTags(a, .{ .title = "T", .album = &latin1_album, .track = "5", .disc = "2/2", .date = "0" }, "05 t.mp3");
    try t.expectEqual(@as(u32, 2), tr.disc.?);
    try t.expectEqual(@as(?u32, null), tr.year); // date "0" is not a real year
    try t.expectEqualStrings("Communiqué", tr.album.?);
}
