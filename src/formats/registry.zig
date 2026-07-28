//! Format-handler lookup table.
//!
//! Single flat array of every `FormatHandler` the codebase knows
//! about. New formats register here. Lookup is by `Format` enum
//! value (for code that already has the enum) or by extension (for
//! the scan-walk filter that only has a filename to work with).
//!
//! Adding a format = adding one entry below + the module's
//! `pub const handler` constant. No other files change.

const std = @import("std");
const meta = @import("../core/metadata.zig");
const handler_mod = @import("handler.zig");

const epub_mod = @import("epub.zig");
const mobi_mod = @import("mobi.zig");
const pdf_mod = @import("pdf.zig");
const cbz_mod = @import("cbz.zig");
const cbr_mod = @import("cbr.zig");
const cb7_mod = @import("cb7.zig");
const cbt_mod = @import("cbt.zig");

/// The registry. Ordered: most-common first so the lookup hits
/// quickly for typical libraries. (The array is small enough that
/// ordering only matters for taste.)
pub const handlers = [_]handler_mod.FormatHandler{
    epub_mod.handler,
    mobi_mod.handler_mobi,
    mobi_mod.handler_azw3,
    pdf_mod.handler,
    cbz_mod.handler,
    cbr_mod.handler,
    cb7_mod.handler,
    cbt_mod.handler,
};

/// Lookup by `Format` enum tag. Returns null when the format isn't
/// registered (notably `.unknown`).
pub fn forFormat(fmt: meta.Format) ?*const handler_mod.FormatHandler {
    for (&handlers) |*h| {
        if (h.format == fmt) return h;
    }
    return null;
}

/// Lookup by file extension (lowercase, no leading dot). Used by the
/// scan-walk filter — `meta.Format.fromExtension` knows the same
/// mapping, but going through the registry means future formats only
/// have to register here, not in two places.
pub fn forExtension(ext: []const u8) ?*const handler_mod.FormatHandler {
    var lower_buf: [16]u8 = undefined;
    if (ext.len > lower_buf.len) return null;
    for (ext, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..ext.len];
    for (&handlers) |*h| {
        for (h.extensions) |e| {
            if (std.mem.eql(u8, e, lower)) return h;
        }
    }
    return null;
}

/// Lookup by full path. Pulls the extension off and delegates to
/// `forExtension`. Returns null for paths without an extension or
/// extensions no handler claims.
pub fn forPath(path: []const u8) ?*const handler_mod.FormatHandler {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return null;
    return forExtension(ext[1..]);
}
