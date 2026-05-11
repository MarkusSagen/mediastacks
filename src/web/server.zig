//! HTTP server for the booktool web UI.
//!
//! Tiny on purpose: one acceptor loop, one request at a time. Plenty
//! fast for a localhost personal-library tool. If we ever care about
//! concurrency we swap the loop body to spawn a fiber.

const std = @import("std");
const catalog_mod = @import("../core/catalog.zig");
const api = @import("api.zig");
const static = @import("static.zig");

pub const ServeOptions = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8787,
};

pub fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
    opts: ServeOptions,
    log: *std.Io.Writer,
) !void {
    var address = try std.Io.net.IpAddress.parse(opts.bind, opts.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try log.print("listening on http://{s}:{d}/\n", .{ opts.bind, opts.port });
    try log.flush();

    while (true) {
        var stream = server.accept(io) catch |err| {
            std.log.warn("accept error: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.socket.close(io);

        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [64 * 1024]u8 = undefined;
        var stream_reader = stream.reader(io, &in_buf);
        var stream_writer = stream.writer(io, &out_buf);
        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

        var request = http_server.receiveHead() catch |err| {
            std.log.warn("recv head: {s}", .{@errorName(err)});
            continue;
        };

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Snapshot the request line before handling — the head's slices
        // are tied to the receive buffer and the act of responding can
        // invalidate them.
        var target_buf: [512]u8 = undefined;
        const target_snapshot = std.fmt.bufPrint(
            &target_buf,
            "{s}",
            .{request.head.target[0..@min(request.head.target.len, target_buf.len)]},
        ) catch "?";
        const method_tag = @tagName(request.head.method);

        handle(arena, io, cat, &request) catch |err| {
            std.log.warn("{s} {s}: {s}", .{ method_tag, target_snapshot, @errorName(err) });
            request.respond("internal error\n", .{
                .status = .internal_server_error,
                .keep_alive = false,
            }) catch {};
            continue;
        };

        std.log.info("{s} {s}", .{ method_tag, target_snapshot });
    }
}

fn handle(
    arena: std.mem.Allocator,
    io: std.Io,
    cat: *catalog_mod.Catalog,
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
        // Browser-injected probes (Chrome DevTools workspace discovery
        // etc). Return 204 quietly so they don't show up as 404s.
        try request.respond("", .{ .status = .no_content });
        return;
    }
    if (std.mem.eql(u8, path, "/api/books")) {
        return api.handleBooksList(arena, cat, request);
    }
    if (std.mem.eql(u8, path, "/api/duplicates")) {
        return api.handleDuplicates(arena, cat, request);
    }
    if (std.mem.eql(u8, path, "/api/missing")) {
        return api.handleMissing(arena, cat, request);
    }
    if (std.mem.eql(u8, path, "/api/unverified")) {
        return api.handleUnverified(arena, cat, request);
    }
    if (std.mem.eql(u8, path, "/api/authors")) {
        return api.handleFacets(arena, cat, request, .authors);
    }
    if (std.mem.eql(u8, path, "/api/series")) {
        return api.handleFacets(arena, cat, request, .series);
    }
    if (std.mem.eql(u8, path, "/api/genres")) {
        return api.handleFacets(arena, cat, request, .genres);
    }
    if (matchPrefix(path, "/api/books/")) |rest| {
        return api.handleBookSubresource(arena, io, cat, request, rest);
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
