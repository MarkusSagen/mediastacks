//! `medias serve` — the organizer web app (a fuller, biblio-styled shell over
//! the same Plan/edit/apply core as `medias review`). Slice 1: the app shell +
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
const probe = @import("../core/probe.zig");
const indexer = @import("../core/indexer.zig");
const standardize = @import("../core/standardize.zig");
const review = @import("review.zig");
const static = @import("static.zig");
const shutdown = @import("../util/shutdown.zig");
const exec = @import("../util/exec.zig");
const opener = @import("../util/opener.zig");
const media_enrich_job = @import("media_enrich_job.zig");
const demo = @import("../core/demo.zig");

pub const Options = struct { bind: []const u8 = "127.0.0.1", port: u16 = 8799 };

const App = struct {
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    base_cfg: config.Config,
    plan_arena: std.heap.ArenaAllocator,
    session: review.Session, // .arena/.cfg/.plan; plan null until first organize
    has_plan: bool = false,
    enrich_job: media_enrich_job.Job,
    // Demo sandbox state (see /api/demo): when active, XDG_* + library_root are
    // pointed at a throwaway seeded dir; the saved_* strings restore the real
    // environment on "leave demo".
    demo_active: bool = false,
    saved_data: ?[]const u8 = null,
    saved_config: ?[]const u8 = null,
    saved_cache: ?[]const u8 = null,
    saved_lib: ?[]const u8 = null,
};

pub fn serve(io: std.Io, gpa: std.mem.Allocator, cfg: config.Config, env: *std.process.Environ.Map, opts: Options, log: *std.Io.Writer) !void {
    var app = App{
        .gpa = gpa,
        .env = env,
        .base_cfg = cfg,
        .plan_arena = std.heap.ArenaAllocator.init(gpa),
        .session = .{ .arena = undefined, .cfg = cfg, .plan = .{ .library_root = cfg.library_root, .source = "", .groups = &.{} } },
        .enrich_job = media_enrich_job.Job.init(gpa),
    };
    defer app.plan_arena.deinit();

    var address = try std.Io.net.IpAddress.parse(opts.bind, opts.port);
    var server = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 64 });
    defer server.deinit(io);
    try log.print("medias web app at http://{s}:{d}/  (Ctrl+C to stop)\n", .{ opts.bind, opts.port });
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

const RangeSpec = union(enum) {
    none,
    unsatisfiable,
    ok: struct { start: u64, end: u64 },
};

