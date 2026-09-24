//! Demo sandbox seeder. Creates throwaway synthetic media under a temp `root`
//! so the web app's REAL Organize/Library/detail/play/enrich flows can be tried
//! without touching any of the user's files. Reseeded (wiped) on each call.
//!
//! `activate` also points the XDG env vars at the sandbox so the catalog,
//! config, cache, and undo journals all live under `root` — full isolation.

const std = @import("std");

pub const Seeded = struct {
    root: []const u8,
    library: []const u8, // demo library_root, pre-organized
    downloads: []const u8, // a messy folder to Organize
};

fn appendU32le(alloc: std.mem.Allocator, b: *std.ArrayList(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try b.appendSlice(alloc, &buf);
}
fn appendU16le(alloc: std.mem.Allocator, b: *std.ArrayList(u8), v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try b.appendSlice(alloc, &buf);
}

/// A minimal valid PCM WAV (mono, 8 kHz, 16-bit, ~0.1s of silence) so the
/// inline `<audio>` player genuinely plays something in the demo.
fn wavBytes(alloc: std.mem.Allocator) ![]u8 {
    const sample_rate: u32 = 8000;
    const data_len: u32 = 1600; // 0.1s of 16-bit mono silence
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(alloc);
    try b.appendSlice(alloc, "RIFF");
    try appendU32le(alloc, &b, 36 + data_len);
    try b.appendSlice(alloc, "WAVE");
    try b.appendSlice(alloc, "fmt ");
    try appendU32le(alloc, &b, 16); // PCM fmt chunk size
    try appendU16le(alloc, &b, 1); // audio format = PCM
    try appendU16le(alloc, &b, 1); // channels = mono
    try appendU32le(alloc, &b, sample_rate);
    try appendU32le(alloc, &b, sample_rate * 2); // byte rate (mono 16-bit)
    try appendU16le(alloc, &b, 2); // block align
    try appendU16le(alloc, &b, 16); // bits per sample
    try b.appendSlice(alloc, "data");
    try appendU32le(alloc, &b, data_len);
    try b.appendNTimes(alloc, 0, data_len);
    return b.toOwnedSlice(alloc);
}

fn mkfile(alloc: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, base: []const u8, rel: []const u8, bytes: []const u8) !void {
    const full = try std.fs.path.join(alloc, &.{ base, rel });
    if (std.fs.path.dirname(full)) |d| try cwd.createDirPath(io, d);
    try cwd.writeFile(io, .{ .sub_path = full, .data = bytes });
}

/// Wipe + reseed the demo sandbox under `root`. Returns library + downloads paths.
pub fn seed(alloc: std.mem.Allocator, io: std.Io, root: []const u8) !Seeded {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, root) catch {};
    const library = try std.fs.path.join(alloc, &.{ root, "library" });
    const downloads = try std.fs.path.join(alloc, &.{ root, "downloads" });
    const wav = try wavBytes(alloc);

    // A few pre-organized items so Library / detail / play are explorable at once.
    try mkfile(alloc, io, cwd, library, "Movies/Blade Runner 2049 (2017) [tmdbid-335984]/Blade Runner 2049 (2017).mp4", "demo");
    try mkfile(alloc, io, cwd, library, "Shows/Severance/Season 01/Severance - S01E01.mp4", "demo");
    try mkfile(alloc, io, cwd, library, "Music/Daft Punk/Discovery (2001)/01 One More Time.wav", wav);
    try mkfile(alloc, io, cwd, library, "Music/Daft Punk/Discovery (2001)/02 Aerodynamic.wav", wav);

    // A messy download folder to run Organize → Preview → Apply on.
    try mkfile(alloc, io, cwd, downloads, "arcane.s01e01.1080p.web.h264-x.mkv", "demo");
    try mkfile(alloc, io, cwd, downloads, "arcane.s01e02.1080p.web.h264-x.mkv", "demo");
    try mkfile(alloc, io, cwd, downloads, "Dune.2021.1080p.WEBRip.x264-GRP.mkv", "demo");

    return .{ .root = root, .library = library, .downloads = downloads };
}

/// The sandbox root: `$XDG_CACHE_HOME/mediastacks/demo` else `~/.cache/mediastacks/demo`.
pub fn rootPath(alloc: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CACHE_HOME")) |xdg| return std.fs.path.join(alloc, &.{ xdg, "mediastacks", "demo" });
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(alloc, &.{ home, ".cache", "mediastacks", "demo" });
}

/// Seed the sandbox AND point XDG_{DATA,CONFIG,CACHE}_HOME at it, so the
/// catalog, config, and undo journals are all sandboxed. Computes the root
/// from the current env BEFORE overriding it.
pub fn activate(alloc: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !Seeded {
    const root = try rootPath(alloc, env);
    const s = try seed(alloc, io, root);
    try env.put("XDG_DATA_HOME", try std.fs.path.join(alloc, &.{ root, "data" }));
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(alloc, &.{ root, "cfg" }));
    try env.put("XDG_CACHE_HOME", try std.fs.path.join(alloc, &.{ root, "cache" }));
    return s;
}

test "seed creates the library + downloads tree with a valid WAV" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    var rb: [96]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/mediastacks-demo-test-{d}", .{std.c.getpid()});
    defer cwd.deleteTree(io, root) catch {};

    const s = try seed(a, io, root);

    // library items exist
    var f1 = try cwd.openFile(io, try std.fs.path.join(a, &.{ s.library, "Movies/Blade Runner 2049 (2017) [tmdbid-335984]/Blade Runner 2049 (2017).mp4" }), .{});
    f1.close(io);
    // the music track is a real WAV (starts with "RIFF")
    var wf = try cwd.openFile(io, try std.fs.path.join(a, &.{ s.library, "Music/Daft Punk/Discovery (2001)/01 One More Time.wav" }), .{});
    defer wf.close(io);
    var hdr: [4]u8 = undefined;
    _ = try wf.readPositionalAll(io, &hdr, 0);
    try t.expectEqualStrings("RIFF", &hdr);
    // downloads to organize exist
    var d1 = try cwd.openFile(io, try std.fs.path.join(a, &.{ s.downloads, "arcane.s01e01.1080p.web.h264-x.mkv" }), .{});
    d1.close(io);
}
