//! `booktool scan DIR` — walk DIR recursively, extract embedded metadata,
//! and upsert each ebook into the SQLite catalog.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");
const format_mod = @import("../formats/format.zig");
const registry = @import("../formats/registry.zig");
const epub_reader = @import("../formats/epub.zig");
const mobi_reader = @import("../formats/mobi.zig");
const hash_util = @import("../util/hash.zig");
const path_meta = @import("../core/path_meta.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: booktool scan DIR\n", .{});
        return 1;
    }
    const dir_path = args[0];

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(ctx.io, dir_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("cannot open {s}: {s}\n", .{ dir_path, @errorName(err) });
        return 2;
    };
    defer dir.close(ctx.io);

    const catalog_path = catalog_mod.defaultPath(ctx.arena, ctx.env) catch |err| {
        try ctx.stderr.print("cannot resolve catalog path: {s}\n", .{@errorName(err)});
        return 2;
    };
    var cat = catalog_mod.Catalog.open(catalog_path) catch |err| {
        try ctx.stderr.print("cannot open catalog at {s}: {s}\n", .{ catalog_path, @errorName(err) });
        return 2;
    };
    defer cat.close();

    var walker = try dir.walk(ctx.arena);
    defer walker.deinit();

    var counters: struct { seen: u32 = 0, ingested: u32 = 0, skipped: u32 = 0, errors: u32 = 0 } = .{};

    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (ext.len < 2) continue;
        const fmt = meta.Format.fromExtension(ext[1..]);
        if (fmt == .unknown) continue;

        counters.seen += 1;
        const full_path = try std.fs.path.join(ctx.arena, &.{ dir_path, entry.path });

        const result = ingestOne(ctx, &cat, full_path, fmt) catch |err| {
            try ctx.stderr.print("error: {s}: {s}\n", .{ full_path, @errorName(err) });
            counters.errors += 1;
            continue;
        };
        switch (result) {
            .ingested => |id| {
                counters.ingested += 1;
                try ctx.stdout.print("[+] id={d} {s} {s}\n", .{ id, @tagName(fmt), full_path });
            },
            .skipped_unchanged => |id| {
                counters.skipped += 1;
                try ctx.stdout.print("[=] id={d} {s}\n", .{ id, full_path });
            },
        }
    }

    try ctx.stdout.print(
        "\nseen={d} ingested={d} unchanged={d} errors={d}\n",
        .{ counters.seen, counters.ingested, counters.skipped, counters.errors },
    );
    return if (counters.errors == 0) 0 else 1;
}

const IngestResult = union(enum) {
    ingested: i64,
    skipped_unchanged: i64,
};

fn ingestOne(
    ctx: cli.Context,
    cat: *catalog_mod.Catalog,
    path: []const u8,
    fmt: meta.Format,
) !IngestResult {
    var hex_buf: [hash_util.HEX_LEN]u8 = undefined;
    const sha = try hash_util.fileSha256Hex(ctx.io, path, &hex_buf);
    const sha_owned = try ctx.arena.dupe(u8, sha);

    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(ctx.io, path, .{});
    defer f.close(ctx.io);
    const stat = try f.stat(ctx.io);
    const size = stat.size;
    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));

    if (try cat.getBookByPath(ctx.arena, path)) |existing| {
        if (std.mem.eql(u8, existing.sha256, sha_owned)) {
            return .{ .skipped_unchanged = existing.id };
        }
    }

    var md = if (registry.forFormat(fmt)) |h|
        try h.readMetadata(ctx.arena, ctx.io, path)
    else
        meta.BookMetadata{ .source = .derived, .confidence = 0.1 };

    const derived = path_meta.fromPath(ctx.arena, path) catch path_meta.Derived{};
    if (md.series == null and derived.series != null) {
        md.series = derived.series;
        if (derived.series_index) |idx| md.series_index = idx;
    } else if (md.series_index == null and derived.series_index != null and
        md.series != null and derived.series != null and
        std.ascii.eqlIgnoreCase(md.series.?, derived.series.?))
    {
        md.series_index = derived.series_index;
    }

    const id = try cat.upsertBook(ctx.arena, .{
        .path = path,
        .sha256 = sha_owned,
        .size = size,
        .format = fmt,
        .mtime = mtime,
        .metadata = md,
    });
    return .{ .ingested = id };
}
