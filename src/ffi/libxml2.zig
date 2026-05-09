//! Tiny libxml2 helpers for OPF / XHTML parsing.
//!
//! The full libxml2 API is huge; here we expose just enough to:
//!   - parse an in-memory XML buffer
//!   - run an XPath query and pull a single text node out

const std = @import("std");
const c = @import("c");

pub const Error = error{
    ParseFailed,
    XPathFailed,
    Empty,
};

pub const Doc = struct {
    ptr: *c.xmlDoc,

    pub fn parseMemory(buf: []const u8) !Doc {
        const doc = c.xmlReadMemory(
            buf.ptr,
            @intCast(buf.len),
            "noname.xml",
            null,
            c.XML_PARSE_NOBLANKS | c.XML_PARSE_NOERROR | c.XML_PARSE_NOWARNING,
        ) orelse return Error.ParseFailed;
        return .{ .ptr = doc };
    }

    pub fn deinit(self: *Doc) void {
        c.xmlFreeDoc(self.ptr);
    }

    /// Run an XPath query that registers a single namespace prefix.
    /// Returns owned text content of the first matching node, or null
    /// if no match. Caller must free.
    pub fn firstString(
        self: Doc,
        allocator: std.mem.Allocator,
        ns_prefix: ?[]const u8,
        ns_uri: ?[]const u8,
        xpath: []const u8,
    ) !?[]u8 {
        const ctx = c.xmlXPathNewContext(self.ptr) orelse return Error.XPathFailed;
        defer c.xmlXPathFreeContext(ctx);

        if (ns_prefix) |p| {
            if (ns_uri) |u| {
                var p_z: [128]u8 = undefined;
                var u_z: [256]u8 = undefined;
                if (p.len >= p_z.len or u.len >= u_z.len) return Error.XPathFailed;
                @memcpy(p_z[0..p.len], p);
                p_z[p.len] = 0;
                @memcpy(u_z[0..u.len], u);
                u_z[u.len] = 0;
                _ = c.xmlXPathRegisterNs(ctx, @ptrCast(&p_z), @ptrCast(&u_z));
            }
        }

        var xp_z: [1024]u8 = undefined;
        if (xpath.len >= xp_z.len) return Error.XPathFailed;
        @memcpy(xp_z[0..xpath.len], xpath);
        xp_z[xpath.len] = 0;

        const result = c.xmlXPathEvalExpression(@ptrCast(&xp_z), ctx) orelse return Error.XPathFailed;
        defer c.xmlXPathFreeObject(result);

        const nodes = result.*.nodesetval;
        if (nodes == null or nodes.*.nodeNr == 0) return null;
        const node = nodes.*.nodeTab[0];
        const content = c.xmlNodeGetContent(node) orelse return null;
        defer c.xmlFree.?(content);

        const len = std.mem.len(@as([*c]u8, @ptrCast(content)));
        if (len == 0) return null;
        return try allocator.dupe(u8, @as([*c]u8, @ptrCast(content))[0..len]);
    }
};
