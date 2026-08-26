//! Background batch-enrichment job state for the media (shelve) catalog.
//!
//! One job at a time. Owned by the web context. The worker thread updates
//! atomic counters as it goes; the HTTP handler reads them for the
//! progress endpoint. `current_title` lives in a fixed-size buffer so
//! we don't need a mutex to coordinate allocator ownership between
//! writer and readers — Zig 0.16's stdlib doesn't ship a blocking
//! Thread.Mutex anyway. A 256-byte cap is plenty for any item title;
//! anything longer is truncated for display.

const std = @import("std");
const mc = @import("../core/mediacatalog.zig");
const group = @import("../core/group.zig");
const media_enrich = @import("media_enrich.zig");
const tmdb = @import("../providers/tmdb.zig");
const musicbrainz = @import("../providers/musicbrainz.zig");
const http = @import("../util/http.zig");
const httpcache = @import("../util/httpcache.zig");
const config = @import("../core/config.zig");
const clock = @import("../util/clock.zig");
const shutdown = @import("../util/shutdown.zig");

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

fn finalize(job: *Job, terminal: State) void {
    job.state.store(terminal, .monotonic);
    job.finished_at.store(clock.nowSeconds(), .monotonic);
    job.clearCurrent();
}

const WorkerCtx = struct {
    job: *Job,
    cat_path: []u8,
    library_root: []u8,
    cache_dir: []u8,
    tmdb_key: ?[]u8,
    mb_contact: ?[]u8,
    mb_enabled: bool,
    only_id: ?i64,
    allocator: std.mem.Allocator,
    io: std.Io,
};

fn workerEntry(ctx: *WorkerCtx) void {
    defer {
        ctx.allocator.free(ctx.cat_path);
        ctx.allocator.free(ctx.library_root);
        ctx.allocator.free(ctx.cache_dir);
        if (ctx.tmdb_key) |k| ctx.allocator.free(k);
        if (ctx.mb_contact) |c| ctx.allocator.free(c);
        ctx.allocator.destroy(ctx);
    }

    var cat = mc.Catalog.open(ctx.cat_path) catch {
        finalize(ctx.job, .canceled);
        return;
    };
    defer cat.close();

    var outer = std.heap.ArenaAllocator.init(ctx.allocator);
    defer outer.deinit();
    const oa = outer.allocator();

    // Target list: one item, or all missing-metadata items.
    const items = if (ctx.only_id) |id| blk: {
        const one = cat.getById(oa, id) catch null;
        if (one) |it| {
            const buf = oa.alloc(mc.Item, 1) catch break :blk &[_]mc.Item{};
            buf[0] = it;
            break :blk buf;
        }
        break :blk &[_]mc.Item{};
    } else cat.search(oa, .{ .status = .missing_metadata }) catch &[_]mc.Item{};

    ctx.job.total.store(items.len, .monotonic);

    // Build real enrichers once (own their caching http clients).
    var real = http.RealHttpClient{ .io = ctx.io };
    var caching_mb = httpcache.CachingHttpClient{ .inner = real.client(), .dir = ctx.cache_dir, .throttle_ms = 1100 };
    var caching_tmdb = httpcache.CachingHttpClient{ .inner = real.client(), .dir = ctx.cache_dir, .throttle_ms = 250 };
    var mb = musicbrainz.MusicBrainz{ .http_client = caching_mb.client(), .contact = ctx.mb_contact };
    var music_enr = musicbrainz.Enricher.init(oa, &mb);
    var tmdb_api = tmdb.Tmdb{ .http_client = caching_tmdb.client(), .api_key = ctx.tmdb_key orelse "" };
    var video_enr = tmdb.Enricher.init(oa, &tmdb_api);
    const online = group.Online{
        .music = if (ctx.mb_enabled) &music_enr else null,
        .video = if (ctx.tmdb_key != null) &video_enr else null,
    };

    var inner = std.heap.ArenaAllocator.init(ctx.allocator);
    defer inner.deinit();
    for (items) |it| {
        if (ctx.job.cancel_requested.load(.monotonic) or shutdown.isRequested()) {
            finalize(ctx.job, .canceled);
            return;
        }
        _ = inner.reset(.retain_capacity);
        ctx.job.setCurrent(it.id, it.title);
        const outcome = media_enrich.enrichOne(inner.allocator(), &cat, it, online, ctx.library_root);
        switch (outcome) {
            .ok => _ = ctx.job.ok.fetchAdd(1, .monotonic),
            .no_match => _ = ctx.job.no_match.fetchAdd(1, .monotonic),
            .err => _ = ctx.job.errored.fetchAdd(1, .monotonic),
        }
        _ = ctx.job.processed.fetchAdd(1, .monotonic);
    }
    ctx.job.clearCurrent();
    finalize(ctx.job, .finished);
}

/// Start the batch worker. Returns error.JobBusy if one is already in
/// flight. The job struct's state transitions to `.running` before
/// the thread is spawned so a racing GET sees the right state.
pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    cache_dir: []const u8,
    cat_path: []const u8,
    library_root: []const u8,
    only_id: ?i64,
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
        .library_root = try allocator.dupe(u8, library_root),
        .cache_dir = try allocator.dupe(u8, cache_dir),
        .tmdb_key = if (cfg.tmdb_key) |k| try allocator.dupe(u8, k) else null,
        .mb_contact = if (cfg.musicbrainz_contact) |c| try allocator.dupe(u8, c) else null,
        .mb_enabled = cfg.musicbrainz_enabled,
        .only_id = only_id,
        .allocator = allocator,
        .io = io,
    };
    const thread = try std.Thread.spawn(.{}, workerEntry, .{ctx});
    thread.detach();
}
