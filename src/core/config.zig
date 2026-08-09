//! Organizer configuration: the library root and per-kind naming
//! templates. Read from `$XDG_CONFIG_HOME/stacks/config.toml` as simple
//! `key = value` lines; a missing file yields all defaults.

const std = @import("std");

// Jellyfin-style defaults (also parse cleanly in Plex/Kodi):
//   Shows/Series/Season 01/Series S01E01 - Title.mkv
//   Movies/Film (2009)/Film (2009).mkv
// Note: the Season folder deliberately omits the series name (Jellyfin
// mis-detects otherwise), and template `sanitize` strips the characters
// Jellyfin reserves (< > : " / \ | ? *).
pub const DEFAULT_ROOT = "~/Media";
pub const DEFAULT_TV = "Shows/{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title}.{ext}";
pub const DEFAULT_MOVIE = "Movies/{title} ({year})/{title} ({year}).{ext}";
pub const DEFAULT_MUSIC = "Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}";

pub const Config = struct {
    library_root: []const u8,
    tv_template: []const u8,
    movie_template: []const u8,
    music_template: []const u8,
};

pub fn freeConfig(alloc: std.mem.Allocator, cfg: Config) void {
    alloc.free(cfg.library_root);
    alloc.free(cfg.tv_template);
    alloc.free(cfg.movie_template);
    alloc.free(cfg.music_template);
}

const Preset = struct { tv: []const u8, movie: []const u8, music: []const u8 };

/// Built-in naming presets. jellyfin is the default. (All presets share the
/// same music layout for now.)
fn presetByName(name: []const u8) ?Preset {
    if (std.mem.eql(u8, name, "jellyfin")) return .{ .tv = DEFAULT_TV, .movie = DEFAULT_MOVIE, .music = DEFAULT_MUSIC };
    if (std.mem.eql(u8, name, "plex")) return .{
        .tv = "TV Shows/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}",
        .movie = DEFAULT_MOVIE,
        .music = DEFAULT_MUSIC,
    };
    if (std.mem.eql(u8, name, "kodi")) return .{
        .tv = "TV Shows/{series}/Season {season:02}/{series} S{season:02}E{episode:02} - {title}.{ext}",
        .movie = DEFAULT_MOVIE,
        .music = DEFAULT_MUSIC,
    };
    return null;
}

/// Resolve one media type's template. Highest wins: explicit template →
/// per-type preset → global preset → jellyfin default.
fn resolve(comptime field: []const u8, explicit: ?[]const u8, per_type: ?[]const u8, global: ?[]const u8) ![]const u8 {
    if (explicit) |x| return x;
    if (per_type) |name| return @field(presetByName(name) orelse return error.UnknownPreset, field);
    if (global) |name| return @field(presetByName(name) orelse return error.UnknownPreset, field);
    return @field(presetByName("jellyfin").?, field);
}

/// Parse `key = value` config text, resolving presets. Owned by `alloc`.
/// Unknown preset name → `error.UnknownPreset`.
pub fn parseLines(alloc: std.mem.Allocator, text: []const u8) !Config {
    // Raw values borrow from `text` (valid for the duration of this call).
    var library_root: ?[]const u8 = null;
    var preset: ?[]const u8 = null;
    var tv_preset: ?[]const u8 = null;
    var movie_preset: ?[]const u8 = null;
    var tv_template: ?[]const u8 = null;
    var movie_template: ?[]const u8 = null;
    var music_preset: ?[]const u8 = null;
    var music_template: ?[]const u8 = null;

    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len == 0) continue;

        if (std.mem.eql(u8, key, "library_root")) library_root = val
        else if (std.mem.eql(u8, key, "preset")) preset = val
        else if (std.mem.eql(u8, key, "tv_preset")) tv_preset = val
        else if (std.mem.eql(u8, key, "movie_preset")) movie_preset = val
        else if (std.mem.eql(u8, key, "tv_template")) tv_template = val
        else if (std.mem.eql(u8, key, "movie_template")) movie_template = val
        else if (std.mem.eql(u8, key, "music_preset")) music_preset = val
        else if (std.mem.eql(u8, key, "music_template")) music_template = val;
    }

    const tv = try resolve("tv", tv_template, tv_preset, preset);
    const movie = try resolve("movie", movie_template, movie_preset, preset);
    const music = try resolve("music", music_template, music_preset, preset);
    const root = library_root orelse DEFAULT_ROOT;

    const lr = try alloc.dupe(u8, root);
    errdefer alloc.free(lr);
    const tt = try alloc.dupe(u8, tv);
    errdefer alloc.free(tt);
    const mt = try alloc.dupe(u8, movie);
    errdefer alloc.free(mt);
    const mu = try alloc.dupe(u8, music);
    return .{ .library_root = lr, .tv_template = tt, .movie_template = mt, .music_template = mu };
}

fn configPath(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(alloc, &.{ xdg, "stacks", "config.toml" });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".config", "stacks", "config.toml" });
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
    try t.expectEqualStrings(DEFAULT_MUSIC, cfg.music_template);
}

test "global preset resolves both; per-type overrides" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\preset = plex
        \\movie_preset = kodi
    );
    defer freeConfig(a, cfg);
    try t.expect(std.mem.startsWith(u8, cfg.tv_template, "TV Shows/")); // plex tv
    try t.expect(std.mem.indexOf(u8, cfg.tv_template, " - S") != null); // plex dash form
    try t.expect(std.mem.startsWith(u8, cfg.movie_template, "Movies/")); // kodi movie
}

test "explicit template overrides preset" {
    const a = t.allocator;
    const cfg = try parseLines(a,
        \\preset = plex
        \\tv_template = X/{series}.{ext}
    );
    defer freeConfig(a, cfg);
    try t.expectEqualStrings("X/{series}.{ext}", cfg.tv_template);
}

test "unknown preset errors" {
    try t.expectError(error.UnknownPreset, parseLines(t.allocator, "preset = nope"));
}
