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

    const ext = std.fs.path.extension(path);
    const ext_fmt: meta.Format = if (ext.len > 1) meta.Format.fromExtension(ext[1..]) else .unknown;

    const magic_class = magicClass(head[0..n]);
    return switch (magic_class) {
        .pdf => .pdf,
        .zip => switch (ext_fmt) {
            .cbz => .cbz,
            else => if (ext_fmt == .unknown) .epub else ext_fmt,
        },
        .rar => switch (ext_fmt) {
            .cbr => .cbr,
            else => if (ext_fmt == .unknown) .cbr else ext_fmt,
        },
        .sevenz => switch (ext_fmt) {
            .cb7 => .cb7,
            else => if (ext_fmt == .unknown) .cb7 else ext_fmt,
        },
        .unknown => ext_fmt,
    };
}

const MagicClass = enum { pdf, zip, rar, sevenz, unknown };

fn magicClass(head: []const u8) MagicClass {
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "%PDF")) return .pdf;
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "PK\x03\x04")) return .zip;
    if (head.len >= 6 and std.mem.eql(u8, head[0..6], "Rar!\x1a\x07")) return .rar;
    if (head.len >= 6 and std.mem.eql(u8, head[0..6], "7z\xbc\xaf\x27\x1c")) return .sevenz;
    return .unknown;
}

/// Kept for backward compatibility / tests. Returns the single most
/// likely format from magic alone, with the legacy ZIP=EPUB default.
/// New callers should use `detect` (which combines extension).
pub fn detectFromMagic(head: []const u8) meta.Format {
    return switch (magicClass(head)) {
        .pdf => .pdf,
        .zip => .epub,
        .rar => .cbr,
        .sevenz => .cb7,
        .unknown => .unknown,
    };
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
