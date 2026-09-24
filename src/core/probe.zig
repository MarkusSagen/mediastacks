//! Read-only media inspection via `ffprobe`.
//!
//! `parse` is pure (ffprobe JSON → `Probe`) so it's tested against captured
//! fixtures without spawning anything. `run`/`available` (Task 3) wrap the
//! actual process. Everything here is read-only — we never touch the media.

const std = @import("std");
const exec = @import("../util/exec.zig");

pub const Confidence = enum { none, generic, authoritative };

/// Library metadata embedded in the container (iTunes atoms, Matroska tags).
pub const Embedded = struct {
    series: ?[]const u8 = null,
    season: ?u32 = null,
    episode: ?u32 = null,
    title: ?[]const u8 = null,
    confidence: Confidence = .none,
};

pub const TrackKind = enum { audio, subtitle };

/// One audio or subtitle stream, for language-aware display + (later) remux.
pub const Track = struct {
    kind: TrackKind,
    codec: ?[]const u8 = null,
    lang: ?[]const u8 = null, // ffprobe tags.language (usually ISO 639-2, e.g. "eng")
    title: ?[]const u8 = null,
    default: bool = false,
    forced: bool = false,
};

pub const Probe = struct {
    readable: bool = true,
    vcodec: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    duration_s: ?f64 = null,
    bitrate: ?u64 = null,
    embedded: Embedded = .{},
    audio: []const Track = &.{},
    subs: []const Track = &.{},
};

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn asU32(v: ?std.json.Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u32, s, 10) catch null,
        else => null,
    };
}

