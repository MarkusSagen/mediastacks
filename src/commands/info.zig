//! `booktool info FILE` — print embedded metadata of one ebook.

const std = @import("std");
const cli = @import("../cli.zig");
const format_mod = @import("../formats/format.zig");
const format_registry = @import("../formats/registry.zig");
const meta = @import("../core/metadata.zig");
const drm = @import("../core/drm.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: booktool info FILE\n", .{});
        return 1;
    }
    const path = args[0];

    // Detect DRM up front so we can report it even when a protected book's
    // metadata can't be read.
    const scheme = drm.detectEbook(ctx.arena, path);

    const fmt = format_mod.detect(ctx.io, path) catch |err| {
        if (scheme != .none) {
            try ctx.stdout.print("Path:        {s}\nDRM:         {s}\n", .{ path, drm.label(scheme) });
            return 0;
        }
        try ctx.stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };

    const h = format_registry.forFormat(fmt) orelse {
        try ctx.stderr.print("info not supported for {s}\n", .{@tagName(fmt)});
        return 2;
    };
    const md: meta.BookMetadata = h.readMetadata(ctx.arena, ctx.io, path) catch |err| {
        if (scheme != .none) {
            try ctx.stdout.print("Path:        {s}\nFormat:      {s}\nDRM:         {s}\n", .{ path, @tagName(fmt), drm.label(scheme) });
            return 0;
        }
        return err;
    };

    try printMetadata(ctx.stdout, path, fmt, md);
    if (scheme != .none) try ctx.stdout.print("DRM:         {s}\n", .{drm.label(scheme)});
    return 0;
}

fn printMetadata(w: *std.Io.Writer, path: []const u8, fmt: meta.Format, md: meta.BookMetadata) !void {
    try w.print("Path:        {s}\n", .{path});
    try w.print("Format:      {s}\n", .{@tagName(fmt)});
    if (md.title) |t| try w.print("Title:       {s}\n", .{t});
    if (md.authors.len > 0) {
        try w.print("Authors:     ", .{});
        for (md.authors, 0..) |a, i| {
            if (i > 0) try w.writeAll("; ");
            try w.print("{s}", .{a.sort});
        }
        try w.writeAll("\n");
    }
    if (md.series) |s| try w.print("Series:      {s}\n", .{s});
    if (md.series_index) |idx| try w.print("Series #:    {d}\n", .{idx});
    if (md.publisher) |p| try w.print("Publisher:   {s}\n", .{p});
    if (md.published_year) |y| try w.print("Year:        {d}\n", .{y});
    if (md.isbn) |i| try w.print("ISBN:        {s}\n", .{i});
    if (md.language) |l| try w.print("Language:    {s}\n", .{l});
    if (md.cover_path) |c| try w.print("Cover:       {s}\n", .{c});
}
