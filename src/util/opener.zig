//! Per-OS "reveal in file manager" / "open in default app" argv builder.
//!
//!   macOS   → `open -R <path>` (reveal) · `open <path>` (launch)
//!   Windows → `explorer /select,<path>` (reveal) · `explorer <path>` (launch)
//!   Linux   → `xdg-open <dir>` (reveal → containing folder) · `xdg-open <path>`
//!
//! When MEDIASTACKS_OPEN_CMD is set (used by tests to record calls instead of
//! launching anything), the macOS-style `{cmd, -R, path}` / `{cmd, path}` form
//! is used regardless of OS so the recorder keeps working.

const std = @import("std");
const builtin = @import("builtin");

/// Build the argv. `abs` is a native-looking absolute path (with `/`); on
/// Windows the separators are flipped to `\` for the shell command.
pub fn argv(arena: std.mem.Allocator, env: *std.process.Environ.Map, reveal: bool, abs: []const u8) ![]const []const u8 {
    var a: std.ArrayList([]const u8) = .empty;
    if (env.get("MEDIASTACKS_OPEN_CMD")) |cmd| {
        try a.append(arena, cmd);
        if (reveal) try a.append(arena, "-R");
        try a.append(arena, abs);
        return a.toOwnedSlice(arena);
    }
    switch (builtin.os.tag) {
        .macos => {
            try a.append(arena, "open");
            if (reveal) try a.append(arena, "-R");
            try a.append(arena, abs);
        },
        .windows => {
            const win = try toBackslash(arena, abs);
            try a.append(arena, "explorer");
            try a.append(arena, if (reveal)
                try std.fmt.allocPrint(arena, "/select,{s}", .{win})
            else
                win);
        },
        else => {
            try a.append(arena, "xdg-open");
            try a.append(arena, if (reveal) (std.fs.path.dirname(abs) orelse abs) else abs);
        },
    }
    return a.toOwnedSlice(arena);
}

/// Whether a non-zero exit code from the opener means real failure. Windows
/// `explorer` returns 1 even on success, so its exit code is not meaningful.
pub fn exitIsMeaningful() bool {
    return builtin.os.tag != .windows;
}

fn toBackslash(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return out;
}

test "argv: MEDIASTACKS_OPEN_CMD override keeps the recorder form" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("MEDIASTACKS_OPEN_CMD", "/tmp/rec.sh");
    const r = try argv(a, &env, true, "/lib/Movies/X/X.mkv");
    try t.expectEqual(@as(usize, 3), r.len);
    try t.expectEqualStrings("/tmp/rec.sh", r[0]);
    try t.expectEqualStrings("-R", r[1]);
    try t.expectEqualStrings("/lib/Movies/X/X.mkv", r[2]);
}

test "argv: native opener per OS (reveal + launch)" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    const reveal = try argv(a, &env, true, "/lib/M/X.mkv");
    const launch = try argv(a, &env, false, "/lib/M/X.mkv");
    switch (builtin.os.tag) {
        .macos => {
            try t.expectEqualStrings("open", reveal[0]);
            try t.expectEqualStrings("-R", reveal[1]);
            try t.expectEqualStrings("open", launch[0]);
            try t.expectEqual(@as(usize, 2), launch.len);
        },
        .windows => {
            try t.expectEqualStrings("explorer", reveal[0]);
            try t.expectEqualStrings("/select,\\lib\\M\\X.mkv", reveal[1]);
            try t.expectEqualStrings("\\lib\\M\\X.mkv", launch[1]);
        },
        else => {
            try t.expectEqualStrings("xdg-open", reveal[0]);
            try t.expectEqualStrings("/lib/M", reveal[1]); // containing dir
            try t.expectEqualStrings("/lib/M/X.mkv", launch[1]);
        },
    }
}
