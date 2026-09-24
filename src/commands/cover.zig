//! `mediastacks cover FILE` — render the book's cover in the terminal via
//! chafa. Auto-detects Kitty/Sixel/iTerm2/Unicode.

const std = @import("std");
const cli = @import("../cli.zig");
const format_mod = @import("../formats/format.zig");
const cover_mod = @import("../core/cover.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: mediastacks cover FILE\n", .{});
        return 1;
    }
    const path = args[0];
    const fmt = format_mod.detect(ctx.io, path) catch |err| {
        try ctx.stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };

    const bytes = cover_mod.extract(ctx.arena, ctx.io, path, fmt) catch |err| {
        try ctx.stderr.print("no cover: {s}\n", .{@errorName(err)});
        return 2;
    };

    const tmp_path = try cover_mod.writeTmp(ctx.arena, bytes, "img");
    var unlink_buf: [4096]u8 = undefined;
    const tmp_path_z = try std.fmt.bufPrintZ(&unlink_buf, "{s}", .{tmp_path});
    defer _ = std.c.unlink(tmp_path_z.ptr);

    try ctx.stdout.flush();

    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "chafa", tmp_path },
    }) catch |err| {
        try ctx.stderr.print("chafa failed: {s} (install with: brew install chafa)\n", .{@errorName(err)});
        return 2;
    };
    if (result.stdout.len > 0) try ctx.stdout.writeAll(result.stdout);
    if (result.stderr.len > 0) try ctx.stderr.writeAll(result.stderr);
    return switch (result.term) {
        .exited => |code| code,
        else => 2,
    };
}
