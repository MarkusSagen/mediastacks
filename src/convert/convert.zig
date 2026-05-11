//! Conversion dispatcher: chooses libmobi or Calibre based on src/dst pair.

const std = @import("std");
const meta = @import("../core/metadata.zig");
const calibre = @import("via_calibre.zig");
const libmobi_path = @import("via_libmobi.zig");

pub const ConvertError = error{
    UnsupportedConversion,
    CalibreMissing,
    ConversionFailed,
};

pub const Engine = enum { libmobi, calibre };

pub fn pickEngine(src: meta.Format, dst: meta.Format) ?Engine {
    if (src == dst) return null;
    return switch (src) {
        .mobi, .azw3 => switch (dst) {
            .epub => .libmobi,
            else => .calibre,
        },
        .epub => .calibre,
        .pdf => .calibre,
        .unknown => null,
    };
}

pub fn convert(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    src_format: meta.Format,
    dst_format: meta.Format,
    out_dir: []const u8,
) ![]u8 {
    const engine = pickEngine(src_format, dst_format) orelse return ConvertError.UnsupportedConversion;
    return switch (engine) {
        .libmobi => libmobi_path.toEpub(allocator, io, src_path, out_dir),
        .calibre => calibre.run(allocator, io, src_path, dst_format, out_dir),
    };
}

test "pickEngine routes MOBI->EPUB to libmobi" {
    try std.testing.expectEqual(Engine.libmobi, pickEngine(.mobi, .epub).?);
    try std.testing.expectEqual(Engine.libmobi, pickEngine(.azw3, .epub).?);
}

test "pickEngine routes EPUB->MOBI to Calibre" {
    try std.testing.expectEqual(Engine.calibre, pickEngine(.epub, .mobi).?);
}

test "pickEngine returns null for same-format conversion" {
    try std.testing.expectEqual(@as(?Engine, null), pickEngine(.epub, .epub));
}
