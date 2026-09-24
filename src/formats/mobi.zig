//! MOBI/AZW3 reader — pulls embedded metadata via libmobi.

const std = @import("std");
const ffi = @import("../ffi/libmobi.zig");
const meta = @import("../core/metadata.zig");
const handler_mod = @import("handler.zig");

pub const CoverError = error{ NoCover, ExtractFailed };

/// Registry-facing handlers — separate constants for .mobi and .azw3
/// so dispatch by `Format` enum value picks the right one. They share
/// `readMetadata` + `extractCover` because libmobi treats both as the
/// same on-disk container shape.
pub const handler_mobi: handler_mod.FormatHandler = .{
    .format = .mobi,
    .extensions = &.{ "mobi", "prc" },
    .capabilities = .{
        .embedded_metadata = true,
        .embedded_cover = true,
        .reader_inline = true,
    },
    .read_metadata_fn = readMetadataShim,
    .extract_cover_fn = extractCoverShim,
    .write_metadata_fn = writeMetadataShim,
};

pub const handler_azw3: handler_mod.FormatHandler = .{
    .format = .azw3,
    .extensions = &.{ "azw3", "azw" },
    .capabilities = .{
        .embedded_metadata = true,
        .embedded_cover = true,
        .reader_inline = true,
    },
    .read_metadata_fn = readMetadataShim,
    .extract_cover_fn = extractCoverShim,
    .write_metadata_fn = writeMetadataShim,
};

fn readMetadataShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) anyerror!meta.BookMetadata {
    _ = io;
    return readMetadata(allocator, path);
}

fn extractCoverShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) anyerror![]u8 {
    return extractCover(allocator, io, path);
}

fn writeMetadataShim(
    _: *const anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    update: handler_mod.MetadataUpdate,
) anyerror!void {
    return writeMetadata(allocator, io, path, update);
}

/// MOBI/AZW3 metadata writes shell out to `mobimeta` (ships with
/// libmobi). Supports `title`, `author`, and `year` (mapped onto
/// `publishdate`); other fields are unsupported and surface as
/// `error.NotSupported`. Series + index can't be written via mobimeta
/// at all — convert to EPUB first if you want those.
pub fn writeMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    u: handler_mod.MetadataUpdate,
) !void {
    if (u.series != null or u.series_index != null) return error.NotSupported;
    if (u.publisher != null or u.language != null or u.description != null or u.isbn != null) {
        return error.NotSupported;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "mobimeta");
    if (u.title) |t| {
        try argv.append(allocator, "-a");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "title={s}", .{t}));
    }
    if (u.author) |a| {
        try argv.append(allocator, "-a");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "author={s}", .{a}));
    }
    if (u.year) |y| {
        try argv.append(allocator, "-a");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "publishdate={s}", .{y}));
    }
    try argv.append(allocator, path);

    const result = std.process.run(allocator, io, .{ .argv = argv.items }) catch
        return error.MobimetaFailed;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.MobimetaFailed,
        else => return error.MobimetaFailed,
    }
}

/// Extract a cover image by shelling out to `mobitool -c`. libmobi's
/// EXTH-by-uid resource access is on the path-to-pure-Zig list; the
/// subprocess is what the v1 web layer expected from this module and
/// what existing tests cover. Bytes are returned in-memory; the
/// caller is responsible for freeing.
pub fn extractCover(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/mediastacks-cover-{d}", .{std.c.getpid()});
    var dir_z_buf: [256]u8 = undefined;
    const dir_z = try std.fmt.bufPrintZ(&dir_z_buf, "{s}", .{dir});
    _ = std.c.mkdir(dir_z.ptr, 0o755);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "mobitool", "-c", "-o", dir, path },
    }) catch return CoverError.ExtractFailed;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return CoverError.ExtractFailed,
        else => return CoverError.ExtractFailed,
    }

    const stem = std.fs.path.stem(std.fs.path.basename(path));
    for ([_][]const u8{ "jpg", "jpeg", "png", "gif" }) |ext| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}_cover.{s}", .{ dir, stem, ext });
        defer allocator.free(candidate);
        if (readWholeFile(allocator, candidate)) |bytes| return bytes else |_| {}
    }
    return CoverError.NoCover;
}

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z_buf: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return CoverError.ExtractFailed;
    defer _ = std.c.fclose(fp);

    if (fseek(fp, 0, 2) != 0) return CoverError.ExtractFailed;
    const size_signed = ftell(fp);
    if (size_signed < 0) return CoverError.ExtractFailed;
    const size: usize = @intCast(size_signed);
    _ = fseek(fp, 0, 0);

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const n = std.c.fread(buf.ptr, 1, size, fp);
    if (n != size) return CoverError.ExtractFailed;
    return buf;
}

pub fn readMetadata(allocator: std.mem.Allocator, path: []const u8) !meta.BookMetadata {
    var book = try ffi.MobiBook.open(path);
    defer book.close();

    const title = try book.title(allocator);
    const author_raw = try book.author(allocator);
    const publisher = try book.publisher(allocator);
    const isbn = try book.isbn(allocator);
    const description = try book.description(allocator);
    const language = try book.language(allocator);
    const pubdate = try book.publishDate(allocator);
    const subject_raw = try book.subject(allocator);

    var authors_buf: std.ArrayList(meta.Author) = .empty;
    if (author_raw) |raw| {
        const author = try meta.Author.fromDisplay(allocator, raw);
        try authors_buf.append(allocator, author);
        allocator.free(raw);
    }

    var year: ?u16 = null;
    if (pubdate) |pd| {
        defer allocator.free(pd);
        if (pd.len >= 4) {
            year = std.fmt.parseInt(u16, pd[0..4], 10) catch null;
        }
    }

    var subjects_buf: std.ArrayList([]const u8) = .empty;
    if (subject_raw) |s| {
        var it = std.mem.splitSequence(u8, s, ", ");
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len == 0) continue;
            try subjects_buf.append(allocator, try allocator.dupe(u8, trimmed));
        }
        allocator.free(s);
    }

    return .{
        .title = title,
        .authors = try authors_buf.toOwnedSlice(allocator),
        .publisher = publisher,
        .isbn = isbn,
        .description = description,
        .language = language,
        .published_year = year,
        .subjects = try subjects_buf.toOwnedSlice(allocator),
        .source = .embedded,
        .confidence = 0.9,
    };
}

test "writeMetadata returns NotSupported when series fields are present" {
    const update = handler_mod.MetadataUpdate{
        .series = "Stormlight",
        .series_index = "1",
    };
    const io: std.Io = undefined;
    try std.testing.expectError(
        error.NotSupported,
        writeMetadata(std.testing.allocator, io, "/nonexistent.mobi", update),
    );
}

test "writeMetadata returns NotSupported for fields mobimeta can't carry" {
    const cases = [_]handler_mod.MetadataUpdate{
        .{ .publisher = "Tor" },
        .{ .language = "en" },
        .{ .description = "..." },
        .{ .isbn = "9780000000001" },
    };
    const io: std.Io = undefined;
    for (cases) |u| {
        try std.testing.expectError(
            error.NotSupported,
            writeMetadata(std.testing.allocator, io, "/nonexistent.mobi", u),
        );
    }
}
