//! Tiny safe wrapper around the miniz ZIP-reading API.
//!
//! miniz.h is too messy for Zig 0.16's translate-c (which crashes on the
//! zlib-compat alias macros), so we declare the small set of symbols we
//! use here as `extern "c"`. The vendored miniz.c source is compiled by
//! build.zig and linked into the same module.
//!
//! Only the read path is exposed — write support comes when v1 needs it.

const std = @import("std");

pub const Error = error{
    OpenFailed,
    NotFound,
    ReadFailed,
};

// `mz_zip_archive` is a ~few-hundred-byte struct. We treat it as opaque
// bytes — miniz internally manages the layout via mz_zip_reader_init_*.
//
// Size source: miniz 3.0.2 amalgamation, 64-bit build with default
// macros. We over-allocate to be safe; miniz reads fields by name from
// C, not by structural shape from Zig.
const MZ_ZIP_ARCHIVE_SIZE = 512;
const MZ_ZIP_FILE_STAT_SIZE = 768;

pub const ZipReader = struct {
    archive: [MZ_ZIP_ARCHIVE_SIZE]u8 align(8),

    pub fn openFile(path: []const u8) !ZipReader {
        var self: ZipReader = .{ .archive = std.mem.zeroes([MZ_ZIP_ARCHIVE_SIZE]u8) };
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return Error.OpenFailed;
        if (mz_zip_reader_init_file(&self.archive, path_z.ptr, 0) == 0) return Error.OpenFailed;
        return self;
    }

    pub fn close(self: *ZipReader) void {
        _ = mz_zip_reader_end(&self.archive);
    }

    pub fn readMember(
        self: *ZipReader,
        allocator: std.mem.Allocator,
        member_name: []const u8,
    ) ![]u8 {
        var name_buf: [1024]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{member_name}) catch return Error.NotFound;

        const idx = mz_zip_reader_locate_file(&self.archive, name_z.ptr, null, 0);
        if (idx < 0) return Error.NotFound;

        var stat: [MZ_ZIP_FILE_STAT_SIZE]u8 align(8) = std.mem.zeroes([MZ_ZIP_FILE_STAT_SIZE]u8);
        if (mz_zip_reader_file_stat(&self.archive, @intCast(idx), &stat) == 0) {
            return Error.ReadFailed;
        }
        // file_stat layout (offset 8): m_uncomp_size: u64.
        const uncomp_size: u64 = @as(*const u64, @ptrCast(@alignCast(stat[8..16].ptr))).*;

        const buf = try allocator.alloc(u8, uncomp_size);
        errdefer allocator.free(buf);
        if (mz_zip_reader_extract_to_mem(
            &self.archive,
            @intCast(idx),
            buf.ptr,
            buf.len,
            0,
        ) == 0) {
            return Error.ReadFailed;
        }
        return buf;
    }
};

// ---- C ABI (vendored miniz.c) ------------------------------------------

extern "c" fn mz_zip_reader_init_file(
    archive: *anyopaque,
    filename: [*:0]const u8,
    flags: c_uint,
) c_int;

extern "c" fn mz_zip_reader_end(archive: *anyopaque) c_int;

extern "c" fn mz_zip_reader_locate_file(
    archive: *anyopaque,
    name: [*:0]const u8,
    comment: ?[*:0]const u8,
    flags: c_uint,
) c_int;

extern "c" fn mz_zip_reader_file_stat(
    archive: *anyopaque,
    file_index: c_uint,
    stat: *anyopaque,
) c_int;

extern "c" fn mz_zip_reader_extract_to_mem(
    archive: *anyopaque,
    file_index: c_uint,
    buf: *anyopaque,
    buf_size: usize,
    flags: c_uint,
) c_int;
