//! FFI for lib/mediastacks_c/cover_resize.c.
//!
//! Single entrypoint: `resize(bytes, max_width, quality)` produces a
//! width-capped JPEG. Caller-owned allocator copies the C-side buffer
//! and frees the C allocation, so the rest of the codebase doesn't
//! have to deal with malloc/free semantics.

const std = @import("std");

extern "c" fn mediastacks_cover_resize(
    input: [*]const u8,
    input_len: usize,
    max_width: c_int,
    jpeg_quality: c_int,
    out_len: *usize,
) ?[*]u8;

extern "c" fn mediastacks_cover_resize_free(buf: [*]u8) void;

pub const Error = error{ResizeFailed};

/// Resize cover-image bytes to a width-capped JPEG. Returns a freshly
/// allocated slice owned by `allocator`. On failure, returns
/// `Error.ResizeFailed` and writes nothing.
pub fn resize(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_width: u32,
    jpeg_quality: u32,
) ![]u8 {
    var out_len: usize = 0;
    const raw = mediastacks_cover_resize(
        input.ptr,
        input.len,
        @intCast(max_width),
        @intCast(jpeg_quality),
        &out_len,
    ) orelse return Error.ResizeFailed;
    defer mediastacks_cover_resize_free(raw);

    if (out_len == 0) return Error.ResizeFailed;
    const out = try allocator.alloc(u8, out_len);
    @memcpy(out, raw[0..out_len]);
    return out;
}
