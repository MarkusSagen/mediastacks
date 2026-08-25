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
const journal = @import("../core/journal.zig");
const mediacatalog = @import("../core/mediacatalog.zig");
const indexer = @import("../core/indexer.zig");
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
    if (std.mem.eql(u8, path, "/api/library")) return handleLibrary(app, request, target);
    if (std.mem.eql(u8, path, "/api/reindex")) return handleReindex(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/cover")) return handleCover(app, request, target);
    if (std.mem.eql(u8, path, "/api/undo/list")) return handleUndoList(io, app, request);
    if (std.mem.eql(u8, path, "/api/undo/revert")) return handleUndoRevert(app, request, target);

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
    if (request.head.method == .POST) return handleConfigSave(app, request);
    const c = app.base_cfg;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena,
        \\{{"library_root":"{s}","write_tags":{s},"write_nfo":{s},"id_suffix":{s},"emit_ignore":{s},"musicbrainz":{s},"musicbrainz_contact":"{s}","tmdb_key":"{s}"}}
    , .{
        try jsonEsc(arena, c.library_root),
        boolStr(c.write_tags),
        boolStr(c.write_nfo),
        boolStr(c.id_suffix),
        boolStr(c.emit_ignore),
        boolStr(c.musicbrainz_enabled),
        try jsonEsc(arena, c.musicbrainz_contact orelse ""),
        try jsonEsc(arena, c.tmdb_key orelse ""),
    });
    try respondJson(request, body);
}

const ConfigForm = struct {
    library_root: ?[]const u8 = null,
    write_tags: ?bool = null,
    write_nfo: ?bool = null,
    id_suffix: ?bool = null,
    emit_ignore: ?bool = null,
    musicbrainz: ?bool = null,
    musicbrainz_contact: ?[]const u8 = null,
    tmdb_key: ?[]const u8 = null,
};

/// POST /api/config — merge submitted settings into config.toml and reload.
fn handleConfigSave(app: *App, request: *std.http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = readBody(arena, request, 64 * 1024) catch return request.respond("bad body\n", .{ .status = .bad_request });
    const parsed = std.json.parseFromSlice(ConfigForm, arena, body, .{ .ignore_unknown_fields = true }) catch
        return request.respond("bad json\n", .{ .status = .bad_request });
    const f = parsed.value;

    var updates: std.ArrayList([2][]const u8) = .empty;
    if (f.library_root) |v| try updates.append(arena, .{ "library_root", v });
    if (f.write_tags) |v| try updates.append(arena, .{ "write_tags", if (v) "on" else "off" });
    if (f.write_nfo) |v| try updates.append(arena, .{ "write_nfo", if (v) "on" else "off" });
    if (f.id_suffix) |v| try updates.append(arena, .{ "id_suffix", if (v) "on" else "off" });
    if (f.emit_ignore) |v| try updates.append(arena, .{ "emit_ignore", if (v) "on" else "off" });
    if (f.musicbrainz) |v| try updates.append(arena, .{ "musicbrainz", if (v) "on" else "off" });
    if (f.musicbrainz_contact) |v| if (v.len > 0) try updates.append(arena, .{ "musicbrainz_contact", v });
    if (f.tmdb_key) |v| if (v.len > 0) try updates.append(arena, .{ "tmdb_key", v });

    config.save(arena, app.env, updates.items) catch |err|
        return request.respond(try std.fmt.allocPrint(arena, "save failed: {s}\n", .{@errorName(err)}), .{ .status = .internal_server_error });

    // Reload so subsequent organizes use the new settings.
    const fresh = config.load(app.gpa, app.env) catch return respondJson(request, "{\"ok\":true}");
    app.base_cfg = fresh;
    try respondJson(request, "{\"ok\":true}");
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

// ── library browse ─────────────────────────────────────────────────

fn jsonEsc(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => {},
        '\t' => try out.appendSlice(arena, "\\t"),
        else => try out.append(arena, c),
    };
    return out.toOwnedSlice(arena);
}

fn kindLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "movie")) return "Movies";
    if (std.mem.eql(u8, kind, "tv")) return "Shows";
    if (std.mem.eql(u8, kind, "music")) return "Music";
    if (std.mem.eql(u8, kind, "audiobook")) return "Audiobooks";
    if (std.mem.eql(u8, kind, "comic")) return "Comics";
    return kind;
}

fn parseStatus(s: ?[]const u8) mediacatalog.Status {
    const v = s orelse return .all;
    if (std.mem.eql(u8, v, "missing_cover")) return .missing_cover;
    if (std.mem.eql(u8, v, "missing_metadata")) return .missing_metadata;
    if (std.mem.eql(u8, v, "duplicates")) return .duplicates;
    return .all;
}

