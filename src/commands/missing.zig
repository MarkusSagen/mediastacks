//! `booktool missing` — list catalogued books with incomplete metadata.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const score_mod = @import("../core/score.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    _ = args;

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    const books = try cat.listIncomplete(ctx.arena);
    if (books.len == 0) {
        try ctx.stdout.print("(no incomplete books)\n", .{});
        return 0;
    }

    for (books) |book| {
        const missing = try score_mod.missingFields(ctx.arena, book.metadata);
        try ctx.stdout.print("id={d}  {s}\n", .{ book.id, book.path });
        try ctx.stdout.print("    missing:", .{});
        for (missing) |field| try ctx.stdout.print(" {s}", .{field});
        try ctx.stdout.print("\n", .{});
    }
    try ctx.stdout.print("\n{d} book(s) with incomplete metadata\n", .{books.len});
    return 0;
}
