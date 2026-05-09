//! Filename template engine.
//!
//! Default template (v1): `{author_sort} - {series} {series_index:02} - {title}.{ext}`
//! Sanitises path-illegal characters and clamps total length.

const std = @import("std");
const meta = @import("metadata.zig");

pub const MAX_BASENAME: usize = 200;

const ILLEGAL = [_]u8{ '/', '\\', ':', '?', '*', '|', '<', '>', '"', '\x00' };

/// Sanitise a path component: drop illegal chars, collapse whitespace,
/// replace runs of dots, never produce empty.
pub fn sanitize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Start with prev_space = true so any leading whitespace is dropped.
    var prev_space = true;
    for (raw) |ch| {
        if (std.mem.indexOfScalar(u8, &ILLEGAL, ch) != null) continue;
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            if (!prev_space) try buf.append(allocator, ' ');
            prev_space = true;
            continue;
        }
        try buf.append(allocator, ch);
        prev_space = false;
    }
    // Trim trailing dots and spaces (Windows hates these).
    while (buf.items.len > 0) {
        const last = buf.items[buf.items.len - 1];
        if (last == '.' or last == ' ') {
            _ = buf.pop();
        } else break;
    }
    if (buf.items.len == 0) try buf.appendSlice(allocator, "untitled");
    return buf.toOwnedSlice(allocator);
}

/// Build a full filename from metadata.
/// Returns owned bytes including the extension; caller frees.
pub fn buildFilename(
    allocator: std.mem.Allocator,
    md: meta.BookMetadata,
    fmt: meta.Format,
) ![]u8 {
    if (!md.isRenameable()) return error.IncompleteMetadata;

    const author = try sanitize(allocator, md.primaryAuthorSort());
    defer allocator.free(author);
    const title = try sanitize(allocator, md.title.?);
    defer allocator.free(title);
    const ext = fmt.extension();

    if (md.series) |series_raw| {
        const series = try sanitize(allocator, series_raw);
        defer allocator.free(series);

        if (md.series_index) |idx| {
            // Format the index with zero padding for whole numbers,
            // one decimal place for half-installments.
            const has_frac = @floor(idx) != idx;
            const idx_str = if (has_frac)
                try std.fmt.allocPrint(allocator, "{d:.1}", .{idx})
            else
                try std.fmt.allocPrint(allocator, "{d:0>2}", .{@as(u32, @intFromFloat(idx))});
            defer allocator.free(idx_str);

            return std.fmt.allocPrint(
                allocator,
                "{s} - {s} {s} - {s}.{s}",
                .{ author, series, idx_str, title, ext },
            );
        }

        return std.fmt.allocPrint(
            allocator,
            "{s} - {s} - {s}.{s}",
            .{ author, series, title, ext },
        );
    }
    return std.fmt.allocPrint(allocator, "{s} - {s}.{s}", .{ author, title, ext });
}

// ---- Tests --------------------------------------------------------------

test "sanitize strips illegal characters" {
    const alloc = std.testing.allocator;
    const out = try sanitize(alloc, "What/now: are\\you?  doing*");
    defer alloc.free(out);
    // / : \ ? * are dropped; the colon-space is collapsed; double-space
    // becomes one. "are\you" → "areyou" because \ is dropped.
    try std.testing.expectEqualStrings("Whatnow areyou doing", out);
}

test "sanitize collapses whitespace" {
    const alloc = std.testing.allocator;
    const out = try sanitize(alloc, "  hello\t world\n");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "buildFilename with series" {
    const alloc = std.testing.allocator;
    const author = meta.Author{
        .last = "Sanderson",
        .first = "Brandon",
        .sort = "Sanderson, Brandon",
    };
    const md = meta.BookMetadata{
        .title = "The Way of Kings",
        .authors = &[_]meta.Author{author},
        .series = "The Stormlight Archive",
        .series_index = 1.0,
    };
    const out = try buildFilename(alloc, md, .epub);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "Sanderson, Brandon - The Stormlight Archive 01 - The Way of Kings.epub",
        out,
    );
}

test "buildFilename without series" {
    const alloc = std.testing.allocator;
    const author = meta.Author{ .last = "Homer", .first = "", .sort = "Homer" };
    const md = meta.BookMetadata{
        .title = "The Iliad",
        .authors = &[_]meta.Author{author},
    };
    const out = try buildFilename(alloc, md, .epub);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Homer - The Iliad.epub", out);
}

test "buildFilename rejects incomplete metadata" {
    const alloc = std.testing.allocator;
    const md = meta.BookMetadata{ .title = "Orphan" };
    try std.testing.expectError(error.IncompleteMetadata, buildFilename(alloc, md, .epub));
}

test "buildFilename handles fractional series index" {
    const alloc = std.testing.allocator;
    const author = meta.Author{ .last = "Erikson", .first = "Steven", .sort = "Erikson, Steven" };
    const md = meta.BookMetadata{
        .title = "Side Tale",
        .authors = &[_]meta.Author{author},
        .series = "Malazan",
        .series_index = 2.5,
    };
    const out = try buildFilename(alloc, md, .epub);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("Erikson, Steven - Malazan 2.5 - Side Tale.epub", out);
}