fn parseSort(s: ?[]const u8) mediacatalog.Sort {
    const v = s orelse return .kind_title;
    if (std.mem.eql(u8, v, "title")) return .title;
    if (std.mem.eql(u8, v, "year")) return .year;
    return .kind_title;
}

/// Catalog-backed library listing. Opens the media catalog per request.
fn handleLibrary(app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lib = app.base_cfg.library_root;

    // Optional, URL-decoded query params.
    const q_text = if (queryValue(target, "q")) |v| try urlDecode(arena, v) else null;
    const q_kind = if (queryValue(target, "kind")) |v| try urlDecode(arena, v) else null;
    const query: mediacatalog.SearchQuery = .{
        .text = if (q_text) |t| (if (t.len > 0) t else null) else null,
        .kind = if (q_kind) |k| (if (k.len > 0) k else null) else null,
        .status = parseStatus(queryValue(target, "status")),
        .sort = parseSort(queryValue(target, "sort")),
    };

    const db_path = try mediacatalog.defaultPath(arena, app.env);
    var cat = mediacatalog.Catalog.open(db_path) catch {
        // No catalog yet → empty library; the UI shows a Rescan prompt.
        return respondJson(request, try std.fmt.allocPrint(arena, "{{\"library_root\":\"{s}\",\"total\":0,\"counts\":{{}},\"items\":[]}}", .{try jsonEsc(arena, lib)}));
    };
    defer cat.close();

    // Per-kind counts are always the UNFILTERED totals (for the chips); the item
    // list honors the active filters.
    const all = try cat.search(arena, .{});
    var counts = std.StringHashMap(u32).init(arena);
    for (all) |it| {
        const gop = try counts.getOrPut(it.kind);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
    }

    const items = try cat.search(arena, query);

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"library_root\":\"{s}\",\"total\":{d},\"counts\":{{", .{ try jsonEsc(arena, lib), all.len }));
    var first_c = true;
    var cit = counts.iterator();
    while (cit.next()) |e| {
        if (!first_c) try body.appendSlice(arena, ",");
        first_c = false;
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\"{s}\":{d}", .{ e.key_ptr.*, e.value_ptr.* }));
    }
    try body.appendSlice(arena, "},\"items\":[");
    for (items, 0..) |it, i| {
        if (i > 0) try body.appendSlice(arena, ",");
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"id\":{d},\"kind\":\"{s}\",\"label\":\"{s}\",\"title\":\"{s}\",\"subtitle\":\"{s}\",\"count\":{d},\"container\":\"{s}\",\"playable\":{s},\"has_cover\":{s},\"has_metadata\":{s}", .{
            it.id,
            it.kind,
            kindLabel(it.kind),
            try jsonEsc(arena, it.title),
            try jsonEsc(arena, it.subtitle orelse ""),
            it.file_count,
            it.container orelse "",
            boolStr(it.playable_inline),
            boolStr(it.has_cover),
            boolStr(it.has_metadata),
        }));
        if (it.year) |y| try body.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"year\":{d}", .{y}));
        if (it.cover_path) |cp| {
            // /api/cover wants an absolute path under library_root.
            const abs = try std.fs.path.join(arena, &.{ lib, cp });
            try body.appendSlice(arena, ",\"cover\":\"/api/cover?path=");
            try body.appendSlice(arena, try urlEncode(arena, abs));
            try body.appendSlice(arena, "\"");
        }
        try body.appendSlice(arena, "}");
    }
    try body.appendSlice(arena, "]}");
    try respondJson(request, body.items);
}

/// Rebuild/refresh the media catalog from library_root.
fn handleReindex(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = readBody(arena, request, 4096) catch {}; // consume body before respond
    const rebuild = if (queryValue(target, "rebuild")) |v| std.mem.eql(u8, v, "1") else false;

    const db_path = try mediacatalog.defaultPath(arena, app.env);
    var cat = mediacatalog.Catalog.open(db_path) catch
        return request.respond("cannot open catalog\n", .{ .status = .internal_server_error });
    defer cat.close();
    const st = indexer.scan(arena, io, &cat, app.base_cfg.library_root, rebuild) catch |err|
        return request.respond(try std.fmt.allocPrint(arena, "reindex failed: {s}\n", .{@errorName(err)}), .{ .status = .internal_server_error });
    try respondJson(request, try std.fmt.allocPrint(arena, "{{\"added\":{d},\"updated\":{d},\"removed\":{d},\"total\":{d}}}", .{ st.added, st.updated, st.removed, st.total }));
}

