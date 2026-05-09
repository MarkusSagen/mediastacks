//! Format detection by magic bytes (with extension as a fallback).

const std = @import("std");
const meta = @import("../core/metadata.zig");

pub fn detect(io: std.Io, path: []const u8) !meta.Format {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    var head: [16]u8 = undefined;
    var bufs = [_][]u8{&head};
    const n = file.readStreaming(io, &bufs) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    const fmt = detectFromMagic(head[0..n]);
    if (fmt != .unknown) return fmt;

    const ext = std.fs.path.extension(path);
    if (ext.len > 1) return meta.Format.fromExtension(ext[1..]);
    return .unknown;
}

pub fn detectFromMagic(head: []const u8) meta.Format {
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "PK\x03\x04")) return .epub;
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "%PDF")) return .pdf;
    // PalmDB containers (MOBI/AZW3/PRC) carry "BOOKMOBI" / "TPZ3" at offset
    // 60 — not visible in the first 16 bytes. Fall through to extension.
    return .unknown;
}

test "detectFromMagic identifies EPUB by ZIP magic" {
    const head = "PK\x03\x04rest";
    try std.testing.expectEqual(meta.Format.epub, detectFromMagic(head));
}

test "detectFromMagic identifies PDF" {
    const head = "%PDF-1.7";
    try std.testing.expectEqual(meta.Format.pdf, detectFromMagic(head));
}

test "detectFromMagic returns unknown for short input" {
    try std.testing.expectEqual(meta.Format.unknown, detectFromMagic(""));
}
