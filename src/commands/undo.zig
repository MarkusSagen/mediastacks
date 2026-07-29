//! `shelve undo` — reverse the most recent apply from its journal.

const std = @import("std");
const cli = @import("../cli.zig");
const journal = @import("../core/journal.zig");
const apply_mod = @import("../core/apply.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    _ = args;

    const jpath = (journal.latest(ctx.arena, ctx.env) catch |err| {
        try ctx.stderr.print("cannot locate journal: {s}\n", .{@errorName(err)});
        return 2;
    }) orelse {
        try ctx.stderr.print("no journal to undo\n", .{});
        return 1;
    };

    const j = journal.load(ctx.arena, jpath) catch |err| {
        try ctx.stderr.print("cannot load journal {s}: {s}\n", .{ jpath, @errorName(err) });
        return 2;
    };

    apply_mod.undo(ctx.arena, j) catch |err| {
        try ctx.stderr.print("undo failed: {s}\n", .{@errorName(err)});
        return 2;
    };

    try ctx.stdout.print("undid {d} operations from {s}\n", .{ j.entries.len, jpath });
    return 0;
}
