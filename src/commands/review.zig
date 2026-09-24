//! `medias review DIR [flags]` — build a Plan and serve the local web
//! review UI. Applies on click (with an undo journal), like `organize`.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../core/config.zig");
const group = @import("../core/group.zig");
const plan_mod = @import("../core/plan.zig");
const review = @import("../web/review.zig");
const http = @import("../util/http.zig");
const httpcache = @import("../util/httpcache.zig");
const musicbrainz = @import("../providers/musicbrainz.zig");
const tmdb = @import("../providers/tmdb.zig");
const standardize = @import("../core/standardize.zig");

fn mbCacheDir(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    const base = if (env.get("XDG_CACHE_HOME")) |x|
        try std.fs.path.join(alloc, &.{ x, "mediastacks", "mb" })
    else
        try std.fs.path.join(alloc, &.{ env.get("HOME") orelse "/tmp", ".cache", "mediastacks", "mb" });
    standardize.mkdirParents(base) catch {};
    return base;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var pz: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&pz, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        try buf.appendSlice(alloc, chunk[0..n]);
    }
    return buf.toOwnedSlice(alloc);
}

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var dir: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var port: u16 = 8788;
    var no_probe = false;
    var offline = false;
    var from: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            to = args[i];
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            port = std.fmt.parseInt(u16, args[i], 10) catch return usage(ctx);
        } else if (std.mem.eql(u8, a, "--no-probe")) {
            no_probe = true;
        } else if (std.mem.eql(u8, a, "--offline")) {
            offline = true;
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            from = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return usage(ctx);
        } else if (dir == null) {
            dir = a;
        }
    }

    var cfg = try config.load(ctx.arena, ctx.env);
    if (to) |x| cfg.library_root = x;

    const p: plan_mod.Plan = blk: {
        if (from) |fp| {
            const bytes = readFile(ctx.arena, fp) catch |err| {
                try ctx.stderr.print("cannot read plan {s}: {s}\n", .{ fp, @errorName(err) });
                return 2;
            };
            break :blk plan_mod.fromJson(ctx.arena, bytes) catch |err| {
                try ctx.stderr.print("cannot parse plan {s}: {s}\n", .{ fp, @errorName(err) });
                return 2;
            };
        }
        const d = dir orelse return usage(ctx);
        var real = http.RealHttpClient{ .io = ctx.io };
        const cache_dir = try mbCacheDir(ctx.arena, ctx.env);
        var caching_mb = httpcache.CachingHttpClient{ .inner = real.client(), .dir = cache_dir, .throttle_ms = 1100 };
        var caching_tmdb = httpcache.CachingHttpClient{ .inner = real.client(), .dir = cache_dir, .throttle_ms = 250 };
        var mb = musicbrainz.MusicBrainz{ .http_client = caching_mb.client(), .contact = cfg.musicbrainz_contact };
        var music_enr = musicbrainz.Enricher.init(ctx.arena, &mb);
        var tmdb_api = tmdb.Tmdb{ .http_client = caching_tmdb.client(), .api_key = cfg.tmdb_key orelse "" };
        var video_enr = tmdb.Enricher.init(ctx.arena, &tmdb_api);
        const online = group.Online{
            .music = if (cfg.musicbrainz_enabled and !offline) &music_enr else null,
            .video = if (cfg.tmdb_key != null and !offline) &video_enr else null,
        };
        break :blk group.buildPlan(ctx.arena, ctx.io, d, cfg, !no_probe, online) catch |err| {
            try ctx.stderr.print("cannot scan {s}: {s}\n", .{ d, @errorName(err) });
            return 2;
        };
    };

    var session = review.Session{ .arena = ctx.arena, .cfg = cfg, .plan = p };
    try review.serve(ctx.io, &session, ctx.env, .{ .port = port }, ctx.stdout);
    return 0;
}

fn usage(ctx: cli.Context) !u8 {
    try ctx.stderr.print("usage: medias review DIR [--to LIB] [--port N] [--no-probe] [--offline] [--from FILE]\n", .{});
    return 1;
}
