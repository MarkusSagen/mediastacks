//! `booktool sources …` — manage watched ebook folders.
//!
//! A "library source" is a folder the user has asked booktool to
//! track. The catalog stores each source's path + a couple of stats
//! about the last scan. Rescanning a source walks the folder, ingests
//! new files (linked to the source), and marks previously-known books
//! whose files have vanished from disk.
//!
//! Subcommands:
//!   add PATH [--name N]   register a folder + scan it
//!   list                  show all sources with last-scan stats
//!   rescan ID|all         re-walk a source (or every source) and
//!                         update missing flags
//!   remove ID             drop a source (books keep their entries
//!                         but lose the source_id link)
//!
//! The actual scan helper (`scanSource`) is reused by the web API
//! handler, so the same code path runs whether the user calls the
//! CLI, the web button, or the TUI key.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");
const epub_reader = @import("../formats/epub.zig");
const mobi_reader = @import("../formats/mobi.zig");
const hash_util = @import("../util/hash.zig");
const path_meta = @import("../core/path_meta.zig");
const clock = @import("../util/clock.zig");
const shutdown = @import("../util/shutdown.zig");

pub const ScanStats = struct {
    seen: u32 = 0,
    added: u32 = 0,
    updated: u32 = 0,
    missing: u32 = 0,
    errors: u32 = 0,
};

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 1) return printUsage(ctx);
    const sub = args[0];
    const rest = args[1..];

    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(catalog_path);
    defer cat.close();

    if (std.mem.eql(u8, sub, "add")) return runAdd(ctx, &cat, rest);
    if (std.mem.eql(u8, sub, "list")) return runList(ctx, &cat);
    if (std.mem.eql(u8, sub, "rescan")) return runRescan(ctx, &cat, rest);
    if (std.mem.eql(u8, sub, "remove")) return runRemove(ctx, &cat, rest);
    return printUsage(ctx);
}

fn printUsage(ctx: cli.Context) !u8 {
    try ctx.stderr.print(
        \\usage:
        \\  booktool sources add PATH [--name N]
        \\  booktool sources list
        \\  booktool sources rescan ID|all
        \\  booktool sources remove ID
        \\
    , .{});
    return 1;
}

fn runAdd(ctx: cli.Context, cat: *catalog_mod.Catalog, args: []const []const u8) !u8 {
    if (args.len < 1) return printUsage(ctx);
    const path = args[0];
    var name: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--name") and i + 1 < args.len) {
            name = args[i + 1];
            i += 1;
        }
    }

    const abs_owned = try ctx.arena.dupe(u8, path);

    const id = try cat.addSource(ctx.arena, abs_owned, name);
    try ctx.stdout.print("[+] source id={d} path={s}\n", .{ id, abs_owned });

    const stats = scanSource(ctx, cat, id, abs_owned) catch |err| {
        try ctx.stderr.print("scan failed: {s}\n", .{@errorName(err)});
        return 0;
    };
    try printStats(ctx, stats);
    return 0;
}

fn runList(ctx: cli.Context, cat: *catalog_mod.Catalog) !u8 {
    const sources = try cat.listSources(ctx.arena);
    if (sources.len == 0) {
        try ctx.stdout.print("no sources registered. use `booktool sources add PATH` to add one.\n", .{});
        return 0;
    }
    for (sources) |s| {
        const name = s.name orelse std.fs.path.basename(s.path);
        const last = if (s.last_scanned_at) |t| std.fmt.allocPrint(ctx.arena, "{d}s ago", .{clock.nowSeconds() - t}) catch "?" else "never";
        try ctx.stdout.print(
            "  id={d}  {s}\n      path:        {s}\n      last scan:   {s}\n      last counts: seen={d} added={d} missing={d}\n\n",
            .{ s.id, name, s.path, last, s.last_seen, s.last_added, s.last_missing },
        );
    }
    return 0;
}

