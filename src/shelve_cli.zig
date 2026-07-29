//! `shelve` CLI dispatcher — the media-organizer front-end. Shares the
//! same core library as the book binary; exposes only the organize/undo
//! surface.

const std = @import("std");
const cli = @import("cli.zig");
const organize_cmd = @import("commands/organize.zig");
const undo_cmd = @import("commands/undo.zig");

pub fn run(ctx: cli.Context) !u8 {
    if (ctx.args.len < 2) {
        try printUsage(ctx.stdout);
        return 1;
    }

    const cmd = ctx.args[1];
    const rest = ctx.args[2..];

    if (eq(cmd, "help") or eq(cmd, "-h") or eq(cmd, "--help")) {
        try printUsage(ctx.stdout);
        return 0;
    }
    if (eq(cmd, "version") or eq(cmd, "--version") or eq(cmd, "-V")) {
        try ctx.stdout.print("shelve 0.0.0\n", .{});
        return 0;
    }
    if (eq(cmd, "organize")) return organize_cmd.run(ctx, rest);
    if (eq(cmd, "undo")) return undo_cmd.run(ctx, rest);

    try ctx.stderr.print("unknown command: {s}\n", .{cmd});
    try printUsage(ctx.stderr);
    return 1;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\shelve — reorganize & relabel media into a clean library.
        \\
        \\Usage:
        \\  shelve <command> [args]
        \\
        \\Commands:
        \\  organize DIR [flags]   Plan a reorganization (dry-run by default)
        \\    --to LIB               Override the library root
        \\    --apply                Execute the plan (move + journal)
        \\    --plan FILE            Write the plan as JSON
        \\    --from FILE            Apply/inspect a plan JSON instead of scanning
        \\    --on-conflict WHICH    skip (default) | suffix | overwrite
        \\  undo                   Reverse the most recent apply
        \\  help                   Show this help
        \\  version                Print version
        \\
        \\Configuration:
        \\  $XDG_CONFIG_HOME/stacks/config.toml — library_root, tv_template, movie_template
        \\  Undo journals live under $XDG_DATA_HOME/stacks/undo/
        \\
    );
}
