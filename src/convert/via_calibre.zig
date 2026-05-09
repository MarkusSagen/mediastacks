//! Calibre `ebook-convert` subprocess wrapper.

const std = @import("std");
const meta = @import("../core/metadata.zig");

pub fn isAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "ebook-convert", "--version" },
    }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    dst_format: meta.Format,
    out_dir: []const u8,
) ![]u8 {
    if (!isAvailable(allocator, io)) return error.CalibreMissing;

    const stem = std.fs.path.stem(src_path);
    const dst_name = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ stem, dst_format.extension() },
    );
    defer allocator.free(dst_name);
    const dst_path = try std.fs.path.join(allocator, &.{ out_dir, dst_name });
    errdefer allocator.free(dst_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "ebook-convert", src_path, dst_path },
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ConversionFailed,
        else => return error.ConversionFailed,
    }
    return dst_path;
}
