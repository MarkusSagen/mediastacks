//! HTTP client wrapper.
//!
//! Built on `std.http.Client` over the 0.16 `std.Io` interface. The
//! single GET surface is enough for the Open Library provider; further
//! provider integrations can extend this without touching call sites.

const std = @import("std");

const log = std.log.scoped(.http);

pub const Error = error{
    HttpError,
    NotImplemented,
    OutOfMemory,
};

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const ClientOptions = struct {
    user_agent: []const u8 = "booktool/0.0 (+https://github.com/markussagen/booktool)",
};

/// GET a URL and return the body. Caller owns `Response.body`.
pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    opts: ClientOptions,
) !Response {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();

    var extra = [_]std.http.Header{
        .{ .name = "user-agent", .value = opts.user_agent },
        .{ .name = "accept", .value = "application/json,*/*;q=0.5" },
    };

    log.debug("GET {s}", .{url});

    const fetched = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .extra_headers = &extra,
        .response_writer = &sink.writer,
    }) catch |err| {
        std.log.warn("http.get {s}: {s}", .{ url, @errorName(err) });
        return Error.HttpError;
    };

    const body = try sink.toOwnedSlice();
    log.debug("  → {d} ({d} bytes)", .{ @intFromEnum(fetched.status), body.len });
    return .{
        .status = @intFromEnum(fetched.status),
        .body = body,
    };
}

pub const HttpClient = struct {
    ctx: *anyopaque,
    get_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        opts: ClientOptions,
    ) anyerror!Response,

    pub fn fetchGet(self: HttpClient, allocator: std.mem.Allocator, url: []const u8, opts: ClientOptions) !Response {
        return self.get_fn(self.ctx, allocator, url, opts);
    }
};

/// Wrap `http.get` as a `HttpClient`. Construct via struct literal
/// (`RealHttpClient{ .io = io }`) — the value must outlive the
/// `HttpClient` returned from `.client()` (it borrows the ctx
/// pointer). For long-lived callers the typical pattern is a stack
/// local right next to the consumer.
pub const RealHttpClient = struct {
    io: std.Io,

    pub fn client(self: *RealHttpClient) HttpClient {
        return .{ .ctx = self, .get_fn = getReal };
    }
    fn getReal(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, opts: ClientOptions) anyerror!Response {
        const self: *RealHttpClient = @ptrCast(@alignCast(ctx));
        return get(allocator, self.io, url, opts);
    }
};

/// Test double. `add(url, status, body)` queues a canned response;
/// when the client is asked for that URL it pops it. URLs that aren't
/// in the map return `Error.HttpError` (matches a real network failure
/// in the provider's `catch`-and-fall-through code paths).
///
/// `calls` records every URL the SUT asked for, in order, so tests
/// can assert on the request sequence (e.g. ISBN-then-search ladder).
pub const MockClient = struct {
    allocator: std.mem.Allocator,
    responses: std.StringHashMap(MockResponse),
    calls: std.ArrayList([]const u8),

    pub const MockResponse = struct {
        status: u16,
        body: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) MockClient {
        return .{
            .allocator = allocator,
            .responses = std.StringHashMap(MockResponse).init(allocator),
            .calls = .empty,
        };
    }

    pub fn deinit(self: *MockClient) void {
        var it = self.responses.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.body);
        }
        self.responses.deinit();
        for (self.calls.items) |c| self.allocator.free(c);
        self.calls.deinit(self.allocator);
    }

    pub fn add(self: *MockClient, url: []const u8, status: u16, body: []const u8) !void {
        const k = try self.allocator.dupe(u8, url);
        const v = try self.allocator.dupe(u8, body);
        try self.responses.put(k, .{ .status = status, .body = v });
    }

    pub fn client(self: *MockClient) HttpClient {
        return .{ .ctx = self, .get_fn = getMock };
    }

    fn getMock(ctx: *anyopaque, allocator: std.mem.Allocator, url: []const u8, opts: ClientOptions) anyerror!Response {
        _ = opts;
        const self: *MockClient = @ptrCast(@alignCast(ctx));
        try self.calls.append(self.allocator, try self.allocator.dupe(u8, url));
        const hit = self.responses.get(url) orelse return Error.HttpError;
        const body_copy = try allocator.dupe(u8, hit.body);
        return .{ .status = hit.status, .body = body_copy };
    }
};

test "MockClient records calls and returns canned bodies" {
    var mock = MockClient.init(std.testing.allocator);
    defer mock.deinit();
    try mock.add("https://example.com/a", 200, "hello");

    const c = mock.client();
    var resp = try c.fetchGet(std.testing.allocator, "https://example.com/a", .{});
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello", resp.body);

    try std.testing.expectError(Error.HttpError, c.fetchGet(std.testing.allocator, "https://example.com/missing", .{}));

    try std.testing.expectEqual(@as(usize, 2), mock.calls.items.len);
    try std.testing.expectEqualStrings("https://example.com/a", mock.calls.items[0]);
    try std.testing.expectEqualStrings("https://example.com/missing", mock.calls.items[1]);
}
