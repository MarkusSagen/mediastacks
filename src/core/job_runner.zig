//! Job executor + scheduler loop.
//!
//! Shared by the in-process scheduler running inside `mediastacks serve`
//! and the standalone `mediastacks schedule daemon`. The executor takes
//! a Job and dispatches by `job_type` to the actual work. The loop
//! polls the catalog every minute for due jobs and runs them one at
//! a time.
//!
//! Concurrency: a single global mutex guards "is a job running right
//! now?" so the loop can't double-fire and so the web UI's Run-now
//! button can wait for an in-progress job to finish.

const std = @import("std");
const c = @import("c");
const sql = @import("../ffi/sqlite3.zig");
const catalog_mod = @import("catalog.zig");
const jobs = @import("jobs.zig");
const sources_cmd = @import("../commands/sources.zig");
const path_meta = @import("path_meta.zig");
const clock = @import("../util/clock.zig");
const shutdown = @import("../util/shutdown.zig");
const enrich_job = @import("../web/enrich_job.zig");
const standardize = @import("standardize.zig");

const log = std.log.scoped(.sched);

/// Single global "is a job running" flag. The scheduler loop and the
/// web Run-now handler both check + set it. tryLock semantics: if
/// taken, the caller skips this tick. Zig 0.16 has no Thread.Mutex
/// but std.Io.Mutex's tryLock works without needing an Io for the
/// non-blocking check.
var running_mu: std.Io.Mutex = std.Io.Mutex.init;

/// Run a single job to completion. Updates the row's last_run_*
/// columns and recomputes next_run_at. Returns true if it actually
/// ran (false when another job was already in flight).
pub fn runJob(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    job: jobs.Job,
) !bool {
    if (!running_mu.tryLock()) return false;
    defer running_mu.unlock(io);

    const start = clock.nowSeconds();
    jobs.markRunning(cat.db, job.id, start) catch |err| {
        log.warn("markRunning({d}): {s}", .{ job.id, @errorName(err) });
    };
    log.info("job {d} '{s}' ({s}) starting", .{ job.id, job.name, job.job_type.toString() });

    var summary_buf: [512]u8 = undefined;
    const outcome = dispatch(arena, io, cat, job, &summary_buf);
    jobs.markComplete(cat.db, job, outcome.status, outcome.summary, clock.nowSeconds()) catch |err| {
        log.warn("markComplete({d}): {s}", .{ job.id, @errorName(err) });
    };
    log.info("job {d} '{s}' done: {s} — {s}", .{ job.id, job.name, outcome.status.toString(), outcome.summary });
    return true;
}

const Outcome = struct {
    status: jobs.RunStatus,
    summary: []const u8,
};

fn dispatch(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    job: jobs.Job,
    buf: *[512]u8,
) Outcome {
    return switch (job.job_type) {
        .rescan_all => blk: {
            const result = runRescanAll(arena, io, cat) catch |err| {
                break :blk errResult(buf, err);
            };
            break :blk okResult(buf, "{d} sources scanned, {d} added, {d} missing, {d} errors", .{
                result.sources, result.added, result.missing, result.errors,
            });
        },
        .backfill_paths => blk: {
            const n = runBackfillPaths(arena, cat) catch |err| {
                break :blk errResult(buf, err);
            };
            break :blk okResult(buf, "{d} row{s} updated", .{ n, if (n == 1) @as([]const u8, "") else @as([]const u8, "s") });
        },
        .enrich_missing => blk: {
            const r = runEnrichMissing(arena, io, cat) catch |err| {
                break :blk errResult(buf, err);
            };
            break :blk okResult(buf, "{d} queried, {d} ok, {d} no-match, {d} errors", .{ r.queried, r.ok, r.no_match, r.errors });
        },
        .standardize_dry => blk: {
            const r = runStandardizeDry(arena, cat) catch |err| {
                break :blk errResult(buf, err);
            };
            break :blk okResult(buf, "{d} total, {d} would change, {d} already canonical, {d} unrenameable", .{ r.total, r.would_change, r.same, r.unrenameable });
        },
    };
}

fn okResult(buf: *[512]u8, comptime fmt: []const u8, args: anytype) Outcome {
    const s = std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
    return .{ .status = .ok, .summary = s };
}
fn errResult(buf: *[512]u8, err: anyerror) Outcome {
    const s = std.fmt.bufPrint(buf, "error: {s}", .{@errorName(err)}) catch buf[0..0];
    return .{ .status = .err, .summary = s };
}

const RescanSummary = struct {
    sources: u32 = 0,
    added: u32 = 0,
    missing: u32 = 0,
    errors: u32 = 0,
};

/// rescan-all: walk every tracked library source. Equivalent to the
/// web UI's "Rescan all" button + the smoke test's bulk rescan.
fn runRescanAll(arena: std.mem.Allocator, io: std.Io, cat: *catalog_mod.Catalog) !RescanSummary {
    const sources = try cat.listSources(arena);
    var r: RescanSummary = .{};
    for (sources) |src| {
        if (shutdown.isRequested()) break;
        const stats = sources_cmd.scanSourceFromHttp(arena, io, cat, src.id, src.path) catch |err| {
            log.warn("rescan {d} ({s}): {s}", .{ src.id, src.path, @errorName(err) });
            r.errors += 1;
            continue;
        };
        r.sources += 1;
        r.added += stats.added;
        r.missing += stats.missing;
    }
    return r;
}

