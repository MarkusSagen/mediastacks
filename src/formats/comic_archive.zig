//! Shared comic-archive logic.
//!
//! All four comic formats (CBZ/CBR/CB7/CBT) need the same two things:
//!   1. Locate `ComicInfo.xml` inside the archive (case-insensitive,
//!      may be nested).
//!   2. Pick the cover — first image entry sorted lexicographically.
//!
//! What differs is *how* bytes come out of the archive: CBZ uses
//! miniz in-process; CBR/CB7/CBT shell out to the `7zz` (sevenzip)
//! binary. This module abstracts the "list members" + "read one
//! member" pair behind an `ArchiveReader` struct (same pattern as
//! `Provider`), then provides the shared metadata + cover routines
//! that any format can use.
//!
//! Adding a new archive backing = implement `ArchiveReader`. The
//! comic-format logic itself stays single-source.

const std = @import("std");
const meta = @import("../core/metadata.zig");
const cbz_mod = @import("cbz.zig");
const exec = @import("../util/exec.zig");

const log = std.log.scoped(.comic);

pub const Error = error{
    NoCover,
    ExtractFailed,
    ExecutableMissing,
};

/// "I can list and read members of an archive." The two operations
/// the comic handlers need; nothing more. Implementations: miniz for
/// CBZ (see `MinizAdapter` below), `7zz` for CBR/CB7/CBT.
pub const ArchiveReader = struct {
    ctx: *anyopaque,
    /// Returns owned member names (caller frees each + the outer
    /// slice). Order is implementation-defined; callers sort.
    list_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror![]const []const u8,
    /// Returns owned bytes of the named member.
    read_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        member: []const u8,
    ) anyerror![]u8,

    pub fn list(self: ArchiveReader, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.list_fn(self.ctx, allocator);
    }

    pub fn read(self: ArchiveReader, allocator: std.mem.Allocator, member: []const u8) ![]u8 {
        return self.read_fn(self.ctx, allocator, member);
    }
};

/// Look for a `ComicInfo.xml` entry (case-insensitive). Returns an
/// owned name slice, or null when the archive has no ComicInfo.
pub fn findComicInfo(
    reader: ArchiveReader,
    allocator: std.mem.Allocator,
) !?[]u8 {
    const members = try reader.list(allocator);
    defer freeOwned(allocator, members);
    for (members) |name| {
        const basename = std.fs.path.basename(name);
        if (std.ascii.eqlIgnoreCase(basename, "ComicInfo.xml")) {
            return try allocator.dupe(u8, name);
        }
    }
    return null;
}

/// Read the comic-archive metadata: ComicInfo.xml if present (high
/// confidence), else a filename-only stub. Path is passed through so
/// the stub branch knows what to call the book.
pub fn readMetadata(
    reader: ArchiveReader,
    allocator: std.mem.Allocator,
    path: []const u8,
) !meta.BookMetadata {
    if (try findComicInfo(reader, allocator)) |name| {
        defer allocator.free(name);
        if (reader.read(allocator, name)) |bytes| {
            defer allocator.free(bytes);
            return cbz_mod.parseComicInfo(allocator, bytes) catch derivedFromPath(allocator, path);
        } else |err| {
            log.debug("comic_archive: ComicInfo found but unreadable: {s}", .{@errorName(err)});
        }
    }
    return derivedFromPath(allocator, path);
}

/// Extract the cover: first image entry by lexicographic sort. macOS
/// resource forks (`__MACOSX/`), hidden files, and `Thumbs.db` are
/// filtered out by `isImageMember`.
pub fn extractCover(
    reader: ArchiveReader,
    allocator: std.mem.Allocator,
) ![]u8 {
    const members = try reader.list(allocator);
    defer freeOwned(allocator, members);

    var images: std.ArrayList([]const u8) = .empty;
    defer images.deinit(allocator);
    for (members) |name| {
        if (cbz_mod.isImageMemberPub(name)) {
            try images.append(allocator, name);
        }
    }
    if (images.items.len == 0) return Error.NoCover;
    std.mem.sort([]const u8, images.items, {}, ltStr);

    return reader.read(allocator, images.items[0]);
}

