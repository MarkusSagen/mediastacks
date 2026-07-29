//! The reorganization Plan — the serializable contract shared by the CLI,
//! the TUI, and the Web UI. The CLI emits it; review surfaces render and
//! edit it; `apply` executes it.

const std = @import("std");
const kind = @import("kind.zig");

pub const Role = enum { primary, sidecar, duplicate, junk };
pub const Op = enum { move, copy, trash, skip };

pub const Item = struct {
    src: []const u8,
    role: Role,
    op: Op,
    /// Destination path; null for trash/skip.
    dst: ?[]const u8 = null,
    reason: []const u8 = "",
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
