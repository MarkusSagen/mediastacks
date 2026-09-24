//! `mediastacks missing [PATH] [--glob PATTERN]` — list books with
//! incomplete metadata.
//!
//! With no arguments, lists every incomplete book in the catalog. With
//! a PATH, restricts to books underneath that directory. With --glob,
//! filters paths against a shell-style pattern.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const score_mod = @import("../core/score.zig");
const glob = @import("../core/glob.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var path_filter: ?[]const u8 = null;
    var glob_pattern: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--glob") and i + 1 < args.len) {
            i += 1;
            glob_pattern = args[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printHelp(ctx.stdout);
            return 0;
        } else if (a.len > 0 and a[0] != '-' and path_filter == null) {
            path_filter = a;
        } else {
            try ctx.stderr.print("unknown argument: {s}\n", .{a});
            return 1;
        }
    }

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    const books = try cat.listIncomplete(ctx.arena);
    var matched: u32 = 0;
    for (books) |book| {
        if (path_filter) |p| if (!std.mem.startsWith(u8, book.path, p)) continue;
        if (glob_pattern) |pat| if (!glob.match(pat, book.path)) continue;

        const missing = try score_mod.missingFields(ctx.arena, book.metadata);
        try ctx.stdout.print("id={d}  {s}\n", .{ book.id, book.path });
        try ctx.stdout.print("    missing:", .{});
        for (missing) |field| try ctx.stdout.print(" {s}", .{field});
        try ctx.stdout.print("\n", .{});
        matched += 1;
    }

    if (matched == 0) {
        try ctx.stdout.print("(no incomplete books match the filter)\n", .{});
        return 0;
    }
    try ctx.stdout.print("\n{d} book(s) with incomplete metadata\n", .{matched});
    return 0;
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: mediastacks missing [PATH] [--glob PATTERN]
        \\
        \\Lists catalogued books that lack one or more of: title, author,
        \\published_year, isbn. Use PATH to restrict by directory prefix
        \\and --glob for shell-style patterns.
        \\
        \\Examples:
        \\  mediastacks missing
        \\  mediastacks missing ~/Books/scifi
        \\  mediastacks missing --glob "**/Hobb*"
        \\
    );
}
