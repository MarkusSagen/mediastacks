//! `booktool dedup [--apply]` — find and optionally delete duplicate
//! books from the catalog and filesystem.
//!
//! Two tiers reported:
//!   - exact: identical SHA-256
//!   - fuzzy: same author + Jaro-Winkler title similarity > threshold
//!
//! With `--apply`, exact duplicates are removed (keeping the smallest
//! row id, i.e. the first one scanned). Fuzzy matches are NEVER auto-
//! deleted — they're listed for manual review.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const dedup_mod = @import("../core/dedup.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var apply = false;
    var skip_fuzzy = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--apply")) apply = true;
        if (std.mem.eql(u8, a, "--exact-only")) skip_fuzzy = true;
    }

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    // Tier 1: exact.
    const exact_groups = try cat.listExactDuplicateGroups(ctx.arena);
    var removed: u32 = 0;

    if (exact_groups.len == 0) {
        try ctx.stdout.print("(no exact duplicates)\n", .{});
    } else {
        try ctx.stdout.print("== Exact duplicates (by SHA-256) ==\n", .{});
        for (exact_groups) |group| {
            try ctx.stdout.print("\nsha256={s}\n", .{group.sha256[0..12]});
            for (group.ids, 0..) |id, i| {
                const b = (try cat.getBookById(ctx.arena, id)) orelse continue;
                const marker = if (i == 0) "keep " else if (apply) "REMOVE" else "dup  ";
                try ctx.stdout.print("  [{s}] id={d}  {s}\n", .{ marker, b.id, b.path });
                if (apply and i > 0) {
                    try removeBook(ctx, &cat, b);
                    removed += 1;
                }
            }
        }
    }

    if (!skip_fuzzy) {
        try findFuzzy(ctx, &cat);
    }

    if (apply) {
        try ctx.stdout.print("\nremoved {d} duplicate file(s)\n", .{removed});
    } else if (exact_groups.len > 0) {
        try ctx.stdout.print("\n(dry run — pass --apply to delete duplicates)\n", .{});
    }
    return 0;
}

fn removeBook(ctx: cli.Context, cat: *catalog_mod.Catalog, book: catalog_mod.Book) !void {
    // Delete the file first, then the catalog row. Tolerate file already
    // missing (idempotent --apply).
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{book.path});
    _ = std.c.unlink(path_z.ptr);
    try cat.deleteBook(book.id);
    _ = ctx;
}

fn findFuzzy(ctx: cli.Context, cat: *catalog_mod.Catalog) !void {
    const books = try cat.listBooks(ctx.arena);
    if (books.len < 2) return;

    var any_found = false;
    var i: usize = 0;
    while (i < books.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < books.len) : (j += 1) {
            const a = books[i];
            const b = books[j];
            if (a.metadata.title == null or b.metadata.title == null) continue;
            if (a.metadata.authors.len == 0 or b.metadata.authors.len == 0) continue;
            if (!std.mem.eql(u8, a.metadata.authors[0].sort, b.metadata.authors[0].sort)) continue;
            if (std.mem.eql(u8, a.sha256, b.sha256)) continue; // already reported as exact

            const score = try dedup_mod.compareTitles(ctx.arena, a.metadata.title.?, b.metadata.title.?);
            if (score < dedup_mod.FUZZY_THRESHOLD) continue;

            if (!any_found) {
                try ctx.stdout.print("\n== Fuzzy matches (same author + similar title) ==\n", .{});
                any_found = true;
            }
            try ctx.stdout.print(
                "  score={d:.3}  id={d} {s}\n            id={d} {s}\n",
                .{ score, a.id, a.path, b.id, b.path },
            );
        }
    }
    if (!any_found) try ctx.stdout.print("(no fuzzy duplicates)\n", .{});
}