fn ltStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Returns the sorted list of image members in the archive (caller
/// owns + frees each entry + the outer slice). Backs the comic
/// reader's "list pages" endpoint. Empty list when the archive has
/// no images — the caller decides what to do (typically 404).
pub fn listImagePages(
    reader: ArchiveReader,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    const members = try reader.list(allocator);
    defer freeOwned(allocator, members);

    var images: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (images.items) |i| allocator.free(i);
        images.deinit(allocator);
    }
    for (members) |name| {
        if (cbz_mod.isImageMemberPub(name)) {
            try images.append(allocator, try allocator.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, images.items, {}, ltStr);
    return images.toOwnedSlice(allocator);
}

/// Read one image page (zero-indexed). Returns owned bytes. Useful
/// for the per-page streaming endpoint; the page index resolves to
/// `listImagePages()[index]` so callers don't have to round-trip
/// member names.
pub fn readImagePage(
    reader: ArchiveReader,
    allocator: std.mem.Allocator,
    index: usize,
) ![]u8 {
    const pages = try listImagePages(reader, allocator);
    defer freeOwned(allocator, pages);
    if (index >= pages.len) return error.PageOutOfRange;
    return reader.read(allocator, pages[index]);
}

fn freeOwned(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

fn derivedFromPath(allocator: std.mem.Allocator, path: []const u8) !meta.BookMetadata {
    const basename = std.fs.path.basename(path);
    const ext_dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = std.mem.trim(u8, basename[0..ext_dot], " ");
    return .{
        .title = if (stem.len > 0) try allocator.dupe(u8, stem) else null,
        .source = .derived,
        .confidence = 0.2,
    };
}

pub const Sevenzip = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,

    pub fn reader(self: *Sevenzip) ArchiveReader {
        return .{
            .ctx = self,
            .list_fn = listShim,
            .read_fn = readShim,
        };
    }

    /// Quick check that `7zz` is available before we try any
    /// operation. Memoised at the call site (per-handler) so it's
    /// not run on every cover fetch.
    pub fn isAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
        if (exec.isExecutableInPath(allocator, io, "7zz")) return true;
        if (exec.isExecutableInPath(allocator, io, "7z")) return true;
        return false;
    }

    /// Returns the binary name to use ("7zz" preferred). Caller is
    /// expected to have checked `isAvailable` first.
    fn executableName(self: *Sevenzip) []const u8 {
        if (exec.isExecutableInPath(self.allocator, self.io, "7zz")) return "7zz";
        return "7z";
    }

    fn listShim(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *Sevenzip = @ptrCast(@alignCast(ctx));
        return listMembers(self, allocator);
    }

    fn readShim(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        member: []const u8,
    ) anyerror![]u8 {
        const self: *Sevenzip = @ptrCast(@alignCast(ctx));
        return readMember(self, allocator, member);
    }

    fn listMembers(self: *Sevenzip, allocator: std.mem.Allocator) ![]const []const u8 {
        const bin = self.executableName();
        const r = exec.runCaptureStdout(
            self.allocator,
            self.io,
            &.{ bin, "l", "-ba", "-slt", "--", self.archive_path },
            8 * 1024 * 1024,
        ) catch return Error.ExtractFailed;
        defer self.allocator.free(r.stdout);
        if (r.exit_code != 0) return Error.ExtractFailed;

        var list: std.ArrayList([]const u8) = .empty;
        errdefer freeOwned(allocator, list.items);
        var it = std.mem.splitScalar(u8, r.stdout, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, trimmed, "Path = ")) continue;
            const name = trimmed["Path = ".len..];
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, self.archive_path)) continue;
            try list.append(allocator, try allocator.dupe(u8, name));
        }
        return list.toOwnedSlice(allocator);
    }

    fn readMember(self: *Sevenzip, allocator: std.mem.Allocator, member: []const u8) ![]u8 {
        const bin = self.executableName();
        const r = exec.runCaptureStdout(
            self.allocator,
            self.io,
            &.{ bin, "e", "-so", "-y", "--", self.archive_path, member },
            64 * 1024 * 1024,
        ) catch return Error.ExtractFailed;
        if (r.exit_code != 0) {
            self.allocator.free(r.stdout);
            return Error.ExtractFailed;
        }
        defer self.allocator.free(r.stdout);
        return allocator.dupe(u8, r.stdout);
    }
};

const zip = @import("../ffi/miniz.zig");

pub const MinizAdapter = struct {
    reader: zip.ZipReader,

    pub fn open(self: *MinizAdapter, path: []const u8) !void {
        self.reader = .{};
        try self.reader.open(path);
    }

    pub fn close(self: *MinizAdapter) void {
        self.reader.close();
    }

    pub fn archiveReader(self: *MinizAdapter) ArchiveReader {
        return .{
            .ctx = self,
            .list_fn = listShim,
            .read_fn = readShim,
        };
    }

    fn listShim(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *MinizAdapter = @ptrCast(@alignCast(ctx));
        var collector: NameCollector = .{ .allocator = allocator };
        errdefer collector.deinit();
        try self.reader.forEachMember(&collector, NameCollector.add);
        return collector.entries.toOwnedSlice(allocator);
    }

    fn readShim(ctx: *anyopaque, allocator: std.mem.Allocator, member: []const u8) anyerror![]u8 {
        const self: *MinizAdapter = @ptrCast(@alignCast(ctx));
        return self.reader.readMember(allocator, member);
    }
};

