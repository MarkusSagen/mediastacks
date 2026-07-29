//! Organizer configuration: the library root and per-kind naming
//! templates. Read from `$XDG_CONFIG_HOME/booktool/config.toml` as simple
//! `key = value` lines; a missing file yields all defaults.

const std = @import("std");

pub const DEFAULT_ROOT = "~/Media";
pub const DEFAULT_TV = "TV/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}";
pub const DEFAULT_MOVIE = "Movies/{title} ({year})/{title} ({year}).{ext}";

pub const Config = struct {
    library_root: []const u8,
    tv_template: []const u8,
    movie_template: []const u8,
};

pub fn freeConfig(alloc: std.mem.Allocator, cfg: Config) void {
    alloc.free(cfg.library_root);
    alloc.free(cfg.tv_template);
    alloc.free(cfg.movie_template);
}

fn dupeDefaults(alloc: std.mem.Allocator) !Config {
    return .{
        .library_root = try alloc.dupe(u8, DEFAULT_ROOT),
        .tv_template = try alloc.dupe(u8, DEFAULT_TV),
        .movie_template = try alloc.dupe(u8, DEFAULT_MOVIE),
    };
}

fn setKey(alloc: std.mem.Allocator, slot: *[]const u8, val: []const u8) !void {
    alloc.free(slot.*);
    slot.* = try alloc.dupe(u8, val);
}

/// Parse `key = value` config text over the defaults. Owned by `alloc`.
pub fn parseLines(alloc: std.mem.Allocator, text: []const u8) !Config {
    var cfg = try dupeDefaults(alloc);
    errdefer freeConfig(alloc, cfg);

    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len == 0) continue;

        if (std.mem.eql(u8, key, "library_root")) {
            try setKey(alloc, &cfg.library_root, val);
        } else if (std.mem.eql(u8, key, "tv_template")) {
            try setKey(alloc, &cfg.tv_template, val);
        } else if (std.mem.eql(u8, key, "movie_template")) {
            try setKey(alloc, &cfg.movie_template, val);
        }
    }
    return cfg;
}

fn configPath(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(alloc, &.{ xdg, "booktool", "config.toml" });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".config", "booktool", "config.toml" });
}

fn expandTilde(alloc: std.mem.Allocator, env: *std.process.Environ.Map, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return alloc.dupe(u8, path);
    const home = env.get("HOME") orelse return alloc.dupe(u8, path);
    const rest = if (path.len >= 2 and path[1] == '/') path[2..] else path[1..];
    return std.fs.path.join(alloc, &.{ home, rest });
}

fn readFileZ(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return null;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        try buf.appendSlice(alloc, chunk[0..n]);
    }
    return try buf.toOwnedSlice(alloc);
}

/// Load config from disk (or defaults if absent), with `~` expanded in
/// `library_root`. Owned by `alloc`.
pub fn load(alloc: std.mem.Allocator, env: *std.process.Environ.Map) !Config {
    const path = try configPath(alloc, env);
    defer alloc.free(path);

    const text = (try readFileZ(alloc, path)) orelse try alloc.dupe(u8, "");
    defer alloc.free(text);

    var cfg = try parseLines(alloc, text);
    const expanded = try expandTilde(alloc, env, cfg.library_root);
    alloc.free(cfg.library_root);
    cfg.library_root = expanded;
    return cfg;
}

const t = std.testing;

test "parseLines overrides only provided keys" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\# my config
        \\library_root = /Volumes/Media
        \\tv_template = TV/{series}/{title}.{ext}
    );
    defer freeConfig(a, cfg);
    try t.expectEqualStrings("/Volumes/Media", cfg.library_root);
    try t.expectEqualStrings("TV/{series}/{title}.{ext}", cfg.tv_template);
    try t.expectEqualStrings(DEFAULT_MOVIE, cfg.movie_template);
}

test "parseLines with empty text yields defaults" {
    const a = t.allocator;
    const cfg = try parseLines(a, "");
    defer freeConfig(a, cfg);
    try t.expectEqualStrings(DEFAULT_ROOT, cfg.library_root);
    try t.expectEqualStrings(DEFAULT_TV, cfg.tv_template);
}
