//! Canonical-rename planner + applier — shared between the CLI
//! `mediastacks rename` command and the web "Rename preview" lens.
//!
//! Two surfaces:
//!   - `planAll(arena, cat, template)` — dry-run; returns one
//!     `RenamePlan` per book in the catalog. Books with incomplete
//!     metadata (no author, no title) come back with an
//!     `unrenameable_reason` instead of a dst path.
//!   - `applyOne(cat, plan)` — execute one move (mkdir -p, rename(2),
//!     `cat.updateBookPath`). Errors are returned per call so the
//!     caller can decide whether to keep going or stop on first failure.
//!
//! Filesystem moves use `std.c.rename` directly so a cross-device
//! rename surfaces as `error.RenameFailed` (EXDEV) rather than the
//! Zig stdlib's bespoke fallback copy. Cross-device support is a
//! separate concern; for now we let the caller surface the error.
//!
//! `original_path` is preserved automatically because
//! `Catalog.updateBookPath` only touches the `path` column (see
//! `src/core/catalog.zig::updateBookPath`).

const std = @import("std");
const catalog_mod = @import("catalog.zig");
const template_mod = @import("template.zig");

pub const RenamePlan = struct {
    id: i64,
    src: []const u8,
    /// Canonical destination path. Null when the book can't be renamed
    /// (incomplete metadata, template render failure, etc).
    dst: ?[]const u8 = null,
    /// True when dst equals src exactly — already canonical.
    same: bool = false,
    /// Set when dst is null; explains why. UI surface this in the
    /// "unrenameable" column of the preview list.
    unrenameable_reason: ?[]const u8 = null,
};

pub const Counts = struct {
    total: usize,
    would_change: usize,
    same: usize,
    unrenameable: usize,
};

/// Render a `RenamePlan` for every book in the catalog. All slices in
/// the returned plans are owned by `arena` — the caller resets the
/// arena to free them.
pub fn planAll(
    arena: std.mem.Allocator,
    cat: *catalog_mod.Catalog,
    template_str: []const u8,
) ![]RenamePlan {
    const books = try cat.listBooks(arena);
    var plans: std.ArrayList(RenamePlan) = .empty;
    try plans.ensureTotalCapacity(arena, books.len);

    for (books) |book| {
        const new_rel = template_mod.render(arena, template_str, book.metadata, book.format) catch |err| switch (err) {
            template_mod.Error.IncompleteMetadata => {
                try plans.append(arena, .{
                    .id = book.id,
                    .src = book.path,
                    .unrenameable_reason = if (book.metadata.title == null)
                        @as([]const u8, "no title")
                    else
                        @as([]const u8, "no author"),
                });
                continue;
            },
            else => return err,
        };
        const parent = std.fs.path.dirname(book.path) orelse ".";
        const dst_path = try std.fs.path.join(arena, &.{ parent, new_rel });
        const same = std.mem.eql(u8, book.path, dst_path);
        try plans.append(arena, .{
            .id = book.id,
            .src = book.path,
            .dst = dst_path,
            .same = same,
        });
    }
    return plans.toOwnedSlice(arena);
}

/// Roll up a slice of plans into the high-level counts the UI uses.
pub fn summarize(plans: []const RenamePlan) Counts {
    var c = Counts{ .total = plans.len, .would_change = 0, .same = 0, .unrenameable = 0 };
    for (plans) |p| {
        if (p.dst == null) c.unrenameable += 1 else if (p.same) c.same += 1 else c.would_change += 1;
    }
    return c;
}

/// Execute one plan: create parent dirs, rename(2), and update the
/// catalog row to point at the new path. The book's id is preserved,
/// so `original_path` (set on first INSERT) survives untouched —
/// that's the whole reason canonical-rename has a clean payoff.
///
/// Returns `error.NotApplicable` when the plan has no dst (skipped
/// metadata) or when dst already equals src. Callers should normally
/// filter those out before calling, but it's safe to call blindly.
pub fn applyOne(cat: *catalog_mod.Catalog, plan: RenamePlan) !void {
    const dst = plan.dst orelse return error.NotApplicable;
    if (plan.same) return error.NotApplicable;

    if (std.fs.path.dirname(dst)) |parent| {
        try mkdirParents(parent);
    }

    var src_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    if (plan.src.len >= src_buf.len or dst.len >= dst_buf.len) return error.PathTooLong;
    const src_z = std.fmt.bufPrintZ(&src_buf, "{s}", .{plan.src}) catch return error.PathTooLong;
    const dst_z = std.fmt.bufPrintZ(&dst_buf, "{s}", .{dst}) catch return error.PathTooLong;

    if (std.c.access(dst_z.ptr, 0) == 0) return error.DestinationExists;
    if (std.c.rename(src_z.ptr, dst_z.ptr) != 0) {
        copyAcrossDevices(src_z, dst_z) catch return error.RenameFailed;
        if (std.c.unlink(src_z.ptr) != 0) {}
    }
    try cat.updateBookPath(plan.id, dst);
}

