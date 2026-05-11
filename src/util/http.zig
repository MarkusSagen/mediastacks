//! HTTP client wrapper.
//!
//! Built on `std.http.Client` over the 0.16 `std.Io` interface. The
//! single GET surface is enough for the Open Library provider; further
//! provider integrations can extend this without touching call sites.

const std = @import("std");

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
    return .{
        .status = @intFromEnum(fetched.status),
        .body = body,
    };
}
