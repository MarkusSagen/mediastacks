//! CLI dispatcher.
//!
//! Parses the global options and the subcommand name, then hands the rest
//! of argv to the matching command module. Returns an exit code so main()
//! can call std.process.exit with a real value.

const std = @import("std");

const info_cmd = @import("commands/info.zig");
const scan_cmd = @import("commands/scan.zig");
const cover_cmd = @import("commands/cover.zig");
const convert_cmd = @import("commands/convert.zig");
const enrich_cmd = @import("commands/enrich.zig");
const missing_cmd = @import("commands/missing.zig");
const dedup_cmd = @import("commands/dedup.zig");
const rename_cmd = @import("commands/rename.zig");

pub const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub fn run(ctx: Context) !u8 {
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
        try ctx.stdout.print("booktool 0.0.0\n", .{});
        return 0;
    }
    if (eq(cmd, "info")) return info_cmd.run(ctx, rest);
    if (eq(cmd, "scan")) return scan_cmd.run(ctx, rest);
    if (eq(cmd, "cover")) return cover_cmd.run(ctx, rest);
    if (eq(cmd, "convert")) return convert_cmd.run(ctx, rest);
    if (eq(cmd, "enrich")) return enrich_cmd.run(ctx, rest);
    if (eq(cmd, "missing")) return missing_cmd.run(ctx, rest);
    if (eq(cmd, "dedup")) return dedup_cmd.run(ctx, rest);
    if (eq(cmd, "rename")) return rename_cmd.run(ctx, rest);

    try ctx.stderr.print("unknown command: {s}\n", .{cmd});
    try printUsage(ctx.stderr);
    return 1;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn printUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\booktool — manage an ebook library.
        \\
        \\Usage:
        \\  booktool <command> [args]
        \\
        \\Commands:
        \\  info FILE              Show embedded metadata for a file
        \\  scan DIR               Walk DIR and ingest into the catalog
        \\  cover FILE             Render the cover in the terminal (chafa)
        \\  convert SRC --to FMT   Convert ebook to FMT (epub/mobi/azw3/pdf)
        \\  enrich [--missing]     Pull metadata from Open Library
        \\  missing                List books with incomplete metadata
        \\  dedup [--apply]        Find (and optionally remove) duplicates
        \\  rename [--apply]       Show or perform canonical renames
        \\  help                   Show this help
        \\  version                Print version
        \\
        \\Configuration:
        \\  Catalog DB lives at $XDG_DATA_HOME/booktool/catalog.db
        \\  (default: ~/.local/share/booktool/catalog.db)
        \\
    );
}
