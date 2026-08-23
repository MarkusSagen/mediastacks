//! `shelve serve` — the organizer web app (a fuller, biblio-styled shell over
//! the same Plan/edit/apply core as `shelve review`). Slice 1: the app shell +
//! the Organize flow (enter a folder → preview the plan → edit → apply).
//! Single-threaded, 127.0.0.1 only; the session holds one "current plan" that
//! `/api/organize` rebuilds on demand.

const std = @import("std");
const plan = @import("../core/plan.zig");
const config = @import("../core/config.zig");
const group = @import("../core/group.zig");
const apply_mod = @import("../core/apply.zig");
const review = @import("review.zig");
const static = @import("static.zig");
const shutdown = @import("../util/shutdown.zig");

pub const Options = struct { bind: []const u8 = "127.0.0.1", port: u16 = 8799 };

const App = struct {
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    base_cfg: config.Config,
    plan_arena: std.heap.ArenaAllocator,
    session: review.Session, // .arena/.cfg/.plan; plan null until first organize
    has_plan: bool = false,
};

pub fn serve(io: std.Io, gpa: std.mem.Allocator, cfg: config.Config, env: *std.process.Environ.Map, opts: Options, log: *std.Io.Writer) !void {
    var app = App{
        .gpa = gpa,
        .env = env,
        .base_cfg = cfg,
        .plan_arena = std.heap.ArenaAllocator.init(gpa),
        .session = .{ .arena = undefined, .cfg = cfg, .plan = .{ .library_root = cfg.library_root, .source = "", .groups = &.{} } },
    };
    defer app.plan_arena.deinit();

    var address = try std.Io.net.IpAddress.parse(opts.bind, opts.port);
    var server = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 64 });
    defer server.deinit(io);
    try log.print("shelve web app at http://{s}:{d}/  (Ctrl+C to stop)\n", .{ opts.bind, opts.port });
    try log.flush();

    while (true) {
        if (shutdown.isRequested()) return;
        var stream = server.accept(io) catch |err| {
            if (shutdown.isRequested()) return;
            std.log.warn("accept: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.socket.close(io);

        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [64 * 1024]u8 = undefined;
        var sr = stream.reader(io, &in_buf);
        var sw = stream.writer(io, &out_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);
        var request = http.receiveHead() catch continue;

        handle(io, &app, &request) catch |err| {
            request.respond("internal error\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
            std.log.warn("app handler: {s}", .{@errorName(err)});
        };
    }
}

fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

fn respondAsset(request: *std.http.Server.Request, bytes: []const u8, ctype: []const u8) !void {
    try request.respond(bytes, .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = ctype },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

fn respondJson(request: *std.http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

fn queryValue(target: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.tokenizeScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn urlDecode(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                try out.append(arena, s[i]);
                continue;
            };
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                try out.append(arena, s[i]);
                continue;
            };
            try out.append(arena, @intCast(hi * 16 + lo));
            i += 2;
        } else if (s[i] == '+') {
            try out.append(arena, ' ');
        } else try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}

fn readBody(arena: std.mem.Allocator, request: *std.http.Server.Request, max: usize) ![]u8 {
    if (request.head.content_length) |len| {
        if (len > max) return error.BodyTooLarge;
        var buf: [64 * 1024]u8 = undefined;
        const reader = if (request.head.expect != null) try request.readerExpectContinue(&buf) else request.readerExpectNone(&buf);
        return try reader.readAlloc(arena, @intCast(len));
    }
    var buf: [16]u8 = undefined;
    _ = if (request.head.expect != null) try request.readerExpectContinue(&buf) else request.readerExpectNone(&buf);
    return arena.alloc(u8, 0);
}

fn handle(io: std.Io, app: *App, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = pathOnly(target);

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))
        return respondAsset(request, static.shelve_html, "text/html; charset=utf-8");
    if (std.mem.eql(u8, path, "/shelve.js")) return respondAsset(request, static.shelve_js, "application/javascript");
    if (std.mem.eql(u8, path, "/shelve.css")) return respondAsset(request, static.shelve_css, "text/css");
    if (std.mem.eql(u8, path, "/favicon.svg")) return respondAsset(request, static.favicon_svg, "image/svg+xml");

    if (std.mem.eql(u8, path, "/api/config")) return handleConfig(app, request);
    if (std.mem.eql(u8, path, "/api/organize")) return handleOrganize(io, app, request, target);

    // These operate on the current plan (must exist).
    if (std.mem.eql(u8, path, "/api/plan")) {
        if (!app.has_plan) return respondJson(request, "{\"library_root\":\"\",\"source\":\"\",\"groups\":[]}");
        return respondJson(request, try plan.toJson(app.session.arena, app.session.plan));
    }
    if (std.mem.eql(u8, path, "/api/edit")) {
        if (!app.has_plan) return request.respond("no plan\n", .{ .status = .bad_request });
        const body = readBody(app.session.arena, request, 1 * 1024 * 1024) catch return request.respond("bad body\n", .{ .status = .bad_request });
        review.applyEdit(&app.session, body) catch return request.respond("bad edit\n", .{ .status = .bad_request });
        return respondJson(request, try plan.toJson(app.session.arena, app.session.plan));
    }
    if (std.mem.eql(u8, path, "/api/apply")) {
        if (!app.has_plan) return request.respond("no plan\n", .{ .status = .bad_request });
        const opts = parseApplyOpts(target);
        _ = readBody(app.session.arena, request, 64 * 1024) catch {};
        const res = apply_mod.apply(app.session.arena, app.session.plan, .skip, app.env, .{ .write = opts.write_tags }, app.session.cfg.emit_ignore, opts.write_nfo) catch |err| {
            return request.respond(try std.fmt.allocPrint(app.session.arena, "apply failed: {s}\n", .{@errorName(err)}), .{ .status = .internal_server_error });
        };
        app.has_plan = false; // consumed
        return respondJson(request, try std.fmt.allocPrint(app.session.arena, "{{\"moved\":{d},\"trashed\":{d},\"skipped\":{d},\"journal\":\"{s}\"}}", .{ res.moved, res.trashed, res.skipped, res.journal_path }));
    }
    if (std.mem.eql(u8, path, "/api/thumb")) {
        if (!app.has_plan) return request.respond("", .{ .status = .not_found });
        return review.handleThumb(io, &app.session, request, target);
    }

    try request.respond("not found\n", .{ .status = .not_found });
}

