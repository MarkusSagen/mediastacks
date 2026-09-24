//! A `HttpClient` that caches raw responses on disk (keyed by SHA-256 of the
//! URL) and throttles network *misses* to respect MusicBrainz's 1 req/sec
//! limit. Cache files: `{dir}/{hex-sha256}.cache`, first line `status`, then
//! the body. Best-effort: any FS error degrades to a plain passthrough, so a
//! cache problem never breaks a lookup.

const std = @import("std");
const http = @import("http.zig");

// Wall-clock milliseconds via libc (0.16 has no std.time.Instant / milliTimestamp
// without an Io). `usec` is 32-bit on darwin — matching the C timeval layout.
const Timeval = extern struct { sec: c_long, usec: c_int };
extern "c" fn gettimeofday(tv: *Timeval, tz: ?*anyopaque) c_int;
fn nowMs() i64 {
    var tv: Timeval = undefined;
    if (gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}
fn sleepMs(ms: u64) void {
    const req = std.c.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&req, null);
}

pub const CachingHttpClient = struct {
    inner: http.HttpClient,
    dir: []const u8,
    throttle_ms: u64 = 1100,
    last_net_ms: i64 = 0,

    pub fn client(self: *CachingHttpClient) http.HttpClient {
        return .{ .ctx = self, .get_fn = getShim };
    }

    fn getShim(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, opts: http.ClientOptions) anyerror!http.Response {
        const self: *CachingHttpClient = @ptrCast(@alignCast(ctx));
        return self.get(allocator, url, opts);
    }

    fn get(self: *CachingHttpClient, allocator: std.mem.Allocator, url: []const u8, opts: http.ClientOptions) !http.Response {
        var key_buf: [64]u8 = undefined;
        const key = hexKey(url, &key_buf);
        var path_buf: [4096]u8 = undefined;
        const path: ?[]const u8 = std.fmt.bufPrint(&path_buf, "{s}/{s}.cache", .{ self.dir, key }) catch null;

        if (path) |p| {
            if (readCache(allocator, p)) |hit| return hit;
        }

        // Throttle network misses to honor the 1 req/sec limit.
        if (self.throttle_ms > 0) {
            const now = nowMs();
            if (self.last_net_ms != 0) {
                const elapsed = now - self.last_net_ms;
                if (elapsed >= 0 and @as(u64, @intCast(elapsed)) < self.throttle_ms) {
                    sleepMs(self.throttle_ms - @as(u64, @intCast(elapsed)));
                }
            }
            self.last_net_ms = nowMs();
        }

        const resp = try self.inner.fetchGet(allocator, url, opts);
        // Cache 2xx and 4xx (definitive); skip 5xx (transient) so a blip
        // isn't remembered.
        const cacheable = (resp.status >= 200 and resp.status < 300) or (resp.status >= 400 and resp.status < 500);
        if (cacheable) {
            if (path) |p| writeCache(p, resp.status, resp.body);
        }
        return resp;
    }
};

/// Lowercase-hex SHA-256 of `url` into `out` (64 bytes). Exposed for tests.
pub fn hexKey(url: []const u8, out: *[64]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out[0..64];
}

fn readCache(allocator: std.mem.Allocator, path: []const u8) ?http.Response {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return null;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return null;
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        buf.appendSlice(allocator, chunk[0..n]) catch return null;
    }
    const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse return null;
    const status = std.fmt.parseInt(u16, buf.items[0..nl], 10) catch return null;
    const body = allocator.dupe(u8, buf.items[nl + 1 ..]) catch return null;
    return .{ .status = status, .body = body };
}

fn writeCache(path: []const u8, status: u16, body: []const u8) void {
    var pz: [4096]u8 = undefined;
    if (path.len >= pz.len) return;
    const path_z = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return;
    defer _ = std.c.fclose(fp);
    var hdr: [8]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "{d}\n", .{status}) catch return;
    _ = std.c.fwrite(h.ptr, 1, h.len, fp);
    if (body.len > 0) _ = std.c.fwrite(body.ptr, 1, body.len, fp);
}

const t = std.testing;

fn mkdirZ(path: []const u8) void {
    var pz: [4096]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    _ = std.c.mkdir(p.ptr, 0o755);
}
fn unlinkKey(dir: []const u8, url: []const u8) void {
    var kb: [64]u8 = undefined;
    const key = hexKey(url, &kb);
    var pz: [4096]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pz, "{s}/{s}.cache", .{ dir, key }) catch return;
    _ = std.c.unlink(p.ptr);
}
fn rmdirZ(path: []const u8) void {
    var pz: [4096]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return;
    _ = std.c.rmdir(p.ptr);
}

test "second fetch is served from disk (no inner call)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pid = std.c.getpid();
    var db: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&db, "/tmp/mediastacks-hc-{d}", .{pid});
    mkdirZ(dir);
    defer {
        unlinkKey(dir, "https://mb/x");
        rmdirZ(dir);
    }

    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://mb/x", 200, "BODY");

    var caching = CachingHttpClient{ .inner = mock.client(), .dir = dir, .throttle_ms = 0 };
    const c = caching.client();

    const r1 = try c.fetchGet(a, "https://mb/x", .{});
    try t.expectEqualStrings("BODY", r1.body);
    const r2 = try c.fetchGet(a, "https://mb/x", .{});
    try t.expectEqualStrings("BODY", r2.body);
    // inner was hit exactly once; the second came from disk.
    try t.expectEqual(@as(usize, 1), mock.calls.items.len);
}

test "5xx is not cached" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pid = std.c.getpid();
    var db: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&db, "/tmp/mediastacks-hc5-{d}", .{pid});
    mkdirZ(dir);
    defer {
        unlinkKey(dir, "https://mb/e");
        rmdirZ(dir);
    }

    var mock = http.MockClient.init(t.allocator);
    defer mock.deinit();
    try mock.add("https://mb/e", 500, "ERR");

    var caching = CachingHttpClient{ .inner = mock.client(), .dir = dir, .throttle_ms = 0 };
    const c = caching.client();
    _ = try c.fetchGet(a, "https://mb/e", .{});
    _ = try c.fetchGet(a, "https://mb/e", .{});
    try t.expectEqual(@as(usize, 2), mock.calls.items.len); // not cached
}
