//! Turn a messy directory into a reorganization `Plan`.
//!
//! Walks the tree, classifies each file, parses TV/movie fields, groups
//! copies of the same episode/movie (choosing the best via `mediascore`),
//! flags junk and sidecars, and renders destination paths from the
//! configured templates. Everything is arena-allocated — the caller owns
//! the arena.

const std = @import("std");
const kind = @import("kind.zig");
const classify_mod = @import("classify.zig");
const mediascore = @import("mediascore.zig");
const template = @import("template.zig");
const config = @import("config.zig");
const plan = @import("plan.zig");
const tv = @import("../kinds/tv.zig");
const movie = @import("../kinds/movie.zig");

const Cand = struct {
    abs: []const u8,
    dir: []const u8,
    stem: []const u8,
    size: u64,
    mkind: kind.MediaKind,
    ep: ?tv.Episode = null,
    mv: ?movie.Movie = null,
    group_idx: usize = 0,
    role: plan.Role = .primary,
    dst: ?[]const u8 = null,
    primary_dst: ?[]const u8 = null,
};

const Sidecar = struct {
    abs: []const u8,
    dir: []const u8,
    stem: []const u8,
    ext: []const u8,
};

const GB = struct {
    kind: kind.MediaKind,
    title: []const u8,
    year: ?u32,
    items: std.ArrayList(plan.Item),
};

fn lower(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// OS cruft, sample clips, and torrent-site promo litter — anything that
/// should be trashed rather than organized.
fn isJunkBase(base: []const u8) bool {
    // Exact OS/system files.
    const exact = [_][]const u8{ ".DS_Store", "Thumbs.db", "desktop.ini" };
    for (exact) |e| {
        if (std.mem.eql(u8, base, e)) return true;
    }

    var buf: [512]u8 = undefined;
    if (base.len >= buf.len) return false;
    const lo = std.ascii.lowerString(buf[0..base.len], base);

    // Sample clips (e.g. "Sample.mkv", "movie-sample.mp4").
    if (std.mem.indexOf(u8, lo, "sample") != null) return true;

    // Torrent-site promo litter dropped alongside real media.
    if (std.mem.startsWith(u8, lo, "torrent downloaded from")) return true;
    if (std.mem.indexOf(u8, lo, "rarbg") != null) return true;
    if (std.mem.indexOf(u8, lo, "yts.") != null or std.mem.indexOf(u8, lo, "yify") != null) return true;
    // "www.<site>....txt/nfo" promo drops (but not real media by that name).
    if (std.mem.startsWith(u8, lo, "www.") and
        (std.mem.endsWith(u8, lo, ".txt") or std.mem.endsWith(u8, lo, ".nfo"))) return true;
    // Internet-shortcut litter.
    if (std.mem.endsWith(u8, lo, ".url") or std.mem.endsWith(u8, lo, ".website")) return true;

    return false;
}

fn isSidecarExt(ext_dot: []const u8) bool {
    const set = [_][]const u8{ ".nfo", ".srt", ".sub", ".ass", ".ssa" };
    for (set) |e| {
        if (std.ascii.eqlIgnoreCase(ext_dot, e)) return true;
    }
    return false;
}

fn statSize(io: std.Io, path: []const u8) u64 {
    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    const st = f.stat(io) catch return 0;
    return st.size;
}

fn u32str(arena: std.mem.Allocator, n: u32) ![]u8 {
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

/// Replace `path`'s extension with `new_ext` (no leading dot). Owned by arena.
fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return i;
}

/// Replace `path`'s extension with `new_ext` (no leading dot). Owned by arena.
fn replaceExt(arena: std.mem.Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const e = std.fs.path.extension(path);
    const stem = path[0 .. path.len - e.len];
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ stem, new_ext });
}

fn tvDst(arena: std.mem.Allocator, cfg: config.Config, series: []const u8, ep: tv.Episode) ![]u8 {
    const fields = [_]template.Field{
        .{ .name = "series", .value = series },
        .{ .name = "season", .value = try u32str(arena, ep.season) },
        .{ .name = "episode", .value = try u32str(arena, ep.episode) },
        .{ .name = "title", .value = ep.title orelse "" },
        .{ .name = "ext", .value = ep.ext },
    };
    const rel = try template.renderFields(arena, cfg.tv_template, &fields);
    return std.fs.path.join(arena, &.{ cfg.library_root, rel });
}

