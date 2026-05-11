//! `booktool set-meta FILE [--title T] [--author A] [--series S] [--series-index N] [--year Y]`
//!
//! Edit the embedded metadata of a book file.
//!
//! EPUB: rewrite the OPF document by substituting the existing
//! `<dc:title>`, `<dc:creator>`, etc. elements (or appending if absent),
//! then re-pack the archive. Other entries copy through unchanged.
//!
//! MOBI/AZW3: shell out to `mobimeta` (libmobi). Mapping:
//!   --title  → -a title=...
//!   --author → -a author=...
//!   --series, --series-index → not supported by mobimeta — error out.

const std = @import("std");
const cli = @import("../cli.zig");
const format_mod = @import("../formats/format.zig");
const zip = @import("../ffi/miniz.zig");

const Update = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    series: ?[]const u8 = null,
    series_index: ?[]const u8 = null,
    year: ?[]const u8 = null,
};

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 3) {
        try printHelp(ctx.stdout);
        return 1;
    }
    const path = args[0];
    var update: Update = .{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 >= args.len) {
            try ctx.stderr.print("missing value for {s}\n", .{a});
            return 1;
        }
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--title")) update.title = v
        else if (std.mem.eql(u8, a, "--author")) update.author = v
        else if (std.mem.eql(u8, a, "--series")) update.series = v
        else if (std.mem.eql(u8, a, "--series-index")) update.series_index = v
        else if (std.mem.eql(u8, a, "--year")) update.year = v
        else {
            try ctx.stderr.print("unknown flag: {s}\n", .{a});
            return 1;
        }
    }

    const fmt = format_mod.detect(ctx.io, path) catch |err| {
        try ctx.stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };

    return switch (fmt) {
        .epub => setEpubMeta(ctx, path, update),
        .mobi, .azw3 => setMobiMeta(ctx, path, update),
        else => {
            try ctx.stderr.print("set-meta not supported for {s}\n", .{@tagName(fmt)});
            return 2;
        },
    };
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: booktool set-meta FILE [options]
        \\
        \\Options (any combination):
        \\  --title TEXT
        \\  --author "Last, First" | "First Last"
        \\  --series TEXT
        \\  --series-index N
        \\  --year YYYY
        \\
        \\Notes:
        \\  EPUB: in-place OPF rewrite + zip repack.
        \\  MOBI/AZW3: shells out to mobimeta (--series fields unsupported).
        \\
    );
}

fn setMobiMeta(ctx: cli.Context, path: []const u8, u: Update) !u8 {
    if (u.series != null or u.series_index != null) {
        try ctx.stderr.print("MOBI set-meta does not support --series via mobimeta\n", .{});
        return 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "mobimeta");
    if (u.title) |t| {
        try argv.append(ctx.arena, "-a");
        try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "title={s}", .{t}));
    }
    if (u.author) |a| {
        try argv.append(ctx.arena, "-a");
        try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "author={s}", .{a}));
    }
    if (u.year) |y| {
        try argv.append(ctx.arena, "-a");
        try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "publishdate={s}", .{y}));
    }
    try argv.append(ctx.arena, path);

    const result = std.process.run(ctx.arena, ctx.io, .{ .argv = argv.items }) catch |err| {
        try ctx.stderr.print("mobimeta failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    if (result.stdout.len > 0) try ctx.stdout.writeAll(result.stdout);
    if (result.stderr.len > 0) try ctx.stderr.writeAll(result.stderr);
    return switch (result.term) {
        .exited => |c| c,
        else => 2,
    };
}

fn setEpubMeta(ctx: cli.Context, path: []const u8, u: Update) !u8 {
    var reader: zip.ZipReader = .{};
    try reader.open(path);
    defer reader.close();

    const container = try reader.readMember(ctx.arena, "META-INF/container.xml");
    const opf_path = (try findOpfPath(ctx.arena, container)) orelse {
        try ctx.stderr.print("no OPF in {s}\n", .{path});
        return 2;
    };
    const opf_bytes = try reader.readMember(ctx.arena, opf_path);
    const new_opf = try rewriteOpf(ctx.arena, opf_bytes, u);

    // Rebuild archive, swapping in the new OPF.
    const tmp_path = try std.fmt.allocPrint(ctx.arena, "{s}.meta.tmp", .{path});
    var writer: zip.ZipWriter = .{};
    try writer.create(tmp_path);
    errdefer writer.abort();

    const Walk = struct {
        arena: std.mem.Allocator,
        reader: *zip.ZipReader,
        writer: *zip.ZipWriter,
        opf_path: []const u8,
        new_opf: []const u8,

        fn add(self: *@This(), _: u32, name: []const u8, _: u64) anyerror!void {
            const level: zip.ZipWriter.Compression =
                if (std.mem.eql(u8, name, "mimetype")) .none else .best;
            if (std.mem.eql(u8, name, self.opf_path)) {
                try self.writer.addBytes(name, self.new_opf, level);
            } else {
                const bytes = try self.reader.readMember(self.arena, name);
                defer self.arena.free(bytes);
                try self.writer.addBytes(name, bytes, level);
            }
        }
    };
    var walk_ctx = Walk{
        .arena = ctx.arena,
        .reader = &reader,
        .writer = &writer,
        .opf_path = opf_path,
        .new_opf = new_opf,
    };
    try reader.forEachMember(&walk_ctx, Walk.add);
    try writer.finalizeAndClose();

    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{tmp_path});
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{path});
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) return error.RenameFailed;
    try ctx.stdout.print("updated metadata in {s}\n", .{path});
    return 0;
}

