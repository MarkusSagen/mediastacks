//! `shelve serve [--port N] [--to LIB]` — start the organizer web app
//! (`web/app.zig`). Long-running; Ctrl+C stops it.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../core/config.zig");
const app = @import("../web/app.zig");
const demo = @import("../core/demo.zig");
const mediacatalog = @import("../core/mediacatalog.zig");
const indexer = @import("../core/indexer.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var port: u16 = 8799;
    var to: ?[]const u8 = null;
    var demo_mode = false;

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
        } else if (std.mem.eql(u8, a, "--demo")) {
            demo_mode = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return usage(ctx);
        }
    }

    // --demo: seed a throwaway sandbox and point XDG_*/library at it, so nothing
    // real is touched. Index the seeded library so the Library tab is populated.
    if (demo_mode) {
        const s = demo.activate(ctx.arena, ctx.io, ctx.env) catch |err| {
            try ctx.stderr.print("demo seed failed: {s}\n", .{@errorName(err)});
            return 2;
        };
        to = s.library;
        const db_path = try mediacatalog.defaultPath(ctx.arena, ctx.env);
        if (mediacatalog.Catalog.open(db_path)) |*cat_const| {
            var cat = cat_const.*;
            defer cat.close();
            _ = indexer.scan(ctx.arena, ctx.io, &cat, s.library, true) catch {};
        } else |_| {}
        try ctx.stdout.print("demo mode — sandbox at {s}\n  library: {s}\n  try organizing: {s}\n", .{ s.root, s.library, s.downloads });
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
    try ctx.stderr.print("usage: shelve serve [--port N] [--to LIB] [--demo]\n", .{});
    return 1;
}
