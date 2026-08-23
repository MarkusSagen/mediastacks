//! `shelve serve [--port N] [--to LIB]` — start the organizer web app
//! (`web/app.zig`). Long-running; Ctrl+C stops it.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../core/config.zig");
const app = @import("../web/app.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var port: u16 = 8799;
    var to: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            port = std.fmt.parseInt(u16, args[i], 10) catch return usage(ctx);
        } else if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            to = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return usage(ctx);
        }
    }

    var cfg = try config.load(ctx.arena, ctx.env);
    if (to) |x| cfg.library_root = x;

    app.serve(ctx.io, ctx.arena, cfg, ctx.env, .{ .port = port }, ctx.stdout) catch |err| {
        try ctx.stderr.print("serve failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    return 0;
}

fn usage(ctx: cli.Context) !u8 {
    try ctx.stderr.print("usage: shelve serve [--port N] [--to LIB]\n", .{});
    return 1;
}