/// Cross-filesystem copy used as a fallback when `rename(2)` returns
/// EXDEV. Streams src → dst in 64KB chunks; fsyncs dst before close
/// so the data is on disk before src is unlinked. Returns any I/O
/// error from open/read/write/fsync. The destination is removed on
/// failure to avoid leaving half-written files around.
pub fn copyAcrossDevices(src_z: [:0]const u8, dst_z: [:0]const u8) !void {
    const src_fd = std.c.open(src_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (src_fd < 0) return error.OpenSrcFailed;
    defer _ = std.c.close(src_fd);
    const dst_fd = std.c.open(
        dst_z.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true },
        @as(std.c.mode_t, 0o644),
    );
    if (dst_fd < 0) return error.OpenDstFailed;
    errdefer _ = std.c.unlink(dst_z.ptr);
    defer _ = std.c.close(dst_fd);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(src_fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        var total: usize = 0;
        const want: usize = @intCast(n);
        while (total < want) {
            const w = std.c.write(dst_fd, buf[total..want].ptr, want - total);
            if (w < 0) return error.WriteFailed;
            if (w == 0) return error.WriteFailed;
            total += @intCast(w);
        }
    }
    if (std.c.fsync(dst_fd) != 0) return error.FsyncFailed;
}

/// Resolve a preset name into a template string. Returns
/// `error.UnknownPreset` when the name doesn't match.
pub fn presetTemplate(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "default")) return template_mod.DEFAULT_TEMPLATE;
    if (std.mem.eql(u8, name, "flat")) return template_mod.FLAT_TEMPLATE;
    if (std.mem.eql(u8, name, "series-dir")) return template_mod.SERIES_DIR_TEMPLATE;
    return error.UnknownPreset;
}

/// `mkdir -p` semantics — create every directory component of `path`
/// that doesn't already exist. POSIX-only; on Windows we'd need a
/// different separator + a wide-char API. The CLI's previous home
/// for this code is removed; this is the canonical implementation.
pub fn mkdirParents(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            buf[i] = 0;
            _ = std.c.mkdir(@ptrCast(&buf), 0o755);
            if (i < path.len) buf[i] = '/';
        }
    }
}

const clock = @import("../util/clock.zig");

fn writeFixtureFile(path_z: [:0]const u8, contents: []const u8) !void {
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return error.OpenSrcFailed;
    defer _ = std.c.fclose(fp);
    const n = std.c.fwrite(contents.ptr, 1, contents.len, fp);
    if (n != contents.len) return error.WriteFailed;
}

fn readFixtureFile(allocator: std.mem.Allocator, path_z: [:0]const u8) ![]u8 {
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.OpenSrcFailed;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..n]);
    }
    return buf.toOwnedSlice(allocator);
}

test "copyAcrossDevices: copies bytes and fsyncs the destination" {
    const alloc = std.testing.allocator;
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();

    var src_buf: [128]u8 = undefined;
    const src_str = try std.fmt.bufPrint(&src_buf, "/tmp/mediastacks-exdev-src-{d}-{d}", .{ pid, stamp });
    var src_z_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_z_buf, "{s}", .{src_str});
    defer _ = std.c.unlink(src_z.ptr);

    var dst_buf: [128]u8 = undefined;
    const dst_str = try std.fmt.bufPrint(&dst_buf, "/tmp/mediastacks-exdev-dst-{d}-{d}", .{ pid, stamp });
    var dst_z_buf: [4096]u8 = undefined;
    const dst_z = try std.fmt.bufPrintZ(&dst_z_buf, "{s}", .{dst_str});
    defer _ = std.c.unlink(dst_z.ptr);

    const payload = "EPUB-like bytes\x00with\x01embedded\x02nulls\x03and\x04binary\x05data";
    try writeFixtureFile(src_z, payload);

    try copyAcrossDevices(src_z, dst_z);

    const round_trip = try readFixtureFile(alloc, dst_z);
    defer alloc.free(round_trip);
    try std.testing.expectEqualSlices(u8, payload, round_trip);
}

