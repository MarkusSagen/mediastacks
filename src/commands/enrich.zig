//! `mediastacks enrich [--missing]` — query Open Library for each book in
//! the catalog, merge results into the existing metadata, write the
//! enriched row back, and cache the provider response for audit.
//!
//! --missing: only enrich books with incomplete metadata
//! --limit N: stop after N books (for spot-testing)

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");
const openlibrary = @import("../providers/openlibrary.zig");
const provider_iface = @import("../providers/provider.zig");
const http = @import("../util/http.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var only_missing = false;
    var limit: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--missing")) {
            only_missing = true;
        } else if (std.mem.eql(u8, args[i], "--limit") and i + 1 < args.len) {
            i += 1;
            limit = std.fmt.parseInt(usize, args[i], 10) catch null;
        }
    }

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    const books = if (only_missing)
        try cat.listIncomplete(ctx.arena)
    else
        try cat.listBooks(ctx.arena);

    var real_http = http.RealHttpClient{ .io = ctx.io };
    var ol = openlibrary.OpenLibrary{ .http_client = real_http.client() };
    const provider = ol.provider();

    var counters: struct { queried: u32 = 0, enriched: u32 = 0, no_hit: u32 = 0, errors: u32 = 0 } = .{};

    for (books, 0..) |book, idx| {
        if (limit) |lim| if (idx >= lim) break;

        const q = provider_iface.Query{
            .isbn = book.metadata.isbn,
            .title = book.metadata.title,
            .author = if (book.metadata.authors.len > 0) book.metadata.authors[0].sort else null,
        };
        counters.queried += 1;
        try ctx.stdout.print("[{d}/{d}] {s}\n", .{ idx + 1, books.len, book.path });

        const remote_opt = provider.lookup(ctx.arena, ctx.io, q) catch |err| {
            try ctx.stderr.print("    error: {s}\n", .{@errorName(err)});
            counters.errors += 1;
            continue;
        };

        const remote = remote_opt orelse {
            try ctx.stdout.print("    no match\n", .{});
            counters.no_hit += 1;
            continue;
        };

        const merged = try meta.BookMetadata.merge(ctx.arena, book.metadata, remote);
        _ = try cat.upsertBook(ctx.arena, .{
            .path = book.path,
            .sha256 = book.sha256,
            .size = book.size,
            .format = book.format,
            .mtime = book.mtime,
            .metadata = merged,
        });
        counters.enriched += 1;
        try ctx.stdout.print("    + ", .{});
        if (remote.title) |t| try ctx.stdout.print("title='{s}' ", .{t});
        if (remote.published_year) |y| try ctx.stdout.print("year={d} ", .{y});
        if (remote.isbn) |i_| try ctx.stdout.print("isbn={s} ", .{i_});
        if (remote.cover_path) |c| try ctx.stdout.print("cover={s} ", .{c});
        try ctx.stdout.print("\n", .{});
    }

    try ctx.stdout.print(
        "\nqueried={d} enriched={d} no_match={d} errors={d}\n",
        .{ counters.queried, counters.enriched, counters.no_hit, counters.errors },
    );
    return 0;
}
