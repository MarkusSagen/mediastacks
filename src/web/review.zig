//! Local web review surface for a reorganization Plan.
//!
//! Server-authoritative: the browser sends edit ops; `applyEdit` mutates
//! the in-memory Plan and recomputes destinations via the Zig template
//! engine (`core/naming`). The Plan stays the single contract. The HTTP
//! server (`serve`) is added in a later task.

const std = @import("std");
const plan = @import("../core/plan.zig");
const naming = @import("../core/naming.zig");
const config = @import("../core/config.zig");
const kind = @import("../core/kind.zig");
const static = @import("static.zig");
const apply_mod = @import("../core/apply.zig");
const exec = @import("../util/exec.zig");
const shutdown = @import("../util/shutdown.zig");

pub const Session = struct {
    arena: std.mem.Allocator,
    cfg: config.Config,
    plan: plan.Plan,
};

pub const Options = struct { bind: []const u8 = "127.0.0.1", port: u16 = 8788 };

/// Single-threaded review server — the session is mutable and edit ops are
/// fast, so one request at a time keeps it race-free. 127.0.0.1 only.
pub fn serve(
    io: std.Io,
    session: *Session,
    env: *std.process.Environ.Map,
    opts: Options,
    log: *std.Io.Writer,
) !void {
    var address = try std.Io.net.IpAddress.parse(opts.bind, opts.port);
    var server = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 64 });
    defer server.deinit(io);
    try log.print("reviewing at http://{s}:{d}/  (Ctrl+C to stop)\n", .{ opts.bind, opts.port });
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

        handle(io, session, env, &request) catch |err| {
            request.respond("internal error\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
            std.log.warn("review handler: {s}", .{@errorName(err)});
        };
    }
}

fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

fn respondJson(request: *std.http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

fn respondAsset(request: *std.http.Server.Request, bytes: []const u8, ctype: []const u8) !void {
    try request.respond(bytes, .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = ctype },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

fn claimReader(request: *std.http.Server.Request, buffer: []u8) !*std.Io.Reader {
    if (request.head.expect != null) return try request.readerExpectContinue(buffer);
    return request.readerExpectNone(buffer);
}

fn readBody(arena: std.mem.Allocator, request: *std.http.Server.Request, max: usize) ![]u8 {
    if (request.head.content_length) |len| {
        if (len > max) return error.BodyTooLarge;
        var buf: [64 * 1024]u8 = undefined;
        const reader = try claimReader(request, &buf);
        return try reader.readAlloc(arena, @intCast(len));
    }
    var buf: [16]u8 = undefined;
    _ = try claimReader(request, &buf);
    return arena.alloc(u8, 0);
}

fn handle(io: std.Io, session: *Session, env: *std.process.Environ.Map, request: *std.http.Server.Request) !void {
    const target = request.head.target;
    const path = pathOnly(target);

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        return respondAsset(request, static.review_html, "text/html; charset=utf-8");
    }
    if (std.mem.eql(u8, path, "/review.js")) return respondAsset(request, static.review_js, "application/javascript");
    if (std.mem.eql(u8, path, "/review.css")) return respondAsset(request, static.review_css, "text/css");

    if (std.mem.eql(u8, path, "/api/plan")) {
        return respondJson(request, try plan.toJson(session.arena, session.plan));
    }
    if (std.mem.eql(u8, path, "/api/edit")) {
        const body = readBody(session.arena, request, 1 * 1024 * 1024) catch {
            return request.respond("bad body\n", .{ .status = .bad_request });
        };
        applyEdit(session, body) catch {
            return request.respond("bad edit\n", .{ .status = .bad_request });
        };
        return respondJson(request, try plan.toJson(session.arena, session.plan));
    }
    if (std.mem.eql(u8, path, "/api/apply")) {
        _ = readBody(session.arena, request, 64 * 1024) catch {}; // claim the (empty) POST body
        const res = try apply_mod.apply(session.arena, session.plan, .skip, env, .{ .write = session.cfg.write_tags }, session.cfg.emit_ignore);
        const body = try std.fmt.allocPrint(session.arena, "{{\"moved\":{d},\"trashed\":{d},\"skipped\":{d},\"journal\":\"{s}\"}}", .{ res.moved, res.trashed, res.skipped, res.journal_path });
        return respondJson(request, body);
    }
    if (std.mem.eql(u8, path, "/api/thumb")) {
        return handleThumb(io, session, request, target);
    }

    try request.respond("not found\n", .{ .status = .not_found });
}

/// Poster frame via ffmpeg. `src` must be a path present in the plan.
fn handleThumb(io: std.Io, session: *Session, request: *std.http.Server.Request, target: []const u8) !void {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return request.respond("", .{ .status = .not_found });
    const query = target[q + 1 ..];
    const src_enc = valueOf(query, "src") orelse return request.respond("", .{ .status = .not_found });
    const src = try urlDecode(session.arena, src_enc);

    if (!planHasSrc(session, src)) return request.respond("", .{ .status = .forbidden });

    // -ss 10: past typical intros/black; safe for anything >10s (real
    // episodes/movies). Shorter clips just yield no poster (404 → hidden).
    const argv = [_][]const u8{ "ffmpeg", "-v", "error", "-ss", "10", "-i", src, "-frames:v", "1", "-vf", "scale=320:-1", "-f", "image2pipe", "-vcodec", "mjpeg", "-" };
    const r = exec.runCaptureStdout(session.arena, io, &argv, 4 * 1024 * 1024) catch return request.respond("", .{ .status = .not_found });
    if (r.exit_code != 0 or r.stdout.len == 0) return request.respond("", .{ .status = .not_found });
    try request.respond(r.stdout, .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = "image/jpeg" },
        .{ .name = "cache-control", .value = "max-age=3600" },
    } });
}