fn movieDst(arena: std.mem.Allocator, cfg: config.Config, mv: movie.Movie) ![]u8 {
    const year_str = if (mv.year) |y| try u32str(arena, y) else "";
    const fields = [_]template.Field{
        .{ .name = "title", .value = mv.title },
        .{ .name = "year", .value = year_str },
        .{ .name = "ext", .value = mv.ext },
    };
    const rel = try template.renderFields(arena, cfg.movie_template, &fields);
    return std.fs.path.join(arena, &.{ cfg.library_root, rel });
}

pub fn buildPlan(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    cfg: config.Config,
) !plan.Plan {
    var media: std.ArrayList(*Cand) = .empty;
    var sidecars: std.ArrayList(Sidecar) = .empty;
    var junk: std.ArrayList([]const u8) = .empty;
    var unclassified: std.ArrayList([]const u8) = .empty;

    // ---- Phase A: walk & bucket ---------------------------------------
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        const abs = try std.fs.path.join(arena, &.{ dir_path, entry.path });
        const d = std.fs.path.dirname(abs) orelse dir_path;

        if (isJunkBase(base)) {
            try junk.append(arena, abs);
            continue;
        }

        const ext_dot = std.fs.path.extension(base);
        // `base` aliases the walker's reused name buffer, so any slice of it
        // that outlives this iteration must be duped into the arena.
        const stem = try arena.dupe(u8, base[0 .. base.len - ext_dot.len]);

        if (isSidecarExt(ext_dot)) {
            const ext = try arena.dupe(u8, if (ext_dot.len > 0) ext_dot[1..] else ext_dot);
            try sidecars.append(arena, .{ .abs = abs, .dir = d, .stem = stem, .ext = ext });
            continue;
        }

        const mk = classify_mod.classify(base, false);
        if (mk == .tv or mk == .movie) {
            const c = try arena.create(Cand);
            c.* = .{ .abs = abs, .dir = d, .stem = stem, .size = statSize(io, abs), .mkind = mk };
            if (mk == .tv) c.ep = try tv.parse(arena, base);
            if (mk == .movie) c.mv = try movie.parse(arena, base);
            // A .tv classification with no parseable marker is unexpected; drop to unclassified.
            if (mk == .tv and c.ep == null) {
                try unclassified.append(arena, abs);
            } else {
                try media.append(arena, c);
            }
        } else {
            try unclassified.append(arena, abs);
        }
    }

    // ---- Phase B: group media -----------------------------------------
    var gbs: std.ArrayList(GB) = .empty;
    var key_to_gb = std.StringHashMap(usize).init(arena);
    var gb_cands: std.ArrayList(std.ArrayList(*Cand)) = .empty;

    for (media.items) |c| {
        const key = if (c.mkind == .tv)
            try std.fmt.allocPrint(arena, "tv|{s}|{d}", .{ try lower(arena, c.ep.?.series), c.ep.?.season })
        else
            try std.fmt.allocPrint(arena, "mv|{s}|{?d}", .{ try lower(arena, c.mv.?.title), c.mv.?.year });

        const gop = try key_to_gb.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = gbs.items.len;
            try gbs.append(arena, .{
                .kind = c.mkind,
                .title = if (c.mkind == .tv) c.ep.?.series else c.mv.?.title,
                .year = if (c.mkind == .movie) c.mv.?.year else null,
                .items = .empty,
            });
            try gb_cands.append(arena, .empty);
        }
        c.group_idx = gop.value_ptr.*;
        try gb_cands.items[c.group_idx].append(arena, c);
    }

    // Dedup within each group and compute destinations.
    for (gbs.items, 0..) |*gb, gi| {
        const cands = gb_cands.items[gi];
        if (gb.kind == .tv) {
            // Pick the best copy per episode.
            var best = std.AutoHashMap(u32, *Cand).init(arena);
            for (cands.items) |c| {
                const gop = try best.getOrPut(c.ep.?.episode);
                if (!gop.found_existing or
                    mediascore.videoScore(c.ep.?.quality, c.size) >
                        mediascore.videoScore(gop.value_ptr.*.ep.?.quality, gop.value_ptr.*.size))
                {
                    gop.value_ptr.* = c;
                }
            }
            // Compute each primary's dst.
            var it = best.valueIterator();
            while (it.next()) |cp| {
                cp.*.dst = try tvDst(arena, cfg, gb.title, cp.*.ep.?);
            }
            // Assign roles + emit items.
            for (cands.items) |c| {
                const winner = best.get(c.ep.?.episode).?;
                c.primary_dst = winner.dst;
                if (c == winner) {
                    c.role = .primary;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .primary, .op = .move, .dst = c.dst, .reason = "" });
                } else {
                    c.role = .duplicate;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .duplicate, .op = .skip, .dst = null, .reason = "duplicate of primary" });
                }
            }
        } else {
            // Movie: all copies represent one work; pick the single best.
            var winner = cands.items[0];
            for (cands.items[1..]) |c| {
                if (mediascore.videoScore(c.mv.?.quality, c.size) >
                    mediascore.videoScore(winner.mv.?.quality, winner.size)) winner = c;
            }
            winner.dst = try movieDst(arena, cfg, winner.mv.?);
            for (cands.items) |c| {
                c.primary_dst = winner.dst;
                if (c == winner) {
                    try gb.items.append(arena, .{ .src = c.abs, .role = .primary, .op = .move, .dst = winner.dst, .reason = "" });
                } else {
                    try gb.items.append(arena, .{ .src = c.abs, .role = .duplicate, .op = .skip, .dst = null, .reason = "duplicate of primary" });
                }
            }
        }
    }

    // ---- Phase C: attach sidecars -------------------------------------
    for (sidecars.items) |sc| {
        var best_media: ?*Cand = null;
        var best_len: usize = 0;
        for (media.items) |c| {
            if (!std.mem.eql(u8, c.dir, sc.dir)) continue;
            const cp = commonPrefixLen(sc.stem, c.stem);
            if (cp >= 8 and cp > best_len) {
                best_media = c;
                best_len = cp;
            }
        }
        if (best_media) |c| {
            if (c.primary_dst) |pdst| {
                const dst = try replaceExt(arena, pdst, sc.ext);
                try gbs.items[c.group_idx].items.append(arena, .{ .src = sc.abs, .role = .sidecar, .op = .move, .dst = dst, .reason = "sidecar" });
                continue;
            }
        }
        try unclassified.append(arena, sc.abs);
    }

    // ---- Phase D: junk ------------------------------------------------
    if (junk.items.len > 0) {
        var jitems: std.ArrayList(plan.Item) = .empty;
        for (junk.items) |j| {
            try jitems.append(arena, .{ .src = j, .role = .junk, .op = .trash, .dst = null, .reason = "junk" });
        }
        try gbs.append(arena, .{ .kind = .unknown, .title = "junk", .year = null, .items = jitems });
    }

    // ---- Phase E: finalize --------------------------------------------
    var groups: std.ArrayList(plan.Group) = .empty;
    for (gbs.items) |*gb| {
        try groups.append(arena, .{
            .kind = gb.kind,
            .title = gb.title,
            .year = gb.year,
            .items = try gb.items.toOwnedSlice(arena),
        });
    }

    return plan.Plan{
        .library_root = cfg.library_root,
        .source = dir_path,
        .groups = try groups.toOwnedSlice(arena),
        .unclassified = try unclassified.toOwnedSlice(arena),
    };
}

