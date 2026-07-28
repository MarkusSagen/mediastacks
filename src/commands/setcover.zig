//! `booktool set-cover FILE IMAGE` — replace the embedded cover.
//!
//! EPUB writes the bytes back into the archive (via the handler
//! vtable's `writeCover`). MOBI/AZW3 — libmobi has no cover-write
//! API — write a library-side override at
//! `$XDG_DATA_HOME/booktool/covers/<id>.<ext>` instead, which the
//! booktool catalog renders everywhere.

const std = @import("std");
const cli = @import("../cli.zig");
const format_mod = @import("../formats/format.zig");
const catalog_mod = @import("../core/catalog.zig");
const cover_store = @import("../core/cover_store.zig");
const registry = @import("../formats/registry.zig");

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

    const new_image = try readWhole(ctx.arena, image_path);
    const h = registry.forFormat(fmt) orelse {
        try ctx.stderr.print("set-cover: no handler for {s}\n", .{@tagName(fmt)});
        return 2;
    };

    h.writeCover(ctx.arena, ctx.io, book_path, new_image) catch |err| switch (err) {
        error.NotSupported => return setOverrideCover(ctx, book_path, new_image),
        else => {
            try ctx.stderr.print("{s}: {s}\n", .{ book_path, @errorName(err) });
            return 2;
        },
    };

    if (catalog_mod.defaultPath(ctx.arena, ctx.env)) |catalog_path| {
        if (catalog_mod.Catalog.open(catalog_path)) |cat_v| {
            var cat = cat_v;
            defer cat.close();
            if (cat.getBookByPath(ctx.arena, book_path) catch null) |book| {
                cover_store.write(ctx.arena, ctx.env, book.id, new_image) catch {};
            }
        } else |_| {}
    } else |_| {}

    try ctx.stdout.print("replaced cover in {s}\n", .{book_path});
    return 0;
}

/// Write a library-side cover override for the book at `book_path`.
/// Used when the format's handler returns `error.NotSupported`
/// (MOBI/AZW3/PDF/comics). Requires the file to have been scanned
/// first so we have a stable book id to key off of.
fn setOverrideCover(ctx: cli.Context, book_path: []const u8, new_image: []const u8) !u8 {
    const catalog_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = catalog_mod.Catalog.open(catalog_path) catch |err| {
        try ctx.stderr.print("cannot open catalog ({s}): {s}\n", .{ catalog_path, @errorName(err) });
        return 2;
    };
    defer cat.close();

    const book = (try cat.getBookByPath(ctx.arena, book_path)) orelse {
        try ctx.stderr.print(
            "no catalog row for {s}.\n  Run `booktool scan` on its directory first so the cover override\n  can be stored against a stable book id.\n",
            .{book_path},
        );
        return 2;
    };

    cover_store.write(ctx.arena, ctx.env, book.id, new_image) catch |err| {
        try ctx.stderr.print("override write failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    const override_dir = try cover_store.dirPath(ctx.arena, ctx.env);
    try ctx.stdout.print(
        "cover override written to {s}/{d}.{s}\n" ++
            "note: this format doesn't support in-file cover editing.\n" ++
            "      booktool will show this cover everywhere, but {s} is unchanged.\n" ++
            "      Run `booktool convert {s} --to epub` to bake it in.\n",
        .{ override_dir, book.id, cover_store.sniff(new_image).asString(), book_path, book_path },
    );
    return 0;
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
