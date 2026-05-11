//! `booktool find PATH [--glob PATTERN] [--format FMT] [-0]`
//!
//! Discover ebook files in a directory tree without touching the
//! catalog. Filters:
//!   --glob PATTERN  Only files whose path-relative-to-PATH matches.
//!   --format FMT    epub | mobi | azw3 | pdf
//!   -0              NUL-separated output (for xargs -0)
//!
//! Exit status is 0 on success, 1 if no matches found.

const std = @import("std");
const cli = @import("../cli.zig");
const meta = @import("../core/metadata.zig");
const glob = @import("../core/glob.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    var path: ?[]const u8 = null;
    var pattern: ?[]const u8 = null;
    var filter_format: ?meta.Format = null;
    var nul_sep = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--glob") and i + 1 < args.len) {
            i += 1;
            pattern = args[i];
        } else if (std.mem.eql(u8, a, "--format") and i + 1 < args.len) {
            i += 1;
            const f = meta.Format.fromExtension(args[i]);
            if (f == .unknown) {
                try ctx.stderr.print("unknown format: {s}\n", .{args[i]});
                return 1;
            }
            filter_format = f;
        } else if (std.mem.eql(u8, a, "-0") or std.mem.eql(u8, a, "--null")) {
            nul_sep = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try printHelp(ctx.stdout);
            return 0;
        } else if (a.len > 0 and a[0] != '-' and path == null) {
            path = a;
        } else {
            try ctx.stderr.print("unknown argument: {s}\n", .{a});
            return 1;
        }
    }

    const search_path = path orelse {
        try ctx.stderr.print("usage: booktool find PATH [--glob PAT] [--format FMT]\n", .{});
        return 1;
    };

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(ctx.io, search_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("cannot open {s}: {s}\n", .{ search_path, @errorName(err) });
        return 2;
    };
    defer dir.close(ctx.io);

    var walker = try dir.walk(ctx.arena);
    defer walker.deinit();

    var count: u32 = 0;
    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        if (ext.len < 2) continue;
        const fmt = meta.Format.fromExtension(ext[1..]);
        if (fmt == .unknown) continue;
        if (filter_format) |ff| if (fmt != ff) continue;
        if (pattern) |pat| if (!glob.match(pat, entry.path)) continue;

        const full_path = try std.fs.path.join(ctx.arena, &.{ search_path, entry.path });
        if (nul_sep) {
            try ctx.stdout.writeAll(full_path);
            try ctx.stdout.writeAll(&[_]u8{0});
        } else {
            try ctx.stdout.print("{s}\n", .{full_path});
        }
        count += 1;
    }

    if (count == 0) return 1;
    return 0;
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: booktool find PATH [options]
        \\
        \\Walk PATH recursively and print every ebook file. Does not modify
        \\the catalog.
        \\
        \\Options:
        \\  --glob PATTERN   Filter by glob (supports *, **, ?, [abc]). Match
        \\                   is against the path RELATIVE to PATH.
        \\  --format FMT     Only this format (epub, mobi, azw3, pdf).
        \\  -0, --null       NUL-separate output for safe xargs -0.
        \\
        \\Examples:
        \\  booktool find ~/Books
        \\  booktool find . --glob "**/Hobb*" --format mobi
        \\  booktool find . -0 | xargs -0 booktool info
        \\
    );
}
