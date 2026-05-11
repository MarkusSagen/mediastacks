//! Safe Zig wrapper over libmobi.
//!
//! Reads MOBI/AZW3 metadata, extracts the cover, and (post-v1) drives
//! the MOBI->EPUB conversion path. We deliberately copy strings out of
//! libmobi's internals into the caller's allocator so the rest of the
//! codebase never sees raw C pointers.

const std = @import("std");
const c = @import("c");

pub const Error = error{
    OpenFailed,
    LoadFailed,
    NoMetadata,
    NoCover,
    OutOfMemory,
};

pub const MobiBook = struct {
    data: *c.MOBIData,

    pub fn open(path: []const u8) !MobiBook {
        const data = c.mobi_init() orelse return Error.OpenFailed;
        errdefer c.mobi_free(data);

        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len) return Error.OpenFailed;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const file = c.fopen(@ptrCast(&path_z), "rb") orelse return Error.OpenFailed;
        defer _ = c.fclose(file);

        const rc = c.mobi_load_file(data, file);
        if (rc != c.MOBI_SUCCESS) return Error.LoadFailed;

        return .{ .data = data };
    }

    pub fn close(self: *MobiBook) void {
        c.mobi_free(self.data);
    }

    pub fn title(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_title(self.data));
    }

    pub fn author(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_author(self.data));
    }

    pub fn publisher(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_publisher(self.data));
    }

    pub fn isbn(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_isbn(self.data));
    }

    pub fn description(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_description(self.data));
    }

    pub fn publishDate(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_publishdate(self.data));
    }

    pub fn language(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_language(self.data));
    }

    pub fn subject(self: MobiBook, allocator: std.mem.Allocator) !?[]const u8 {
        return dupeIfPresent(allocator, c.mobi_meta_get_subject(self.data));
    }
};

fn dupeIfPresent(allocator: std.mem.Allocator, ptr: [*c]u8) !?[]const u8 {
    if (ptr == null) return null;
    defer c.free(ptr);
    const len = std.mem.len(ptr);
    if (len == 0) return null;
    return try allocator.dupe(u8, ptr[0..len]);
}
