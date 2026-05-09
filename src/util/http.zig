//! Thin HTTP client wrapper for provider clients.
//!
//! Currently a stub: the actual std.http API in 0.16 is wired to the new
//! std.Io interface and is still settling. We expose a tiny GET surface
//! that providers can call so swapping the implementation later (e.g. to
//! libcurl) is one-file work.

const std = @import("std");

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

/// GET a URL. Returns a body owned by `allocator`.
/// NOTE: implementation pending — currently returns error.NotImplemented.
pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    opts: ClientOptions,
) !Response {
    _ = allocator;
    _ = io;
    _ = url;
    _ = opts;
    return error.NotImplemented;
}
