//! `booktool cover FILE` — extract the cover and render it in the terminal
//! by piping through chafa.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: booktool cover FILE\n", .{});
        return 1;
    }
    // Implementation pending: extract cover bytes (libmobi for MOBI,
    // miniz+OPF for EPUB), spill to a temp file, exec chafa.
    try ctx.stderr.print("cover: not implemented yet (target: {s})\n", .{args[0]});
    return 2;
}
