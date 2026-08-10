//! `shelve organize DIR [flags]` — build a reorganization plan and, with
//! `--apply`, execute it. The dry-run plan is always printed first.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../core/config.zig");
const group = @import("../core/group.zig");
const plan_mod = @import("../core/plan.zig");
const apply_mod = @import("../core/apply.zig");
const http = @import("../util/http.zig");
const httpcache = @import("../util/httpcache.zig");
const musicbrainz = @import("../providers/musicbrainz.zig");
const tmdb = @import("../providers/tmdb.zig");
const standardize = @import("../core/standardize.zig");

const Opts = struct {
    dir: ?[]const u8 = null,
    to: ?[]const u8 = null,
    dry_run: bool = false,
    no_probe: bool = false,
    offline: bool = false,
    write_tags_flag: ?bool = null,
    write_nfo_flag: ?bool = null,
    plan_out: ?[]const u8 = null,
    from: ?[]const u8 = null,
    on_conflict: apply_mod.OnConflict = .skip,
};

/// `$XDG_CACHE_HOME/stacks/mb` (or `$HOME/.cache/stacks/mb`), created.
fn mbCacheDir(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    const base = if (env.get("XDG_CACHE_HOME")) |x|
        try std.fs.path.join(alloc, &.{ x, "stacks", "mb" })
    else
        try std.fs.path.join(alloc, &.{ env.get("HOME") orelse "/tmp", ".cache", "stacks", "mb" });
    standardize.mkdirParents(base) catch {};
    return base;
}

fn parseConflict(s: []const u8) ?apply_mod.OnConflict {
    if (std.mem.eql(u8, s, "skip")) return .skip;
    if (std.mem.eql(u8, s, "suffix")) return .suffix;
    if (std.mem.eql(u8, s, "overwrite")) return .overwrite;
    return null;
}

fn parseArgs(args: []const []const u8) !Opts {
    var o: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.to = args[i];
        } else if (std.mem.eql(u8, a, "--dry-run") or std.mem.eql(u8, a, "-n")) {
            o.dry_run = true;
        } else if (std.mem.eql(u8, a, "--no-probe")) {
            o.no_probe = true;
        } else if (std.mem.eql(u8, a, "--offline")) {
            o.offline = true;
        } else if (std.mem.eql(u8, a, "--write-tags")) {
            o.write_tags_flag = true;
        } else if (std.mem.eql(u8, a, "--no-write-tags")) {
            o.write_tags_flag = false;
        } else if (std.mem.eql(u8, a, "--nfo")) {
            o.write_nfo_flag = true;
        } else if (std.mem.eql(u8, a, "--no-nfo")) {
            o.write_nfo_flag = false;
        } else if (std.mem.eql(u8, a, "--plan")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.plan_out = args[i];
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.from = args[i];
        } else if (std.mem.eql(u8, a, "--on-conflict")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.on_conflict = parseConflict(args[i]) orelse return error.BadConflict;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else if (o.dir == null) {
            o.dir = a;
        }
    }
    return o;
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

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var pz: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&pz, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) return error.WriteFailed;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Keep = struct { dst: []const u8, media: ?plan_mod.MediaInfo };
fn lessKeep(_: void, a: Keep, b: Keep) bool {
    return std.mem.lessThan(u8, a.dst, b.dst);
}

/// Replace a leading $HOME with `~` for readable output.
fn abbrev(alloc: std.mem.Allocator, home: []const u8, path: []const u8) []const u8 {
    if (home.len > 0 and std.mem.startsWith(u8, path, home)) {
        return std.fmt.allocPrint(alloc, "~{s}", .{path[home.len..]}) catch path;
    }
    return path;
}