fn planHasSrc(session: *Session, src: []const u8) bool {
    for (session.plan.groups) |g| {
        for (g.items) |it| if (std.mem.eql(u8, it.src, src)) return true;
    }
    return false;
}

fn valueOf(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, query, '&');
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
        } else {
            try out.append(arena, s[i]);
        }
    }
    return out.toOwnedSlice(arena);
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}
fn getInt(v: std.json.Value, key: []const u8) ?usize {
    const x = objGet(v, key) orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}
fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = objGet(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

fn recompute(s: *Session, g: usize, i: usize) !void {
    const grp = &s.plan.groups[g];
    var item = &grp.items[i];
    if (item.role == .primary or item.role == .sidecar) {
        if (item.fields) |f| item.dst = try naming.dstFor(s.arena, s.cfg, grp.kind, f);
    } else {
        item.dst = null;
    }
}

fn appendItem(a: std.mem.Allocator, items: []plan.Item, extra: plan.Item) ![]plan.Item {
    const out = try a.alloc(plan.Item, items.len + 1);
    @memcpy(out[0..items.len], items);
    out[items.len] = extra;
    return out;
}
fn removeItem(a: std.mem.Allocator, items: []plan.Item, idx: usize) ![]plan.Item {
    const out = try a.alloc(plan.Item, items.len - 1);
    @memcpy(out[0..idx], items[0..idx]);
    @memcpy(out[idx..], items[idx + 1 ..]);
    return out;
}

/// Apply one edit op (JSON) to `s.plan`, recomputing affected destinations.
/// Bad index → error.BadIndex; unknown/ill-formed op → error.BadOp.
pub fn applyEdit(s: *Session, op_json: []const u8) !void {
    const op = std.json.parseFromSliceLeaky(std.json.Value, s.arena, op_json, .{ .allocate = .alloc_always }) catch return error.BadOp;
    const op_name = getStr(op, "op") orelse return error.BadOp;

    if (std.mem.eql(u8, op_name, "set-role")) {
        const g = getInt(op, "group") orelse return error.BadOp;
        const i = getInt(op, "item") orelse return error.BadOp;
        if (g >= s.plan.groups.len) return error.BadIndex;
        if (i >= s.plan.groups[g].items.len) return error.BadIndex;
        const role_s = getStr(op, "role") orelse return error.BadOp;
        var item = &s.plan.groups[g].items[i];
        if (std.mem.eql(u8, role_s, "primary")) {
            item.role = .primary;
            item.op = .move;
        } else if (std.mem.eql(u8, role_s, "skip")) {
            item.role = .duplicate;
            item.op = .skip;
        } else if (std.mem.eql(u8, role_s, "trash")) {
            item.role = .junk;
            item.op = .trash;
        } else return error.BadOp;
        try recompute(s, g, i);
    } else if (std.mem.eql(u8, op_name, "retitle")) {
        const g = getInt(op, "group") orelse return error.BadOp;
        if (g >= s.plan.groups.len) return error.BadIndex;
        const title = getStr(op, "title") orelse return error.BadOp;
        s.plan.groups[g].title = title;
        const is_tv = s.plan.groups[g].kind == .tv;
        for (s.plan.groups[g].items, 0..) |*item, i| {
            if (is_tv) {
                if (item.fields) |*f| f.series = title;
            }
            try recompute(s, g, i);
        }
    } else if (std.mem.eql(u8, op_name, "move-item")) {
        const from = getInt(op, "from") orelse return error.BadOp;
        const it_i = getInt(op, "item") orelse return error.BadOp;
        const to = getInt(op, "to") orelse return error.BadOp;
        if (from >= s.plan.groups.len or to >= s.plan.groups.len) return error.BadIndex;
        if (it_i >= s.plan.groups[from].items.len) return error.BadIndex;
        var moved = s.plan.groups[from].items[it_i];
        if (s.plan.groups[to].kind == .tv) {
            if (moved.fields) |*f| f.series = s.plan.groups[to].title;
        }
        s.plan.groups[to].items = try appendItem(s.arena, s.plan.groups[to].items, moved);
        s.plan.groups[from].items = try removeItem(s.arena, s.plan.groups[from].items, it_i);
        try recompute(s, to, s.plan.groups[to].items.len - 1);
    } else if (std.mem.eql(u8, op_name, "split")) {
        const g = getInt(op, "group") orelse return error.BadOp;
        if (g >= s.plan.groups.len) return error.BadIndex;
        const title = getStr(op, "title") orelse return error.BadOp;
        const arr = objGet(op, "items") orelse return error.BadOp;
        if (arr != .array) return error.BadOp;
        // Collect selected items (validate indices), build the new group.
        var picked: std.ArrayList(plan.Item) = .empty;
        for (arr.array.items) |v| {
            const idx: usize = switch (v) {
                .integer => |x| if (x >= 0) @intCast(x) else return error.BadIndex,
                else => return error.BadOp,
            };
            if (idx >= s.plan.groups[g].items.len) return error.BadIndex;
            var it = s.plan.groups[g].items[idx];
            if (s.plan.groups[g].kind == .tv) {
                if (it.fields) |*f| f.series = title;
            }
            try picked.append(s.arena, it);
        }
        // Remove the picked indices from the source (high→low to keep indices valid).
        const order = try s.arena.dupe(std.json.Value, arr.array.items);
        std.mem.sort(std.json.Value, order, {}, cmpIntDesc);
        for (order) |v| s.plan.groups[g].items = try removeItem(s.arena, s.plan.groups[g].items, @intCast(v.integer));
        const new_group = plan.Group{ .kind = s.plan.groups[g].kind, .title = title, .items = try picked.toOwnedSlice(s.arena) };
        s.plan.groups = try appendGroup(s.arena, s.plan.groups, new_group);
        // Recompute the new group's items.
        const ng = s.plan.groups.len - 1;
        for (0..s.plan.groups[ng].items.len) |i| try recompute(s, ng, i);
    } else return error.BadOp;
}

fn cmpIntDesc(_: void, a: std.json.Value, b: std.json.Value) bool {
    return a.integer > b.integer;
}
fn appendGroup(a: std.mem.Allocator, groups: []plan.Group, extra: plan.Group) ![]plan.Group {
    const out = try a.alloc(plan.Group, groups.len + 1);
    @memcpy(out[0..groups.len], groups);
    out[groups.len] = extra;
    return out;
}

const t = std.testing;

fn mkSession(a: std.mem.Allocator) Session {
    const items = a.alloc(plan.Item, 1) catch unreachable;
    items[0] = .{ .src = "/x/a.mkv", .role = .primary, .op = .move, .dst = "/lib/old.mkv", .fields = .{ .series = "Old", .season = 1, .episode = 1, .ext = "mkv" } };
    const groups = a.alloc(plan.Group, 1) catch unreachable;
    groups[0] = .{ .kind = .tv, .title = "Old", .items = items };
    return .{ .arena = a, .cfg = .{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC }, .plan = .{ .library_root = "/lib", .source = "/x", .groups = groups } };
}

test "retitle recomputes dst" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try applyEdit(&s, "{\"op\":\"retitle\",\"group\":0,\"title\":\"New Show\"}");
    try t.expectEqualStrings("New Show", s.plan.groups[0].title);
    try t.expect(std.mem.indexOf(u8, s.plan.groups[0].items[0].dst.?, "New Show") != null);
}

