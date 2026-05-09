//! `booktool scan DIR` — walk DIR, hash files, ingest metadata into catalog.
//! Stub: walks the tree and prints what it would ingest. Catalog write
//! integration follows once the repo layer is filled in.

const std = @import("std");
const cli = @import("../cli.zig");
const format_mod = @import("../formats/format.zig");
const hash_util = @import("../util/hash.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: booktool scan DIR\n", .{});
        return 1;
    }
    const dir_path = args[0];

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(ctx.io, dir_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("cannot open {s}: {s}\n", .{ dir_path, @errorName(err) });
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
        const fmt = @import("../core/metadata.zig").Format.fromExtension(ext[1..]);
        if (fmt == .unknown) continue;

        const full_path = try std.fs.path.join(ctx.arena, &.{ dir_path, entry.path });
        var hex_buf: [hash_util.HEX_LEN]u8 = undefined;
        const sha = hash_util.fileSha256Hex(ctx.io, full_path, &hex_buf) catch |err| {
            try ctx.stderr.print("hash failed for {s}: {s}\n", .{ full_path, @errorName(err) });
            continue;
        };
        try ctx.stdout.print("{s}  {s}  {s}\n", .{ sha[0..12], @tagName(fmt), full_path });
        count += 1;
    }

    try ctx.stdout.print("scanned {d} files\n", .{count});
    return 0;
}
