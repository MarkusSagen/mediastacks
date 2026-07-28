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

    /// Iterate every member in the archive, calling `cb(ctx, idx, name, uncomp_size)`.
    /// `name` is valid only for the duration of the callback.
    pub fn forEachMember(
        self: *ZipReader,
        ctx: anytype,
        comptime cb: fn (@TypeOf(ctx), idx: u32, name: []const u8, uncomp_size: u64) anyerror!void,
    ) !void {
        const total = mz_zip_reader_get_num_files(&self.archive);
        var idx: u32 = 0;
        while (idx < total) : (idx += 1) {
            var stat: [MZ_ZIP_FILE_STAT_SIZE]u8 align(8) = std.mem.zeroes([MZ_ZIP_FILE_STAT_SIZE]u8);
            if (mz_zip_reader_file_stat(&self.archive, idx, &stat) == 0) return Error.ReadFailed;
            var name_buf: [512]u8 = undefined;
            const name_len = mz_zip_reader_get_filename(&self.archive, idx, &name_buf, name_buf.len);
            if (name_len == 0) continue;
            const name = name_buf[0 .. name_len - 1];
            const uncomp: u64 = @as(
                *const u64,
                @ptrCast(@alignCast(stat[UNCOMP_SIZE_OFFSET..][0..@sizeOf(u64)].ptr)),
            ).*;
            try cb(ctx, idx, name, uncomp);
        }
    }
};

pub const ZipWriter = struct {
    archive: [MZ_ZIP_ARCHIVE_SIZE]u8 align(8) = std.mem.zeroes([MZ_ZIP_ARCHIVE_SIZE]u8),

    pub const Compression = enum(c_int) {
        none = 0,
        fastest = 1,
        best = 9,
        uber = 10,
    };

    pub fn create(self: *ZipWriter, path: []const u8) !void {
        self.* = .{};
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return Error.OpenFailed;
        if (mz_zip_writer_init_file(&self.archive, path_z.ptr, 0) == 0) return Error.OpenFailed;
    }

    pub fn finalizeAndClose(self: *ZipWriter) !void {
        if (mz_zip_writer_finalize_archive(&self.archive) == 0) return Error.ReadFailed;
        _ = mz_zip_writer_end(&self.archive);
    }

    pub fn abort(self: *ZipWriter) void {
        _ = mz_zip_writer_end(&self.archive);
    }

    pub fn addBytes(
        self: *ZipWriter,
        name: []const u8,
        bytes: []const u8,
        level: Compression,
    ) !void {
        var name_buf: [1024]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return Error.ReadFailed;
        const level_int: c_uint = @intCast(@intFromEnum(level));
        const ok = mz_zip_writer_add_mem(
            &self.archive,
            name_z.ptr,
            if (bytes.len == 0) null else bytes.ptr,
            bytes.len,
            level_int,
        );
        if (ok == 0) return Error.ReadFailed;
    }
};

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

extern "c" fn mz_zip_reader_get_num_files(archive: *anyopaque) c_uint;
extern "c" fn mz_zip_reader_get_filename(
    archive: *anyopaque,
    file_index: c_uint,
    filename_buf: [*]u8,
    filename_buf_size: c_uint,
) c_uint;

extern "c" fn mz_zip_writer_init_file(
    archive: *anyopaque,
    filename: [*:0]const u8,
    size_to_reserve_at_beginning: u64,
) c_int;
extern "c" fn mz_zip_writer_add_mem(
    archive: *anyopaque,
    name: [*:0]const u8,
    buf: ?[*]const u8,
    buf_size: usize,
    level_and_flags: c_uint,
) c_int;
extern "c" fn mz_zip_writer_finalize_archive(archive: *anyopaque) c_int;
extern "c" fn mz_zip_writer_end(archive: *anyopaque) c_int;
