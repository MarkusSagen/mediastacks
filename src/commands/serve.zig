//! `booktool serve [--port N] [--bind IP]` — start the web UI.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const web = @import("../web/server.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var opts = web.ServeOptions{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--port") and i + 1 < args.len) {
            i += 1;
            opts.port = std.fmt.parseInt(u16, args[i], 10) catch {
                try ctx.stderr.print("invalid port: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, a, "--bind") and i + 1 < args.len) {
            i += 1;
            opts.bind = args[i];
        } else {
            try ctx.stderr.print("usage: booktool serve [--port N] [--bind IP]\n", .{});
            return 1;
        }
    }

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    try web.serve(ctx.arena, ctx.io, &cat, opts, ctx.stdout);
    return 0;
}