const ApplyOpts = struct { write_tags: bool, write_nfo: bool };
fn parseApplyOpts(target: []const u8) ApplyOpts {
    return .{
        .write_tags = if (queryValue(target, "write_tags")) |v| std.mem.eql(u8, v, "1") else false,
        .write_nfo = if (queryValue(target, "write_nfo")) |v| std.mem.eql(u8, v, "1") else true,
    };
}

fn handleConfig(app: *App, request: *std.http.Server.Request) !void {
    const c = app.base_cfg;
    const body = try std.fmt.allocPrint(app.gpa,
        \\{{"library_root":"{s}","write_tags":{s},"write_nfo":{s},"id_suffix":{s},"musicbrainz":{s},"tmdb":{s}}}
    , .{
        c.library_root,
        boolStr(c.write_tags),
        boolStr(c.write_nfo),
        boolStr(c.id_suffix),
        boolStr(c.musicbrainz_enabled),
        boolStr(c.tmdb_key != null),
    });
    defer app.gpa.free(body);
    try respondJson(request, body);
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Build a fresh plan for `?dir=…` (offline by default; `&online=1` enables
/// configured providers). Resets the per-plan arena so repeated runs don't grow.
fn handleOrganize(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    const dir_enc = queryValue(target, "dir") orelse return request.respond("missing dir\n", .{ .status = .bad_request });
    _ = app.plan_arena.reset(.free_all);
    const arena = app.plan_arena.allocator();
    const dir = try urlDecode(arena, dir_enc);

    var cfg = app.base_cfg;
    if (queryValue(target, "to")) |to_enc| cfg.library_root = try urlDecode(arena, to_enc);
    const no_probe = if (queryValue(target, "no_probe")) |v| std.mem.eql(u8, v, "1") else false;

    const p = group.buildPlan(arena, io, dir, cfg, !no_probe, .{}) catch |err| {
        return request.respond(try std.fmt.allocPrint(arena, "cannot scan {s}: {s}\n", .{ dir, @errorName(err) }), .{ .status = .bad_request });
    };
    app.session.arena = arena;
    app.session.cfg = cfg;
    app.session.plan = p;
    app.has_plan = true;
    return respondJson(request, try plan.toJson(arena, p));
}
