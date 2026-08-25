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

const t = std.testing;

test "scan indexes a synthetic library" {
    // Arena-backed (matches the command path, which passes ctx.arena to scan);
    // frees everything on deinit, so scan's arena-style allocation is leak-clean.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Real temp dir tree. Threaded io — the same accessor group.zig tests use.
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // NOTE: this toolchain has NO `std.fs.cwd()` — use the io-based `std.Io.Dir`
    // (createDirPath = recursive mkdir; writeFile; deleteTree; deleteFile).
    const cwd = std.Io.Dir.cwd();
    const root = try std.fmt.allocPrint(a, "/tmp/stacks-idx-{d}", .{clock.nowSeconds()});
    defer cwd.deleteTree(io, root) catch {};
    try writeFile(io, cwd, a, root, "Movies/Dune (2021) [tmdbid-438631]/Dune (2021).mkv", "x");
    try writeFile(io, cwd, a, root, "Movies/Dune (2021) [tmdbid-438631]/poster.jpg", "img");
    try writeFile(io, cwd, a, root, "Shows/Severance/Season 01/Severance - S01E01.mkv", "x");
    try writeFile(io, cwd, a, root, "Shows/Severance/Season 01/Severance - S01E02.mkv", "x");
    try writeFile(io, cwd, a, root, "Music/Daft Punk/Discovery (2001)/01 One More Time.flac", "x");

    const db = try std.fmt.allocPrint(a, "/tmp/stacks-idx-{d}.db", .{clock.nowSeconds()});
    defer cwd.deleteFile(io, db) catch {};
    var cat = try mc.Catalog.open(db);
    defer cat.close();

    const st = try scan(a, io, &cat, root, true);
    try t.expectEqual(@as(usize, 3), st.total);

    const movie = (try cat.getByPath(a, "Movies/Dune (2021) [tmdbid-438631]")).?;
    try t.expectEqualStrings("Dune", movie.title);
    try t.expectEqual(@as(?i64, 2021), movie.year);
    try t.expectEqualStrings("tmdb", movie.provider.?);
    try t.expect(movie.has_cover);
    try t.expect(movie.has_metadata); // provider id present
    try t.expectEqualStrings("mkv", movie.container.?);
    try t.expect(!movie.playable_inline);

    const show = (try cat.getByPath(a, "Shows/Severance")).?;
    try t.expectEqual(@as(i64, 2), show.file_count);

    const album = (try cat.getByPath(a, "Music/Daft Punk/Discovery (2001)")).?;
    try t.expectEqualStrings("Discovery", album.title);
    try t.expectEqualStrings("Daft Punk", album.subtitle.?);
    try t.expect(album.playable_inline);

    // Re-scan after deleting the album folder → it's removed from the catalog.
    try cwd.deleteTree(io, try std.fs.path.join(a, &.{ root, "Music" }));
    const st2 = try scan(a, io, &cat, root, false);
    try t.expectEqual(@as(usize, 1), st2.removed);
    try t.expectEqual(@as(?mc.Item, null), try cat.getByPath(a, "Music/Daft Punk/Discovery (2001)"));
}

fn writeFile(io: std.Io, cwd: std.Io.Dir, a: std.mem.Allocator, root: []const u8, rel: []const u8, bytes: []const u8) !void {
    const full = try std.fs.path.join(a, &.{ root, rel });
    if (std.fs.path.dirname(full)) |d| try cwd.createDirPath(io, d);
    try cwd.writeFile(io, .{ .sub_path = full, .data = bytes });
}

pub const KindScan = struct { root: []const u8, kind: []const u8, depth: u8 };
pub const kind_scans = [_]KindScan{
    .{ .root = "Movies", .kind = "movie", .depth = 1 },
    .{ .root = "Shows", .kind = "tv", .depth = 1 },
    .{ .root = "Music", .kind = "music", .depth = 2 },
    .{ .root = "Audiobooks", .kind = "audiobook", .depth = 2 },
    .{ .root = "Comics", .kind = "comic", .depth = 1 },
};

pub const Stats = struct {
    added: usize = 0,
    updated: usize = 0,
    removed: usize = 0,
    total: usize = 0,
};

fn statSize(io: std.Io, path: []const u8) u64 {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    const st = f.stat(io) catch return 0;
    return st.size;
}

/// Aggregate one item folder: media file count/bytes, primary file + container,
/// cover presence. `item_abs` is the absolute item folder; walks recursively.
const Agg = struct {
    file_count: i64 = 0,
    total_bytes: i64 = 0,
    has_cover: bool = false,
    has_nfo: bool = false,
    primary_rel: ?[]const u8 = null, // relative to library_root
    container: ?[]const u8 = null,
    playable_inline: bool = false,
};

