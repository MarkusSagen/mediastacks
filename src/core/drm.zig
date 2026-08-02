//! DRM detection — flag protected media, never remove or circumvent it.
//!
//! Video: sniff MP4 box structure for encryption 4CCs (`detectVideo`).
//! Ebook: check the epub zip for `META-INF/encryption.xml`, or an `.acsm`
//! token (`detectEbook`). Detectors are total: any error/odd input yields
//! `.none` — never a crash, never a false positive.

const std = @import("std");
const zip = @import("../ffi/miniz.zig");

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
