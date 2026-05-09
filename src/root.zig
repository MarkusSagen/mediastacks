//! Public library surface for booktool.
//!
//! The CLI in `cli.zig` is a thin dispatcher over these modules; the future
//! TUI and Web UI will call the same APIs.

const std = @import("std");

pub const cli = @import("cli.zig");

// Core domain
pub const metadata = @import("core/metadata.zig");
pub const catalog = @import("core/catalog.zig");
pub const dedup = @import("core/dedup.zig");
pub const rename = @import("core/rename.zig");
pub const score = @import("core/score.zig");

// Formats
pub const format = @import("formats/format.zig");
pub const epub = @import("formats/epub.zig");
pub const mobi = @import("formats/mobi.zig");

// Providers
pub const provider = @import("providers/provider.zig");
pub const openlibrary = @import("providers/openlibrary.zig");

// Conversion
pub const convert = @import("convert/convert.zig");

// Utilities
pub const hash = @import("util/hash.zig");
pub const isbn = @import("util/isbn.zig");
pub const fuzzy = @import("util/fuzzy.zig");
pub const http = @import("util/http.zig");

test {
    // Pulls in tests from every submodule.
    std.testing.refAllDecls(@This());
    _ = metadata;
    _ = catalog;
    _ = dedup;
    _ = rename;
    _ = score;
    _ = format;
    _ = epub;
    _ = mobi;
    _ = openlibrary;
    _ = isbn;
    _ = fuzzy;
    _ = hash;
    _ = convert;
}