/// Parse an HTTP `Range` header value against `size`. Only the first range of a
/// list is honored. Lenient: anything it can't parse becomes `.none` (caller
/// serves from the start), a valid-but-out-of-bounds range becomes
/// `.unsatisfiable` (→ 416).
fn parseRange(header: ?[]const u8, size: u64) RangeSpec {
    const h = header orelse return .none;
    if (!std.mem.startsWith(u8, h, "bytes=")) return .none;
    const spec = std.mem.trim(u8, h[6..], " ");
    const first = if (std.mem.indexOfScalar(u8, spec, ',')) |c| spec[0..c] else spec;
    const dash = std.mem.indexOfScalar(u8, first, '-') orelse return .none;
    const start_s = std.mem.trim(u8, first[0..dash], " ");
    const end_s = std.mem.trim(u8, first[dash + 1 ..], " ");

    if (size == 0) return .unsatisfiable;

    if (start_s.len == 0) {
        // suffix range: last N bytes
        const n = std.fmt.parseInt(u64, end_s, 10) catch return .none;
        if (n == 0) return .unsatisfiable;
        const nn = @min(n, size);
        return .{ .ok = .{ .start = size - nn, .end = size - 1 } };
    }

    const start = std.fmt.parseInt(u64, start_s, 10) catch return .none;
    if (start >= size) return .unsatisfiable;
    var end: u64 = size - 1;
    if (end_s.len != 0) {
        const e = std.fmt.parseInt(u64, end_s, 10) catch return .none;
        if (e < start) return .none;
        end = @min(e, size - 1);
    }
    return .{ .ok = .{ .start = start, .end = end } };
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
        return respondAsset(request, static.medias_html, "text/html; charset=utf-8");
    if (std.mem.eql(u8, path, "/medias.js")) return respondAsset(request, static.medias_js, "application/javascript");
    if (std.mem.eql(u8, path, "/medias.css")) return respondAsset(request, static.medias_css, "text/css");
    if (std.mem.eql(u8, path, "/favicon.svg")) return respondAsset(request, static.favicon_svg, "image/svg+xml");

    if (std.mem.eql(u8, path, "/api/config")) return handleConfig(app, request);
    if (std.mem.eql(u8, path, "/api/organize")) return handleOrganize(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/library")) return handleLibrary(app, request, target);
    if (std.mem.eql(u8, path, "/api/item")) return handleItem(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/reindex")) return handleReindex(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/cover")) return handleCover(app, request, target);
    if (std.mem.eql(u8, path, "/api/undo/list")) return handleUndoList(io, app, request);
    if (std.mem.eql(u8, path, "/api/undo/revert")) return handleUndoRevert(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/open")) return handleOpen(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/stream")) return handleStream(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/enrich")) return handleEnrich(io, app, request, target);
    if (std.mem.eql(u8, path, "/api/enrich/status")) return handleEnrichStatus(app, request);
    if (std.mem.eql(u8, path, "/api/demo")) return handleDemo(io, app, request, target);

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
        reindexQuietly(io, app); // catalog reflects the newly organized items
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
    // First run = never configured (no config.toml) AND an empty/absent catalog.
    const first_run = !app.demo_active and !config.exists(arena, app.env) and catalogEmpty(arena, app);
    const body = try std.fmt.allocPrint(arena,
        \\{{"library_root":"{s}","write_tags":{s},"write_nfo":{s},"id_suffix":{s},"emit_ignore":{s},"musicbrainz":{s},"musicbrainz_contact":"{s}","tmdb_key":"{s}","first_run":{s},"demo_active":{s}}}
    , .{
        try jsonEsc(arena, c.library_root),
        boolStr(c.write_tags),
        boolStr(c.write_nfo),
        boolStr(c.id_suffix),
        boolStr(c.emit_ignore),
        boolStr(c.musicbrainz_enabled),
        try jsonEsc(arena, c.musicbrainz_contact orelse ""),
        try jsonEsc(arena, c.tmdb_key orelse ""),
        boolStr(first_run),
        boolStr(app.demo_active),
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
        else => if (c < 0x20) {
            const hex = "0123456789abcdef";
            try out.appendSlice(arena, "\\u00");
            try out.append(arena, hex[(c >> 4) & 0xf]);
            try out.append(arena, hex[c & 0xf]);
        } else try out.append(arena, c),
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

fn fileRole(kind: []const u8, base: []const u8) []const u8 {
    if (indexer.isCoverName(base)) return "cover";
    if (std.ascii.endsWithIgnoreCase(base, ".nfo")) return "nfo";
    const ext = std.fs.path.extension(base);
    if (indexer.mediaExtForKind(kind, ext)) return "media";
    return "other";
}

fn statSizeApp(io: std.Io, path: []const u8) u64 {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    const st = f.stat(io) catch return 0;
    return st.size;
}

/// One item's full detail + the files currently on disk under its folder.
fn appendTracks(arena: std.mem.Allocator, body: *std.ArrayList(u8), key: []const u8, tracks: []const probe.Track) !void {
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"{s}\":[", .{key}));
    for (tracks, 0..) |tr, i| {
        if (i > 0) try body.appendSlice(arena, ",");
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"lang\":\"{s}\",\"codec\":\"{s}\",\"title\":\"{s}\",\"default\":{s},\"forced\":{s}}}", .{
            try jsonEsc(arena, tr.lang orelse ""),
            try jsonEsc(arena, tr.codec orelse ""),
            try jsonEsc(arena, tr.title orelse ""),
            boolStr(tr.default),
            boolStr(tr.forced),
        }));
    }
    try body.appendSlice(arena, "]");
}

