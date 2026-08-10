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
const config = @import("config.zig");
const plan = @import("plan.zig");
const tv = @import("../kinds/tv.zig");
const movie = @import("../kinds/movie.zig");
const music = @import("../kinds/music.zig");
const probe = @import("probe.zig");
const enrich = @import("enrich.zig");
const drm = @import("drm.zig");
const naming = @import("naming.zig");
const musicbrainz = @import("../providers/musicbrainz.zig");
const tmdb = @import("../providers/tmdb.zig");

/// Optional online enrichers, one per family. Absent → offline for that kind.
pub const Online = struct {
    music: ?*musicbrainz.Enricher = null,
    video: ?*tmdb.Enricher = null,
};

const Cand = struct {
    abs: []const u8,
    dir: []const u8,
    stem: []const u8,
    size: u64,
    mkind: kind.MediaKind,
    ep: ?tv.Episode = null,
    mv: ?movie.Movie = null,
    track: ?music.Track = null,
    probe: ?probe.Probe = null,
    warnings: []const []const u8 = &.{},
    group_idx: usize = 0,
    role: plan.Role = .primary,
    dst: ?[]const u8 = null,
    primary_dst: ?[]const u8 = null,
    fields: ?plan.Fields = null,
    album_dir: ?[]const u8 = null,
    disc: ?u32 = null,
};

const Sidecar = struct {
    abs: []const u8,
    dir: []const u8,
    stem: []const u8,
    ext: []const u8,
};

const Cover = struct { abs: []const u8, dir: []const u8, ext: []const u8 };

fn isCoverImage(base: []const u8) bool {
    const ext = std.fs.path.extension(base);
    const is_img = std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg") or std.ascii.eqlIgnoreCase(ext, ".png");
    if (!is_img) return false;
    const stem = base[0 .. base.len - ext.len];
    const names = [_][]const u8{ "cover", "folder", "front", "albumart", "album" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(stem, n)) return true;
    return false;
}

fn musicAlbum(c: *Cand) []const u8 {
    return c.track.?.album orelse "Unknown Album";
}

/// True if any track carries a usable (non-empty, non-mojibake) album tag —
/// i.e. the album name is tag-authoritative rather than folder-derived.
fn hadUsableAlbumTag(cands: []const *Cand) bool {
    for (cands) |c| if (c.track.?.album) |al| {
        if (al.len > 0 and std.mem.indexOf(u8, al, "\u{FFFD}") == null) return true;
    };
    return false;
}
fn audioScoreOf(c: *Cand) f32 {
    const ext = c.track.?.ext;
    const lossless = std.ascii.eqlIgnoreCase(ext, "flac") or std.ascii.eqlIgnoreCase(ext, "alac");
    return mediascore.audioScore(lossless, null, c.size);
}

const GB = struct {
    kind: kind.MediaKind,
    title: []const u8,
    year: ?u32,
    items: std.ArrayList(plan.Item),
    warnings: std.ArrayList([]const u8),
};

/// Best-copy score for a candidate: probe-aware when a readable probe
/// exists, else the filename-quality heuristic.
fn candScore(c: *Cand) f32 {
    if (c.probe) |pr| {
        if (pr.readable) return mediascore.videoScoreProbed(pr.height, pr.bitrate, c.size);
    }
    const q = if (c.mkind == .tv) c.ep.?.quality else c.mv.?.quality;
    return mediascore.videoScore(q, c.size);
}

/// MediaInfo for the plan, from a readable probe.
fn mediaOf(c: *Cand) ?plan.MediaInfo {
    const pr = c.probe orelse return null;
    if (!pr.readable) return null;
    return .{ .codec = pr.vcodec, .width = pr.width, .height = pr.height, .duration_s = pr.duration_s };
}

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

/// Length of the shared leading run of `a` and `b` (for sidecar matching).
fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return i;
}

/// Album root for a music destination: the file's parent, or its grandparent
/// when the parent is a "CD N"/"Disc N" folder (so covers land at album root).
fn albumRootOf(p: []const u8) []const u8 {
    const dir = std.fs.path.dirname(p) orelse p;
    const b = std.fs.path.basename(dir);
    if (music.discFromDirName(b) != null) return std.fs.path.dirname(dir) orelse dir;
    return dir;
}

