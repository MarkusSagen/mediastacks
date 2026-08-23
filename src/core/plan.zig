//! The reorganization Plan — the serializable contract shared by the CLI,
//! the TUI, and the Web UI. The CLI emits it; review surfaces render and
//! edit it; `apply` executes it.

const std = @import("std");
const kind = @import("kind.zig");

pub const Role = enum { primary, sidecar, duplicate, junk, extra };
pub const Op = enum { move, copy, trash, skip };

/// Optional technical facts from ffprobe, shown in the plan and reused by
/// the future TUI. Additive — absent when not probed.
pub const MediaInfo = struct {
    codec: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    duration_s: ?f64 = null,
};

/// Structured naming fields, kept so a review surface can recompute the
/// destination after an edit (retitle / regroup). Additive.
pub const Fields = struct {
    series: ?[]const u8 = null,
    season: ?u32 = null,
    episode: ?u32 = null,
    title: ?[]const u8 = null,
    year: ?u32 = null,
    ext: ?[]const u8 = null,
    // movie version/part (Jellyfin)
    edition: ?[]const u8 = null,
    part: ?u32 = null,
    // music
    album_artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    track: ?u32 = null,
    disc: ?u32 = null,
    artists: []const []const u8 = &.{},
    release_mbid: ?[]const u8 = null,
    recording_mbid: ?[]const u8 = null,
    // video online (TMDB)
    series_year: ?u32 = null,
    tmdb_id: ?[]const u8 = null,
    imdb_id: ?[]const u8 = null,
    tvdb_id: ?[]const u8 = null,
    original_language: ?[]const u8 = null,
    // comic
    issue: ?f32 = null,
    volume: ?u32 = null,
};

pub const Item = struct {
    src: []const u8,
    role: Role,
    op: Op,
    /// Destination path; null for trash/skip.
    dst: ?[]const u8 = null,
    reason: []const u8 = "",
    media: ?MediaInfo = null,
    fields: ?Fields = null,
    /// Source path of the album's cover image, stamped on music primaries so
    /// tag write-back can embed it (APIC/PICTURE). Not serialized-critical.
    cover_src: ?[]const u8 = null,
};

pub const Group = struct {
    kind: kind.MediaKind,
    title: []const u8,
    year: ?u32 = null,
    items: []Item,
    warnings: []const []const u8 = &.{},
};

pub const Plan = struct {
    library_root: []const u8,
    source: []const u8,
    groups: []Group,
    unclassified: []const []const u8 = &.{},
};

/// Serialize a Plan to JSON. Owned by `alloc`.
pub fn toJson(alloc: std.mem.Allocator, plan: Plan) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, plan, .{ .whitespace = .indent_2 });
}

/// Parse a Plan from JSON. Uses `alloc` leakily — pass an arena the caller
/// owns.
pub fn fromJson(alloc: std.mem.Allocator, bytes: []const u8) !Plan {
    // `.alloc_always` so parsed strings own their memory rather than
    // aliasing `bytes` (which the caller may free).
    return std.json.parseFromSliceLeaky(Plan, alloc, bytes, .{ .allocate = .alloc_always });
}

const t = std.testing;

test "plan json round-trips group and item shape" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var items = [_]Item{.{
        .src = "/x/a.mkv",
        .role = .primary,
        .op = .move,
        .dst = "/lib/TV/Show/Season 01/Show - S01E01.mkv",
        .reason = "",
    }};
    var groups = [_]Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const plan = Plan{ .library_root = "/lib", .source = "/x", .groups = groups[0..] };

    const bytes = try toJson(a, plan);
    const back = try fromJson(a, bytes);
    try t.expectEqual(@as(usize, 1), back.groups.len);
    try t.expectEqual(kind.MediaKind.tv, back.groups[0].kind);
    try t.expectEqual(Role.primary, back.groups[0].items[0].role);
    try t.expectEqualStrings("/x/a.mkv", back.groups[0].items[0].src);
    try t.expectEqualStrings("/lib/TV/Show/Season 01/Show - S01E01.mkv", back.groups[0].items[0].dst.?);
}

test "plan json round-trips media info" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var items = [_]Item{.{
        .src = "/x/a.mkv",
        .role = .primary,
        .op = .move,
        .dst = "/lib/a.mkv",
        .media = .{ .codec = "h264", .width = 1920, .height = 1080, .duration_s = 1400 },
    }};
    var groups = [_]Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const plan = Plan{ .library_root = "/lib", .source = "/x", .groups = groups[0..] };

    const bytes = try toJson(a, plan);
    const back = try fromJson(a, bytes);
    try t.expectEqual(@as(u32, 1080), back.groups[0].items[0].media.?.height.?);
    try t.expectEqualStrings("h264", back.groups[0].items[0].media.?.codec.?);
}

test "plan json round-trips item fields" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = [_]Item{.{ .src = "/x/a.mkv", .role = .primary, .op = .move, .dst = "/lib/a.mkv", .fields = .{ .series = "Show", .season = 1, .episode = 2, .ext = "mkv" } }};
    var groups = [_]Group{.{ .kind = .tv, .title = "Show", .items = items[0..] }};
    const plan = Plan{ .library_root = "/lib", .source = "/x", .groups = groups[0..] };
    const back = try fromJson(a, try toJson(a, plan));
    try t.expectEqual(@as(u32, 2), back.groups[0].items[0].fields.?.episode.?);
    try t.expectEqualStrings("Show", back.groups[0].items[0].fields.?.series.?);
}
