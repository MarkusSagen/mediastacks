//! MOBI/AZW3 → EPUB conversion.
//!
//! libmobi exposes the EPUB-writing logic only via its `mobitool` source
//! (no public `mobi_write_epub` API), so we shell out to the same
//! `mobitool -e` that's installed alongside libmobi. This keeps us off
//! the larger "reimplement EPUB packing on top of MOBIRawml" path until
//! the part-3 pure-Zig rewrite.
//!
//! mobitool writes `<stem>.epub` into the output directory.

const std = @import("std");

pub const Error = error{
    MobitoolMissing,
    ConversionFailed,
};

pub fn toEpub(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    out_dir: []const u8,
) ![]u8 {
    if (!mobitoolAvailable(allocator, io)) return Error.MobitoolMissing;

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "mobitool", "-e", "-o", out_dir, src_path },
    }) catch return Error.ConversionFailed;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return Error.ConversionFailed,
        else => return Error.ConversionFailed,
    }

    const stem = std.fs.path.stem(std.fs.path.basename(src_path));
    return std.fmt.allocPrint(allocator, "{s}/{s}.epub", .{ out_dir, stem });
}

fn mobitoolAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "mobitool", "--help" },
    }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return true;
}