fn handleItem(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lib = app.base_cfg.library_root;

    const id_s = queryValue(target, "id") orelse return request.respond("missing id\n", .{ .status = .bad_request });
    const id = std.fmt.parseInt(i64, id_s, 10) catch return request.respond("bad id\n", .{ .status = .bad_request });

    const db_path = try mediacatalog.defaultPath(arena, app.env);
    var cat = mediacatalog.Catalog.open(db_path) catch return request.respond("no catalog\n", .{ .status = .not_found });
    defer cat.close();
    const item = (cat.getById(arena, id) catch null) orelse return request.respond("not found\n", .{ .status = .not_found });

    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, try std.fmt.allocPrint(arena,
        "{{\"id\":{d},\"kind\":\"{s}\",\"title\":\"{s}\",\"subtitle\":\"{s}\",\"path\":\"{s}\",\"count\":{d},\"total_bytes\":{d},\"container\":\"{s}\",\"playable\":{s},\"has_cover\":{s},\"has_metadata\":{s}", .{
        item.id, item.kind,
        try jsonEsc(arena, item.title),
        try jsonEsc(arena, item.subtitle orelse ""),
        try jsonEsc(arena, item.path),
        item.file_count, item.total_bytes,
        item.container orelse "",
        boolStr(item.playable_inline), boolStr(item.has_cover), boolStr(item.has_metadata),
    }));
    if (item.year) |y| try body.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"year\":{d}", .{y}));
    if (item.provider) |p| try body.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"provider\":\"{s}\"", .{p}));
    if (item.provider_id) |pid| try body.appendSlice(arena, try std.fmt.allocPrint(arena, ",\"provider_id\":\"{s}\"", .{try jsonEsc(arena, pid)}));
    if (item.cover_path) |cp| {
        const abs = try std.fs.path.join(arena, &.{ lib, cp });
        try body.appendSlice(arena, ",\"cover\":\"/api/cover?path=");
        try body.appendSlice(arena, try urlEncode(arena, abs));
        try body.appendSlice(arena, "\"");
    }

    // Live file listing under the item folder. Same walk idiom as
    // indexer.aggregate(): openDir/walk with catch-to-fallback so any error
    // still yields valid JSON with an empty files array.
    try body.appendSlice(arena, ",\"files\":[");
    const item_abs = try std.fs.path.join(arena, &.{ lib, item.path });
    const cwd = std.Io.Dir.cwd();
    var first = true;
    walk_files: {
        var dir = cwd.openDir(io, item_abs, .{ .iterate = true }) catch break :walk_files;
        defer dir.close(io);
        var walker = dir.walk(arena) catch break :walk_files;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const base = std.fs.path.basename(entry.path);
            const abs = try std.fs.path.join(arena, &.{ item_abs, entry.path });
            if (!first) try body.appendSlice(arena, ",");
            first = false;
            try body.appendSlice(arena, try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"rel\":\"{s}\",\"size\":{d},\"role\":\"{s}\"}}", .{
                try jsonEsc(arena, base),
                try jsonEsc(arena, entry.path),
                statSizeApp(io, abs),
                fileRole(item.kind, base),
            }));
        }
    }
    try body.appendSlice(arena, "]");

    // Audio/subtitle tracks (epic Phase B): probe the primary video on demand
    // (skipped silently when ffprobe is missing or the item isn't video).
    if (std.mem.eql(u8, item.kind, "movie") or std.mem.eql(u8, item.kind, "tv")) {
        if (item.primary_path) |pp| {
            const pabs = try std.fs.path.join(arena, &.{ lib, pp });
            if (probe.run(arena, io, pabs)) |pr| {
                try appendTracks(arena, &body, "audio", pr.audio);
                try appendTracks(arena, &body, "subs", pr.subs);
            }
        }
    }

    try body.appendSlice(arena, "}");
    try respondJson(request, body.items);
}

/// Open an item in the OS: mode=reveal → `open -R <target>` (Finder),
/// mode=launch → `open <target>` (default app). Target is the item's primary
/// file when present, else its folder. Allowlisted to library_root.
fn handleOpen(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = readBody(arena, request, 4096) catch {}; // consume body before respond
    const lib = app.base_cfg.library_root;

    const id_s = queryValue(target, "id") orelse return request.respond("missing id\n", .{ .status = .bad_request });
    const id = std.fmt.parseInt(i64, id_s, 10) catch return request.respond("bad id\n", .{ .status = .bad_request });
    const reveal = if (queryValue(target, "mode")) |m| std.mem.eql(u8, m, "reveal") else true;

    const db_path = try mediacatalog.defaultPath(arena, app.env);
    var cat = mediacatalog.Catalog.open(db_path) catch return request.respond("no catalog\n", .{ .status = .not_found });
    defer cat.close();
    const item = (cat.getById(arena, id) catch null) orelse return request.respond("not found\n", .{ .status = .not_found });

    // Launch → primary file if known; reveal (or no primary) → the item folder.
    const rel = if (!reveal and item.primary_path != null) item.primary_path.? else item.path;
    const abs = try std.fs.path.join(arena, &.{ lib, rel });
    if (!pathUnderRoot(abs, lib) or std.mem.indexOf(u8, abs, "..") != null)
        return request.respond("forbidden\n", .{ .status = .forbidden });

    const argv = opener.argv(arena, app.env, reveal, abs) catch
        return request.respond("open failed\n", .{ .status = .internal_server_error });
    const r = exec.runCaptureStdout(arena, io, argv, 4096) catch
        return request.respond("open failed\n", .{ .status = .internal_server_error });
    arena.free(r.stdout);
    // Windows `explorer` returns 1 even on success, so its exit code is ignored.
    if (opener.exitIsMeaningful() and r.exit_code != 0)
        return request.respond("open exited nonzero\n", .{ .status = .internal_server_error });
    try respondJson(request, "{\"ok\":true}");
}

