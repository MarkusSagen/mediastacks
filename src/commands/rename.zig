//! `booktool rename [--apply] [--template TPL] [--preset NAME]` — show or
//! perform canonical renames.
//!
//! Templates: see src/core/template.zig. CLI gives three knobs:
//!   --template "...":  raw template string
//!   --preset NAME:     one of `default`, `flat`, `series-dir`
//!   (default if neither flag is set: the `default` preset)
//!
//! Templates can produce relative paths with `/` separators (e.g.
//! `series-dir`). The destination directory below the book's current
//! parent is created as needed.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const template_mod = @import("../core/template.zig");
const standardize = @import("../core/standardize.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var apply = false;
    var template_str: []const u8 = template_mod.DEFAULT_TEMPLATE;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--apply")) {
            apply = true;
        } else if (std.mem.eql(u8, a, "--template") and i + 1 < args.len) {
            i += 1;
            template_str = args[i];
        } else if (std.mem.eql(u8, a, "--preset") and i + 1 < args.len) {
            i += 1;
            template_str = try presetTemplate(args[i]);
        } else if (std.mem.eql(u8, a, "--list-presets")) {
            try printPresets(ctx.stdout);
            return 0;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printHelp(ctx.stdout);
            return 0;
        } else {
            try ctx.stderr.print("unknown argument: {s}\n", .{a});
            try printHelp(ctx.stderr);
            return 1;
        }
    }

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    const plans = try standardize.planAll(ctx.arena, &cat, template_str);
    if (plans.len == 0) {
        try ctx.stdout.print("(catalog is empty)\n", .{});
        return 0;
    }
    const counts = standardize.summarize(plans);

    var changed: u32 = 0;
    var errors: u32 = 0;

    for (plans) |plan| {
        if (plan.dst == null or plan.same) continue;
        try ctx.stdout.print("id={d}\n  - {s}\n  + {s}\n", .{ plan.id, plan.src, plan.dst.? });
        if (apply) {
            standardize.applyOne(&cat, plan) catch |err| {
                try ctx.stderr.print("    ! {s}\n", .{@errorName(err)});
                errors += 1;
                continue;
            };
            changed += 1;
        }
    }

    if (apply) {
        try ctx.stdout.print(
            "\nrenamed={d} unchanged={d} unrenameable={d} errors={d}\n",
            .{ changed, counts.same, counts.unrenameable, errors },
        );
    } else {
        try ctx.stdout.print(
            "\n{d} would be renamed, {d} already canonical, {d} unrenameable (missing metadata)\n",
            .{ counts.would_change, counts.same, counts.unrenameable },
        );
        try ctx.stdout.print("(dry run — pass --apply to execute)\n", .{});
    }
    return if (errors == 0) 0 else 1;
}

fn presetTemplate(name: []const u8) ![]const u8 {
    return standardize.presetTemplate(name);
}

fn printPresets(w: *std.Io.Writer) !void {
    try w.print("default     {s}\n", .{template_mod.DEFAULT_TEMPLATE});
    try w.print("flat        {s}\n", .{template_mod.FLAT_TEMPLATE});
    try w.print("series-dir  {s}\n", .{template_mod.SERIES_DIR_TEMPLATE});
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: booktool rename [options]
        \\
        \\Options:
        \\  --template "TPL"   Custom rename template (see template fields below)
        \\  --preset NAME      Use a built-in template (default, flat, series-dir)
        \\  --apply            Actually move files (default is dry-run)
        \\  --list-presets     Show built-in templates
        \\
        \\Template fields:
        \\  {author_sort}      "Last, First"
        \\  {author}           "First Last"
        \\  {title}            Book title
        \\  {series}           Series name
        \\  {series_index:02}  Series position (zero-padded width)
        \\  {year}             Published year
        \\  {isbn}             ISBN-13
        \\  {format}, {ext}    epub/mobi/azw3/pdf
        \\
        \\Templates may include '/' to nest into subdirectories (series-dir does).
        \\
    );
}
