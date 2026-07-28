//! Background batch-enrichment job state.
//!
//! One job at a time. Owned by `WebContext`. The worker thread updates
//! atomic counters as it goes; the HTTP handler reads them for the
//! progress endpoint. `current_title` lives in a fixed-size buffer so
//! we don't need a mutex to coordinate allocator ownership between
//! writer and readers — Zig 0.16's stdlib doesn't ship a blocking
//! Thread.Mutex anyway. A 256-byte cap is plenty for any book title;
//! anything longer is truncated for display.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");
const meta = @import("../core/metadata.zig");
const openlibrary = @import("../providers/openlibrary.zig");
const provider_iface = @import("../providers/provider.zig");
const path_meta = @import("../core/path_meta.zig");
const http = @import("../util/http.zig");
const clock = @import("../util/clock.zig");
const shutdown = @import("../util/shutdown.zig");

const enrich_log = std.log.scoped(.enrich);

pub const State = enum(u8) { idle, running, finished, canceled };

const TITLE_CAP: usize = 256;

/// Snapshot returned to the frontend. All strings are owned by the
/// caller-provided allocator so the job's own buffer can mutate
/// freely after the snapshot is taken.
pub const Snapshot = struct {
    state: State,
    total: u64,
    processed: u64,
    ok: u64,
    no_match: u64,
    errored: u64,
    current_id: i64,
    current_title: []const u8,
    started_at: i64,
    finished_at: i64,
};

pub const Job = struct {
    state: std.atomic.Value(State) = .init(.idle),
    total: std.atomic.Value(u64) = .init(0),
    processed: std.atomic.Value(u64) = .init(0),
    ok: std.atomic.Value(u64) = .init(0),
    no_match: std.atomic.Value(u64) = .init(0),
    errored: std.atomic.Value(u64) = .init(0),
    current_id: std.atomic.Value(i64) = .init(0),
    /// Fixed buffer + atomic length. Writer copies into the buffer
    /// then publishes the length last; reader loads the length first
    /// then memcpys out of the buffer. The very brief window where a
    /// reader could see a partially-written buffer manifests as a
    /// garbled title for one poll — acceptable for a UI label.
    current_title_buf: [TITLE_CAP]u8 = undefined,
    current_title_len: std.atomic.Value(u32) = .init(0),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    started_at: std.atomic.Value(i64) = .init(0),
    finished_at: std.atomic.Value(i64) = .init(0),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Job {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Job) void {
        _ = self;
    }

    /// True iff the worker is mid-flight. Snapshot data is fresh
    /// regardless; this is only used by the HTTP layer to reject a
    /// duplicate "start" request with 409.
    pub fn isRunning(self: *Job) bool {
        return self.state.load(.monotonic) == .running;
    }

    pub fn requestCancel(self: *Job) void {
        self.cancel_requested.store(true, .monotonic);
    }

    /// Take a consistent snapshot. Counters use monotonic atomics so
    /// the values may be slightly skewed across loads (e.g. processed
    /// might lag ok+no_match+errored by 1 for a frame). That's
    /// acceptable for a progress display.
    pub fn snapshot(self: *Job, arena: std.mem.Allocator) !Snapshot {
        const len = self.current_title_len.load(.acquire);
        const capped = @min(len, @as(u32, TITLE_CAP));
        const title_copy = try arena.dupe(u8, self.current_title_buf[0..capped]);
        return .{
            .state = self.state.load(.monotonic),
            .total = self.total.load(.monotonic),
            .processed = self.processed.load(.monotonic),
            .ok = self.ok.load(.monotonic),
            .no_match = self.no_match.load(.monotonic),
            .errored = self.errored.load(.monotonic),
            .current_id = self.current_id.load(.monotonic),
            .current_title = title_copy,
            .started_at = self.started_at.load(.monotonic),
            .finished_at = self.finished_at.load(.monotonic),
        };
    }

    fn setCurrent(self: *Job, id: i64, title: []const u8) void {
        self.current_id.store(id, .monotonic);
        self.current_title_len.store(0, .release);
        const n = @min(title.len, TITLE_CAP);
        @memcpy(self.current_title_buf[0..n], title[0..n]);
        self.current_title_len.store(@intCast(n), .release);
    }

    fn clearCurrent(self: *Job) void {
        self.current_id.store(0, .monotonic);
        self.current_title_len.store(0, .release);
    }
};

const WorkerCtx = struct {
    job: *Job,
    cat_path: []u8,
    allocator: std.mem.Allocator,
    io: std.Io,
};