pub fn buildPlan(
    arena: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    cfg: config.Config,
    probe_enabled: bool,
    online: Online,
) !plan.Plan {
    var media: std.ArrayList(*Cand) = .empty;
    var sidecars: std.ArrayList(Sidecar) = .empty;
    var covers: std.ArrayList(Cover) = .empty;
    var junk: std.ArrayList([]const u8) = .empty;
    var unclassified: std.ArrayList([]const u8) = .empty;

    // `--no-probe` (probe_enabled=false) skips all file inspection. DRM
    // detection runs whenever we inspect; ffprobe availability gates only
    // the ffprobe call.
    const inspect = probe_enabled;
    const ffprobe_ok = probe_enabled and probe.available(arena, io);

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

        if (isCoverImage(base)) {
            const ext = try arena.dupe(u8, if (ext_dot.len > 0) ext_dot[1..] else ext_dot);
            try covers.append(arena, .{ .abs = abs, .dir = d, .ext = ext });
            continue;
        }

        const mk = classify_mod.classify(base, false);
        if (mk == .music) {
            const c = try arena.create(Cand);
            c.* = .{ .abs = abs, .dir = d, .stem = stem, .size = statSize(io, abs), .mkind = .music };
            c.track = if (inspect) try music.parse(arena, io, abs) else try music.fromTags(arena, .{}, base);
            const parent_base = std.fs.path.basename(d);
            const sub_disc = music.discFromDirName(parent_base);
            c.disc = c.track.?.disc orelse sub_disc;
            // A "CD N"/"Disc N" subfolder rolls up to its parent album dir.
            c.album_dir = if (sub_disc != null) (std.fs.path.dirname(d) orelse d) else d;
            try media.append(arena, c);
        } else if (mk == .tv or mk == .movie) {
            const c = try arena.create(Cand);
            c.* = .{ .abs = abs, .dir = d, .stem = stem, .size = statSize(io, abs), .mkind = mk };
            if (mk == .tv) c.ep = try tv.parse(arena, base);
            if (mk == .movie) c.mv = try movie.parse(arena, base);
            // A .tv classification with no parseable marker is unexpected; drop to unclassified.
            if (mk == .tv and c.ep == null) {
                try unclassified.append(arena, abs);
            } else {
                if (inspect) {
                    const scheme = drm.detectVideo(arena, abs);
                    if (scheme != .none) {
                        // Organized by its filename fields, flagged, not probed.
                        const wl = try arena.alloc([]const u8, 1);
                        wl[0] = try std.fmt.allocPrint(arena, "DRM — {s}", .{drm.label(scheme)});
                        c.warnings = wl;
                    } else if (ffprobe_ok) {
                        c.probe = probe.run(arena, io, abs);
                        if (mk == .tv) {
                            const m = try enrich.mergeTv(arena, c.ep.?, c.probe);
                            c.ep = .{ .series = m.fields.series, .season = m.fields.season, .episode = m.fields.episode, .title = m.fields.title, .quality = m.fields.quality, .ext = c.ep.?.ext };
                            c.warnings = m.warnings;
                        } else {
                            const m = try enrich.mergeMovie(arena, c.mv.?, c.probe);
                            c.mv = .{ .title = m.fields.title, .year = m.fields.year, .quality = m.fields.quality, .ext = c.mv.?.ext };
                            c.warnings = m.warnings;
                        }
                    }
                }
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
        const key = switch (c.mkind) {
            .tv => try std.fmt.allocPrint(arena, "tv|{s}|{d}", .{ try lower(arena, c.ep.?.series), c.ep.?.season }),
            .movie => try std.fmt.allocPrint(arena, "mv|{s}|{?d}", .{ try lower(arena, c.mv.?.title), c.mv.?.year }),
            .music => try std.fmt.allocPrint(arena, "mu|{s}", .{c.album_dir.?}),
            else => unreachable,
        };

        const gop = try key_to_gb.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = gbs.items.len;
            const gtitle = switch (c.mkind) {
                .tv => c.ep.?.series,
                .movie => c.mv.?.title,
                .music => musicAlbum(c),
                else => "",
            };
            const gyear = switch (c.mkind) {
                .movie => c.mv.?.year,
                .music => c.track.?.year,
                else => null,
            };
            try gbs.append(arena, .{
                .kind = c.mkind,
                .title = gtitle,
                .year = gyear,
                .items = .empty,
                .warnings = .empty,
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
                if (!gop.found_existing or candScore(c) > candScore(gop.value_ptr.*)) {
                    gop.value_ptr.* = c;
                }
            }
            // Compute each primary's fields + dst.
            var it = best.valueIterator();
            while (it.next()) |cp| {
                const f = plan.Fields{ .series = gb.title, .season = cp.*.ep.?.season, .episode = cp.*.ep.?.episode, .title = cp.*.ep.?.title, .ext = cp.*.ep.?.ext };
                cp.*.fields = f;
                cp.*.dst = try naming.dstFor(arena, cfg, .tv, f);
            }
            // TMDB enrichment (opt-in): canonical series name/year + ids +
            // per-episode titles; recompute dst. Offline plan untouched on miss.
            if (online.video) |venr| {
                if (venr.lookupSeries(arena, gb.title, null) catch null) |s| {
                    var it2 = best.valueIterator();
                    while (it2.next()) |cp| {
                        const et = venr.episodeTitle(arena, s.tmdb_id, cp.*.ep.?.season, cp.*.ep.?.episode) catch null;
                        const m = try enrich.mergeTvOnline(arena, cp.*.fields.?, s, et);
                        cp.*.fields = m.fields;
                        cp.*.dst = try naming.dstFor(arena, cfg, .tv, m.fields);
                        for (m.warnings) |w| try gb.warnings.append(arena, w);
                    }
                    if (s.name.len > 0) gb.title = s.name;
                    if (s.year != null) gb.year = s.year;
                    try gb.warnings.append(arena, try std.fmt.allocPrint(arena, "TMDB: matched \"{s}\"", .{s.name}));
                } else try gb.warnings.append(arena, "TMDB: no confident match");
            }
            // Assign roles + emit items. Every candidate carries its
            // episode's primary fields so a sidecar matching a duplicate
            // still resolves to the primary's destination.
            for (cands.items) |c| {
                for (c.warnings) |w| try gb.warnings.append(arena, w);
                const winner = best.get(c.ep.?.episode).?;
                c.primary_dst = winner.dst;
                c.fields = winner.fields;
                if (c == winner) {
                    c.role = .primary;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .primary, .op = .move, .dst = winner.dst, .reason = "", .media = mediaOf(c), .fields = winner.fields });
                } else {
                    c.role = .duplicate;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .duplicate, .op = .skip, .dst = null, .reason = "duplicate of primary" });
                }
            }
        } else if (gb.kind == .movie) {
            // Movie: all copies represent one work; pick the single best.
            var winner = cands.items[0];
            for (cands.items[1..]) |c| {
                if (candScore(c) > candScore(winner)) winner = c;
            }
            const f = plan.Fields{ .title = winner.mv.?.title, .year = winner.mv.?.year, .ext = winner.mv.?.ext };
            winner.fields = f;
            winner.dst = try naming.dstFor(arena, cfg, .movie, f);
            // TMDB enrichment (opt-in): canonical title/year + ids + language;
            // recompute dst. Offline plan untouched on miss.
            if (online.video) |venr| {
                if (venr.lookupMovie(arena, winner.mv.?.title, winner.mv.?.year) catch null) |info| {
                    const m = try enrich.mergeMovieOnline(arena, winner.fields.?, info);
                    winner.fields = m.fields;
                    winner.dst = try naming.dstFor(arena, cfg, .movie, m.fields);
                    for (m.warnings) |w| try gb.warnings.append(arena, w);
                    if (info.title.len > 0) gb.title = info.title;
                    if (info.year != null) gb.year = info.year;
                    try gb.warnings.append(arena, try std.fmt.allocPrint(arena, "TMDB: matched \"{s}\"", .{info.title}));
                } else try gb.warnings.append(arena, "TMDB: no confident match");
            }
            for (cands.items) |c| {
                for (c.warnings) |w| try gb.warnings.append(arena, w);
                c.primary_dst = winner.dst;
                c.fields = winner.fields;
                if (c == winner) {
                    try gb.items.append(arena, .{ .src = c.abs, .role = .primary, .op = .move, .dst = winner.dst, .reason = "", .media = mediaOf(winner), .fields = winner.fields });
                } else {
                    try gb.items.append(arena, .{ .src = c.abs, .role = .duplicate, .op = .skip, .dst = null, .reason = "duplicate of primary" });
                }
            }
        } else {
            // Music: one album per source folder. Consensus album/artist/year
            // (Various-Artists fallback); dedup by (disc, track#, title).
            var tracks = try arena.alloc(music.Track, cands.items.len);
            for (cands.items, 0..) |c, i| tracks[i] = c.track.?;
            const folder_name = std.fs.path.basename(cands.items[0].album_dir.?);
            const meta = try music.albumMeta(arena, tracks, folder_name);

            var distinct = std.AutoHashMap(u32, void).init(arena);
            for (cands.items) |c| if (c.disc) |dn| try distinct.put(dn, {});
            const multi = distinct.count() > 1;

            gb.title = meta.album;
            gb.year = meta.year;

            var best = std.StringHashMap(*Cand).init(arena);
            for (cands.items) |c| {
                const dkey: u32 = if (multi) (c.disc orelse 1) else 0;
                const tk = try std.fmt.allocPrint(arena, "{d}|{?d}|{s}", .{ dkey, c.track.?.track, try lower(arena, c.track.?.title orelse "") });
                const gop = try best.getOrPut(tk);
                if (!gop.found_existing or audioScoreOf(c) > audioScoreOf(gop.value_ptr.*)) gop.value_ptr.* = c;
            }
            var it = best.valueIterator();
            while (it.next()) |cp| {
                const f = plan.Fields{
                    .album_artist = meta.album_artist,
                    .album = meta.album,
                    .year = meta.year,
                    .track = cp.*.track.?.track,
                    .title = cp.*.track.?.title,
                    .artists = cp.*.track.?.artists,
                    .ext = cp.*.track.?.ext,
                    .disc = if (multi) (cp.*.disc orelse 1) else null,
                };
                cp.*.fields = f;
                cp.*.dst = try naming.dstFor(arena, cfg, .music, f);
            }

            // MusicBrainz enrichment (opt-in). Corrects the winners' fields in
            // place and recomputes dst; the offline plan is untouched when the
            // enricher is null or returns no confident match.
            if (online.music) |enr| {
                const album_from_folder = !hadUsableAlbumTag(cands.items);
                const rel = enr.lookupAlbum(arena, meta.album, meta.album_artist, best.count(), meta.year) catch null;
                if (rel) |release| {
                    var wit = best.valueIterator();
                    while (wit.next()) |cp| {
                        const pos = cp.*.track.?.track orelse 0;
                        const merged = try enrich.mergeMusic(arena, cp.*.fields.?, pos, release, album_from_folder);
                        cp.*.fields = merged.fields;
                        cp.*.dst = try naming.dstFor(arena, cfg, .music, merged.fields);
                        for (merged.warnings) |w| try gb.warnings.append(arena, w);
                    }
                    if (release.title.len > 0) gb.title = release.title;
                    if (release.year != null) gb.year = release.year;
                    try gb.warnings.append(arena, try std.fmt.allocPrint(arena, "MusicBrainz: matched \"{s}\"", .{release.title}));
                } else {
                    try gb.warnings.append(arena, "MusicBrainz: no confident match");
                }
            }

            if (std.mem.eql(u8, meta.album, "Unknown Album")) try gb.warnings.append(arena, "untagged — filed under Unknown Album");
            for (cands.items) |c| {
                const dkey: u32 = if (multi) (c.disc orelse 1) else 0;
                const tk = try std.fmt.allocPrint(arena, "{d}|{?d}|{s}", .{ dkey, c.track.?.track, try lower(arena, c.track.?.title orelse "") });
                const winner = best.get(tk).?;
                c.primary_dst = winner.dst;
                c.fields = winner.fields;
                if (c == winner) {
                    c.role = .primary;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .primary, .op = .move, .dst = winner.dst, .reason = "", .fields = winner.fields });
                } else {
                    c.role = .duplicate;
                    try gb.items.append(arena, .{ .src = c.abs, .role = .duplicate, .op = .skip, .dst = null, .reason = "duplicate track" });
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
            if (c.fields) |pf| {
                var f = pf;
                f.ext = sc.ext; // sidecar sits beside the primary, own extension
                const gk = gbs.items[c.group_idx].kind;
                const dst = try naming.dstFor(arena, cfg, gk, f);
                try gbs.items[c.group_idx].items.append(arena, .{ .src = sc.abs, .role = .sidecar, .op = .move, .dst = dst, .reason = "sidecar", .fields = f });
                continue;
            }
        }
        try unclassified.append(arena, sc.abs);
    }

    // ---- Phase C2: attach album covers --------------------------------
    for (covers.items) |cov| {
        var attached = false;
        for (media.items) |c| {
            if (c.mkind != .music) continue;
            const same_dir = std.mem.eql(u8, c.dir, cov.dir) or
                (c.album_dir != null and std.mem.eql(u8, c.album_dir.?, cov.dir));
            if (!same_dir) continue;
            if (c.primary_dst) |pd| {
                const album_root = albumRootOf(pd);
                const dst = try std.fmt.allocPrint(arena, "{s}/cover.{s}", .{ album_root, cov.ext });
                try gbs.items[c.group_idx].items.append(arena, .{ .src = cov.abs, .role = .sidecar, .op = .move, .dst = dst, .reason = "cover" });
                attached = true;
            }
            break;
        }
        if (!attached) try unclassified.append(arena, cov.abs);
    }

    // ---- Phase D: junk ------------------------------------------------
    if (junk.items.len > 0) {
        var jitems: std.ArrayList(plan.Item) = .empty;
        for (junk.items) |j| {
            try jitems.append(arena, .{ .src = j, .role = .junk, .op = .trash, .dst = null, .reason = "junk" });
        }
        try gbs.append(arena, .{ .kind = .unknown, .title = "junk", .year = null, .items = jitems, .warnings = .empty });
    }

    // ---- Phase E: finalize --------------------------------------------
    var groups: std.ArrayList(plan.Group) = .empty;
    for (gbs.items) |*gb| {
        try groups.append(arena, .{
            .kind = gb.kind,
            .title = gb.title,
            .year = gb.year,
            .items = try gb.items.toOwnedSlice(arena),
            .warnings = try gb.warnings.toOwnedSlice(arena),
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

fn writeDrmMp4(path_z: [:0]const u8) void {
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    var box: [16]u8 = undefined;
    std.mem.writeInt(u32, box[0..4], 16, .big);
    @memcpy(box[4..8], "ftyp");
    @memcpy(box[8..12], "isom");
    std.mem.writeInt(u32, box[12..16], 0, .big);
    _ = std.c.fwrite(&box, 1, 16, fp);
    const payload = "trak....pssh....";
    var mh: [8]u8 = undefined;
    std.mem.writeInt(u32, mh[0..4], @intCast(8 + payload.len), .big);
    @memcpy(mh[4..8], "moov");
    _ = std.c.fwrite(&mh, 1, 8, fp);
    _ = std.c.fwrite(payload.ptr, 1, payload.len, fp);
}

test "buildPlan groups music into an album and attaches cover (no-probe)" {
    // Deterministic: probe_enabled=false → no ffprobe, filename-only tags.
    // The tag-driven path is covered end-to-end by scripts/music-smoke.sh.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pid = std.c.getpid();
    var rb: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/stacks-music-{d}", .{pid});
    mkdirAt("{s}", .{root});
    try writeFileAt("{s}/track a.mp3", .{root}, "aaa");
    try writeFileAt("{s}/track b.flac", .{root}, "bbbb");
    try writeFileAt("{s}/cover.jpg", .{root}, "jpeg");

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const p = try buildPlan(a, threaded.io(), root, cfg, false, .{}); // no probe

    var music_groups: usize = 0;
    var primaries: usize = 0;
    var covers: usize = 0;
    for (p.groups) |g| {
        if (g.kind == .music) music_groups += 1;
        for (g.items) |it| {
            if (it.role == .primary) primaries += 1;
            if (it.role == .sidecar and std.mem.endsWith(u8, it.dst orelse "", "cover.jpg")) covers += 1;
        }
    }
    try t.expectEqual(@as(usize, 1), music_groups); // one Unknown Album
    try t.expectEqual(@as(usize, 2), primaries); // the two tracks
    try t.expectEqual(@as(usize, 1), covers); // cover attached to the album

    unlinkAt("{s}/track a.mp3", .{root});
    unlinkAt("{s}/track b.flac", .{root});
    unlinkAt("{s}/cover.jpg", .{root});
    rmdirAt("{s}", .{root});
}

test "buildPlan rolls CD subfolders into one multi-disc album (no-probe)" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pid = std.c.getpid();
    var rb: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/stacks-disc-{d}", .{pid});
    mkdirAt("{s}", .{root});
    mkdirAt("{s}/CD 1", .{root});
    mkdirAt("{s}/CD 2", .{root});
    try writeFileAt("{s}/CD 1/01 song one.mp3", .{root}, "aaa");
    try writeFileAt("{s}/CD 2/01 song two.mp3", .{root}, "bbbb");

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const p = try buildPlan(a, threaded.io(), root, cfg, false, .{}); // no probe: disc comes from folder names

    var music_groups: usize = 0;
    var primaries: usize = 0;
    var cd1 = false;
    var cd2 = false;
    for (p.groups) |g| {
        if (g.kind != .music) continue;
        music_groups += 1;
        for (g.items) |it| {
            if (it.role != .primary) continue;
            primaries += 1;
            const dst = it.dst orelse "";
            if (std.mem.indexOf(u8, dst, "/CD1/") != null) cd1 = true;
            if (std.mem.indexOf(u8, dst, "/CD2/") != null) cd2 = true;
        }
    }
    try t.expectEqual(@as(usize, 1), music_groups); // both discs → one album
    try t.expectEqual(@as(usize, 2), primaries);
    try t.expect(cd1);
    try t.expect(cd2);

    unlinkAt("{s}/CD 1/01 song one.mp3", .{root});
    unlinkAt("{s}/CD 2/01 song two.mp3", .{root});
    rmdirAt("{s}/CD 1", .{root});
    rmdirAt("{s}/CD 2", .{root});
    rmdirAt("{s}", .{root});
}

test "buildPlan flags a DRM video and skips probing" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pid = std.c.getpid();
    var rb: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/stacks-drm-{d}", .{pid});
    mkdirAt("{s}", .{root});

    var fb: [400]u8 = undefined;
    const fpath = try std.fmt.bufPrintZ(&fb, "{s}/The.Show.S01E01.mp4", .{root});
    writeDrmMp4(fpath);

    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const cfg = config.Config{ .library_root = "/lib", .tv_template = config.DEFAULT_TV, .movie_template = config.DEFAULT_MOVIE, .music_template = config.DEFAULT_MUSIC };
    const p = try buildPlan(a, threaded.io(), root, cfg, true, .{}); // probe_enabled

    var warned = false;
    var media_present = false;
    for (p.groups) |g| {
        for (g.warnings) |w| if (std.mem.indexOf(u8, w, "DRM") != null) {
            warned = true;
        };
        for (g.items) |it| if (it.media != null) {
            media_present = true;
        };
    }
    try t.expect(warned);
    try t.expect(!media_present); // DRM file wasn't probed

    unlinkAt("{s}/The.Show.S01E01.mp4", .{root});
    rmdirAt("{s}", .{root});
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
        .music_template = config.DEFAULT_MUSIC,
    };
    const p = try buildPlan(a, io, root, cfg, false, .{}); // probe off: deterministic, no ffprobe dep

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
                .extra => {},
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
