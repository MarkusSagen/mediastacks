//! `booktool rename [--apply]` — propose or perform canonical renames.
//!
//! For each renameable book in the catalog, compute
//!   `{author_sort} - {series} {series_index:02} - {title}.{ext}`
//! relative to the file's current directory. Dry-run by default.
//!
//! On --apply: rename the file on disk, then update the catalog row's
//! path atomically (in that order — if the rename fails, the DB is
//! untouched; if the DB update fails, a stale row is left pointing at
//! the new path and a re-scan will repair it).

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const rename_mod = @import("../core/rename.zig");

const RenamePlan = struct {
    id: i64,
    src: []const u8,
    dst: []const u8,
    same: bool,
};

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var apply = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--apply")) apply = true;
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
        if (!book.metadata.isRenameable()) {
            unrenameable += 1;
            continue;
        }
        const new_basename = rename_mod.buildFilename(ctx.arena, book.metadata, book.format) catch |err| switch (err) {
            error.IncompleteMetadata => {
                unrenameable += 1;
                continue;
            },
            else => return err,
        };
        const parent = std.fs.path.dirname(book.path) orelse ".";
        const dst_path = try std.fs.path.join(ctx.arena, &.{ parent, new_basename });
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
            executeRename(ctx, &cat, plan) catch |err| {
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

fn executeRename(
    ctx: cli.Context,
    cat: *catalog_mod.Catalog,
    plan: RenamePlan,
) !void {
    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{plan.src});
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{plan.dst});

    // Refuse to clobber an existing destination unless the user is just
    // re-applying an already-completed rename.
    if (std.c.access(dst_z.ptr, 0) == 0) {
        return error.DestinationExists;
    }
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) return error.RenameFailed;
    try cat.updateBookPath(plan.id, plan.dst);
    _ = ctx;
}
