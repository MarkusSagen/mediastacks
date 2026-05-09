//! `booktool convert SRC --to FMT` — convert one file.

const std = @import("std");
const cli = @import("../cli.zig");
const meta = @import("../core/metadata.zig");
const format_mod = @import("../formats/format.zig");
const convert_mod = @import("../convert/convert.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--to")) {
        try ctx.stderr.print("usage: booktool convert SRC --to FMT\n", .{});
        return 1;
    }
    const src = args[0];
    const dst = meta.Format.fromExtension(args[2]);
    if (dst == .unknown) {
        try ctx.stderr.print("unknown target format: {s}\n", .{args[2]});
        return 1;
    }

    const src_fmt = format_mod.detect(ctx.io, src) catch |err| {
        try ctx.stderr.print("cannot read {s}: {s}\n", .{ src, @errorName(err) });
        return 2;
    };

    const out_dir = std.fs.path.dirname(src) orelse ".";
    const out_path = convert_mod.convert(ctx.arena, ctx.io, src, src_fmt, dst, out_dir) catch |err| {
        try ctx.stderr.print("convert failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    try ctx.stdout.print("{s}\n", .{out_path});
    return 0;
}