// ---- tests ------------------------------------------------------------

const t = std.testing;

fn writeFileAt(comptime fmt: []const u8, args: anytype, contents: []const u8) !void {
    var pz: [512]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&pz, fmt, args);
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    _ = std.c.fwrite(contents.ptr, 1, contents.len, fp);
}

fn mkdirAt(comptime fmt: []const u8, args: anytype) void {
    var pz: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pz, fmt, args) catch return;
    _ = std.c.mkdir(path_z.ptr, 0o755);
}

fn unlinkAt(comptime fmt: []const u8, args: anytype) void {
    var pz: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pz, fmt, args) catch return;
    _ = std.c.unlink(path_z.ptr);
}

fn rmdirAt(comptime fmt: []const u8, args: anytype) void {
    var pz: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pz, fmt, args) catch return;
    _ = std.c.rmdir(path_z.ptr);
}

test "isJunkBase catches OS cruft, samples, and torrent-site promo litter" {
    // junk
    try t.expect(isJunkBase(".DS_Store"));
    try t.expect(isJunkBase("Thumbs.db"));
    try t.expect(isJunkBase("Sample.mkv"));
    try t.expect(isJunkBase("Torrent Downloaded From UIndex.org.txt"));
    try t.expect(isJunkBase("RARBG.txt"));
    try t.expect(isJunkBase("RARBG_DO_NOT_MIRROR.exe"));
    try t.expect(isJunkBase("www.YTS.MX.jpg"));
    try t.expect(isJunkBase("visit-us.url"));
    // NOT junk
    try t.expect(!isJunkBase("Witch Hat Atelier - S01E01 - The Magic.mkv"));
    try t.expect(!isJunkBase("The.Matrix.1999.1080p.mkv"));
    try t.expect(!isJunkBase("episode.nfo"));
}