test "set-role trash clears dst and sets trash op" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try applyEdit(&s, "{\"op\":\"set-role\",\"group\":0,\"item\":0,\"role\":\"trash\"}");
    try t.expectEqual(plan.Op.trash, s.plan.groups[0].items[0].op);
    try t.expect(s.plan.groups[0].items[0].dst == null);
}

test "move-item re-parents and recomputes under the new group" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var s = mkSession(a);
    // add a second (empty) tv group to move into
    const g2_items = try a.alloc(plan.Item, 0);
    s.plan.groups = try appendGroup(a, s.plan.groups, .{ .kind = .tv, .title = "Dest Show", .items = g2_items });
    try applyEdit(&s, "{\"op\":\"move-item\",\"from\":0,\"item\":0,\"to\":1}");
    try t.expectEqual(@as(usize, 0), s.plan.groups[0].items.len);
    try t.expectEqual(@as(usize, 1), s.plan.groups[1].items.len);
    try t.expect(std.mem.indexOf(u8, s.plan.groups[1].items[0].dst.?, "Dest Show") != null);
}

test "bad index errors" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s = mkSession(arena_state.allocator());
    try t.expectError(error.BadIndex, applyEdit(&s, "{\"op\":\"retitle\",\"group\":9,\"title\":\"x\"}"));
}
