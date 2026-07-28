//! `booktool set-meta FILE [--title T] [--author A] [--series S] [--series-index N] [--year Y]`
//!
//! Edit the embedded metadata of a book file. The CLI is a thin shell
//! over `formats.registry.forFormat(fmt).?.writeMetadata(...)` — the
//! per-format dispatch lives behind the FormatHandler vtable, so
//! adding a new writable format means wiring its handler, not editing
//! this file.

const std = @import("std");
const cli = @import("../cli.zig");
const format_mod = @import("../formats/format.zig");
const handler_mod = @import("../formats/handler.zig");
const registry = @import("../formats/registry.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 3) {
        try printHelp(ctx.stdout);
        return 1;
    }
    const path = args[0];
    var update: handler_mod.MetadataUpdate = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 >= args.len) {
            try ctx.stderr.print("missing value for {s}\n", .{a});
            return 1;
        }
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--title")) update.title = v else if (std.mem.eql(u8, a, "--author")) update.author = v else if (std.mem.eql(u8, a, "--series")) update.series = v else if (std.mem.eql(u8, a, "--series-index")) update.series_index = v else if (std.mem.eql(u8, a, "--year")) update.year = v else {
            try ctx.stderr.print("unknown flag: {s}\n", .{a});
            return 1;
        }
    }

    const fmt = format_mod.detect(ctx.io, path) catch |err| {
        try ctx.stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };

    const h = registry.forFormat(fmt) orelse {
        try ctx.stderr.print("set-meta: no handler for {s}\n", .{@tagName(fmt)});
        return 2;
    };
    h.writeMetadata(ctx.arena, ctx.io, path, update) catch |err| switch (err) {
        error.NotSupported => {
            try ctx.stderr.print("set-meta not supported for {s}\n", .{@tagName(fmt)});
            return 2;
        },
        else => {
            try ctx.stderr.print("{s}: {s}\n", .{ path, @errorName(err) });
            return 2;
        },
    };
    try ctx.stdout.print("updated metadata in {s}\n", .{path});
    return 0;
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: booktool set-meta FILE [options]
        \\
        \\Options (any combination):
        \\  --title TEXT
        \\  --author "Last, First" | "First Last"
        \\  --series TEXT
        \\  --series-index N
        \\  --year YYYY
        \\
        \\Notes:
        \\  EPUB: in-place OPF rewrite + zip repack.
        \\  MOBI/AZW3: shells out to mobimeta (--series fields unsupported).
        \\
    );
}
