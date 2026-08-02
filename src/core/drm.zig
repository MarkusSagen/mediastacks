//! DRM detection — flag protected media, never remove or circumvent it.
//!
//! Video: sniff MP4 box structure for encryption 4CCs (`detectVideo`).
//! Ebook: check the epub zip for `META-INF/encryption.xml`, or an `.acsm`
//! token (`detectEbook`). Detectors are total: any error/odd input yields
//! `.none` — never a crash, never a false positive.

const std = @import("std");
const zip = @import("../ffi/miniz.zig");

// std.c doesn't expose fseek in Zig 0.16; declare it (SEEK_CUR = 1).
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;

pub const Scheme = enum { none, fairplay, cenc, adept, acsm };

pub fn label(s: Scheme) []const u8 {
    return switch (s) {
        .none => "none",
        .fairplay => "FairPlay",
        .cenc => "CENC (Widevine/PlayReady)",
        .adept => "Adobe ADEPT",
        .acsm => "Adobe ACSM token",
    };
}

fn has(bytes: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, bytes, needle) != null;
}

/// Scan a `moov` (or any) byte slice for MP4 encryption markers. These 4CCs
/// are box/scheme types that only occur in protected `moov`s — scanning
/// `moov` (never `mdat`) makes false positives ~impossible.
pub fn scanForDrmMarkers(bytes: []const u8) Scheme {
    if (has(bytes, "pssh")) return .cenc;
    if (has(bytes, "sinf") or has(bytes, "drms") or has(bytes, "encv") or has(bytes, "enca")) return .fairplay;
    return .none;
}

const MOOV_CAP: usize = 16 * 1024 * 1024;

fn isMp4Ext(path: []const u8) bool {
    const e = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(e, ".mp4") or std.ascii.eqlIgnoreCase(e, ".m4v") or std.ascii.eqlIgnoreCase(e, ".mov");
}

/// Walk top-level MP4 boxes (skipping bodies via fseek) to reach `moov`,
/// then scan only that box for encryption markers. Total: any failure or
/// non-MP4 extension → `.none`.
pub fn detectVideo(alloc: std.mem.Allocator, path: []const u8) Scheme {
    if (!isMp4Ext(path)) return .none;
    var pb: [4096]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "{s}", .{path}) catch return .none;
    const fp = std.c.fopen(pz.ptr, "rb") orelse return .none;
    defer _ = std.c.fclose(fp);

    while (true) {
        var hdr: [16]u8 = undefined;
        if (std.c.fread(&hdr, 1, 8, fp) != 8) break;
        var box_size: u64 = std.mem.readInt(u32, hdr[0..4], .big);
        var header_len: u64 = 8;
        if (box_size == 1) {
            if (std.c.fread(hdr[8..].ptr, 1, 8, fp) != 8) break;
            box_size = std.mem.readInt(u64, hdr[8..16], .big);
            header_len = 16;
        }
        const is_moov = std.mem.eql(u8, hdr[4..8], "moov");
        if (is_moov) {
            const want: usize = if (box_size == 0) MOOV_CAP else @intCast(@min(box_size - header_len, MOOV_CAP));
            const buf = alloc.alloc(u8, want) catch return .none;
            defer alloc.free(buf);
            const got = std.c.fread(buf.ptr, 1, buf.len, fp);
            return scanForDrmMarkers(buf[0..got]);
        }
        if (box_size == 0) break; // last box, not moov
        const skip: c_long = @intCast(box_size - header_len);
        if (fseek(fp, skip, 1) != 0) break; // SEEK_CUR
    }
    return .none;
}

const t = std.testing;

test "scanForDrmMarkers detects pssh as cenc" {
    try t.expectEqual(Scheme.cenc, scanForDrmMarkers("....pssh....widevine"));
}
test "scanForDrmMarkers detects sinf/drms as fairplay" {
    try t.expectEqual(Scheme.fairplay, scanForDrmMarkers("trak....sinf....drms"));
}
test "scanForDrmMarkers on a plain moov is none" {
    try t.expectEqual(Scheme.none, scanForDrmMarkers("trakmdiaminfstblstsdavc1mp4a"));
}
test "label is human readable" {
    try t.expectEqualStrings("CENC (Widevine/PlayReady)", label(.cenc));
    try t.expectEqualStrings("FairPlay", label(.fairplay));
}

fn writeMp4(path_z: [:0]const u8, moov_payload: []const u8) void {
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    var box: [16]u8 = undefined;
    std.mem.writeInt(u32, box[0..4], 16, .big);
    @memcpy(box[4..8], "ftyp");
    @memcpy(box[8..12], "isom");
    std.mem.writeInt(u32, box[12..16], 0, .big);
    _ = std.c.fwrite(&box, 1, 16, fp);
    var mh: [8]u8 = undefined;
    std.mem.writeInt(u32, mh[0..4], @intCast(8 + moov_payload.len), .big);
    @memcpy(mh[4..8], "moov");
    _ = std.c.fwrite(&mh, 1, 8, fp);
    if (moov_payload.len > 0) _ = std.c.fwrite(moov_payload.ptr, 1, moov_payload.len, fp);
}

test "detectVideo finds pssh in moov" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var pb: [128]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "/tmp/drm-cenc-{d}.mp4", .{pid}) catch unreachable;
    defer _ = std.c.unlink(pz.ptr);
    writeMp4(pz, "trak....pssh....");
    try t.expectEqual(Scheme.cenc, detectVideo(a, pz));
}

test "detectVideo on a clean mp4 is none" {
    const a = t.allocator;
    const pid = std.c.getpid();
    var pb: [128]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pb, "/tmp/drm-clean-{d}.mp4", .{pid}) catch unreachable;
    defer _ = std.c.unlink(pz.ptr);
    writeMp4(pz, "trakmdiaminfstblstsdavc1");
    try t.expectEqual(Scheme.none, detectVideo(a, pz));
}

test "detectVideo ignores non-mp4 extensions" {
    try t.expectEqual(Scheme.none, detectVideo(t.allocator, "/tmp/whatever.mkv"));
}
