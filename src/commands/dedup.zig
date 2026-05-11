//! `booktool dedup [--apply] [--exact-only] [--fuzzy-only]`
//!
//! Two-tier duplicate detection:
//!   exact  identical SHA-256 → certain duplicate
//!   fuzzy  same author + Jaro-Winkler title above threshold, regardless
//!          of format/edition (so EPUB + MOBI of the same book group)
//!
//! With --apply, every duplicate beyond the "keep" candidate is deleted
//! from disk and the catalog. The "keep" book is the highest-scoring
//! copy per `core/quality.zig`: format (EPUB > AZW3 > MOBI > PDF),
//! metadata completeness, then file size as tiebreaker.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const dedup_mod = @import("../core/dedup.zig");
const quality = @import("../core/quality.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var apply = false;
    var only_exact = false;
    var only_fuzzy = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--apply")) apply = true;
        if (std.mem.eql(u8, a, "--exact-only")) only_exact = true;
        if (std.mem.eql(u8, a, "--fuzzy-only")) only_fuzzy = true;
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printHelp(ctx.stdout);
            return 0;
        }
    }

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    var removed: u32 = 0;

    if (!only_fuzzy) {
        removed += try reportExact(ctx, &cat, apply);
    }
    if (!only_exact) {
        removed += try reportFuzzy(ctx, &cat, apply);
    }

    if (apply) {
        try ctx.stdout.print("\nremoved {d} duplicate file(s)\n", .{removed});
    }
    return 0;
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: booktool dedup [options]
        \\
        \\Options:
        \\  --apply         Actually delete duplicates (default is dry-run)
        \\  --exact-only    Skip fuzzy detection
        \\  --fuzzy-only    Skip exact-SHA detection
        \\
        \\The book kept from each group is the highest-quality copy:
        \\format (EPUB > AZW3 > MOBI > PDF) + metadata completeness + size.
        \\
    );
}

fn reportExact(ctx: cli.Context, cat: *catalog_mod.Catalog, apply: bool) !u32 {
    const groups = try cat.listExactDuplicateGroups(ctx.arena);
    if (groups.len == 0) {
        try ctx.stdout.print("(no exact duplicates)\n", .{});
        return 0;
    }
    try ctx.stdout.print("== Exact duplicates (identical SHA-256) ==\n", .{});

    var removed: u32 = 0;
    for (groups) |group| {
        try ctx.stdout.print("\nsha256 {s}…  ({d} copies)\n", .{ group.sha256[0..12], group.ids.len });

        // Materialize Book rows so we can score and order them.
        var books: std.ArrayList(catalog_mod.Book) = .empty;
        for (group.ids) |id| {
            if (try cat.getBookById(ctx.arena, id)) |b| try books.append(ctx.arena, b);
        }
        std.mem.sort(catalog_mod.Book, books.items, {}, scoreDesc);

        for (books.items, 0..) |b, i| {
            const tag = if (i == 0) "keep" else if (apply) " del" else " dup";
            try ctx.stdout.print("  [{s}] id={d}  {s}\n", .{ tag, b.id, b.path });
            if (apply and i > 0) {
                try removeBook(&cat.*, b);
                removed += 1;
            }
        }
    }
    return removed;
}

fn reportFuzzy(ctx: cli.Context, cat: *catalog_mod.Catalog, apply: bool) !u32 {
    const books = try cat.listBooks(ctx.arena);
    const groups = try dedup_mod.groupByLogicalIdentity(ctx.arena, books);

    // Filter out groups that are 100% exact-SHA matches (already
    // reported in the exact section).
    var meaningful: std.ArrayList(dedup_mod.Group) = .empty;
    for (groups) |g| {
        var all_same_hash = true;
        var i: usize = 1;
        while (i < g.books.len) : (i += 1) {
            if (!std.mem.eql(u8, g.books[0].sha256, g.books[i].sha256)) {
                all_same_hash = false;
                break;
            }
        }
        if (!all_same_hash) try meaningful.append(ctx.arena, g);
    }

    if (meaningful.items.len == 0) {
        try ctx.stdout.print("\n(no cross-format / different-edition duplicates)\n", .{});
        return 0;
    }

    try ctx.stdout.print("\n== Cross-format / fuzzy duplicates ==\n", .{});
    var removed: u32 = 0;

    for (meaningful.items) |group| {
        try ctx.stdout.print(
            "\n{s} — {s}\n",
            .{ group.books[0].metadata.authors[0].sort, group.books[0].metadata.title.? },
        );
        for (group.books, 0..) |b, i| {
            const tag = if (i == 0) "keep" else if (apply) " del" else " dup";
            const score = quality.scoreBook(b);
            try ctx.stdout.print(
                "  [{s}] id={d}  {s}  ({s}, {d} bytes, score {d:.1})\n",
                .{ tag, b.id, b.path, @tagName(b.format), b.size, score },
            );
            if (apply and i > 0) {
                try removeBook(&cat.*, b);
                removed += 1;
            }
        }
    }
    return removed;
}

fn scoreDesc(_: void, a: catalog_mod.Book, b: catalog_mod.Book) bool {
    return quality.scoreBook(a) > quality.scoreBook(b);
}

fn removeBook(cat: *catalog_mod.Catalog, book: catalog_mod.Book) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{book.path});
    _ = std.c.unlink(path_z.ptr); // tolerate already-missing file
    try cat.deleteBook(book.id);
}
