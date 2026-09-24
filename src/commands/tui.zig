//! `mediastacks tui` — interactive terminal UI for browsing and reading.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const tui_app = @import("../tui/app.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    _ = args;

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    try tui_app.run(ctx.arena, ctx.io, ctx.env, &cat);
    return 0;
}