fn printPlan(alloc: std.mem.Allocator, w: *std.Io.Writer, p: plan_mod.Plan, home: []const u8) !void {
    var keep: std.ArrayList(Keep) = .empty; // destinations (move/copy) + media info
    var dups: std.ArrayList([]const u8) = .empty; // source leaf names (left in place)
    var junk: std.ArrayList([]const u8) = .empty; // source leaf names (→ trash)

    for (p.groups) |g| {
        for (g.items) |it| {
            switch (it.role) {
                .primary, .sidecar, .extra => if (it.dst) |d| try keep.append(alloc, .{ .dst = d, .media = it.media }),
                .duplicate => try dups.append(alloc, std.fs.path.basename(it.src)),
                .junk => try junk.append(alloc, std.fs.path.basename(it.src)),
            }
        }
    }

    std.mem.sort(Keep, keep.items, {}, lessKeep);
    std.mem.sort([]const u8, dups.items, {}, lessStr);
    std.mem.sort([]const u8, junk.items, {}, lessStr);

    // ── what gets organized, grouped by destination folder ──
    var folders: usize = 0;
    if (keep.items.len == 0) {
        try w.print("Nothing to organize.\n", .{});
    } else {
        try w.print("Organize {d} file(s) into the library:\n", .{keep.items.len});
        var cur_dir: ?[]const u8 = null;
        for (keep.items) |k| {
            const dir = std.fs.path.dirname(k.dst) orelse ".";
            if (cur_dir == null or !std.mem.eql(u8, cur_dir.?, dir)) {
                try w.print("\n  {s}/\n", .{abbrev(alloc, home, dir)});
                cur_dir = dir;
                folders += 1;
            }
            try w.print("      {s}", .{std.fs.path.basename(k.dst)});
            if (k.media) |m| {
                try w.print("   ·", .{});
                if (m.codec) |c| try w.print(" {s}", .{c});
                if (m.height) |h| try w.print(" {d}p", .{h});
                if (m.duration_s) |d| try w.print(" · {d}m", .{@as(u32, @intFromFloat(d / 60))});
            }
            try w.print("\n", .{});
        }
    }

    // ── what will NOT be kept ──
    if (dups.items.len > 0 or junk.items.len > 0 or p.unclassified.len > 0) {
        try w.print("\nNot kept:\n", .{});
        if (dups.items.len > 0) {
            try w.print("  duplicates — left in place, not imported ({d}):\n", .{dups.items.len});
            for (dups.items) |d| try w.print("      {s}\n", .{d});
        }
        if (junk.items.len > 0) {
            try w.print("  junk — moved to trash ({d}):\n", .{junk.items.len});
            // Collapse runs of identical basenames into "name ×N".
            var i: usize = 0;
            while (i < junk.items.len) {
                var n: usize = 1;
                while (i + n < junk.items.len and std.mem.eql(u8, junk.items[i], junk.items[i + n])) n += 1;
                if (n > 1) {
                    try w.print("      {s} ×{d}\n", .{ junk.items[i], n });
                } else {
                    try w.print("      {s}\n", .{junk.items[i]});
                }
                i += n;
            }
        }
        if (p.unclassified.len > 0) {
            try w.print("  unrecognized — skipped ({d}):\n", .{p.unclassified.len});
            for (p.unclassified) |u| try w.print("      {s}\n", .{std.fs.path.basename(u)});
        }
    }

    // ── advisory warnings (from ffprobe) ──
    var wcount: usize = 0;
    for (p.groups) |g| wcount += g.warnings.len;
    if (wcount > 0) {
        try w.print("\nWarnings:\n", .{});
        for (p.groups) |g| {
            for (g.warnings) |warn| try w.print("  [{s}] {s}\n", .{ g.title, warn });
        }
    }

    // ── one-line summary ──
    try w.print(
        "\nsummary: {d} file(s) into {d} folder(s) · {d} duplicate(s) left · {d} junk trashed · {d} unrecognized\n",
        .{ keep.items.len, folders, dups.items.len, junk.items.len, p.unclassified.len },
    );
}

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    const opts = parseArgs(args) catch |err| {
        try ctx.stderr.print("bad arguments: {s}\n", .{@errorName(err)});
        try ctx.stderr.print("usage: shelve organize DIR [--dry-run|-n] [--no-probe] [--to LIB] [--plan FILE] [--from FILE] [--on-conflict skip|suffix|overwrite]\n", .{});
        return 1;
    };

    // Applying is the default (rsync-style); --dry-run only previews.
    const do_apply = !opts.dry_run;

    var cfg = try config.load(ctx.arena, ctx.env);
    if (opts.to) |to| cfg.library_root = to;

    const p: plan_mod.Plan = blk: {
        if (opts.from) |fp| {
            const bytes = readFile(ctx.arena, fp) catch |err| {
                try ctx.stderr.print("cannot read plan {s}: {s}\n", .{ fp, @errorName(err) });
                return 2;
            };
            break :blk plan_mod.fromJson(ctx.arena, bytes) catch |err| {
                try ctx.stderr.print("cannot parse plan {s}: {s}\n", .{ fp, @errorName(err) });
                return 2;
            };
        }
        const dir = opts.dir orelse {
            try ctx.stderr.print("usage: shelve organize DIR [flags]\n", .{});
            return 1;
        };
        // Online enrichment (MusicBrainz + TMDB) when configured and not --offline.
        // Separate caching clients so each keeps its own throttle (MusicBrainz
        // is a strict 1 req/sec; TMDB is generous) over a shared on-disk cache.
        var real = http.RealHttpClient{ .io = ctx.io };
        const cache_dir = try mbCacheDir(ctx.arena, ctx.env);
        var caching_mb = httpcache.CachingHttpClient{ .inner = real.client(), .dir = cache_dir, .throttle_ms = 1100 };
        var caching_tmdb = httpcache.CachingHttpClient{ .inner = real.client(), .dir = cache_dir, .throttle_ms = 250 };
        var mb = musicbrainz.MusicBrainz{ .http_client = caching_mb.client(), .contact = cfg.musicbrainz_contact };
        var music_enr = musicbrainz.Enricher.init(ctx.arena, &mb);
        var tmdb_api = tmdb.Tmdb{ .http_client = caching_tmdb.client(), .api_key = cfg.tmdb_key orelse "" };
        var video_enr = tmdb.Enricher.init(ctx.arena, &tmdb_api);
        const online = group.Online{
            .music = if (cfg.musicbrainz_enabled and !opts.offline) &music_enr else null,
            .video = if (cfg.tmdb_key != null and !opts.offline) &video_enr else null,
        };
        break :blk group.buildPlan(ctx.arena, ctx.io, dir, cfg, !opts.no_probe, online) catch |err| {
            try ctx.stderr.print("cannot scan {s}: {s}\n", .{ dir, @errorName(err) });
            return 2;
        };
    };

    if (opts.plan_out) |op| {
        const j = try plan_mod.toJson(ctx.arena, p);
        writeFile(op, j) catch |err| {
            try ctx.stderr.print("cannot write plan {s}: {s}\n", .{ op, @errorName(err) });
            return 2;
        };
        try ctx.stdout.print("wrote plan to {s}\n", .{op});
    }

    const home = ctx.env.get("HOME") orelse "";
    try printPlan(ctx.arena, ctx.stdout, p, home);

    if (!do_apply) {
        try ctx.stdout.print("\n(dry-run — nothing changed; drop --dry-run to apply)\n", .{});
        return 0;
    }

    const write_tags = opts.write_tags_flag orelse cfg.write_tags;
    const write_nfo = opts.write_nfo_flag orelse cfg.write_nfo;
    const res = apply_mod.apply(ctx.arena, p, opts.on_conflict, ctx.env, .{ .write = write_tags }, cfg.emit_ignore, write_nfo) catch |err| {
        try ctx.stderr.print("apply failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    try ctx.stdout.print(
        "\napplied: moved={d} trashed={d} skipped={d}\nundo with: shelve undo   (journal: {s})\n",
        .{ res.moved, res.trashed, res.skipped, res.journal_path },
    );
    return 0;
}