fn streamContentType(ext: []const u8) []const u8 {
    const map = [_]struct { e: []const u8, t: []const u8 }{
        .{ .e = ".mp4", .t = "video/mp4" },   .{ .e = ".m4v", .t = "video/mp4" },
        .{ .e = ".webm", .t = "video/webm" }, .{ .e = ".mkv", .t = "video/x-matroska" },
        .{ .e = ".mov", .t = "video/quicktime" },
        .{ .e = ".mp3", .t = "audio/mpeg" },  .{ .e = ".flac", .t = "audio/flac" },
        .{ .e = ".m4a", .t = "audio/mp4" },   .{ .e = ".m4b", .t = "audio/mp4" },
        .{ .e = ".aac", .t = "audio/aac" },   .{ .e = ".ogg", .t = "audio/ogg" },
        .{ .e = ".opus", .t = "audio/ogg" },  .{ .e = ".wav", .t = "audio/wav" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(ext, m.e)) return m.t;
    return "application/octet-stream";
}

fn rangeHeader(request: *std.http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "range")) return h.value;
    return null;
}

const STREAM_MAX_CHUNK: u64 = 8 * 1024 * 1024;

/// Serve the item's primary media file with HTTP Range support so a browser
/// <audio>/<video> element can play it. Chunks are capped so memory stays flat.
fn handleStream(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lib = app.base_cfg.library_root;

    const id_s = queryValue(target, "id") orelse return request.respond("missing id\n", .{ .status = .bad_request });
    const id = std.fmt.parseInt(i64, id_s, 10) catch return request.respond("bad id\n", .{ .status = .bad_request });

    const db_path = try mediacatalog.defaultPath(arena, app.env);
    var cat = mediacatalog.Catalog.open(db_path) catch return request.respond("no catalog\n", .{ .status = .not_found });
    defer cat.close();
    const item = (cat.getById(arena, id) catch null) orelse return request.respond("not found\n", .{ .status = .not_found });
    const rel = item.primary_path orelse return request.respond("no media\n", .{ .status = .not_found });

    const abs = try std.fs.path.join(arena, &.{ lib, rel });
    if (!pathUnderRoot(abs, lib) or std.mem.indexOf(u8, abs, "..") != null)
        return request.respond("forbidden\n", .{ .status = .forbidden });

    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, abs, .{}) catch return request.respond("not found\n", .{ .status = .not_found });
    defer f.close(io);
    const size: u64 = (f.stat(io) catch return request.respond("stat failed\n", .{ .status = .internal_server_error })).size;
    const ctype = streamContentType(std.fs.path.extension(abs));

    // Resolve the byte window + status.
    var start: u64 = 0;
    var end: u64 = if (size == 0) 0 else size - 1;
    var partial = false;
    switch (parseRange(rangeHeader(request), size)) {
        .unsatisfiable => {
            const cr = try std.fmt.allocPrint(arena, "bytes */{d}", .{size});
            return request.respond("", .{ .status = .range_not_satisfiable, .extra_headers = &.{
                .{ .name = "content-range", .value = cr },
                .{ .name = "accept-ranges", .value = "bytes" },
            } });
        },
        .ok => |r| {
            start = r.start;
            end = r.end;
            partial = true;
        },
        .none => {
            // No Range: whole file if small, else 206 first chunk (Accept-Ranges
            // tells the client it may range).
            if (size > STREAM_MAX_CHUNK) {
                end = STREAM_MAX_CHUNK - 1;
                partial = true;
            }
        },
    }
    // Cap the served window.
    if (end >= start + STREAM_MAX_CHUNK) {
        end = start + STREAM_MAX_CHUNK - 1;
        partial = true;
    }

    const len: usize = @intCast(if (size == 0) 0 else end - start + 1);
    const buf = try arena.alloc(u8, len);
    const n = if (len == 0) 0 else f.readPositionalAll(io, buf, start) catch
        return request.respond("read failed\n", .{ .status = .internal_server_error });

    if (partial) {
        const cr = try std.fmt.allocPrint(arena, "bytes {d}-{d}/{d}", .{ start, end, size });
        return request.respond(buf[0..n], .{ .status = .partial_content, .extra_headers = &.{
            .{ .name = "content-type", .value = ctype },
            .{ .name = "content-range", .value = cr },
            .{ .name = "accept-ranges", .value = "bytes" },
            .{ .name = "cache-control", .value = "no-cache" },
        } });
    }
    return request.respond(buf[0..n], .{ .status = .ok, .extra_headers = &.{
        .{ .name = "content-type", .value = ctype },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

/// Best-effort full re-scan of the catalog after a mutation (the catalog is a
/// derived cache; errors are swallowed and Rescan can always fix it).
fn reindexQuietly(io: std.Io, app: *App) void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db_path = mediacatalog.defaultPath(arena, app.env) catch return;
    var cat = mediacatalog.Catalog.open(db_path) catch return;
    defer cat.close();
    _ = indexer.scan(arena, io, &cat, app.base_cfg.library_root, false) catch {};
}

/// True when the media catalog has no rows (or doesn't exist yet).
fn catalogEmpty(arena: std.mem.Allocator, app: *App) bool {
    const db_path = mediacatalog.defaultPath(arena, app.env) catch return true;
    var cat = mediacatalog.Catalog.open(db_path) catch return true;
    defer cat.close();
    return (cat.count() catch 0) == 0;
}

/// Dup an env value into `gpa` (owned), or null. Used to save the real XDG_*
/// before the demo overrides them, so "leave demo" can restore.
fn saveEnv(app: *App, key: []const u8) ?[]const u8 {
    const v = app.env.get(key) orelse return null;
    return app.gpa.dupe(u8, v) catch null;
}

/// POST /api/demo — enter the throwaway demo sandbox (seed + point XDG_*/library
/// at it + reindex). `?exit=1` restores the real environment. The single-user,
/// localhost server holds the demo state on `App`.
fn handleDemo(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = readBody(arena, request, 4096) catch {}; // consume body before respond

    if (queryValue(target, "exit") != null) {
        if (app.saved_data) |v| app.env.put("XDG_DATA_HOME", v) catch {};
        if (app.saved_config) |v| app.env.put("XDG_CONFIG_HOME", v) catch {};
        if (app.saved_cache) |v| app.env.put("XDG_CACHE_HOME", v) catch {};
        if (app.saved_lib) |v| app.base_cfg.library_root = v;
        app.demo_active = false;
        reindexQuietly(io, app);
        return respondJson(request, "{\"ok\":true,\"demo\":false}");
    }

    // Save the real environment once, before the first override.
    if (!app.demo_active) {
        app.saved_data = saveEnv(app, "XDG_DATA_HOME");
        app.saved_config = saveEnv(app, "XDG_CONFIG_HOME");
        app.saved_cache = saveEnv(app, "XDG_CACHE_HOME");
        app.saved_lib = app.gpa.dupe(u8, app.base_cfg.library_root) catch null;
    }

    const s = demo.activate(arena, io, app.env) catch
        return request.respond("demo seed failed\n", .{ .status = .internal_server_error });
    // library_root must outlive the request (base_cfg is read on every request).
    app.base_cfg.library_root = app.gpa.dupe(u8, s.library) catch s.library;
    app.demo_active = true;
    reindexQuietly(io, app);
    try respondJson(request, try std.fmt.allocPrint(arena, "{{\"ok\":true,\"demo\":true,\"downloads\":\"{s}\"}}", .{try jsonEsc(arena, s.downloads)}));
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

/// Cache dir for provider HTTP responses: `$XDG_CACHE_HOME/mediastacks/mb` else
/// `$HOME/.cache/mediastacks/mb`. Mirrors `commands/organize.zig`'s `mbCacheDir`.
fn enrichCacheDir(arena: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    const base = if (env.get("XDG_CACHE_HOME")) |x|
        try std.fs.path.join(arena, &.{ x, "mediastacks", "mb" })
    else
        try std.fs.path.join(arena, &.{ env.get("HOME") orelse "/tmp", ".cache", "mediastacks", "mb" });
    standardize.mkdirParents(base) catch {};
    return base;
}

/// Start (or reject if already running) a background enrichment batch:
/// `?id=N` enriches one item, otherwise all items missing metadata.
fn handleEnrich(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = readBody(arena, request, 4096) catch {}; // consume body before respond

    const only_id: ?i64 = if (queryValue(target, "id")) |v| (std.fmt.parseInt(i64, v, 10) catch null) else null;
    const cat_path = try mediacatalog.defaultPath(arena, app.env);
    const cache_dir = try enrichCacheDir(arena, app.env);

    media_enrich_job.spawn(app.gpa, io, app.base_cfg, cache_dir, cat_path, app.base_cfg.library_root, only_id, &app.enrich_job) catch |err| {
        if (err == error.JobBusy) return request.respond("{\"error\":\"busy\"}", .{ .status = .conflict, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return request.respond("enrich failed\n", .{ .status = .internal_server_error });
    };
    try respondJson(request, "{\"started\":true}");
}

/// Progress snapshot for the in-flight (or last completed) enrichment batch.
fn handleEnrichStatus(app: *App, request: *std.http.Server.Request) !void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try app.enrich_job.snapshot(arena);
    const state = switch (s.state) {
        .idle => "idle",
        .running => "running",
        .finished => "finished",
        .canceled => "canceled",
    };
    const body = try std.fmt.allocPrint(arena,
        "{{\"state\":\"{s}\",\"total\":{d},\"processed\":{d},\"ok\":{d},\"no_match\":{d},\"errored\":{d},\"current_id\":{d},\"current_title\":\"{s}\"}}",
        .{ state, s.total, s.processed, s.ok, s.no_match, s.errored, s.current_id, try jsonEsc(arena, s.current_title) });
    try respondJson(request, body);
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
fn handleUndoRevert(io: std.Io, app: *App, request: *std.http.Server.Request, target: []const u8) !void {
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
    reindexQuietly(io, app); // catalog reflects the reverted items
    return respondJson(request, "{\"ok\":true}");
}

/// True iff `abs` is `root` itself or lies under `root/`. Lexical only — a
/// trailing slash on `root` is tolerated; callers MUST still reject ".."
/// separately (this does not canonicalize).
fn pathUnderRoot(abs: []const u8, root: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "/");
    if (r.len == 0) return false; // refuse an empty / "/"-only root rather than match everything
    if (std.mem.eql(u8, abs, r)) return true;
    return abs.len > r.len and std.mem.startsWith(u8, abs, r) and abs[r.len] == '/';
}

/// Serve a cover image, but only from within the library root (path allowlist).
fn handleCover(app: *App, request: *std.http.Server.Request, target: []const u8) !void {
    const enc = queryValue(target, "path") orelse return request.respond("", .{ .status = .not_found });
    const p = try urlDecode(app.gpa, enc);
    defer app.gpa.free(p);
    if (!pathUnderRoot(p, app.base_cfg.library_root)) return request.respond("", .{ .status = .forbidden });
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

test "parseRange" {
    const t = std.testing;
    // no / unparseable header → none
    try t.expect(parseRange(null, 100) == .none);
    try t.expect(parseRange("nonsense", 100) == .none);
    try t.expect(parseRange("bytes=abc", 100) == .none);

    // open-ended and closed ranges
    switch (parseRange("bytes=0-", 100)) {
        .ok => |r| {
            try t.expectEqual(@as(u64, 0), r.start);
            try t.expectEqual(@as(u64, 99), r.end);
        },
        else => return error.TestUnexpected,
    }
    switch (parseRange("bytes=10-19", 100)) {
        .ok => |r| {
            try t.expectEqual(@as(u64, 10), r.start);
            try t.expectEqual(@as(u64, 19), r.end);
        },
        else => return error.TestUnexpected,
    }
    // clamp end past EOF
    switch (parseRange("bytes=0-999", 100)) {
        .ok => |r| try t.expectEqual(@as(u64, 99), r.end),
        else => return error.TestUnexpected,
    }
    // suffix range: last 20 bytes of 100 → [80,99]
    switch (parseRange("bytes=-20", 100)) {
        .ok => |r| {
            try t.expectEqual(@as(u64, 80), r.start);
            try t.expectEqual(@as(u64, 99), r.end);
        },
        else => return error.TestUnexpected,
    }
    // start past EOF → unsatisfiable
    try t.expect(parseRange("bytes=200-", 100) == .unsatisfiable);
    // any range against a zero-length file → unsatisfiable
    try t.expect(parseRange("bytes=0-", 0) == .unsatisfiable);
}
