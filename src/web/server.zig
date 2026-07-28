//! HTTP server for the booktool web UI.
//!
//! Concurrency model: one acceptor loop + one detached thread per
//! request. Each thread owns its own arena allocator, stack buffers,
//! and stream — no shared mutable state outside the Catalog (whose
//! sqlite3 connection is in WAL mode + the default "serialized"
//! thread mode, so concurrent reads/writes are safe).
//!
//! Why threaded: enrich/lookup calls block on slow Open Library
//! roundtrips (often 10-30s including TLS retries). A single-threaded
//! server stalls every other request — cover thumbnails, navigation,
//! standardize-preview — behind that one slow lookup. Detached threads
//! let each request run to completion independently.
//!
//! Why detached (no pool): user load is single-person + localhost, so
//! the pathological case is ~12 simultaneous threads (one per visible
//! card's cover fetch). Each is cheap (~8MB stack) and short-lived.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");
const api = @import("api.zig");
const static = @import("static.zig");
const prewarm = @import("prewarm.zig");
const enrich_job_mod = @import("enrich_job.zig");
const shutdown = @import("../util/shutdown.zig");
const job_runner = @import("../core/job_runner.zig");

const SchedCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
};

fn schedThreadEntry(s: *SchedCtx) void {
    defer s.allocator.destroy(s);
    job_runner.loop(s.allocator, s.io, s.cat, .{}) catch |err|
        std.log.warn("scheduler loop exited with error: {s}", .{@errorName(err)});
}

pub const ServeOptions = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8787,
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    env: *std.process.Environ.Map,
    opts: ServeOptions,
    log: *std.Io.Writer,
) !void {
    var address = try std.Io.net.IpAddress.parse(opts.bind, opts.port);
    var server = try address.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 1024,
    });
    defer server.deinit(io);

    try log.print("listening on http://{s}:{d}/\n", .{ opts.bind, opts.port });
    try log.flush();

    const catalog_path = try catalog_mod.defaultPath(allocator, env);

    var enrich_job = enrich_job_mod.Job.init(allocator);
    defer enrich_job.deinit();

    var ctx = api.WebContext{
        .cat = cat,
        .env = env,
        .catalog_path = catalog_path,
        .worker_allocator = allocator,
        .enrich_job = &enrich_job,
    };

    prewarm.spawnPrewarm(allocator, io, catalog_path, env) catch |err|
        std.log.warn("prewarm: spawn failed: {s}", .{@errorName(err)});

    const sched_ctx = allocator.create(SchedCtx) catch null;
    if (sched_ctx) |s| {
        s.* = .{ .allocator = allocator, .io = io, .cat = cat };
        const t = std.Thread.spawn(.{}, schedThreadEntry, .{s}) catch |err| blk: {
            std.log.warn("scheduler: spawn failed: {s}", .{@errorName(err)});
            allocator.destroy(s);
            break :blk null;
        };
        if (t) |th| th.detach();
    }

    while (true) {
        if (shutdown.isRequested()) {
            enrich_job.requestCancel();
            try log.print("shutting down\n", .{});
            try log.flush();
            return;
        }
        const stream = server.accept(io) catch |err| {
            if (shutdown.isRequested()) return;
            std.log.warn("accept error: {s}", .{@errorName(err)});
            continue;
        };

        const req_ctx = allocator.create(RequestCtx) catch |err| {
            std.log.warn("alloc request ctx: {s}", .{@errorName(err)});
            var s_close = stream;
            s_close.socket.close(io);
            continue;
        };
        req_ctx.* = .{
            .stream = stream,
            .web_ctx = &ctx,
            .allocator = allocator,
            .io = io,
        };

        const thread = std.Thread.spawn(.{}, handleRequest, .{req_ctx}) catch |err| {
            std.log.warn("spawn worker thread: {s} (handling inline)", .{@errorName(err)});
            handleRequest(req_ctx);
            continue;
        };
        thread.detach();
    }
}

/// Heap-allocated state passed to each worker thread. Owns the stream
/// (the thread must close it) and holds the references to the shared
/// ctx + allocator + io. Freed by the thread function before exit.
const RequestCtx = struct {
    stream: std.Io.net.Stream,
    web_ctx: *api.WebContext,
    allocator: std.mem.Allocator,
    io: std.Io,
};

