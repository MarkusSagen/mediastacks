const std = @import("std");
const mc = @import("mediacatalog.zig");
const clock = @import("../util/clock.zig");

pub const Parsed = struct {
    title: []const u8,
    year: ?i64 = null,
    provider: ?[]const u8 = null,
    provider_id: ?[]const u8 = null,
};

/// Parse a Jellyfin-style item folder name:
///   "Title (YYYY) [providerid-VALUE]"  (year + id both optional)
/// Recognised id tokens: tmdbid- / imdbid- / tvdbid- / musicbrainzalbumid-.
pub fn parseItemFolder(alloc: std.mem.Allocator, name: []const u8) !Parsed {
    var rest = name;
    var provider: ?[]const u8 = null;
    var provider_id: ?[]const u8 = null;

    // Trailing "[...]" id token.
    if (std.mem.lastIndexOfScalar(u8, rest, '[')) |lb| {
        if (std.mem.indexOfScalarPos(u8, rest, lb, ']')) |rb| {
            const token = rest[lb + 1 .. rb]; // e.g. "tmdbid-335984"
            if (std.mem.indexOf(u8, token, "id-")) |dash| {
                const prov_key = token[0..dash]; // "tmdb", "imdb", "tvdb", "musicbrainzalbum"
                const val = token[dash + 3 ..];
                const prov: ?[]const u8 =
                    if (std.mem.eql(u8, prov_key, "tmdb")) "tmdb"
                    else if (std.mem.eql(u8, prov_key, "imdb")) "imdb"
                    else if (std.mem.eql(u8, prov_key, "tvdb")) "tvdb"
                    else if (std.mem.eql(u8, prov_key, "musicbrainzalbum")) "musicbrainz"
                    else null;
                if (prov) |p| {
                    if (val.len > 0) {
                        provider = try alloc.dupe(u8, p);
                        provider_id = try alloc.dupe(u8, val);
                    }
                }
            }
            rest = std.mem.trimEnd(u8, rest[0..lb], " ");
        }
    }

    // Trailing "(YYYY)" year.
    var year: ?i64 = null;
    if (rest.len >= 6 and rest[rest.len - 1] == ')') {
        if (std.mem.lastIndexOfScalar(u8, rest, '(')) |lp| {
            const inner = rest[lp + 1 .. rest.len - 1];
            if (inner.len == 4) {
                if (std.fmt.parseInt(i64, inner, 10)) |y| {
                    year = y;
                    rest = std.mem.trimEnd(u8, rest[0..lp], " ");
                } else |_| {}
            }
        }
    }

    return .{
        .title = try alloc.dupe(u8, std.mem.trim(u8, rest, " ")),
        .year = year,
        .provider = provider,
        .provider_id = provider_id,
    };
}

const VIDEO_EXT = [_][]const u8{ ".mkv", ".mp4", ".avi", ".m4v", ".mov", ".webm", ".ts", ".wmv" };
const AUDIO_EXT = [_][]const u8{ ".mp3", ".flac", ".m4a", ".m4b", ".aac", ".ogg", ".opus", ".wav", ".wma" };
const COMIC_EXT = [_][]const u8{ ".cbz", ".cbr", ".cb7", ".cbt" };
const INLINE_EXT = [_][]const u8{ ".mp3", ".flac", ".m4a", ".m4b", ".aac", ".ogg", ".wav", ".mp4", ".m4v", ".webm" };

fn extIn(list: []const []const u8, ext: []const u8) bool {
    for (list) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

pub fn isPlayableInline(ext: []const u8) bool {
    return extIn(&INLINE_EXT, ext);
}

pub fn mediaExtForKind(kind: []const u8, ext: []const u8) bool {
    if (std.mem.eql(u8, kind, "music") or std.mem.eql(u8, kind, "audiobook"))
        return extIn(&AUDIO_EXT, ext);
    if (std.mem.eql(u8, kind, "comic")) return extIn(&COMIC_EXT, ext);
    return extIn(&VIDEO_EXT, ext); // movie, tv
}

/// Extension without the leading dot, lowercased into `buf` (max 15 chars).
pub fn containerOf(buf: []u8, ext: []const u8) []const u8 {
    const e = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;
    const n = @min(e.len, buf.len);
    for (e[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

pub fn isCoverName(base: []const u8) bool {
    const names = [_][]const u8{
        "cover.jpg", "cover.jpeg", "cover.png", "poster.jpg", "poster.png",
        "folder.jpg", "folder.png",
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(base, n)) return true;
    return false;
}

test "parseItemFolder pulls title, year and provider id" {
    const a = std.testing.allocator;

    var p1 = try parseItemFolder(a, "Blade Runner 2049 (2017) [tmdbid-335984]");
    defer freeParsed(a, &p1);
    try std.testing.expectEqualStrings("Blade Runner 2049", p1.title);
    try std.testing.expectEqual(@as(?i64, 2017), p1.year);
    try std.testing.expectEqualStrings("tmdb", p1.provider.?);
    try std.testing.expectEqualStrings("335984", p1.provider_id.?);

    var p2 = try parseItemFolder(a, "Severance");
    defer freeParsed(a, &p2);
    try std.testing.expectEqualStrings("Severance", p2.title);
    try std.testing.expectEqual(@as(?i64, null), p2.year);
    try std.testing.expectEqual(@as(?[]const u8, null), p2.provider);

    var p3 = try parseItemFolder(a, "Dune (2021) [imdbid-tt1160419]");
    defer freeParsed(a, &p3);
    try std.testing.expectEqualStrings("Dune", p3.title);
    try std.testing.expectEqualStrings("imdb", p3.provider.?);
    try std.testing.expectEqualStrings("tt1160419", p3.provider_id.?);

    try std.testing.expect(isPlayableInline(".mp3"));
    try std.testing.expect(isPlayableInline(".mp4"));
    try std.testing.expect(!isPlayableInline(".mkv"));
    try std.testing.expect(mediaExtForKind("movie", ".mkv"));
    try std.testing.expect(!mediaExtForKind("movie", ".flac"));
    try std.testing.expect(mediaExtForKind("music", ".flac"));
    try std.testing.expect(mediaExtForKind("comic", ".cbz"));
    try std.testing.expect(isCoverName("poster.jpg"));
    try std.testing.expect(!isCoverName("episode1.mkv"));
}

fn freeParsed(a: std.mem.Allocator, p: *Parsed) void {
    a.free(p.title);
    if (p.provider) |v| a.free(v);
    if (p.provider_id) |v| a.free(v);
}
