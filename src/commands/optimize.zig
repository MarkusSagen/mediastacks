//! `booktool optimize FILE...` — recompress EPUB containers with the
//! highest-quality deflate level.
//!
//! Approach: round-trip every entry through a fresh archive with
//! `MZ_UBER_COMPRESSION` (level 10). The EPUB spec requires `mimetype`
//! to be the first entry and stored uncompressed — handled specially.
//!
//! Image recompression and HTML/CSS minification are not done here.
//! For those, see `epuboptim` or `epub-optimizer` — adding them would
//! require pulling in libjpeg/libpng/zigimg, which is the next iteration.
//!
//! Refuses to overwrite when the result is larger than the original;
//! prints a one-line per-file summary.

const std = @import("std");
const cli = @import("../cli.zig");
const zip = @import("../ffi/miniz.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try ctx.stderr.print("usage: booktool optimize FILE [FILE ...]\n", .{});
        return 1;
    }
    var any_error = false;
    var total_saved: i64 = 0;

    for (args) |path| {
        if (!std.mem.endsWith(u8, path, ".epub")) {
            try ctx.stderr.print("skip {s}: optimize currently only supports EPUB\n", .{path});
            continue;
        }
        const result = optimizeOne(ctx.arena, path) catch |err| {
            try ctx.stderr.print("error: {s}: {s}\n", .{ path, @errorName(err) });
            any_error = true;
            continue;
        };
        const delta = @as(i64, @intCast(result.old_size)) - @as(i64, @intCast(result.new_size));
        total_saved += delta;
        const pct: f32 = if (result.old_size > 0)
            (@as(f32, @floatFromInt(delta)) / @as(f32, @floatFromInt(result.old_size))) * 100
        else
            0;
        try ctx.stdout.print(
            "{s}\n  {d} → {d} bytes ({d:.1}%)\n",
            .{ path, result.old_size, result.new_size, pct },
        );
    }

    try ctx.stdout.print("\ntotal saved: {d} bytes\n", .{total_saved});
    return if (any_error) 1 else 0;
}

const Result = struct { old_size: u64, new_size: u64 };

fn optimizeOne(arena: std.mem.Allocator, path: []const u8) !Result {
    const old_size = try fileSize(path);

    // Write into "<path>.opt.tmp", then atomically rename over the original
    // only if smaller.
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.opt.tmp", .{path});

    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

    var writer: zip.ZipWriter = .{};
    try writer.create(tmp_path);
    errdefer {
        writer.abort();
        cleanup(tmp_path);
    }

    const Walk = struct {
        arena: std.mem.Allocator,
        reader: *zip.ZipReader,
        writer: *zip.ZipWriter,

        fn add(self: *@This(), idx: u32, name: []const u8, _: u64) anyerror!void {
            const bytes = try self.reader.readMember(self.arena, name);
            defer self.arena.free(bytes);

            // mimetype MUST be first and stored uncompressed per OCF.
            const level: zip.ZipWriter.Compression = if (std.mem.eql(u8, name, "mimetype"))
                .none
            else
                .uber;
            try self.writer.addBytes(name, bytes, level);
            _ = idx;
        }
    };

    var ctx = Walk{ .arena = arena, .reader = &reader, .writer = &writer };
    try reader.forEachMember(&ctx, Walk.add);
    try writer.finalizeAndClose();

    const new_size = try fileSize(tmp_path);

    if (new_size >= old_size) {
        // Optimization didn't help — discard tmp, leave original alone.
        cleanup(tmp_path);
        return .{ .old_size = old_size, .new_size = old_size };
    }

    // Atomic rename: new file replaces original.
    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{tmp_path});
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{path});
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) return error.RenameFailed;
    return .{ .old_size = old_size, .new_size = new_size };
}

fn fileSize(path: []const u8) !u64 {
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (fseek(fp, 0, 2) != 0) return error.SeekFailed;
    const sz = ftell(fp);
    if (sz < 0) return error.SeekFailed;
    return @intCast(sz);
}

fn cleanup(path: []const u8) void {
    var path_z_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(path_z.ptr);
}

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