fn findOpfPath(arena: std.mem.Allocator, container: []const u8) !?[]const u8 {
    // Tiny scanner — easier than spinning libxml2 up just for this.
    const tag = "full-path=\"";
    const start = std.mem.indexOf(u8, container, tag) orelse return null;
    const after = start + tag.len;
    const end = std.mem.indexOfScalarPos(u8, container, after, '"') orelse return null;
    return try arena.dupe(u8, container[after..end]);
}

/// Substitute simple `<dc:title>`, `<dc:creator>`, `<dc:date>` element
/// text in-place. Series and series_index are written as
/// `<meta name="calibre:series"...>` (Calibre's de-facto convention).
/// If a field isn't present in the OPF, we append a new element inside
/// the existing `<metadata>` block.
fn rewriteOpf(arena: std.mem.Allocator, opf: []const u8, u: Update) ![]u8 {
    var current = try arena.dupe(u8, opf);

    if (u.title) |t| current = try replaceElementText(arena, current, "dc:title", t);
    if (u.author) |a| current = try replaceElementText(arena, current, "dc:creator", a);
    if (u.year) |y| current = try replaceElementText(arena, current, "dc:date", y);
    if (u.series) |s|
        current = try upsertMeta(arena, current, "calibre:series", s);
    if (u.series_index) |idx|
        current = try upsertMeta(arena, current, "calibre:series_index", idx);

    return current;
}

/// Replace the text content of the first `<TAG ...>...</TAG>` occurrence.
/// If the tag doesn't exist, append `<TAG>value</TAG>` inside `</metadata>`.
fn replaceElementText(
    arena: std.mem.Allocator,
    src: []const u8,
    tag: []const u8,
    value: []const u8,
) ![]u8 {
    const open_search = try std.fmt.allocPrint(arena, "<{s}", .{tag});
    defer arena.free(open_search);

    if (std.mem.indexOf(u8, src, open_search)) |open_pos| {
        const gt = std.mem.indexOfScalarPos(u8, src, open_pos, '>') orelse return arena.dupe(u8, src);
        const close = try std.fmt.allocPrint(arena, "</{s}>", .{tag});
        defer arena.free(close);
        const close_pos = std.mem.indexOfPos(u8, src, gt + 1, close) orelse return arena.dupe(u8, src);

        const escaped = try xmlEscape(arena, value);
        defer arena.free(escaped);

        return std.fmt.allocPrint(
            arena,
            "{s}{s}{s}",
            .{ src[0 .. gt + 1], escaped, src[close_pos..] },
        );
    }
    return appendInMetadata(arena, src, tag, value);
}

