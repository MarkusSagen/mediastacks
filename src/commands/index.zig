//! `shelve index [--rebuild] [--to LIB]` — scan the organized library into the
//! media catalog ($XDG_DATA_HOME/stacks/media.db). Derived index: safe to
//! rebuild anytime; the filesystem stays the source of truth.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../core/config.zig");
const mc = @import("../core/mediacatalog.zig");
const indexer = @import("../core/indexer.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var to: ?[]const u8 = null;
    var rebuild = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--rebuild")) {
            rebuild = true;
        } else if (std.mem.eql(u8, args[i], "--to")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            to = args[i];
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            return usage(ctx);
        }
    }

    var cfg = try config.load(ctx.arena, ctx.env);
    if (to) |x| cfg.library_root = x;

    const db_path = try mc.defaultPath(ctx.arena, ctx.env);
    var cat = mc.Catalog.open(db_path) catch |err| {
        try ctx.stderr.print("cannot open catalog {s}: {s}\n", .{ db_path, @errorName(err) });
        return 2;
    };
    defer cat.close();

    const st = indexer.scan(ctx.arena, ctx.io, &cat, cfg.library_root, rebuild) catch |err| {
        try ctx.stderr.print("index failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    try ctx.stdout.print(
        "indexed {d} item(s) from {s}  (added {d}, updated {d}, removed {d})\n",
        .{ st.total, cfg.library_root, st.added, st.updated, st.removed },
    );
    return 0;
}

fn usage(ctx: cli.Context) !u8 {
    try ctx.stderr.print("usage: shelve index [--rebuild] [--to LIB]\n", .{});
    return 2;
}
