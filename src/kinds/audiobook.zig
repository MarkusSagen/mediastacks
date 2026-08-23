//! Build a single chaptered `.m4b` audiobook from a list of audio chapter
//! files, via ffmpeg (concat demuxer + an ffmetadata chapter list + optional
//! embedded cover). Re-encodes to AAC (m4b = MP4/AAC). Pure orchestration —
//! the actual work is ffmpeg; we just assemble its inputs and invoke it.

const std = @import("std");
const exec = @import("../util/exec.zig");

pub const Chapter = struct {
    path: []const u8, // absolute source path
    title: []const u8, // chapter title
    duration_ms: u64, // measured length
};

pub const Meta = struct {
    book: []const u8,
    author: []const u8,
    cover_path: ?[]const u8 = null, // JPEG/PNG to embed as front cover
    bitrate: []const u8 = "128k",
};

pub const Error = error{ FfmpegMissing, FfmpegFailed, WriteFailed, OutOfMemory };

/// Measure a file's duration in milliseconds via ffprobe; null if unavailable.
pub fn probeDurationMs(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?u64 {
    const argv = [_][]const u8{ "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path };
    const r = exec.runCaptureStdout(alloc, io, &argv, 64 * 1024) catch return null;
    defer alloc.free(r.stdout);
    if (r.exit_code != 0) return null;
    const s = std.mem.trim(u8, r.stdout, " \t\r\n");
    const secs = std.fmt.parseFloat(f64, s) catch return null;
    if (secs <= 0) return null;
    return @intFromFloat(secs * 1000.0);
}

/// The ffmetadata document: global title/artist + one [CHAPTER] per file with
/// cumulative millisecond START/END. Owned by `alloc`.
pub fn buildFfmetadata(alloc: std.mem.Allocator, chapters: []const Chapter, meta: Meta) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, ";FFMETADATA1\n");
    try appendKv(alloc, &out, "title", meta.book);
    try appendKv(alloc, &out, "artist", meta.author);
    try appendKv(alloc, &out, "album", meta.book);
    var start: u64 = 0;
    for (chapters) |ch| {
        const end = start + ch.duration_ms;
        try out.appendSlice(alloc, "[CHAPTER]\nTIMEBASE=1/1000\n");
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "START={d}\nEND={d}\n", .{ start, end }));
        try appendKv(alloc, &out, "title", ch.title);
        start = end;
    }
    return out.toOwnedSlice(alloc);
}

/// ffmetadata escapes `= ; # \` and newlines with a backslash.
fn appendKv(alloc: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, val: []const u8) !void {
    try out.appendSlice(alloc, key);
    try out.append(alloc, '=');
    for (val) |c| {
        switch (c) {
            '=', ';', '#', '\\' => try out.append(alloc, '\\'),
            '\n' => {
                try out.appendSlice(alloc, "\\\n");
                continue;
            },
            else => {},
        }
        try out.append(alloc, c);
    }
    try out.append(alloc, '\n');
}

/// The concat-demuxer list: `file '<path>'` per line, single-quotes escaped.
pub fn buildConcatList(alloc: std.mem.Allocator, chapters: []const Chapter) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (chapters) |ch| {
        try out.appendSlice(alloc, "file '");
        for (ch.path) |c| {
            if (c == '\'') {
                try out.appendSlice(alloc, "'\\''");
            } else {
                try out.append(alloc, c);
            }
        }
        try out.appendSlice(alloc, "'\n");
    }
    return out.toOwnedSlice(alloc);
}

fn writeFileZ(path: []const u8, bytes: []const u8) !void {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return Error.WriteFailed;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return Error.WriteFailed;
    const fp = std.c.fopen(pzp.ptr, "wb") orelse return Error.WriteFailed;
    defer _ = std.c.fclose(fp);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) return Error.WriteFailed;
}

