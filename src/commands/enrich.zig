//! `booktool enrich [--missing]` — pull metadata from providers.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    _ = args;
    // Implementation pending: iterate catalog, query Open Library by ISBN
    // or title+author, merge results, write back. Blocked on http transport.
    try ctx.stderr.print("enrich: not implemented yet\n", .{});
    return 2;
}