fn urlEncode(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/' or ch == '~';
        if (safe) {
            try out.append(arena, ch);
        } else {
            const hex = "0123456789ABCDEF";
            try out.append(arena, '%');
            try out.append(arena, hex[ch >> 4]);
            try out.append(arena, hex[ch & 0x0f]);
        }
    }
    return out.toOwnedSlice(arena);
}

// ── undo history ───────────────────────────────────────────────────

const UndoRow = struct { id: []const u8, created: i64, moved: u32, trashed: u32, wrote: u32 };

/// List undo journals (newest first). Reverted ones are renamed `.undone` and
/// excluded. Each row summarizes its op counts.
fn handleUndoList(io: std.Io, app: *App, request: *std.http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const udir = journal.dir(arena, app.env) catch return respondJson(request, "{\"runs\":[]}");
    var rows: std.ArrayList(UndoRow) = .empty;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, udir, .{ .iterate = true }) catch return respondJson(request, "{\"runs\":[]}");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const jpath = try std.fs.path.join(arena, &.{ udir, entry.name });
        const j = journal.load(arena, jpath) catch continue;
        var moved: u32 = 0;
        var trashed: u32 = 0;
        var wrote: u32 = 0;
        for (j.entries) |e| switch (e.action) {
            .move => moved += 1,
            .trash => trashed += 1,
            .tagwrite, .create => wrote += 1,
        };
        try rows.append(arena, .{ .id = try arena.dupe(u8, entry.name), .created = j.created, .moved = moved, .trashed = trashed, .wrote = wrote });
    }
    std.mem.sort(UndoRow, rows.items, {}, cmpUndoDesc);

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, "{\"runs\":[");
    for (rows.items, 0..) |r, i| {
        if (i > 0) try body.appendSlice(arena, ",");
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"id\":\"{s}\",\"created\":{d},\"moved\":{d},\"trashed\":{d},\"wrote\":{d}}}", .{ try jsonEsc(arena, r.id), r.created, r.moved, r.trashed, r.wrote }));
    }
    try body.appendSlice(arena, "]}");
    try respondJson(request, body.items);
}

fn cmpUndoDesc(_: void, a: UndoRow, b: UndoRow) bool {
    return a.created > b.created;
}

/// Revert one journal by id, then rename it `.undone` so it can't be re-run.
fn handleUndoRevert(app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = readBody(arena, request, 64 * 1024) catch {}; // consume body so respond() can keep-alive
    const id = queryValue(target, "id") orelse return request.respond("missing id\n", .{ .status = .bad_request });
    if (std.mem.indexOfScalar(u8, id, '/') != null or !std.mem.endsWith(u8, id, ".json"))
        return request.respond("bad id\n", .{ .status = .bad_request });
    const udir = try journal.dir(arena, app.env);
    const jpath = try std.fs.path.join(arena, &.{ udir, id });
    const j = journal.load(arena, jpath) catch return request.respond("cannot load journal\n", .{ .status = .not_found });
    apply_mod.undo(arena, j) catch return request.respond("undo failed\n", .{ .status = .internal_server_error });

    // Rename to .undone so it drops from the list (and can't be re-reverted).
    var fz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    const done = try std.fmt.allocPrint(arena, "{s}.undone", .{jpath});
    if (jpath.len < fz.len and done.len < tz.len) {
        const fzp = try std.fmt.bufPrintZ(&fz, "{s}", .{jpath});
        const tzp = try std.fmt.bufPrintZ(&tz, "{s}", .{done});
        _ = std.c.rename(fzp.ptr, tzp.ptr);
    }
    return respondJson(request, "{\"ok\":true}");
}

/// Serve a cover image, but only from within the library root (path allowlist).
fn handleCover(app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    const enc = queryValue(target, "path") orelse return request.respond("", .{ .status = .not_found });
    const p = try urlDecode(app.gpa, enc);
    defer app.gpa.free(p);
    if (!std.mem.startsWith(u8, p, app.base_cfg.library_root)) return request.respond("", .{ .status = .forbidden });
    if (std.mem.indexOf(u8, p, "..") != null) return request.respond("", .{ .status = .forbidden });

    var pz: [4096]u8 = undefined;
    if (p.len >= pz.len) return request.respond("", .{ .status = .not_found });
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{p}) catch return request.respond("", .{ .status = .not_found });
    const fp = std.c.fopen(pzp.ptr, "rb") orelse return request.respond("", .{ .status = .not_found });
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(app.gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        try buf.appendSlice(app.gpa, chunk[0..n]);
        if (buf.items.len > 16 * 1024 * 1024) break;
    }
    const ctype = if (std.ascii.endsWithIgnoreCase(p, ".png")) "image/png" else "image/jpeg";
    try request.respond(buf.items, .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = ctype },
        .{ .name = "cache-control", .value = "max-age=3600" },
    } });
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
