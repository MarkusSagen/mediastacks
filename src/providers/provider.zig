//! Provider interface (vtable-based for runtime dispatch).
//!
//! A provider is anything that can return candidate metadata for a query.
//! Providers register themselves with the enrich pipeline; the pipeline
//! merges results by confidence + source rank.

const std = @import("std");
const meta = @import("../core/metadata.zig");

pub const Query = struct {
    isbn: ?[]const u8 = null,
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
};

pub const Provider = struct {
    ctx: *anyopaque,
    name_str: []const u8,
    lookup_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        q: Query,
    ) anyerror!?meta.BookMetadata,

    pub fn name(self: Provider) []const u8 {
        return self.name_str;
    }

    pub fn lookup(
        self: Provider,
        allocator: std.mem.Allocator,
        io: std.Io,
        q: Query,
    ) !?meta.BookMetadata {
        return self.lookup_fn(self.ctx, allocator, io, q);
    }
};
