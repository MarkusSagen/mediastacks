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

const RenamePlan = struct {
    id: i64,
    src: []const u8,
    dst: []const u8,
    same: bool,
};

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

    const books = try cat.listBooks(ctx.arena);
    if (books.len == 0) {
        try ctx.stdout.print("(catalog is empty)\n", .{});
        return 0;
    }

    var plans: std.ArrayList(RenamePlan) = .empty;
    var unrenameable: u32 = 0;

    for (books) |book| {
        const new_rel = template_mod.render(ctx.arena, template_str, book.metadata, book.format) catch |err| switch (err) {
            template_mod.Error.IncompleteMetadata => {
                unrenameable += 1;
                continue;
            },
            else => return err,
        };
        const parent = std.fs.path.dirname(book.path) orelse ".";
        const dst_path = try std.fs.path.join(ctx.arena, &.{ parent, new_rel });
        const same = std.mem.eql(u8, book.path, dst_path);
        try plans.append(ctx.arena, .{
            .id = book.id,
            .src = book.path,
            .dst = dst_path,
            .same = same,
        });
    }

    var changed: u32 = 0;
    var skipped_same: u32 = 0;
    var errors: u32 = 0;

    for (plans.items) |plan| {
        if (plan.same) {
            skipped_same += 1;
            continue;
        }
        try ctx.stdout.print("id={d}\n  - {s}\n  + {s}\n", .{ plan.id, plan.src, plan.dst });
        if (apply) {
            executeRename(&cat, plan) catch |err| {
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
            .{ changed, skipped_same, unrenameable, errors },
        );
    } else {
        const would_change = plans.items.len - skipped_same;
        try ctx.stdout.print(
            "\n{d} would be renamed, {d} already canonical, {d} unrenameable (missing metadata)\n",
            .{ would_change, skipped_same, unrenameable },
        );
        try ctx.stdout.print("(dry run — pass --apply to execute)\n", .{});
    }
    return if (errors == 0) 0 else 1;
}

fn presetTemplate(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "default")) return template_mod.DEFAULT_TEMPLATE;
    if (std.mem.eql(u8, name, "flat")) return template_mod.FLAT_TEMPLATE;
    if (std.mem.eql(u8, name, "series-dir")) return template_mod.SERIES_DIR_TEMPLATE;
    return error.UnknownPreset;
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

fn executeRename(cat: *catalog_mod.Catalog, plan: RenamePlan) !void {
    // Ensure the destination's parent directory exists.
    if (std.fs.path.dirname(plan.dst)) |parent| {
        try mkdirParents(parent);
    }

    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{plan.src});
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{plan.dst});

    if (std.c.access(dst_z.ptr, 0) == 0) return error.DestinationExists;
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) return error.RenameFailed;
    try cat.updateBookPath(plan.id, plan.dst);
}

/// Create all parent directories of `path` (mkdir -p semantics).
fn mkdirParents(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    // Walk components, mkdir each level.
    var i: usize = 1; // skip leading '/'
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            buf[i] = 0;
            _ = std.c.mkdir(@ptrCast(&buf), 0o755);
            if (i < path.len) buf[i] = '/';
        }
    }
}
