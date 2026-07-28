//! Background thumb-cache pre-warmer.
//!
//! On serve startup we fan out one worker thread that walks the catalog
//! once and writes a thumb to `$XDG_DATA_HOME/booktool/thumbs/<id>.<ext>`
//! for every book that doesn't already have one. The gallery's
//! IntersectionObserver requests covers as the user scrolls, and once
//! warmed those requests serve from disk in ~0.6ms instead of paying
//! a fresh zip-parse (EPUB) or `fork+exec mobitool` (MOBI/AZW3) per
//! cover.
//!
//! Best-effort, silent on errors: a single book failing to extract
//! (corrupt EPUB, file moved, etc.) should not stop the rest.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");
const cover_mod = @import("../core/cover.zig");
const cover_store = @import("../core/cover_store.zig");
const shutdown = @import("../util/shutdown.zig");

const WorkerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cat_path: []u8,
    env: *std.process.Environ.Map,
};

fn workerEntry(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.cat_path);
        ctx.allocator.destroy(ctx);
    }

    var cat = catalog_mod.Catalog.open(ctx.cat_path) catch |err| {
        std.log.warn("prewarm: open catalog: {s}", .{@errorName(err)});
        return;
    };
    defer cat.close();

    var outer_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer outer_state.deinit();
    const outer = outer_state.allocator();

    const books = cat.listBooks(outer) catch |err| {
        std.log.warn("prewarm: list books: {s}", .{@errorName(err)});
        return;
    };

    var inner_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer inner_state.deinit();

    var warmed: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;

    for (books) |b| {
        if (shutdown.isRequested()) break;
        _ = inner_state.reset(.retain_capacity);
        const inner = inner_state.allocator();

        const existing = cover_store.existingThumbPath(inner, ctx.env, b.id) catch null;
        if (existing != null) {
            skipped += 1;
            continue;
        }
        const override = cover_store.existingPath(inner, ctx.env, b.id) catch null;
        if (override != null) {
            skipped += 1;
            continue;
        }
        const bytes = cover_mod.extract(inner, ctx.io, b.path, b.format) catch {
            failed += 1;
            continue;
        };
        cover_store.writeThumb(inner, ctx.env, b.id, bytes) catch {
            failed += 1;
            continue;
        };
        warmed += 1;
    }

    std.log.info(
        "prewarm: cached {d} new thumb(s), skipped {d}, failed {d}",
        .{ warmed, skipped, failed },
    );
}

/// Spawn a detached worker thread that pre-warms the thumb cache.
/// Returns immediately; the worker frees its own context on exit.
pub fn spawnPrewarm(
    allocator: std.mem.Allocator,
    io: std.Io,
    cat_path: []const u8,
    env: *std.process.Environ.Map,
) !void {
    const ctx = try allocator.create(WorkerCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .io = io,
        .cat_path = try allocator.dupe(u8, cat_path),
        .env = env,
    };
    errdefer allocator.free(ctx.cat_path);
    const thread = try std.Thread.spawn(.{}, workerEntry, .{ctx});
    thread.detach();
}
