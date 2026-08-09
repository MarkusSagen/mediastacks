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
    date: ?[]const u8 = null,
};

pub const Track = struct {
    title: ?[]const u8 = null,
    artists: []const []const u8 = &.{},
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
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

/// Build a Track from a tag set + basename (filename stem is the title
/// fallback). All strings owned by `alloc`.
pub fn fromTags(alloc: std.mem.Allocator, tags: Tags, basename: []const u8) !Track {
    const ext_dot = std.fs.path.extension(basename);
    const ext = try alloc.dupe(u8, if (ext_dot.len > 0) ext_dot[1..] else ext_dot);
    const stem = basename[0 .. basename.len - ext_dot.len];
    return .{
        .title = try alloc.dupe(u8, tags.title orelse stem),
        .artists = if (tags.artist) |ar| try splitArtists(alloc, ar) else &.{},
        .album_artist = if (tags.album_artist) |x| try alloc.dupe(u8, x) else null,
        .album = if (tags.album) |x| try alloc.dupe(u8, x) else null,
        .track = if (tags.track) |x| firstInt(x) else null,
        .year = if (tags.date) |x| firstInt(x) else null,
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