/// Worker-thread entry point. Drives one request to completion:
/// reads the head, builds an arena, runs the handler, closes the
/// socket, cleans up.
fn handleRequest(req_ctx: *RequestCtx) void {
    defer req_ctx.allocator.destroy(req_ctx);
    var stream = req_ctx.stream;
    defer stream.socket.close(req_ctx.io);

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(req_ctx.io, &in_buf);
    var stream_writer = stream.writer(req_ctx.io, &out_buf);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch |err| {
        std.log.warn("recv head: {s}", .{@errorName(err)});
        return;
    };

    var target_buf: [512]u8 = undefined;
    const target_snapshot = std.fmt.bufPrint(
        &target_buf,
        "{s}",
        .{request.head.target[0..@min(request.head.target.len, target_buf.len)]},
    ) catch "?";
    const method_tag = @tagName(request.head.method);

    var arena_state = std.heap.ArenaAllocator.init(req_ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    handle(arena, req_ctx.io, req_ctx.web_ctx, &request) catch |err| {
        std.log.warn("{s} {s}: {s}", .{ method_tag, target_snapshot, @errorName(err) });
        request.respond("internal error\n", .{
            .status = .internal_server_error,
            .keep_alive = false,
        }) catch {};
        return;
    };

    std.log.info("{s} {s}", .{ method_tag, target_snapshot });
}

fn handle(
    arena: std.mem.Allocator,
    io: std.Io,
    ctx: *api.WebContext,
    request: *std.http.Server.Request,
) !void {
    const target = request.head.target;
    const path = pathOnly(target);

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        return respondStatic(request, static.index_html, "text/html; charset=utf-8");
    }
    if (std.mem.eql(u8, path, "/app.js")) {
        return respondStatic(request, static.app_js, "application/javascript");
    }
    if (std.mem.eql(u8, path, "/styles.css")) {
        return respondStatic(request, static.styles_css, "text/css");
    }
    if (std.mem.eql(u8, path, "/favicon.svg") or std.mem.eql(u8, path, "/favicon.ico")) {
        return respondStatic(request, static.favicon_svg, "image/svg+xml");
    }
    if (std.mem.startsWith(u8, path, "/.well-known/")) {
        try request.respond("", .{ .status = .no_content });
        return;
    }
    if (std.mem.eql(u8, path, "/api/books")) {
        return api.handleBooksList(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/duplicates")) {
        return api.handleDuplicates(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/missing")) {
        return api.handleMissing(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/unverified")) {
        return api.handleUnverified(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/missing-files")) {
        return api.handleMissingFiles(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/derive-paths")) {
        return api.handleDerivePaths(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/standardize")) {
        return api.handleStandardizePreview(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/standardize/apply")) {
        return api.handleStandardizeApply(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/sources")) {
        return api.handleSources(arena, io, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/pick-folder")) {
        return api.handlePickFolder(arena, io, request);
    }
    if (std.mem.eql(u8, path, "/api/sevenzip-status")) {
        return api.handleSevenzipStatus(arena, io, request);
    }
    if (std.mem.eql(u8, path, "/api/library-stats")) {
        return api.handleLibraryStats(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/jobs")) {
        return api.handleJobs(arena, io, ctx, request);
    }
    if (matchPrefix(path, "/api/jobs/")) |rest| {
        return api.handleJobSubresource(arena, io, ctx, request, rest);
    }
    if (matchPrefix(path, "/api/export") != null) {
        return api.handleExport(arena, ctx, request);
    }
    if (std.mem.eql(u8, path, "/api/import")) {
        return api.handleImport(arena, ctx, request);
    }
    if (matchPrefix(path, "/api/sources/")) |rest| {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const sid = std.fmt.parseInt(i64, rest[0..slash], 10) catch {
            try request.respond("bad source id\n", .{ .status = .bad_request });
            return;
        };
        const tail = if (slash < rest.len) rest[slash + 1 ..] else "";
        if (std.mem.eql(u8, tail, "rescan")) {
            return api.handleSourceRescan(arena, io, ctx, request, sid);
        }
        if (tail.len == 0 and request.head.method == .DELETE) {
            return api.handleSourceDelete(arena, ctx, request, sid);
        }
        try request.respond("not found\n", .{ .status = .not_found });
        return;
    }
    if (std.mem.eql(u8, path, "/api/authors")) {
        return api.handleFacets(arena, ctx, request, .authors);
    }
    if (std.mem.eql(u8, path, "/api/series")) {
        return api.handleFacets(arena, ctx, request, .series);
    }
    if (std.mem.eql(u8, path, "/api/genres")) {
        return api.handleFacets(arena, ctx, request, .genres);
    }
    if (std.mem.eql(u8, path, "/api/formats")) {
        return api.handleFacets(arena, ctx, request, .formats);
    }
    if (matchPrefix(path, "/api/books/")) |rest| {
        return api.handleBookSubresource(arena, io, ctx, request, rest);
    }
    if (std.mem.eql(u8, path, "/api/tags")) {
        return switch (request.head.method) {
            .GET => api.handleTagsList(arena, ctx, request),
            .POST => api.handleTagsCreate(arena, ctx, request),
            else => request.respond("method not allowed\n", .{ .status = .method_not_allowed }),
        };
    }
    if (matchPrefix(path, "/api/tags/")) |rest| {
        const tag_id = std.fmt.parseInt(i64, rest, 10) catch {
            try request.respond("bad tag id\n", .{ .status = .bad_request });
            return;
        };
        if (request.head.method != .DELETE) {
            try request.respond("method not allowed\n", .{ .status = .method_not_allowed });
            return;
        }
        return api.handleTagsDelete(arena, ctx, request, tag_id);
    }
    if (std.mem.eql(u8, path, "/api/enrich/batch")) {
        return switch (request.head.method) {
            .GET => api.handleEnrichBatchStatus(arena, ctx, request),
            .POST => api.handleEnrichBatchStart(arena, io, ctx, request),
            .DELETE => api.handleEnrichBatchCancel(arena, ctx, request),
            else => request.respond("method not allowed\n", .{ .status = .method_not_allowed }),
        };
    }

    try request.respond("not found\n", .{ .status = .not_found });
}

/// Returns the path portion before the first '?' (if any).
fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

fn matchPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, prefix)) return path[prefix.len..];
    return null;
}

fn respondStatic(
    request: *std.http.Server.Request,
    bytes: []const u8,
    content_type: []const u8,
) !void {
    try request.respond(bytes, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}