fn aggregate(alloc: std.mem.Allocator, io: std.Io, library_root: []const u8, item_rel: []const u8, kind: []const u8) !Agg {
    var agg: Agg = .{};
    const item_abs = try std.fs.path.join(alloc, &.{ library_root, item_rel });
    defer alloc.free(item_abs);
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, item_abs, .{ .iterate = true }) catch return agg;
    defer dir.close(io);
    var walker = dir.walk(alloc) catch return agg;
    defer walker.deinit();
    var cbuf: [16]u8 = undefined;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        if (isCoverName(base)) agg.has_cover = true;
        if (std.ascii.endsWithIgnoreCase(base, ".nfo")) agg.has_nfo = true;
        const ext = std.fs.path.extension(base);
        if (!mediaExtForKind(kind, ext)) continue;
        const abs = std.fs.path.join(alloc, &.{ item_abs, entry.path }) catch continue;
        defer alloc.free(abs);
        agg.file_count += 1;
        agg.total_bytes += @intCast(statSize(io, abs));
        if (agg.primary_rel == null) {
            agg.primary_rel = try std.fs.path.join(alloc, &.{ item_rel, entry.path });
            agg.container = try alloc.dupe(u8, containerOf(&cbuf, ext));
            agg.playable_inline = isPlayableInline(ext);
        }
    }
    return agg;
}

/// Immediate child directory names of `abs`, sorted, owned by `alloc`.
fn childDirs(alloc: std.mem.Allocator, io: std.Io, abs: []const u8) ![][]const u8 {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, abs, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        try out.append(alloc, try alloc.dupe(u8, e.name));
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return slice;
}

pub fn scan(alloc: std.mem.Allocator, io: std.Io, cat: *mc.Catalog, library_root: []const u8, rebuild: bool) !Stats {
    if (rebuild) try cat.clear();
    var st: Stats = .{};
    const now = clock.nowSeconds();

    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();

    for (kind_scans) |ks| {
        const kroot_abs = try std.fs.path.join(alloc, &.{ library_root, ks.root });
        defer alloc.free(kroot_abs);
        const level1 = try childDirs(alloc, io, kroot_abs);
        defer {
            for (level1) |s| alloc.free(s);
            alloc.free(level1);
        }
        for (level1) |name1| {
            if (ks.depth == 1) {
                try indexOne(alloc, io, cat, &seen, &st, library_root, ks.kind, ks.root, name1, null, now);
            } else {
                const l1_abs = try std.fs.path.join(alloc, &.{ kroot_abs, name1 });
                defer alloc.free(l1_abs);
                const level2 = try childDirs(alloc, io, l1_abs);
                defer {
                    for (level2) |s| alloc.free(s);
                    alloc.free(level2);
                }
                for (level2) |name2| {
                    try indexOne(alloc, io, cat, &seen, &st, library_root, ks.kind, ks.root, name2, name1, now);
                }
            }
        }
    }

    // Removal: catalog paths not seen this scan are gone from disk.
    const paths = try cat.allPaths(alloc);
    defer {
        for (paths) |p| alloc.free(p);
        alloc.free(paths);
    }
    for (paths) |p| {
        if (!seen.contains(p)) {
            _ = try cat.deleteUnderPath(p);
            st.removed += 1;
        }
    }
    return st;
}

/// Build + upsert one item. `parent1` is the depth-2 artist/author dir (null for
/// depth-1 kinds). `title_dir` is the item folder name (album/movie/show/series).
fn indexOne(
    alloc: std.mem.Allocator,
    io: std.Io,
    cat: *mc.Catalog,
    seen: *std.StringHashMap(void),
    st: *Stats,
    library_root: []const u8,
    kind: []const u8,
    kind_root: []const u8,
    title_dir: []const u8,
    parent1: ?[]const u8,
    now: i64,
) !void {
    const item_rel = if (parent1) |p1|
        try std.fs.path.join(alloc, &.{ kind_root, p1, title_dir })
    else
        try std.fs.path.join(alloc, &.{ kind_root, title_dir });

    const parsed = try parseItemFolder(alloc, title_dir);
    defer {
        alloc.free(parsed.title);
        if (parsed.provider) |v| alloc.free(v); // Task 4 made provider heap-allocated
        if (parsed.provider_id) |v| alloc.free(v);
    }
    const agg = try aggregate(alloc, io, library_root, item_rel, kind);

    const existed = (try cat.getByPath(alloc, item_rel)) != null;
    if (existed) st.updated += 1 else st.added += 1;
    st.total += 1;

    const sort_title = try std.ascii.allocLowerString(alloc, parsed.title);

    try cat.upsertItem(.{
        .kind = kind,
        .path = item_rel,
        .title = parsed.title,
        .sort_title = sort_title,
        .year = parsed.year,
        .subtitle = parent1, // artist / author for depth-2 kinds
        .provider = parsed.provider,
        .provider_id = parsed.provider_id,
        .cover_path = if (agg.has_cover) null else null, // cover path filled in Slice C
        .primary_path = agg.primary_rel,
        .container = agg.container,
        .playable_inline = agg.playable_inline,
        .file_count = agg.file_count,
        .total_bytes = agg.total_bytes,
        .has_metadata = (parsed.provider_id != null) or agg.has_nfo,
        .has_cover = agg.has_cover,
        .is_duplicate = false, // computed in a later slice
        .mtime = now,
        .indexed_at = now,
        .extra = null,
    });

    try seen.put(try alloc.dupe(u8, item_rel), {});
}