fn asU64Str(v: ?std.json.Value) ?u64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn asF64(v: ?std.json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn dupStr(alloc: std.mem.Allocator, v: ?std.json.Value) !?[]const u8 {
    const x = v orelse return null;
    if (x != .string) return null;
    return try alloc.dupe(u8, x.string);
}

fn strTag(tags: std.json.Value, key: []const u8) ?[]const u8 {
    const v = objGet(tags, key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn parseTrack(alloc: std.mem.Allocator, s: std.json.Value, kind: TrackKind) !Track {
    var tr = Track{ .kind = kind };
    tr.codec = try dupStr(alloc, objGet(s, "codec_name"));
    if (objGet(s, "tags")) |tags| {
        if (strTag(tags, "language")) |l| tr.lang = try alloc.dupe(u8, l);
        if (strTag(tags, "title")) |ti| tr.title = try alloc.dupe(u8, ti);
    }
    if (objGet(s, "disposition")) |disp| {
        tr.default = (asU32(objGet(disp, "default")) orelse 0) != 0;
        tr.forced = (asU32(objGet(disp, "forced")) orelse 0) != 0;
    }
    return tr;
}

/// Parse ffprobe `-print_format json` output. Strings owned by `alloc`.
/// Empty or invalid input yields `Probe{ .readable = false }` — never an error.
pub fn parse(alloc: std.mem.Allocator, json_bytes: []const u8) !Probe {
    if (json_bytes.len == 0) return .{ .readable = false };

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json_bytes, .{}) catch
        return .{ .readable = false };

    var p: Probe = .{};

    if (objGet(root, "streams")) |streams| {
        if (streams == .array) {
            var audio: std.ArrayList(Track) = .empty;
            var subs: std.ArrayList(Track) = .empty;
            var have_video = false;
            for (streams.array.items) |s| {
                const ct = objGet(s, "codec_type") orelse continue;
                if (ct != .string) continue;
                if (!have_video and std.mem.eql(u8, ct.string, "video")) {
                    p.vcodec = try dupStr(alloc, objGet(s, "codec_name"));
                    p.width = asU32(objGet(s, "width"));
                    p.height = asU32(objGet(s, "height"));
                    have_video = true;
                } else if (std.mem.eql(u8, ct.string, "audio")) {
                    try audio.append(alloc, try parseTrack(alloc, s, .audio));
                } else if (std.mem.eql(u8, ct.string, "subtitle")) {
                    try subs.append(alloc, try parseTrack(alloc, s, .subtitle));
                }
            }
            p.audio = try audio.toOwnedSlice(alloc);
            p.subs = try subs.toOwnedSlice(alloc);
        }
    }

    if (objGet(root, "format")) |fmt| {
        p.duration_s = asF64(objGet(fmt, "duration"));
        p.bitrate = asU64Str(objGet(fmt, "bit_rate"));

        if (objGet(fmt, "tags")) |tags| {
            const show = strTag(tags, "show");
            const snum = asU32(objGet(tags, "season_number"));
            const enum_ = asU32(objGet(tags, "episode_sort")) orelse asU32(objGet(tags, "episode_id"));
            if (show != null and snum != null and enum_ != null) {
                // iTunes-style structured tags: authoritative TV identity.
                p.embedded = .{
                    .series = try alloc.dupe(u8, show.?),
                    .season = snum,
                    .episode = enum_,
                    .title = try dupStr(alloc, objGet(tags, "title")),
                    .confidence = .authoritative,
                };
            } else if (strTag(tags, "title") orelse strTag(tags, "TITLE")) |ti| {
                // A lone free-form title — only good enough to fill a gap.
                p.embedded = .{ .title = try alloc.dupe(u8, ti), .confidence = .generic };
            }
        }
    }

    // No video, no format, no dimensions → effectively unreadable.
    if (p.vcodec == null and p.duration_s == null and p.width == null) p.readable = false;
    return p;
}

fn freeTrack(alloc: std.mem.Allocator, tr: Track) void {
    if (tr.codec) |x| alloc.free(x);
    if (tr.lang) |x| alloc.free(x);
    if (tr.title) |x| alloc.free(x);
}

pub fn freeProbe(alloc: std.mem.Allocator, p: Probe) void {
    if (p.vcodec) |x| alloc.free(x);
    if (p.embedded.series) |x| alloc.free(x);
    if (p.embedded.title) |x| alloc.free(x);
    for (p.audio) |tr| freeTrack(alloc, tr);
    for (p.subs) |tr| freeTrack(alloc, tr);
    if (p.audio.len > 0) alloc.free(p.audio);
    if (p.subs.len > 0) alloc.free(p.subs);
}

/// True iff `ffprobe` is on PATH.
pub fn available(alloc: std.mem.Allocator, io: std.Io) bool {
    return exec.isExecutableInPath(alloc, io, "ffprobe");
}

/// Spawn ffprobe on `path`. Returns null when ffprobe is missing or the
/// spawn fails; `.readable = false` when ffprobe ran but couldn't decode.
/// Strings owned by `alloc`.
pub fn run(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?Probe {
    const argv = [_][]const u8{
        "ffprobe", "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", path,
    };
    const r = exec.runCaptureStdout(alloc, io, &argv, 8 * 1024 * 1024) catch return null;
    defer alloc.free(r.stdout);
    if (r.exit_code != 0 or r.stdout.len == 0) return Probe{ .readable = false };
    return parse(alloc, r.stdout) catch Probe{ .readable = false };
}

const t = std.testing;

const SCENE_MKV_JSON =
    \\{"streams":[
    \\  {"codec_type":"video","codec_name":"h264","width":1920,"height":1080},
    \\  {"codec_type":"audio","codec_name":"aac","channels":2,"tags":{"language":"jpn"}}
    \\],
    \\"format":{"duration":"1420.087000","size":"1526000000","bit_rate":"8200000","tags":{"title":"witch.hat.atelier.s01e12.mkv"}}}
;

test "parse extracts technical facts from scene mkv" {
    const a = t.allocator;
    const p = try parse(a, SCENE_MKV_JSON);
    defer freeProbe(a, p);
    try t.expect(p.readable);
    try t.expectEqualStrings("h264", p.vcodec.?);
    try t.expectEqual(@as(u32, 1920), p.width.?);
    try t.expectEqual(@as(u32, 1080), p.height.?);
    try t.expectEqual(@as(u64, 8_200_000), p.bitrate.?);
    try t.expect(p.duration_s.? > 1419 and p.duration_s.? < 1421);
}

const ITUNES_MP4_JSON =
    \\{"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080}],
    \\"format":{"duration":"1400.0","bit_rate":"5000000","tags":{
    \\  "media_type":"10","show":"Severance","season_number":"2","episode_sort":"5","title":"Goodbye, Mrs. Selvig"}}}
;

test "parse captures audio + subtitle tracks with languages + flags" {
    const a = t.allocator;
    const json =
        \\{"streams":[
        \\{"codec_type":"video","codec_name":"h264","width":1920,"height":1080},
        \\{"codec_type":"audio","codec_name":"eac3","tags":{"language":"eng","title":"Surround"},"disposition":{"default":1,"forced":0}},
        \\{"codec_type":"audio","codec_name":"aac","tags":{"language":"jpn"},"disposition":{"default":0,"forced":0}},
        \\{"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"eng"},"disposition":{"default":0,"forced":1}}
        \\],"format":{"duration":"120.0"}}
    ;
    const p = try parse(a, json);
    defer freeProbe(a, p);
    try t.expect(p.readable);
    try t.expectEqual(@as(usize, 2), p.audio.len);
    try t.expectEqualStrings("eng", p.audio[0].lang.?);
    try t.expectEqualStrings("Surround", p.audio[0].title.?);
    try t.expect(p.audio[0].default);
    try t.expectEqualStrings("jpn", p.audio[1].lang.?);
    try t.expectEqual(@as(usize, 1), p.subs.len);
    try t.expectEqualStrings("eng", p.subs[0].lang.?);
    try t.expect(p.subs[0].forced);
}

test "parse classifies iTunes tags as authoritative" {
    const a = t.allocator;
    const p = try parse(a, ITUNES_MP4_JSON);
    defer freeProbe(a, p);
    try t.expectEqual(Confidence.authoritative, p.embedded.confidence);
    try t.expectEqualStrings("Severance", p.embedded.series.?);
    try t.expectEqual(@as(u32, 2), p.embedded.season.?);
    try t.expectEqual(@as(u32, 5), p.embedded.episode.?);
    try t.expectEqualStrings("Goodbye, Mrs. Selvig", p.embedded.title.?);
}

test "parse classifies a lone title tag as generic" {
    const a = t.allocator;
    const p = try parse(a, SCENE_MKV_JSON); // has only format.tags.title
    defer freeProbe(a, p);
    try t.expectEqual(Confidence.generic, p.embedded.confidence);
    try t.expect(p.embedded.series == null);
}

test "available() runs without crashing" {
    const a = t.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    _ = available(a, threaded.io()); // consistent with `which ffprobe`; must not crash
}

test "parse of empty/garbage json is unreadable, not a crash" {
    const a = t.allocator;
    const p1 = try parse(a, "");
    defer freeProbe(a, p1);
    try t.expect(!p1.readable);
    const p2 = try parse(a, "not json at all");
    defer freeProbe(a, p2);
    try t.expect(!p2.readable);
}