/// Assemble `chapters` into a chaptered `.m4b` at `out_path` (parent dirs must
/// exist). Writes a temp file then atomically renames. Keeps the sources.
pub fn makeM4b(alloc: std.mem.Allocator, io: std.Io, chapters: []const Chapter, out_path: []const u8, meta: Meta) Error!void {
    if (!exec.isExecutableInPath(alloc, io, "ffmpeg")) return Error.FfmpegMissing;
    if (chapters.len == 0) return Error.FfmpegFailed;

    const list = buildConcatList(alloc, chapters) catch return Error.OutOfMemory;
    const ff = buildFfmetadata(alloc, chapters, meta) catch return Error.OutOfMemory;
    const list_path = std.fmt.allocPrint(alloc, "{s}.list.txt", .{out_path}) catch return Error.OutOfMemory;
    const meta_path = std.fmt.allocPrint(alloc, "{s}.ffmeta", .{out_path}) catch return Error.OutOfMemory;
    const tmp_out = std.fmt.allocPrint(alloc, "{s}.tmp", .{out_path}) catch return Error.OutOfMemory;
    try writeFileZ(list_path, list);
    try writeFileZ(meta_path, ff);
    defer {
        unlinkZ(list_path);
        unlinkZ(meta_path);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(al: std.mem.Allocator, l: *std.ArrayList([]const u8), s: []const u8) void {
            l.append(al, s) catch {};
        }
    }.f;
    add(alloc, &argv, "ffmpeg");
    add(alloc, &argv, "-v");
    add(alloc, &argv, "error");
    add(alloc, &argv, "-f");
    add(alloc, &argv, "concat");
    add(alloc, &argv, "-safe");
    add(alloc, &argv, "0");
    add(alloc, &argv, "-i");
    add(alloc, &argv, list_path);
    add(alloc, &argv, "-i");
    add(alloc, &argv, meta_path);
    if (meta.cover_path) |cov| {
        add(alloc, &argv, "-i");
        add(alloc, &argv, cov);
    }
    add(alloc, &argv, "-map");
    add(alloc, &argv, "0:a");
    if (meta.cover_path != null) {
        add(alloc, &argv, "-map");
        add(alloc, &argv, "2:v");
    }
    add(alloc, &argv, "-map_metadata");
    add(alloc, &argv, "1");
    add(alloc, &argv, "-map_chapters");
    add(alloc, &argv, "1");
    add(alloc, &argv, "-c:a");
    add(alloc, &argv, "aac");
    add(alloc, &argv, "-b:a");
    add(alloc, &argv, meta.bitrate);
    if (meta.cover_path != null) {
        add(alloc, &argv, "-c:v");
        add(alloc, &argv, "copy");
        add(alloc, &argv, "-disposition:v");
        add(alloc, &argv, "attached_pic");
    }
    add(alloc, &argv, "-f");
    add(alloc, &argv, "mp4");
    add(alloc, &argv, "-y");
    add(alloc, &argv, tmp_out);

    const r = exec.runCaptureStdout(alloc, io, argv.items, 1024) catch return Error.FfmpegFailed;
    alloc.free(r.stdout);
    if (r.exit_code != 0) {
        unlinkZ(tmp_out);
        return Error.FfmpegFailed;
    }
    // Atomic swap into place.
    var tz: [4096]u8 = undefined;
    var oz: [4096]u8 = undefined;
    if (tmp_out.len >= tz.len or out_path.len >= oz.len) return Error.WriteFailed;
    const tzp = std.fmt.bufPrintZ(&tz, "{s}", .{tmp_out}) catch return Error.WriteFailed;
    const ozp = std.fmt.bufPrintZ(&oz, "{s}", .{out_path}) catch return Error.WriteFailed;
    if (std.c.rename(tzp.ptr, ozp.ptr) != 0) {
        unlinkZ(tmp_out);
        return Error.WriteFailed;
    }
}

fn unlinkZ(path: []const u8) void {
    var pz: [4096]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    _ = std.c.unlink(p.ptr);
}

const t = std.testing;

test "buildFfmetadata emits cumulative chapters" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const chs = [_]Chapter{
        .{ .path = "/x/01.mp3", .title = "Prologue", .duration_ms = 1000 },
        .{ .path = "/x/02.mp3", .title = "Chapter 1", .duration_ms = 2000 },
    };
    const s = try buildFfmetadata(a, &chs, .{ .book = "1984", .author = "George Orwell" });
    try t.expect(std.mem.startsWith(u8, s, ";FFMETADATA1\n"));
    try t.expect(std.mem.indexOf(u8, s, "title=1984") != null);
    try t.expect(std.mem.indexOf(u8, s, "START=0\nEND=1000") != null);
    try t.expect(std.mem.indexOf(u8, s, "START=1000\nEND=3000") != null);
    try t.expect(std.mem.indexOf(u8, s, "title=Chapter 1") != null);
}

test "buildConcatList escapes single quotes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const chs = [_]Chapter{.{ .path = "/x/it's a book.mp3", .title = "T", .duration_ms = 1 }};
    const s = try buildConcatList(a, &chs);
    try t.expectEqualStrings("file '/x/it'\\''s a book.mp3'\n", s);
}