test "buildPlan groups a season, dedups, trashes junk, attaches sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pid = std.c.getpid();
    var rb: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/stacks-group-{d}", .{pid});

    mkdirAt("{s}", .{root});
    mkdirAt("{s}/wrap", .{root});
    // S01E04 copy A (loose), copy B (nested) -> duplicate pair
    try writeFileAt("{s}/witch.hat.atelier.s01e04.1080p.web.h264-skyanime.mkv", .{root}, "aaaa");
    try writeFileAt("{s}/wrap/Witch Hat Atelier S01E04 Meetings in Kalhn 1080p CR WEB-DL-Kitsune.mkv", .{root}, "bbbbbbbb");
    // S01E05 single + its subtitle sidecar (same dir, stem prefix)
    try writeFileAt("{s}/witch.hat.atelier.s01e05.1080p.web.h264-skyanime.mkv", .{root}, "ccc");
    try writeFileAt("{s}/witch.hat.atelier.s01e05.en.srt", .{root}, "1\n00:00\nhi\n");
    // junk
    try writeFileAt("{s}/.DS_Store", .{root}, "junk");

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = config.Config{
        .library_root = "/lib",
        .tv_template = config.DEFAULT_TV,
        .movie_template = config.DEFAULT_MOVIE,
    };
    const p = try buildPlan(a, io, root, cfg);

    var tv_groups: usize = 0;
    var primaries: usize = 0;
    var dups: usize = 0;
    var trashed: usize = 0;
    var sidecar_items: usize = 0;
    var sidecar_dst_ok = false;
    for (p.groups) |g| {
        if (g.kind == .tv) tv_groups += 1;
        for (g.items) |it| {
            switch (it.role) {
                .primary => primaries += 1,
                .duplicate => dups += 1,
                .junk => {},
                .sidecar => {
                    sidecar_items += 1;
                    if (it.dst) |dv| {
                        if (std.mem.endsWith(u8, dv, ".srt")) sidecar_dst_ok = true;
                    }
                },
            }
            if (it.op == .trash) trashed += 1;
        }
    }
    try t.expectEqual(@as(usize, 1), tv_groups); // one series+season
    try t.expectEqual(@as(usize, 2), primaries); // S01E04 + S01E05
    try t.expectEqual(@as(usize, 1), dups); // second S01E04 copy
    try t.expectEqual(@as(usize, 1), trashed); // .DS_Store
    try t.expectEqual(@as(usize, 1), sidecar_items); // the .srt
    try t.expect(sidecar_dst_ok); // sidecar dst keeps its own extension

    // clean up temp tree
    unlinkAt("{s}/witch.hat.atelier.s01e04.1080p.web.h264-skyanime.mkv", .{root});
    unlinkAt("{s}/wrap/Witch Hat Atelier S01E04 Meetings in Kalhn 1080p CR WEB-DL-Kitsune.mkv", .{root});
    unlinkAt("{s}/witch.hat.atelier.s01e05.1080p.web.h264-skyanime.mkv", .{root});
    unlinkAt("{s}/witch.hat.atelier.s01e05.en.srt", .{root});
    unlinkAt("{s}/.DS_Store", .{root});
    rmdirAt("{s}/wrap", .{root});
    rmdirAt("{s}", .{root});
}
