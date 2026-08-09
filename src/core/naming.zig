//! The single place a destination path is rendered from structured
//! fields + the kind's template. Used by `group.buildPlan` and by the
//! review server when it recomputes names after an edit.

const std = @import("std");
const template = @import("template.zig");
const config = @import("config.zig");
const kind = @import("kind.zig");
const plan = @import("plan.zig");

fn u32str(arena: std.mem.Allocator, n: u32) ![]u8 {
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

/// Render the library-relative + rooted destination for `f` under `k`'s
/// template. Owned by `arena`.
pub fn dstFor(arena: std.mem.Allocator, cfg: config.Config, k: kind.MediaKind, f: plan.Fields) ![]u8 {
    const rel = switch (k) {
        .tv => blk: {
            const fields = [_]template.Field{
                .{ .name = "series", .value = f.series orelse "" },
                .{ .name = "season", .value = try u32str(arena, f.season orelse 0) },
                .{ .name = "episode", .value = try u32str(arena, f.episode orelse 0) },
                .{ .name = "title", .value = f.title orelse "" },
                .{ .name = "ext", .value = f.ext orelse "" },
            };
            break :blk try template.renderFields(arena, cfg.tv_template, &fields);
        },
        .movie => blk: {
            const year_str = if (f.year) |y| try u32str(arena, y) else "";
            const fields = [_]template.Field{
                .{ .name = "title", .value = f.title orelse "" },
                .{ .name = "year", .value = year_str },
                .{ .name = "ext", .value = f.ext orelse "" },
            };
            break :blk try template.renderFields(arena, cfg.movie_template, &fields);
        },
        else => return error.UnsupportedKind,
    };
    return std.fs.path.join(arena, &.{ cfg.library_root, rel });
}

const t = std.testing;

test "dstFor renders a jellyfin tv path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE };
    const out = try dstFor(a, cfg, .tv, .{ .series = "Witch Hat Atelier", .season = 1, .episode = 12, .title = "The Shadow of Romonon", .ext = "mkv" });
    try t.expectEqualStrings("/lib/Shows/Witch Hat Atelier/Season 01/Witch Hat Atelier S01E12 - The Shadow of Romonon.mkv", out);
}

test "dstFor renders a movie path" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE };
    const out = try dstFor(a, cfg, .movie, .{ .title = "The Matrix", .year = 1999, .ext = "mkv" });
    try t.expectEqualStrings("/lib/Movies/The Matrix (1999)/The Matrix (1999).mkv", out);
}
