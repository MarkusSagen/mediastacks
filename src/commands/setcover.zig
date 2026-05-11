//! `booktool set-cover FILE IMAGE` — replace the embedded cover.
//!
//! EPUB: re-pack the ZIP, swapping the bytes of the manifest entry
//! marked as `cover-image` (EPUB3) or referenced by `<meta name="cover">`
//! (EPUB2). Image content type is detected from magic bytes.
//!
//! MOBI/AZW3: shell out to `mobimeta -s cover-image=IMAGE FILE` (libmobi
//! tool). Falls back gracefully if `mobimeta` is missing.

const std = @import("std");
const cli = @import("../cli.zig");
const format_mod = @import("../formats/format.zig");
const zip = @import("../ffi/miniz.zig");
const xml = @import("../ffi/libxml2.zig");

const OPF_NS = "http://www.idpf.org/2007/opf";

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try ctx.stderr.print("usage: booktool set-cover FILE IMAGE\n", .{});
        return 1;
    }
    const book_path = args[0];
    const image_path = args[1];

    const fmt = format_mod.detect(ctx.io, book_path) catch |err| {
        try ctx.stderr.print("cannot read {s}: {s}\n", .{ book_path, @errorName(err) });
        return 2;
    };

    return switch (fmt) {
        .epub => setEpubCover(ctx, book_path, image_path),
        .mobi, .azw3 => setMobiCover(ctx, book_path, image_path),
        else => {
            try ctx.stderr.print("set-cover not supported for {s}\n", .{@tagName(fmt)});
            return 2;
        },
    };
}

fn setMobiCover(ctx: cli.Context, book_path: []const u8, image_path: []const u8) !u8 {
    const setter = try std.fmt.allocPrint(ctx.arena, "thumbnail={s}", .{image_path});
    const result = std.process.run(ctx.arena, ctx.io, .{
        .argv = &.{ "mobimeta", "-a", setter, book_path },
    }) catch |err| {
        try ctx.stderr.print("mobimeta failed: {s} (brew install libmobi)\n", .{@errorName(err)});
        return 2;
    };
    if (result.stdout.len > 0) try ctx.stdout.writeAll(result.stdout);
    if (result.stderr.len > 0) try ctx.stderr.writeAll(result.stderr);
    return switch (result.term) {
        .exited => |c| c,
        else => 2,
    };
}

fn setEpubCover(ctx: cli.Context, book_path: []const u8, image_path: []const u8) !u8 {
    const new_image = try readWhole(ctx.arena, image_path);
    applyToEpub(ctx.arena, book_path, new_image) catch |err| {
        try ctx.stderr.print("{s}: {s}\n", .{ book_path, @errorName(err) });
        return 2;
    };
    try ctx.stdout.print("replaced cover in {s}\n", .{book_path});
    return 0;
}

/// I/O-free EPUB cover replacement for use by the web API. `image_bytes`
/// is the raw bytes of the new cover (JPEG/PNG); the existing OPF's
/// declared cover-image entry is overwritten with them and the archive
/// is repacked.
pub fn applyToEpub(arena: std.mem.Allocator, book_path: []const u8, image_bytes: []const u8) !void {
    var reader: zip.ZipReader = .{};
    try reader.open(book_path);
    defer reader.close();

    const container_bytes = try reader.readMember(arena, "META-INF/container.xml");
    var container = try xml.Doc.parseMemory(container_bytes);
    defer container.deinit();
    const opf_path = (try container.firstString(
        arena,
        "c",
        "urn:oasis:names:tc:opendocument:xmlns:container",
        "//c:rootfile/@full-path",
    )) orelse return error.NoOpf;
    const opf_dir = std.fs.path.dirname(opf_path) orelse "";

    const opf_bytes = try reader.readMember(arena, opf_path);
    var opf = try xml.Doc.parseMemory(opf_bytes);
    defer opf.deinit();

    var cover_href = try opf.firstString(
        arena,
        "p",
        OPF_NS,
        "//p:item[contains(@properties,'cover-image')]/@href",
    );
    if (cover_href == null) {
        const cover_id = try opf.firstString(arena, "p", OPF_NS, "//p:meta[@name='cover']/@content");
        if (cover_id) |id| {
            var xp: [256]u8 = undefined;
            const xpath = try std.fmt.bufPrint(&xp, "//p:item[@id='{s}']/@href", .{id});
            cover_href = try opf.firstString(arena, "p", OPF_NS, xpath);
        }
    }
    const href = cover_href orelse return error.NoCoverItem;

    const cover_member_path = if (opf_dir.len > 0)
        try std.fs.path.join(arena, &.{ opf_dir, href })
    else
        try arena.dupe(u8, href);

    const tmp_path = try std.fmt.allocPrint(arena, "{s}.cover.tmp", .{book_path});
    var writer: zip.ZipWriter = .{};
    try writer.create(tmp_path);
    errdefer writer.abort();

    const Walk = struct {
        arena: std.mem.Allocator,
        reader: *zip.ZipReader,
        writer: *zip.ZipWriter,
        cover_path: []const u8,
        new_image: []const u8,
        replaced: bool = false,

        fn add(self: *@This(), _: u32, name: []const u8, _: u64) anyerror!void {
            const level: zip.ZipWriter.Compression =
                if (std.mem.eql(u8, name, "mimetype")) .none else .best;
            if (std.mem.eql(u8, name, self.cover_path)) {
                try self.writer.addBytes(name, self.new_image, level);
                self.replaced = true;
            } else {
                const bytes = try self.reader.readMember(self.arena, name);
                defer self.arena.free(bytes);
                try self.writer.addBytes(name, bytes, level);
            }
        }
    };
    var walk_ctx = Walk{
        .arena = arena,
        .reader = &reader,
        .writer = &writer,
        .cover_path = cover_member_path,
        .new_image = image_bytes,
    };
    try reader.forEachMember(&walk_ctx, Walk.add);
    if (!walk_ctx.replaced) {
        writer.abort();
        unlinkPath(tmp_path);
        return error.CoverMemberMissing;
    }
    try writer.finalizeAndClose();

    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{tmp_path});
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{book_path});
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) {
        unlinkPath(tmp_path);
        return error.RenameFailed;
    }
}

fn unlinkPath(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.unlink(z.ptr);
}

fn readWhole(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (fseek(fp, 0, 2) != 0) return error.SeekFailed;
    const size_signed = ftell(fp);
    if (size_signed < 0) return error.SeekFailed;
    _ = fseek(fp, 0, 0);
    const size: usize = @intCast(size_signed);
    const buf = try arena.alloc(u8, size);
    if (std.c.fread(buf.ptr, 1, size, fp) != size) return error.ReadFailed;
    return buf;
}

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
