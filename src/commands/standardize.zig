//! `booktool standardize DIR [options]`
//!
//! Meta-command that runs the full ingestion pipeline against a directory:
//!
//!   1. scan       walk + hash + extract embedded metadata
//!   2. enrich     query Open Library for each book   (skip with --no-enrich)
//!   3. dedup      remove cross-format / SHA duplicates (skip with --no-dedup)
//!   4. rename     move every catalogued file to the canonical name
//!   5. optimize   recompress EPUBs                    (skip with --no-optimize)
//!
//! Each step is dry-run by default. Pass `--apply` to actually execute
//! mutating operations (rename, dedup deletions, optimize re-writes).
//!
//! Execution is sequential for now. Parallelizing the per-file
//! ingestion path with `io.concurrent` is on the follow-up list, but
//! for libraries of a few thousand books the current speed (hashing is
//! the bottleneck) is already acceptable.

const std = @import("std");
const cli = @import("../cli.zig");
const scan_cmd = @import("scan.zig");
const enrich_cmd = @import("enrich.zig");
const dedup_cmd = @import("dedup.zig");
const rename_cmd = @import("rename.zig");
const optimize_cmd = @import("optimize.zig");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var apply = false;
    var no_enrich = false;
    var no_dedup = false;
    var no_rename = false;
    var no_optimize = false;
    var template: ?[]const u8 = null;
    var dir: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--apply")) apply = true
        else if (std.mem.eql(u8, a, "--no-enrich")) no_enrich = true
        else if (std.mem.eql(u8, a, "--no-dedup")) no_dedup = true
        else if (std.mem.eql(u8, a, "--no-rename")) no_rename = true
        else if (std.mem.eql(u8, a, "--no-optimize")) no_optimize = true
        else if (std.mem.eql(u8, a, "--template") and i + 1 < args.len) {
            i += 1;
            template = args[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printHelp(ctx.stdout);
            return 0;
        } else if (a.len > 0 and a[0] != '-' and dir == null) {
            dir = a;
        } else {
            try ctx.stderr.print("unknown argument: {s}\n", .{a});
            return 1;
        }
    }
    const target = dir orelse {
        try ctx.stderr.print("usage: booktool standardize DIR [options]\n", .{});
        return 1;
    };

    // 1) scan
    try section(ctx, "scan");
    if (try scan_cmd.run(ctx, &.{target}) != 0) return 1;

    // 2) enrich
    if (!no_enrich) {
        try section(ctx, "enrich");
        _ = try enrich_cmd.run(ctx, &.{});
    } else try ctx.stdout.print("\n(skipping enrich)\n", .{});

    // 3) dedup
    if (!no_dedup) {
        try section(ctx, "dedup");
        const dedup_args: []const []const u8 = if (apply) &.{"--apply"} else &.{};
        _ = try dedup_cmd.run(ctx, dedup_args);
    } else try ctx.stdout.print("\n(skipping dedup)\n", .{});

    // 4) rename
    if (!no_rename) {
        try section(ctx, "rename");
        var rargs: std.ArrayList([]const u8) = .empty;
        if (apply) try rargs.append(ctx.arena, "--apply");
        if (template) |t| {
            try rargs.append(ctx.arena, "--template");
            try rargs.append(ctx.arena, t);
        }
        _ = try rename_cmd.run(ctx, rargs.items);
    } else try ctx.stdout.print("\n(skipping rename)\n", .{});

    // 5) optimize — only when --apply (in-place rewrite is real work).
    if (!no_optimize and apply) {
        try section(ctx, "optimize");
        const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
        var cat = try catalog_mod.Catalog.open(catalog_path);
        defer cat.close();
        const books = try cat.listBooks(ctx.arena);
        var paths: std.ArrayList([]const u8) = .empty;
        for (books) |b| if (b.format == .epub) try paths.append(ctx.arena, b.path);
        if (paths.items.len > 0) {
            _ = try optimize_cmd.run(ctx, paths.items);
        } else {
            try ctx.stdout.print("(no EPUBs to optimize)\n", .{});
        }
    } else if (!no_optimize and !apply) {
        try ctx.stdout.print("\n(skipping optimize — pass --apply to run)\n", .{});
    }

    if (!apply) {
        try ctx.stdout.print(
            "\n[summary] dry-run complete. Re-run with --apply to perform changes.\n",
            .{},
        );
    } else {
        try ctx.stdout.print("\n[summary] standardize complete.\n", .{});
    }
    return 0;
}

fn section(ctx: cli.Context, name: []const u8) !void {
    try ctx.stdout.print("\n=== {s} ===\n", .{name});
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: booktool standardize DIR [options]
        \\
        \\Run scan → enrich → dedup → rename → optimize against DIR.
        \\Defaults to dry-run; pass --apply to perform mutations.
        \\
        \\Options:
        \\  --apply              Actually perform rename/dedup/optimize
        \\  --no-enrich          Skip Open Library lookups
        \\  --no-dedup           Skip duplicate removal
        \\  --no-rename          Skip filename rewrites
        \\  --no-optimize        Skip EPUB recompression
        \\  --template "TPL"     Pass-through to rename
        \\
        \\Example:
        \\  booktool standardize ~/Books               # dry-run
        \\  booktool standardize ~/Books --apply       # do it
        \\
    );
}
