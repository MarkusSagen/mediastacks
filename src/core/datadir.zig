//! One-time migration of the pre-rename data directories. The project was once
//! named "stacks" and stored its config/catalog/covers/cache under a `stacks/`
//! directory in each XDG base. After the rename to "mediastacks", those live
//! under `mediastacks/`. On startup we rename each legacy `stacks` dir to
//! `mediastacks` when the old exists and the new does not — best-effort, silent,
//! and idempotent (a no-op once migrated or on a fresh install).

const std = @import("std");

const Base = struct { xdg: []const u8, fallback: []const u8 };
const bases = [_]Base{
    .{ .xdg = "XDG_CONFIG_HOME", .fallback = ".config" },
    .{ .xdg = "XDG_DATA_HOME", .fallback = ".local/share" },
    .{ .xdg = "XDG_CACHE_HOME", .fallback = ".cache" },
};

pub fn migrateLegacyDirs(alloc: std.mem.Allocator, env: *std.process.Environ.Map) void {
    const home = env.get("HOME");
    for (bases) |b| {
        const base = env.get(b.xdg) orelse blk: {
            const h = home orelse continue;
            break :blk std.fs.path.join(alloc, &.{ h, b.fallback }) catch continue;
        };
        const old = std.fs.path.joinZ(alloc, &.{ base, "stacks" }) catch continue;
        const new = std.fs.path.joinZ(alloc, &.{ base, "mediastacks" }) catch continue;
        if (std.c.access(old.ptr, 0) != 0) continue; // legacy dir absent → nothing to do
        if (std.c.access(new.ptr, 0) == 0) continue; // new dir already exists → don't clobber
        _ = std.c.rename(old.ptr, new.ptr); // best-effort; ignore failure
    }
}
