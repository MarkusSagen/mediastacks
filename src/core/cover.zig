//! Cover image extraction.
//!
//! - EPUB: parse the OPF manifest to find the cover-image item, extract
//!   from the ZIP container.
//! - MOBI/AZW3: shell out to `mobitool -c` which understands all the
//!   cover-record layout variations across libmobi-supported formats.
//!   Wiring `mobi_get_resource_by_uid` + EXTH parsing is on the path-3
//!   to-pure-zig list, but for v1 the subprocess works.

const std = @import("std");
const meta = @import("metadata.zig");
const zip = @import("../ffi/miniz.zig");
const xml = @import("../ffi/libxml2.zig");

pub const OPF_NS = "http://www.idpf.org/2007/opf";
pub const DC_NS = "http://purl.org/dc/elements/1.1/";

pub const Error = error{
    NoCover,
    ExtractFailed,
};

/// Extract the cover image bytes from a book. Returns owned bytes on
/// success.
pub fn extract(allocator: std.mem.Allocator, io: std.Io, path: []const u8, fmt: meta.Format) ![]u8 {
    return switch (fmt) {
        .epub => extractEpub(allocator, path),
        .mobi, .azw3 => extractMobiViaMobitool(allocator, io, path),
        else => error.NoCover,
    };
}

fn extractEpub(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

    const container_bytes = try reader.readMember(allocator, "META-INF/container.xml");
    defer allocator.free(container_bytes);

    var container = try xml.Doc.parseMemory(container_bytes);
    defer container.deinit();
    const opf_path = (try container.firstString(
        allocator,
        "c",
        "urn:oasis:names:tc:opendocument:xmlns:container",
        "//c:rootfile/@full-path",
    )) orelse return Error.NoCover;
    defer allocator.free(opf_path);

    const opf_bytes = try reader.readMember(allocator, opf_path);
    defer allocator.free(opf_bytes);

    var opf = try xml.Doc.parseMemory(opf_bytes);
    defer opf.deinit();

    // EPUB3: <item properties="cover-image" href="..." />
    var cover_href = try opf.firstString(
        allocator,
        "p",
        OPF_NS,
        "//p:item[contains(@properties,'cover-image')]/@href",
    );

    // EPUB2 fallback: <meta name="cover" content="ID"/> -> <item id="ID" href="..."/>
    if (cover_href == null) {
        const cover_id = try opf.firstString(
            allocator,
            "p",
            OPF_NS,
            "//p:meta[@name='cover']/@content",
        );
        if (cover_id) |id| {
            defer allocator.free(id);
            var xpath_buf: [256]u8 = undefined;
            const xpath = try std.fmt.bufPrint(&xpath_buf, "//p:item[@id='{s}']/@href", .{id});
            cover_href = try opf.firstString(allocator, "p", OPF_NS, xpath);
        }
    }

    const href = cover_href orelse return Error.NoCover;
    defer allocator.free(href);

    // href is relative to the OPF's directory.
    const opf_dir = std.fs.path.dirname(opf_path) orelse "";
    const member_path = if (opf_dir.len > 0)
        try std.fs.path.join(allocator, &.{ opf_dir, href })
    else
        try allocator.dupe(u8, href);
    defer allocator.free(member_path);

    return reader.readMember(allocator, member_path);
}

fn extractMobiViaMobitool(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // Spill to a unique tmp dir under /tmp/booktool-cover/.
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/booktool-cover-{d}", .{std.c.getpid()});
    var dir_z_buf: [256]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir});
    _ = std.c.mkdir(dir_z.ptr, 0o755);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "mobitool", "-c", "-o", dir, path },
    }) catch return Error.ExtractFailed;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return Error.ExtractFailed,
        else => return Error.ExtractFailed,
    }

    // mobitool writes "<stem>_cover.jpg" (or .png) into the output dir.
    const stem = std.fs.path.stem(std.fs.path.basename(path));
    for ([_][]const u8{ "jpg", "jpeg", "png", "gif" }) |ext| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}_cover.{s}", .{ dir, stem, ext });
        defer allocator.free(candidate);
        if (readWholeFile(allocator, candidate)) |bytes| return bytes else |_| {}
    }
    return Error.NoCover;
}

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return Error.ExtractFailed;
    defer _ = std.c.fclose(fp);

    if (fseek(fp, 0, 2) != 0) return Error.ExtractFailed; // SEEK_END
    const size_signed = ftell(fp);
    if (size_signed < 0) return Error.ExtractFailed;
    const size: usize = @intCast(size_signed);
    _ = fseek(fp, 0, 0); // SEEK_SET

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const n = std.c.fread(buf.ptr, 1, size, fp);
    if (n != size) return Error.ExtractFailed;
    return buf;
}

/// Write `bytes` to a tmp file and return its path (caller frees).
pub fn writeTmp(allocator: std.mem.Allocator, bytes: []const u8, extension: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/booktool-cover-{d}.{s}",
        .{ std.c.getpid(), extension },
    );
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return Error.ExtractFailed;
    defer _ = std.c.fclose(fp);
    const n = std.c.fwrite(bytes.ptr, 1, bytes.len, fp);
    if (n != bytes.len) return Error.ExtractFailed;
    return path;
}
