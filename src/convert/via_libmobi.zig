//! MOBI/AZW3 → EPUB conversion via libmobi.
//!
//! Implementation pending: libmobi exposes `mobi_write_epub` through its
//! source tree but the public-API entry point varies between releases.
//! Mirroring `tools/mobitool.c -e` is the planned approach.

const std = @import("std");

pub fn toEpub(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    out_dir: []const u8,
) ![]u8 {
    _ = allocator;
    _ = src_path;
    _ = out_dir;
    return error.NotImplemented;
}
