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

// `mz_zip_archive` is treated as opaque bytes. We over-allocate slightly
// vs. the actual struct so an ABI bump in a later miniz revision is
// less likely to bite. Verified sizes from miniz 3.0.2, 64-bit:
//   sizeof(mz_zip_archive)            = 112
//   sizeof(mz_zip_archive_file_stat)  = 1112
//   offsetof(m_uncomp_size)           = 40
const MZ_ZIP_ARCHIVE_SIZE = 128;
const MZ_ZIP_FILE_STAT_SIZE = 1200;
const UNCOMP_SIZE_OFFSET = 40;

pub const ZipReader = struct {
    archive: [MZ_ZIP_ARCHIVE_SIZE]u8 align(8) = std.mem.zeroes([MZ_ZIP_ARCHIVE_SIZE]u8),

    /// In-place init. miniz stores self-referential pointers into the
    /// archive buffer, so the buffer's address must remain stable for
    /// the reader's lifetime — i.e. the caller stack-allocates the
    /// ZipReader and passes a pointer here.
    pub fn open(self: *ZipReader, path: []const u8) !void {
        self.* = .{};
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return Error.OpenFailed;
        if (mz_zip_reader_init_file(&self.archive, path_z.ptr, 0) == 0) return Error.OpenFailed;
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
        const uncomp_size: u64 = @as(
            *const u64,
            @ptrCast(@alignCast(stat[UNCOMP_SIZE_OFFSET..][0..@sizeOf(u64)].ptr)),
        ).*;

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