const NameCollector = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *NameCollector) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
    }
    fn add(self: *NameCollector, idx: u32, name: []const u8, uncomp: u64) anyerror!void {
        _ = idx;
        _ = uncomp;
        try self.entries.append(self.allocator, try self.allocator.dupe(u8, name));
    }
};

const StubArchive = struct {
    allocator: std.mem.Allocator,
    members: []const []const u8,
    bodies: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator, members: []const []const u8) StubArchive {
        return .{
            .allocator = allocator,
            .members = members,
            .bodies = std.StringHashMap([]const u8).init(allocator),
        };
    }
    fn deinit(self: *StubArchive) void {
        self.bodies.deinit();
    }
    fn putBody(self: *StubArchive, name: []const u8, body: []const u8) !void {
        try self.bodies.put(name, body);
    }
    fn reader(self: *StubArchive) ArchiveReader {
        return .{
            .ctx = self,
            .list_fn = listShim,
            .read_fn = readShim,
        };
    }
    fn listShim(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]const []const u8 {
        const self: *StubArchive = @ptrCast(@alignCast(ctx));
        var out = try allocator.alloc([]const u8, self.members.len);
        for (self.members, 0..) |m, i| out[i] = try allocator.dupe(u8, m);
        return out;
    }
    fn readShim(ctx: *anyopaque, allocator: std.mem.Allocator, member: []const u8) anyerror![]u8 {
        const self: *StubArchive = @ptrCast(@alignCast(ctx));
        const body = self.bodies.get(member) orelse return error.MemberMissing;
        return allocator.dupe(u8, body);
    }
};

test "listImagePages filters non-images and sorts lexicographically" {
    const alloc = std.testing.allocator;
    var stub = StubArchive.init(alloc, &.{
        "ComicInfo.xml",
        "page-003.jpg",
        "__MACOSX/page-001.jpg",
        "page-001.jpg",
        ".DS_Store",
        "page-002.png",
        "notes.txt",
    });
    defer stub.deinit();

    const pages = try listImagePages(stub.reader(), alloc);
    defer {
        for (pages) |p| alloc.free(p);
        alloc.free(pages);
    }

    try std.testing.expectEqual(@as(usize, 3), pages.len);
    try std.testing.expectEqualStrings("page-001.jpg", pages[0]);
    try std.testing.expectEqualStrings("page-002.png", pages[1]);
    try std.testing.expectEqualStrings("page-003.jpg", pages[2]);
}

test "listImagePages returns empty slice on archive with no images" {
    const alloc = std.testing.allocator;
    var stub = StubArchive.init(alloc, &.{ "ComicInfo.xml", "readme.txt" });
    defer stub.deinit();
    const pages = try listImagePages(stub.reader(), alloc);
    defer alloc.free(pages);
    try std.testing.expectEqual(@as(usize, 0), pages.len);
}

test "readImagePage returns bytes at the sorted index" {
    const alloc = std.testing.allocator;
    var stub = StubArchive.init(alloc, &.{ "page-002.jpg", "page-001.jpg", "page-003.jpg" });
    defer stub.deinit();
    try stub.putBody("page-001.jpg", "FIRST");
    try stub.putBody("page-002.jpg", "SECOND");
    try stub.putBody("page-003.jpg", "THIRD");

    const p0 = try readImagePage(stub.reader(), alloc, 0);
    defer alloc.free(p0);
    try std.testing.expectEqualStrings("FIRST", p0);

    const p2 = try readImagePage(stub.reader(), alloc, 2);
    defer alloc.free(p2);
    try std.testing.expectEqualStrings("THIRD", p2);
}

test "readImagePage rejects out-of-range index" {
    const alloc = std.testing.allocator;
    var stub = StubArchive.init(alloc, &.{"page-001.jpg"});
    defer stub.deinit();
    try stub.putBody("page-001.jpg", "X");

    try std.testing.expectError(error.PageOutOfRange, readImagePage(stub.reader(), alloc, 1));
    try std.testing.expectError(error.PageOutOfRange, readImagePage(stub.reader(), alloc, 99));
}

test "findComicInfo finds case-variant matches" {
    const alloc = std.testing.allocator;
    var stub = StubArchive.init(alloc, &.{ "page-001.jpg", "ComicInfo.XML" });
    defer stub.deinit();
    const found = try findComicInfo(stub.reader(), alloc);
    try std.testing.expect(found != null);
    defer alloc.free(found.?);
    try std.testing.expectEqualStrings("ComicInfo.XML", found.?);
}

test "findComicInfo returns null when missing" {
    const alloc = std.testing.allocator;
    var stub = StubArchive.init(alloc, &.{"page-001.jpg"});
    defer stub.deinit();
    const found = try findComicInfo(stub.reader(), alloc);
    try std.testing.expect(found == null);
}
