//! Lossless container remux planning — build an `ffmpeg -c copy` command that
//! repackages a video into a clean `.mkv`, dropping audio/subtitle tracks
//! outside a keep-languages policy and muxing in external subtitle sidecars.
//! The argv builder is pure (no I/O) so it's unit-tested; commands/remux.zig
//! wraps it with ffprobe, sidecar discovery, and reversible apply.

const std = @import("std");
const probe = @import("probe.zig");
const subtitles = @import("subtitles.zig");

pub const ExtSub = struct {
    path: []const u8,
    lang: ?[]const u8 = null, // 2-letter, from the sidecar filename
    forced: bool = false,
};

pub const Args = struct {
    argv: []const []const u8,
    dropped_audio: usize = 0,
    dropped_subs: usize = 0,
    embedded_subs: usize = 0,
    kept_audio: usize = 0,
    kept_subs: usize = 0,
};

/// Keep a track when the policy is empty (keep everything), the track has no
/// language (never silently drop an untagged track), or its language matches.
fn keepLang(keep: []const []const u8, lang: ?[]const u8) bool {
    if (keep.len == 0) return true;
    const l = lang orelse return true;
    const code = subtitles.toCode(l) orelse l; // normalize eng→en, else raw
    for (keep) |k| {
        const kc = subtitles.toCode(k) orelse k;
        if (std.ascii.eqlIgnoreCase(code, kc)) return true;
    }
    return false;
}

/// Build the ffmpeg argv that remuxes `input` → `dst` (`-c copy`). `keep` is a
/// list of language tokens to retain (empty = keep all). `ext_subs` are muxed
/// in as subtitle tracks (input indices 1..N), each language-tagged.
pub fn buildArgs(arena: std.mem.Allocator, input: []const u8, dst: []const u8, pr: probe.Probe, ext_subs: []const ExtSub, keep: []const []const u8) !Args {
    var a: std.ArrayList([]const u8) = .empty;
    var r = Args{ .argv = &.{} };
    try a.appendSlice(arena, &.{ "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", input });
    for (ext_subs) |s| try a.appendSlice(arena, &.{ "-i", s.path });

    try a.appendSlice(arena, &.{ "-map", "0:v" });
    for (pr.audio, 0..) |tr, i| {
        if (keepLang(keep, tr.lang)) {
            try a.appendSlice(arena, &.{ "-map", try std.fmt.allocPrint(arena, "0:a:{d}", .{i}) });
            r.kept_audio += 1;
        } else r.dropped_audio += 1;
    }
    // internal subtitle streams first, so external ones number after them
    var out_s: usize = 0;
    for (pr.subs, 0..) |tr, i| {
        if (keepLang(keep, tr.lang)) {
            try a.appendSlice(arena, &.{ "-map", try std.fmt.allocPrint(arena, "0:s:{d}", .{i}) });
            r.kept_subs += 1;
            out_s += 1;
        } else r.dropped_subs += 1;
    }
    for (ext_subs, 0..) |s, i| {
        try a.appendSlice(arena, &.{ "-map", try std.fmt.allocPrint(arena, "{d}:0", .{i + 1}) });
        if (s.lang) |l| try a.appendSlice(arena, &.{
            try std.fmt.allocPrint(arena, "-metadata:s:s:{d}", .{out_s}),
            try std.fmt.allocPrint(arena, "language={s}", .{l}),
        });
        if (s.forced) try a.appendSlice(arena, &.{
            try std.fmt.allocPrint(arena, "-disposition:s:{d}", .{out_s}),
            "forced",
        });
        out_s += 1;
        r.embedded_subs += 1;
    }
    try a.appendSlice(arena, &.{ "-c", "copy", dst });
    r.argv = try a.toOwnedSlice(arena);
    return r;
}

/// A remux is a no-op when the input is already `.mkv` and nothing is dropped
/// or added — the caller skips it.
pub fn isNoOp(input: []const u8, r: Args) bool {
    return std.ascii.endsWithIgnoreCase(input, ".mkv") and
        r.dropped_audio == 0 and r.dropped_subs == 0 and r.embedded_subs == 0;
}

const t = std.testing;

test "buildArgs keeps policy languages, drops the rest, embeds external subs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pr = probe.Probe{
        .audio = &.{ .{ .kind = .audio, .lang = "eng" }, .{ .kind = .audio, .lang = "jpn" } },
        .subs = &.{.{ .kind = .subtitle, .lang = "fre" }},
    };
    const ext = [_]ExtSub{.{ .path = "/x/Movie.en.srt", .lang = "en", .forced = false }};
    const r = try buildArgs(a, "/x/Movie.mp4", "/x/.Movie.tmp.mkv", pr, &ext, &.{"en"});

    try t.expectEqual(@as(usize, 1), r.kept_audio); // eng kept
    try t.expectEqual(@as(usize, 1), r.dropped_audio); // jpn dropped
    try t.expectEqual(@as(usize, 0), r.kept_subs); // fre internal sub dropped
    try t.expectEqual(@as(usize, 1), r.dropped_subs);
    try t.expectEqual(@as(usize, 1), r.embedded_subs);
    // argv contains the eng audio map + the external sub input + copy + dst
    const joined = try std.mem.join(a, " ", r.argv);
    try t.expect(std.mem.indexOf(u8, joined, "0:a:0") != null);
    try t.expect(std.mem.indexOf(u8, joined, "0:a:1") == null); // jpn not mapped
    try t.expect(std.mem.indexOf(u8, joined, "-i /x/Movie.en.srt") != null);
    try t.expect(std.mem.indexOf(u8, joined, "language=en") != null);
    try t.expect(std.mem.endsWith(u8, joined, "-c copy /x/.Movie.tmp.mkv"));
}

test "empty keep list retains all tracks; isNoOp for an unchanged mkv" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pr = probe.Probe{ .audio = &.{ .{ .kind = .audio, .lang = "eng" }, .{ .kind = .audio, .lang = "jpn" } } };
    const r = try buildArgs(a, "/x/M.mkv", "/x/.t.mkv", pr, &.{}, &.{});
    try t.expectEqual(@as(usize, 2), r.kept_audio);
    try t.expectEqual(@as(usize, 0), r.dropped_audio);
    try t.expect(isNoOp("/x/M.mkv", r)); // already mkv, nothing changed
    try t.expect(!isNoOp("/x/M.mp4", r)); // mp4 → mkv is a real change
}
