//! Read-only media inspection via `ffprobe`.
//!
//! `parse` is pure (ffprobe JSON → `Probe`) so it's tested against captured
//! fixtures without spawning anything. `run`/`available` (Task 3) wrap the
//! actual process. Everything here is read-only — we never touch the media.

const std = @import("std");

pub const Confidence = enum { none, generic, authoritative };

/// Library metadata embedded in the container (iTunes atoms, Matroska tags).
pub const Embedded = struct {
    series: ?[]const u8 = null,
    season: ?u32 = null,
    episode: ?u32 = null,
    title: ?[]const u8 = null,
    confidence: Confidence = .none,
};

pub const Probe = struct {
    readable: bool = true,
    vcodec: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    duration_s: ?f64 = null,
    bitrate: ?u64 = null,
    embedded: Embedded = .{},
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
            for (streams.array.items) |s| {
                const ct = objGet(s, "codec_type") orelse continue;
                if (ct == .string and std.mem.eql(u8, ct.string, "video")) {
                    p.vcodec = try dupStr(alloc, objGet(s, "codec_name"));
                    p.width = asU32(objGet(s, "width"));
                    p.height = asU32(objGet(s, "height"));
                    break;
                }
            }
        }
    }

    if (objGet(root, "format")) |fmt| {
        p.duration_s = asF64(objGet(fmt, "duration"));
        p.bitrate = asU64Str(objGet(fmt, "bit_rate"));
    }

    // No video, no format, no dimensions → effectively unreadable.
    if (p.vcodec == null and p.duration_s == null and p.width == null) p.readable = false;
    return p;
}

pub fn freeProbe(alloc: std.mem.Allocator, p: Probe) void {
    if (p.vcodec) |x| alloc.free(x);
    if (p.embedded.series) |x| alloc.free(x);
    if (p.embedded.title) |x| alloc.free(x);
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

test "parse of empty/garbage json is unreadable, not a crash" {
    const a = t.allocator;
    const p1 = try parse(a, "");
    defer freeProbe(a, p1);
    try t.expect(!p1.readable);
    const p2 = try parse(a, "not json at all");
    defer freeProbe(a, p2);
    try t.expect(!p2.readable);
}