fn upsertMeta(
    arena: std.mem.Allocator,
    src: []const u8,
    name: []const u8,
    value: []const u8,
) ![]u8 {
    // Find an existing <meta name="NAME" content="..."/> and replace its
    // content. If absent, append before </metadata>.
    const needle = try std.fmt.allocPrint(arena, "name=\"{s}\"", .{name});
    defer arena.free(needle);

    if (std.mem.indexOf(u8, src, needle)) |npos| {
        // Find content attr after this point.
        const after = std.mem.indexOfPos(u8, src, npos, "content=\"") orelse
            return appendMetaInline(arena, src, name, value);
        const after_q = after + "content=\"".len;
        const end_q = std.mem.indexOfScalarPos(u8, src, after_q, '"') orelse
            return appendMetaInline(arena, src, name, value);

        const escaped = try xmlEscape(arena, value);
        defer arena.free(escaped);
        return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ src[0..after_q], escaped, src[end_q..] });
    }
    return appendMetaInline(arena, src, name, value);
}

fn appendMetaInline(
    arena: std.mem.Allocator,
    src: []const u8,
    name: []const u8,
    value: []const u8,
) ![]u8 {
    const escaped = try xmlEscape(arena, value);
    defer arena.free(escaped);
    const tag = try std.fmt.allocPrint(arena, "<meta name=\"{s}\" content=\"{s}\"/>", .{ name, escaped });
    defer arena.free(tag);
    return insertBeforeCloseMetadata(arena, src, tag);
}

fn appendInMetadata(
    arena: std.mem.Allocator,
    src: []const u8,
    tag_name: []const u8,
    value: []const u8,
) ![]u8 {
    const escaped = try xmlEscape(arena, value);
    defer arena.free(escaped);
    const piece = try std.fmt.allocPrint(arena, "<{s}>{s}</{s}>", .{ tag_name, escaped, tag_name });
    defer arena.free(piece);
    return insertBeforeCloseMetadata(arena, src, piece);
}

fn insertBeforeCloseMetadata(arena: std.mem.Allocator, src: []const u8, fragment: []const u8) ![]u8 {
    const pos = std.mem.indexOf(u8, src, "</metadata>") orelse return arena.dupe(u8, src);
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ src[0..pos], fragment, src[pos..] });
}

fn xmlEscape(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    for (s) |ch| switch (ch) {
        '&' => try buf.appendSlice(arena, "&amp;"),
        '<' => try buf.appendSlice(arena, "&lt;"),
        '>' => try buf.appendSlice(arena, "&gt;"),
        '"' => try buf.appendSlice(arena, "&quot;"),
        '\'' => try buf.appendSlice(arena, "&apos;"),
        else => try buf.append(arena, ch),
    };
    return buf.toOwnedSlice(arena);
}

// ---- Tests --------------------------------------------------------------

test "replaceElementText overwrites existing text" {
    const alloc = std.testing.allocator;
    const src =
        "<package><metadata><dc:title>Old</dc:title><dc:creator>X</dc:creator></metadata></package>";
    const out = try replaceElementText(alloc, src, "dc:title", "New");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:title>New</dc:title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Old") == null);
}

test "replaceElementText appends when missing" {
    const alloc = std.testing.allocator;
    const src = "<package><metadata></metadata></package>";
    const out = try replaceElementText(alloc, src, "dc:title", "Brand New");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<dc:title>Brand New</dc:title></metadata>") != null);
}

test "upsertMeta updates existing meta content attribute" {
    const alloc = std.testing.allocator;
    const src = "<metadata><meta name=\"calibre:series\" content=\"Old\"/></metadata>";
    const out = try upsertMeta(alloc, src, "calibre:series", "Stormlight");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "content=\"Stormlight\"") != null);
}

test "xmlEscape handles special chars" {
    const alloc = std.testing.allocator;
    const out = try xmlEscape(alloc, "Tolkien & Sons <Press>");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Tolkien &amp; Sons &lt;Press&gt;", out);
}