const t = std.testing;

test "parseArgs reads flags" {
    const args = [_][]const u8{ "/downloads/show", "--to", "/lib", "--on-conflict", "suffix" };
    const opts = try parseArgs(args[0..]);
    try t.expectEqualStrings("/downloads/show", opts.dir.?);
    try t.expectEqualStrings("/lib", opts.to.?);
    try t.expectEqual(apply_mod.OnConflict.suffix, opts.on_conflict);
}

test "parseArgs default applies (dry_run off)" {
    const args = [_][]const u8{"/x"};
    const opts = try parseArgs(args[0..]);
    try t.expect(!opts.dry_run); // run() applies when dry_run is false
    try t.expectEqual(apply_mod.OnConflict.skip, opts.on_conflict);
    try t.expect(opts.from == null);
}

test "parseArgs --dry-run and -n both set dry_run" {
    const long = try parseArgs((&[_][]const u8{ "/x", "--dry-run" })[0..]);
    try t.expect(long.dry_run);
    const short = try parseArgs((&[_][]const u8{ "/x", "-n" })[0..]);
    try t.expect(short.dry_run);
}

test "parseArgs --no-probe" {
    const o = try parseArgs((&[_][]const u8{ "/x", "--no-probe" })[0..]);
    try t.expect(o.no_probe);
    const d = try parseArgs((&[_][]const u8{"/x"})[0..]);
    try t.expect(!d.no_probe); // probes by default
}
