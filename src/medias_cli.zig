//! `medias` CLI dispatcher — the media-organizer front-end. Shares the
//! same core library as the book binary; exposes only the organize/undo
//! surface.

const std = @import("std");
const cli = @import("cli.zig");
const organize_cmd = @import("commands/organize.zig");
const undo_cmd = @import("commands/undo.zig");
const review_cmd = @import("commands/review.zig");
const makem4b_cmd = @import("commands/makem4b.zig");
const webapp_cmd = @import("commands/webapp.zig");
const index_cmd = @import("commands/index.zig");
const remux_cmd = @import("commands/remux.zig");

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
        try ctx.stdout.print("medias 0.1.0\n", .{});
        return 0;
    }
    if (eq(cmd, "organize")) return organize_cmd.run(ctx, rest);
    if (eq(cmd, "review")) return review_cmd.run(ctx, rest);
    if (eq(cmd, "serve")) return webapp_cmd.run(ctx, rest);
    if (eq(cmd, "makem4b")) return makem4b_cmd.run(ctx, rest);
    if (eq(cmd, "undo")) return undo_cmd.run(ctx, rest);
    if (eq(cmd, "index")) return index_cmd.run(ctx, rest);
    if (eq(cmd, "remux")) return remux_cmd.run(ctx, rest);

    try ctx.stderr.print("unknown command: {s}\n", .{cmd});
    try printUsage(ctx.stderr);
    return 1;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\medias — reorganize & relabel media into a clean library.
        \\
        \\Usage:
        \\  medias <command> [args]
        \\
        \\Commands:
        \\  organize DIR [flags]   Reorganize DIR into the library (applies by default)
        \\    --dry-run, -n          Preview only — print the plan, change nothing
        \\    --to LIB               Override the library root
        \\    --on-conflict WHICH    skip (default) | suffix | overwrite
        \\    --plan FILE            Also write the plan as JSON
        \\    --from FILE            Use a plan JSON instead of scanning DIR
        \\  serve [--port N]       Start the organizer web app (Library / Organize / Undo / Settings)
        \\  review DIR [flags]     Review & edit the plan in a browser, then apply
        \\  makem4b DIR [flags]    Merge a folder of chapter files into one .m4b
        \\    --to LIB               Override the library root
        \\    --out FILE.m4b         Write to an explicit path instead
        \\    --bitrate B            AAC bitrate (default 128k)
        \\  remux FILE|DIR [flags] Losslessly repackage video → clean .mkv (ffmpeg -c copy)
        \\    --keep-langs en,ja     Drop audio/subtitle tracks in other languages
        \\    --no-embed-subs        Don't mux matching external subtitle sidecars in
        \\    --dry-run              Preview only
        \\  undo                   Reverse the most recent organize / remux
        \\  index [--rebuild] [--to LIB]   scan the library into the media catalog
        \\  help                   Show this help
        \\  version                Print version
        \\
        \\Configuration:
        \\  $XDG_CONFIG_HOME/mediastacks/config.toml — library_root, tv_template, movie_template
        \\  Undo journals live under $XDG_DATA_HOME/mediastacks/undo/
        \\
    );
}