fn runRescan(ctx: cli.Context, cat: *catalog_mod.Catalog, args: []const []const u8) !u8 {
    if (args.len < 1) return printUsage(ctx);

    if (std.mem.eql(u8, args[0], "all")) {
        const sources = try cat.listSources(ctx.arena);
        var total = ScanStats{};
        for (sources) |s| {
            try ctx.stdout.print("== scanning id={d} {s} ==\n", .{ s.id, s.path });
            const stats = scanSource(ctx, cat, s.id, s.path) catch |err| {
                try ctx.stderr.print("scan failed: {s}\n", .{@errorName(err)});
                continue;
            };
            try printStats(ctx, stats);
            total.seen += stats.seen;
            total.added += stats.added;
            total.updated += stats.updated;
            total.missing += stats.missing;
            total.errors += stats.errors;
        }
        try ctx.stdout.print("\n== total: seen={d} added={d} updated={d} missing={d} errors={d} ==\n", .{
            total.seen, total.added, total.updated, total.missing, total.errors,
        });
        return 0;
    }

    const id = std.fmt.parseInt(i64, args[0], 10) catch return printUsage(ctx);
    const src = (try cat.getSourceById(ctx.arena, id)) orelse {
        try ctx.stderr.print("no source with id={d}\n", .{id});
        return 2;
    };
    const stats = try scanSource(ctx, cat, src.id, src.path);
    try printStats(ctx, stats);
    return 0;
}

fn runRemove(ctx: cli.Context, cat: *catalog_mod.Catalog, args: []const []const u8) !u8 {
    if (args.len < 1) return printUsage(ctx);
    const id = std.fmt.parseInt(i64, args[0], 10) catch return printUsage(ctx);
    try cat.removeSource(id);
    try ctx.stdout.print("[-] removed source id={d}\n", .{id});
    return 0;
}

fn printStats(ctx: cli.Context, stats: ScanStats) !void {
    try ctx.stdout.print(
        "    seen={d} added={d} updated={d} missing={d} errors={d}\n",
        .{ stats.seen, stats.added, stats.updated, stats.missing, stats.errors },
    );
}

/// CLI-flavoured wrapper. Forwards into `scanSourceWithIo` and prints
/// per-file errors to stderr.
pub fn scanSource(
    ctx: cli.Context,
    cat: *catalog_mod.Catalog,
    source_id: i64,
    root_path: []const u8,
) !ScanStats {
    return scanSourceWithIo(ctx.arena, ctx.io, cat, source_id, root_path, ctx.stderr);
}

/// Context-free version usable from the web API and TUI. `stderr` is
/// optional — pass null to swallow per-file errors silently.
pub fn scanSourceFromHttp(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    source_id: i64,
    root_path: []const u8,
) !ScanStats {
    return scanSourceWithIo(arena, io, cat, source_id, root_path, null);
}

pub fn scanSourceWithIo(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    source_id: i64,
    root_path: []const u8,
    stderr: ?*std.Io.Writer,
) !ScanStats {
    cat.markSourceScanning(source_id, 0) catch {};
    const total = countEbookFiles(arena, io, root_path) catch |err| {
        if (stderr) |w| w.print("cannot open {s}: {s}\n", .{ root_path, @errorName(err) }) catch {};
        cat.markSourceError(source_id, @errorName(err)) catch {};
        return err;
    };
    cat.markSourceScanning(source_id, @intCast(total)) catch {};

    var stats = ScanStats{};

    var prev = std.StringHashMap(i64).init(arena);
    const prior = try cat.listBooksUnderSource(arena, source_id);
    for (prior) |b| try prev.put(b.path, b.id);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| {
        if (stderr) |w| w.print("cannot open {s}: {s}\n", .{ root_path, @errorName(err) }) catch {};
        cat.markSourceError(source_id, @errorName(err)) catch {};
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (shutdown.isRequested()) break;
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (ext.len < 2) continue;
        const fmt = meta.Format.fromExtension(ext[1..]);
        if (fmt == .unknown) continue;

        stats.seen += 1;
        const full_path = try std.fs.path.join(arena, &.{ root_path, entry.path });

        const outcome = ingestOne(arena, io, cat, full_path, fmt, source_id) catch |err| {
            if (stderr) |w| w.print("error: {s}: {s}\n", .{ full_path, @errorName(err) }) catch {};
            stats.errors += 1;
            continue;
        };
        switch (outcome) {
            .added => stats.added += 1,
            .updated => stats.updated += 1,
            .unchanged => {},
        }
        _ = prev.remove(full_path);

        cat.updateSourceScanProgress(source_id, stats.seen) catch {};
    }

    var it = prev.iterator();
    while (it.next()) |kv| {
        cat.markBookMissing(kv.value_ptr.*) catch continue;
        stats.missing += 1;
    }

    try cat.updateSourceScanStats(source_id, stats.seen, stats.added, stats.missing);
    cat.clearSourceScanning(source_id) catch {};
    return stats;
}

const ScanWorkerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cat_path: []u8,
    root_path: []u8,
    source_id: i64,
};

fn workerEntry(ctx: *ScanWorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.cat_path);
        ctx.allocator.free(ctx.root_path);
        ctx.allocator.destroy(ctx);
    }

    var cat = catalog_mod.Catalog.open(ctx.cat_path) catch |err| {
        std.log.warn("scan worker: open catalog: {s}", .{@errorName(err)});
        return;
    };
    defer cat.close();

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();

    _ = scanSourceWithIo(
        arena_state.allocator(),
        ctx.io,
        &cat,
        ctx.source_id,
        ctx.root_path,
        null,
    ) catch |err| {
        std.log.warn("scan worker {d} {s}: {s}", .{ ctx.source_id, ctx.root_path, @errorName(err) });
        cat.clearSourceScanning(ctx.source_id) catch {};
    };
}

/// Spawn a detached worker thread that runs the scan. Returns once
/// the thread has been started — does NOT wait for the scan to
/// finish. The worker frees its own context before exiting.
pub fn spawnBackgroundScan(
    allocator: std.mem.Allocator,
    io: std.Io,
    cat_path: []const u8,
    source_id: i64,
    root_path: []const u8,
) !void {
    const ctx = try allocator.create(ScanWorkerCtx);
    errdefer allocator.destroy(ctx);
    const cat_dupe = try allocator.dupe(u8, cat_path);
    errdefer allocator.free(cat_dupe);
    const root_dupe = try allocator.dupe(u8, root_path);
    errdefer allocator.free(root_dupe);
    ctx.* = .{
        .allocator = allocator,
        .io = io,
        .cat_path = cat_dupe,
        .root_path = root_dupe,
        .source_id = source_id,
    };
    const thread = try std.Thread.spawn(.{}, workerEntry, .{ctx});
    thread.detach();
}

/// Phase 1 helper: count how many ebook files live under `root_path`.
/// Single fast walk — no hashing, no metadata reads. Used to set
/// `scan_total` so the UI shows a real percentage from poll #1.
fn countEbookFiles(
    arena: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
) !usize {
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, root_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (ext.len < 2) continue;
        const fmt = meta.Format.fromExtension(ext[1..]);
        if (fmt == .unknown) continue;
        n += 1;
    }
    return n;
}

const IngestOutcome = enum { added, updated, unchanged };

fn ingestOne(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    path: []const u8,
    fmt: meta.Format,
    source_id: i64,
) !IngestOutcome {
    var hex_buf: [hash_util.HEX_LEN]u8 = undefined;
    const sha = try hash_util.fileSha256Hex(io, path, &hex_buf);
    const sha_owned = try arena.dupe(u8, sha);

    const cwd = std.Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);
    const stat = try f.stat(io);
    const size = stat.size;
    const mtime: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));

    if (try cat.getBookByPath(arena, path)) |existing| {
        if (std.mem.eql(u8, existing.sha256, sha_owned)) {
            try cat.setBookSource(existing.id, source_id);
            if (existing.missing_at != null) try cat.clearBookMissing(existing.id);
            return .unchanged;
        }
    }

    var md = switch (fmt) {
        .epub => try epub_reader.readMetadata(arena, path),
        .mobi, .azw3 => try mobi_reader.readMetadata(arena, path),
        else => meta.BookMetadata{ .source = .derived, .confidence = 0.1 },
    };
    const derived = path_meta.fromPath(arena, path) catch path_meta.Derived{};
    if (md.series == null and derived.series != null) {
        md.series = derived.series;
        if (derived.series_index) |idx| md.series_index = idx;
    }

    const existing_book = try cat.getBookByPath(arena, path);
    const id = try cat.upsertBook(arena, .{
        .path = path,
        .sha256 = sha_owned,
        .size = size,
        .format = fmt,
        .mtime = mtime,
        .metadata = md,
    });
    try cat.setBookSource(id, source_id);
    try cat.clearBookMissing(id);
    return if (existing_book == null) .added else .updated;
}