fn workerEntry(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.cat_path);
        ctx.allocator.destroy(ctx);
    }

    var cat = catalog_mod.Catalog.open(ctx.cat_path) catch |err| {
        std.log.warn("enrich-batch: open catalog: {s}", .{@errorName(err)});
        finalize(ctx.job, .canceled);
        return;
    };
    defer cat.close();

    var outer_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer outer_state.deinit();
    const outer = outer_state.allocator();

    const books = cat.listForEnrichment(outer) catch |err| {
        std.log.warn("enrich-batch: list: {s}", .{@errorName(err)});
        finalize(ctx.job, .canceled);
        return;
    };

    ctx.job.total.store(books.len, .monotonic);

    var inner_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer inner_state.deinit();

    for (books) |b| {
        if (ctx.job.cancel_requested.load(.monotonic) or shutdown.isRequested()) {
            finalize(ctx.job, .canceled);
            return;
        }
        _ = inner_state.reset(.retain_capacity);
        const inner = inner_state.allocator();

        const display = if (b.metadata.title) |t|
            t
        else if (b.path.len > 0)
            std.fs.path.basename(b.path)
        else
            "(untitled)";
        ctx.job.setCurrent(b.id, display);

        const outcome = enrichOne(inner, ctx.io, &cat, b) catch |err| blk: {
            std.log.warn("enrich-batch: book {d}: {s}", .{ b.id, @errorName(err) });
            break :blk catalog_mod.Catalog.EnrichStatus.@"error";
        };
        cat.setEnrichStatus(b.id, outcome) catch {};

        switch (outcome) {
            .ok => _ = ctx.job.ok.fetchAdd(1, .monotonic),
            .no_match => _ = ctx.job.no_match.fetchAdd(1, .monotonic),
            .@"error" => _ = ctx.job.errored.fetchAdd(1, .monotonic),
        }
        _ = ctx.job.processed.fetchAdd(1, .monotonic);
    }

    ctx.job.clearCurrent();
    finalize(ctx.job, .finished);
}

fn finalize(job: *Job, terminal: State) void {
    job.state.store(terminal, .monotonic);
    job.finished_at.store(clock.nowSeconds(), .monotonic);
    job.clearCurrent();
}

/// One book's worth of the same flow `api.handleEnrich` runs for the
/// single-book case. Kept here (rather than calling into api.zig)
/// because the worker doesn't have an HTTP request handle and the
/// API function shape is HTTP-bound.
/// Enrich one book in place. Mutates the catalog row when OL returns
/// a match; otherwise returns `.no_match` or `.error` for the caller
/// to record. Public so `core/job_runner.zig` can reuse the exact
/// same per-book logic from a scheduled job.
pub fn enrichOne(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    book: catalog_mod.Book,
) !catalog_mod.Catalog.EnrichStatus {
    const derived = path_meta.fromPath(arena, book.path) catch path_meta.Derived{};

    var real_http = http.RealHttpClient{ .io = io };
    var ol = openlibrary.OpenLibrary{ .http_client = real_http.client() };
    const q = provider_iface.Query{
        .isbn = book.metadata.isbn,
        .title = book.metadata.title orelse derived.title,
        .author = if (book.metadata.authors.len > 0)
            book.metadata.authors[0].sort
        else
            derived.author,
    };
    const diag = ol.lookupRichDiag(arena, io, q) catch return .@"error";
    const got = diag.result orelse {
        enrich_log.info(
            "book {d} no_match: title={?s} author={?s} variants={d}",
            .{ book.id, q.title, q.author, diag.attempts.len },
        );
        return .no_match;
    };

    var merged = try meta.BookMetadata.merge(arena, book.metadata, got.metadata);
    if (derived.series) |s| {
        merged.series = s;
        if (derived.series_index) |idx| merged.series_index = idx;
    } else if (merged.series == null and derived.series_index != null) {
        merged.series_index = derived.series_index;
    }
    _ = try cat.upsertBook(arena, .{
        .path = book.path,
        .sha256 = book.sha256,
        .size = book.size,
        .format = book.format,
        .mtime = book.mtime,
        .metadata = merged,
    });
    return .ok;
}

/// Start the batch worker. Returns error.JobBusy if one is already in
/// flight. The job struct's state transitions to `.running` before
/// the thread is spawned so a racing GET sees the right state.
pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    cat_path: []const u8,
    job: *Job,
) !void {
    if (job.state.cmpxchgStrong(.idle, .running, .acq_rel, .monotonic) != null and
        job.state.cmpxchgStrong(.finished, .running, .acq_rel, .monotonic) != null and
        job.state.cmpxchgStrong(.canceled, .running, .acq_rel, .monotonic) != null)
    {
        return error.JobBusy;
    }
    job.started_at.store(clock.nowSeconds(), .monotonic);
    job.finished_at.store(0, .monotonic);
    job.processed.store(0, .monotonic);
    job.ok.store(0, .monotonic);
    job.no_match.store(0, .monotonic);
    job.errored.store(0, .monotonic);
    job.current_id.store(0, .monotonic);
    job.cancel_requested.store(false, .monotonic);
    job.current_title_len.store(0, .release);

    const ctx = try allocator.create(WorkerCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .job = job,
        .cat_path = try allocator.dupe(u8, cat_path),
        .allocator = allocator,
        .io = io,
    };
    errdefer allocator.free(ctx.cat_path);
    const thread = try std.Thread.spawn(.{}, workerEntry, .{ctx});
    thread.detach();
}