test "copyAcrossDevices: fails when dst already exists (O_EXCL)" {
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();

    var src_buf: [128]u8 = undefined;
    const src_str = try std.fmt.bufPrint(&src_buf, "/tmp/mediastacks-exdev-src2-{d}-{d}", .{ pid, stamp });
    var src_z_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_z_buf, "{s}", .{src_str});
    defer _ = std.c.unlink(src_z.ptr);

    var dst_buf: [128]u8 = undefined;
    const dst_str = try std.fmt.bufPrint(&dst_buf, "/tmp/mediastacks-exdev-dst2-{d}-{d}", .{ pid, stamp });
    var dst_z_buf: [4096]u8 = undefined;
    const dst_z = try std.fmt.bufPrintZ(&dst_z_buf, "{s}", .{dst_str});
    defer _ = std.c.unlink(dst_z.ptr);

    try writeFixtureFile(src_z, "src data");
    try writeFixtureFile(dst_z, "pre-existing dst data");

    try std.testing.expectError(error.OpenDstFailed, copyAcrossDevices(src_z, dst_z));

    const after = try readFixtureFile(std.testing.allocator, dst_z);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("pre-existing dst data", after);
}

test "applyOne: same-fs rename moves file and updates catalog row" {
    const alloc = std.testing.allocator;
    const pid = std.c.getpid();
    const stamp = clock.nowSeconds();

    var name_buf: [128]u8 = undefined;
    const db = try std.fmt.bufPrint(&name_buf, "/tmp/mediastacks-stdz-applyone-{d}-{d}.db", .{ pid, stamp });
    var db_z: [4096]u8 = undefined;
    const dbz = try std.fmt.bufPrintZ(&db_z, "{s}", .{db});
    defer _ = std.c.unlink(dbz.ptr);

    var src_buf: [128]u8 = undefined;
    const src_str = try std.fmt.bufPrint(&src_buf, "/tmp/mediastacks-stdz-src-{d}-{d}.epub", .{ pid, stamp });
    var src_z_buf: [4096]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_z_buf, "{s}", .{src_str});
    defer _ = std.c.unlink(src_z.ptr);

    var dst_buf: [128]u8 = undefined;
    const dst_str = try std.fmt.bufPrint(&dst_buf, "/tmp/mediastacks-stdz-dst-{d}-{d}.epub", .{ pid, stamp });
    var dst_z_buf: [4096]u8 = undefined;
    const dst_z = try std.fmt.bufPrintZ(&dst_z_buf, "{s}", .{dst_str});
    defer _ = std.c.unlink(dst_z.ptr);

    try writeFixtureFile(src_z, "fake epub bytes");

    var cat = try catalog_mod.Catalog.open(db);
    defer cat.close();

    const meta_mod = @import("metadata.zig");
    const author = meta_mod.Author{ .last = "Test", .first = "User", .sort = "Test, User" };
    const id = try cat.upsertBook(alloc, .{
        .path = src_str,
        .sha256 = "deadbeef",
        .size = 15,
        .format = .epub,
        .mtime = 0,
        .metadata = .{
            .title = "Fixture",
            .authors = &[_]meta_mod.Author{author},
            .source = .embedded,
            .confidence = 0.9,
        },
    });

    try applyOne(&cat, .{
        .id = id,
        .src = src_str,
        .dst = dst_str,
    });

    try std.testing.expect(std.c.access(src_z.ptr, 0) != 0);
    try std.testing.expect(std.c.access(dst_z.ptr, 0) == 0);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fresh = (try cat.getBookById(arena, id)) orelse return error.MissingRow;
    try std.testing.expectEqualStrings(dst_str, fresh.path);
    try std.testing.expect(fresh.original_path != null);
    try std.testing.expectEqualStrings(src_str, fresh.original_path.?);
}
