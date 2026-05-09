//! `booktool dedup [--apply]` — find (and optionally remove) duplicates.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    _ = args;
    try ctx.stderr.print("dedup: not implemented yet\n", .{});
    return 2;
}