const EnrichSummary = struct {
    queried: u32 = 0,
    ok: u32 = 0,
    no_match: u32 = 0,
    errors: u32 = 0,
};

/// enrich-missing: per-book Open Library lookup for every catalog row
/// flagged eligible (`enrich_status IS NULL` or `'error'`). Already-OK
/// and confirmed `no_match` rows are skipped — re-running the job is
/// idempotent. Same code path the web's batch enrich uses, so the
/// scheduler version honours the same enrich_status writeback.
///
/// Note on cache: `enrich_job.enrichOne` does NOT consult the OL
/// metadata-source cache before hitting the network. That's deliberate
/// — the cache is for the per-book "Fetch info" diff flow; the
/// batch/scheduled path is gated by `enrich_status` instead, which is
/// a stronger filter (it tracks completion across catalog runs).
fn runEnrichMissing(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
) !EnrichSummary {
    var r: EnrichSummary = .{};
    const books = try cat.listForEnrichment(arena);
    for (books) |b| {
        if (shutdown.isRequested()) break;
        r.queried += 1;
        const status = enrich_job.enrichOne(arena, io, cat, b) catch |err| blk: {
            log.warn("enrich book {d} ({s}): {s}", .{ b.id, b.path, @errorName(err) });
            r.errors += 1;
            break :blk catalog_mod.Catalog.EnrichStatus.@"error";
        };
        cat.setEnrichStatus(b.id, status) catch {};
        switch (status) {
            .ok => r.ok += 1,
            .no_match => r.no_match += 1,
            .@"error" => {},
        }
    }
    return r;
}

/// standardize-dry: build the canonical-rename plan for every
/// catalogued book and report counts only. No file mutations. Same
/// `default` template the rename lens previews — users see the
/// would-change number tick down each time the maintenance job
/// completes a real rename run.
fn runStandardizeDry(arena: std.mem.Allocator, cat: *catalog_mod.Catalog) !standardize.Counts {
    const template_mod = @import("template.zig");
    const plans = try standardize.planAll(arena, cat, template_mod.DEFAULT_TEMPLATE);
    return standardize.summarize(plans);
}

/// backfill-paths: for every book without `series`, try parsing the
/// filename. Same logic the `Backfill from filenames` sidebar button
/// runs synchronously. Returns the number of rows updated.
fn runBackfillPaths(arena: std.mem.Allocator, cat: *catalog_mod.Catalog) !u32 {
    const books = try cat.listBooks(arena);
    var updated: u32 = 0;
    for (books) |b| {
        if (b.metadata.series != null) continue;
        const derived = path_meta.fromPath(arena, b.path) catch continue;
        if (derived.series == null and derived.series_index == null) continue;
        var md = b.metadata;
        if (derived.series) |s| md.series = s;
        if (derived.series_index) |idx| md.series_index = idx;
        _ = cat.upsertBook(arena, .{
            .path = b.path,
            .sha256 = b.sha256,
            .size = b.size,
            .format = b.format,
            .mtime = b.mtime,
            .metadata = md,
        }) catch continue;
        updated += 1;
    }
    return updated;
}

pub const LoopConfig = struct {
    /// Seconds between ticks. Default 60s — granularity finer than
    /// that doesn't add value for maintenance jobs.
    tick_seconds: u64 = 60,
};

pub fn loop(
    arena_parent: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    cfg: LoopConfig,
) !void {
    log.info("scheduler loop starting (tick={d}s)", .{cfg.tick_seconds});
    while (!shutdown.isRequested()) {
        var arena_state = std.heap.ArenaAllocator.init(arena_parent);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const now = clock.nowSeconds();
        const due = jobs.listDue(cat.db, arena, now) catch |err| {
            log.warn("listDue: {s}", .{@errorName(err)});
            sleepInterruptible(cfg.tick_seconds);
            continue;
        };
        for (due) |job| {
            if (shutdown.isRequested()) break;
            _ = runJob(arena, io, cat, job) catch |err| {
                log.warn("runJob({d}): {s}", .{ job.id, @errorName(err) });
            };
        }
        sleepInterruptible(cfg.tick_seconds);
    }
    log.info("scheduler loop exiting", .{});
}

/// Sleep `seconds` but wake up every 250ms to check the shutdown
/// flag. Matches the rest of the codebase's interruptible-sleep
/// pattern (see providers/openlibrary.zig::httpGetOk).
fn sleepInterruptible(seconds: u64) void {
    var remaining_ms: u64 = seconds * 1000;
    while (remaining_ms > 0) {
        if (shutdown.isRequested()) return;
        const chunk: u64 = if (remaining_ms > 250) 250 else remaining_ms;
        clock.sleepMs(chunk);
        remaining_ms -= chunk;
    }
}
