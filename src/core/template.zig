//! Filename template engine.
//!
//! A template is a string with `{field}` or `{field:fmt}` placeholders.
//! Unknown fields and missing values render as empty (and any adjacent
//! single-space separator is collapsed) so partial metadata produces
//! reasonable filenames without bespoke conditionals.
//!
//! Supported fields:
//!   author_sort  "Last, First" of the first author (falls back to "Unknown")
//!   author       Display name of the first author ("First Last")
//!   title        Book title
//!   series       Series name (empty if absent)
//!   series_index Numeric position in the series
//!   year         4-digit year
//!   isbn         ISBN-13 if known
//!   format       Format tag (epub, mobi, ...)
//!   ext          Extension (no leading dot)
//!
//! Format spec for `series_index`:
//!   `{series_index:02}` zero-padded to 2 digits (default)
//!   `{series_index:0>3}` zero-padded to 3
//!   `{series_index}`     no padding
//!   Fractional indices (e.g. 1.5) always render as `1.5`.
//!
//! Built-in templates:
//!   .default      "{author_sort} - {series} {series_index:02} - {title}.{ext}"
//!   .flat         "{author_sort} - {title}.{ext}"
//!   .series_dir   "{author_sort}/{series}/{series_index:02} - {title}.{ext}"

const std = @import("std");
const meta = @import("metadata.zig");

pub const DEFAULT_TEMPLATE =
    "{author_sort} - {series} {series_index:02} - {title}.{ext}";

pub const FLAT_TEMPLATE =
    "{author_sort} - {title}.{ext}";

pub const SERIES_DIR_TEMPLATE =
    "{author_sort}/{series}/{series_index:02} - {title}.{ext}";

pub const Error = error{
    UnclosedPlaceholder,
    InvalidFormatSpec,
    IncompleteMetadata,
    OutOfMemory,
};

/// Render `template` against `md` to an owned string.
/// Path-illegal characters in field values are sanitized.
pub fn render(
    allocator: std.mem.Allocator,
    template: []const u8,
    md: meta.BookMetadata,
    fmt: meta.Format,
) ![]u8 {
    if (md.title == null or md.authors.len == 0) return Error.IncompleteMetadata;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];
        if (ch != '{') {
            try out.append(allocator, ch);
            i += 1;
            continue;
        }
        const close_off = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse
            return Error.UnclosedPlaceholder;
        const inside = template[i + 1 .. close_off];
        i = close_off + 1;

        const rendered = try renderPlaceholder(allocator, inside, md, fmt);
        defer if (rendered) |r| allocator.free(r);
        const value: ?[]const u8 = if (rendered) |r| r else null;

        if (value == null or value.?.len == 0) {
            if (out.items.len > 0 and out.items[out.items.len - 1] == ' ' and
                i < template.len and template[i] == ' ')
            {
                i += 1;
            } else if (out.items.len > 0 and out.items[out.items.len - 1] == ' ' and
                i < template.len and template[i] == '-' and
                i + 1 < template.len and template[i + 1] == ' ')
            {
                _ = out.pop();
                i += 2;
            }
            continue;
        }

        try out.appendSlice(allocator, value.?);
    }

    return collapseSpaces(allocator, out.items);
}

pub const Field = struct { name: []const u8, value: []const u8 };

/// Render `template` substituting `{name}` / `{name:0N}` from `fields`.
/// Numeric zero-padding applies when the value is all digits. Missing or
/// empty fields render empty (surrounding " - " / "/" separators collapse
/// via the shared `collapseSpaces`). Values are sanitized like `render`.
pub fn renderFields(allocator: std.mem.Allocator, template: []const u8, fields: []const Field) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        const ch = template[i];
        if (ch != '{') {
            try out.append(allocator, ch);
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse
            return Error.UnclosedPlaceholder;
        const inside = template[i + 1 .. close];
        i = close + 1;

        var name = inside;
        var spec: []const u8 = "";
        if (std.mem.indexOfScalar(u8, inside, ':')) |c| {
            name = inside[0..c];
            spec = inside[c + 1 ..];
        }

        const raw = lookupField(fields, name) orelse continue;
        if (raw.len == 0) continue;

        var pad_buf: [32]u8 = undefined;
        var value: []const u8 = raw;
        if (spec.len >= 2 and spec[0] == '0' and allDigits(raw)) {
            const width = std.fmt.parseInt(usize, spec[1..], 10) catch 0;
            if (width > raw.len and width <= pad_buf.len) {
                const pad = width - raw.len;
                @memset(pad_buf[0..pad], '0');
                @memcpy(pad_buf[pad..width], raw);
                value = pad_buf[0..width];
            }
        }

        const clean = try sanitize(allocator, value);
        defer allocator.free(clean);
        try out.appendSlice(allocator, clean);
    }
    return collapseSpaces(allocator, out.items);
}

fn lookupField(fields: []const Field, name: []const u8) ?[]const u8 {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Returns null if the placeholder resolved to a "missing" value (so
/// the caller can collapse surrounding whitespace), otherwise an
/// owned sanitized slice.
fn renderPlaceholder(
    allocator: std.mem.Allocator,
    spec: []const u8,
    md: meta.BookMetadata,
    fmt: meta.Format,
) !?[]u8 {
    var field = spec;
    var fmt_spec: []const u8 = "";
    if (std.mem.indexOfScalar(u8, spec, ':')) |colon| {
        field = spec[0..colon];
        fmt_spec = spec[colon + 1 ..];
    }

    if (std.mem.eql(u8, field, "author_sort")) {
        return try sanitize(allocator, md.primaryAuthorSort());
    }
    if (std.mem.eql(u8, field, "author")) {
        if (md.authors.len == 0) return null;
        const a = md.authors[0];
        const display = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s}",
            .{ a.first, if (a.first.len > 0 and a.last.len > 0) " " else "", a.last },
        );
        defer allocator.free(display);
        return try sanitize(allocator, display);
    }
    if (std.mem.eql(u8, field, "title")) {
        if (md.title) |t| return try sanitize(allocator, t);
        return null;
    }
    if (std.mem.eql(u8, field, "series")) {
        if (md.series) |s| return try sanitize(allocator, s);
        return null;
    }
    if (std.mem.eql(u8, field, "series_index")) {
        const idx = md.series_index orelse return null;
        return try renderNumeric(allocator, idx, fmt_spec);
    }
    if (std.mem.eql(u8, field, "year")) {
        const y = md.published_year orelse return null;
        return try std.fmt.allocPrint(allocator, "{d}", .{y});
    }
    if (std.mem.eql(u8, field, "isbn")) {
        if (md.isbn) |s| return try allocator.dupe(u8, s);
        return null;
    }
    if (std.mem.eql(u8, field, "format")) {
        return try allocator.dupe(u8, @tagName(fmt));
    }
    if (std.mem.eql(u8, field, "ext")) {
        return try allocator.dupe(u8, fmt.extension());
    }

    return try std.fmt.allocPrint(allocator, "{{{s}}}", .{field});
}

fn renderNumeric(allocator: std.mem.Allocator, value: f32, fmt_spec: []const u8) ![]u8 {
    const has_frac = @floor(value) != value;
    if (has_frac) return std.fmt.allocPrint(allocator, "{d:.1}", .{value});

    var width: usize = 2;
    if (fmt_spec.len > 0) {
        if (fmt_spec.len == 2 and fmt_spec[0] == '0') {
            width = std.fmt.parseInt(usize, fmt_spec[1..], 10) catch return Error.InvalidFormatSpec;
        } else if (std.mem.indexOf(u8, fmt_spec, "0>")) |_| {
            const w_start = std.mem.lastIndexOfScalar(u8, fmt_spec, '>') orelse return Error.InvalidFormatSpec;
            width = std.fmt.parseInt(usize, fmt_spec[w_start + 1 ..], 10) catch return Error.InvalidFormatSpec;
        } else {
            width = std.fmt.parseInt(usize, fmt_spec, 10) catch return Error.InvalidFormatSpec;
        }
    }
    const int_val: u32 = @intFromFloat(value);
    var buf: [16]u8 = undefined;
    var s = try std.fmt.bufPrint(&buf, "{d}", .{int_val});
    while (s.len < width and s.len + 1 < buf.len) {
        std.mem.copyBackwards(u8, buf[1 .. s.len + 1], buf[0..s.len]);
        buf[0] = '0';
        s = buf[0 .. s.len + 1];
    }
    return allocator.dupe(u8, s);
}

const ILLEGAL = [_]u8{ '\\', ':', '?', '*', '|', '<', '>', '"', '\x00' };

fn sanitize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
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
    while (buf.items.len > 0) {
        const last = buf.items[buf.items.len - 1];
        if (last == '.' or last == ' ') {
            _ = buf.pop();
        } else break;
    }
    if (buf.items.len == 0) try buf.appendSlice(allocator, "untitled");
    return buf.toOwnedSlice(allocator);
}

fn collapseSpaces(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var spaced: std.ArrayList(u8) = .empty;
    defer spaced.deinit(allocator);
    var prev_space = false;
    for (src) |ch| {
        if (ch == ' ') {
            if (!prev_space) try spaced.append(allocator, ch);
            prev_space = true;
        } else {
            try spaced.append(allocator, ch);
            prev_space = false;
        }
    }

    var unslashed: std.ArrayList(u8) = .empty;
    defer unslashed.deinit(allocator);
    var prev_slash = false;
    for (spaced.items) |ch| {
        if (ch == '/') {
            if (!prev_slash) try unslashed.append(allocator, ch);
            prev_slash = true;
        } else {
            try unslashed.append(allocator, ch);
            prev_slash = false;
        }
    }

    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(allocator);
    var i: usize = 0;
    while (i < unslashed.items.len) {
        const s = unslashed.items[i..];
        if (s.len >= 3 and s[0] == ' ' and s[1] == '(' and s[2] == ')') {
            i += 3;
            continue;
        }
        if (s.len >= 4 and s[0] == '/' and std.mem.eql(u8, s[0..4], "/ - ")) {
            try stripped.append(allocator, '/');
            i += 4;
            continue;
        }
        if (s.len >= 4 and std.mem.eql(u8, s[0..4], " - /")) {
            try stripped.append(allocator, '/');
            i += 4;
            continue;
        }
        if (s.len >= 5 and std.mem.eql(u8, s[0..5], " - - ")) {
            try stripped.appendSlice(allocator, " - ");
            i += 5;
            continue;
        }
        try stripped.append(allocator, unslashed.items[i]);
        i += 1;
    }

    var slice = stripped.items;
    while (slice.len > 0 and (slice[slice.len - 1] == ' ' or slice[slice.len - 1] == '-' or slice[slice.len - 1] == '/'))
        slice = slice[0 .. slice.len - 1];
    while (slice.len > 0 and slice[0] == '/') slice = slice[1..];
    if (std.mem.indexOfScalar(u8, slice, '.')) |dot| {
        var head = slice[0..dot];
        while (head.len > 0 and (head[head.len - 1] == ' ' or head[head.len - 1] == '-'))
            head = head[0 .. head.len - 1];
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ head, slice[dot..] });
    }
    return allocator.dupe(u8, slice);
}

const test_alloc = std.testing.allocator;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

fn mkAuthor(comptime last: []const u8, comptime first: []const u8) meta.Author {
    return .{ .last = last, .first = first, .sort = last ++ ", " ++ first };
}

test "default template with full metadata" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "The Way of Kings",
        .authors = &[_]meta.Author{mkAuthor("Sanderson", "Brandon")},
        .series = "Stormlight",
        .series_index = 1.0,
        .published_year = 2010,
    };
    const out = try render(alloc, DEFAULT_TEMPLATE, md, .epub);
    defer alloc.free(out);
    try expectEqualStrings("Sanderson, Brandon - Stormlight 01 - The Way of Kings.epub", out);
}

test "default template with missing series collapses cleanly" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "Augustus",
        .authors = &[_]meta.Author{mkAuthor("Williams", "John")},
    };
    const out = try render(alloc, DEFAULT_TEMPLATE, md, .epub);
    defer alloc.free(out);
    try expectEqualStrings("Williams, John - Augustus.epub", out);
}

test "fractional series_index renders with one decimal" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "Side Tale",
        .authors = &[_]meta.Author{mkAuthor("Erikson", "Steven")},
        .series = "Malazan",
        .series_index = 2.5,
    };
    const out = try render(alloc, DEFAULT_TEMPLATE, md, .epub);
    defer alloc.free(out);
    try expectEqualStrings("Erikson, Steven - Malazan 2.5 - Side Tale.epub", out);
}

test "custom width for series_index" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "Book",
        .authors = &[_]meta.Author{mkAuthor("X", "Y")},
        .series = "S",
        .series_index = 7,
    };
    const out = try render(alloc, "{series_index:03} - {title}.{ext}", md, .epub);
    defer alloc.free(out);
    try expectEqualStrings("007 - Book.epub", out);
}

test "year and isbn fields" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "X",
        .authors = &[_]meta.Author{mkAuthor("A", "B")},
        .published_year = 2024,
        .isbn = "9780000000001",
    };
    const out = try render(alloc, "{author_sort} - {title} ({year}) [{isbn}].{ext}", md, .epub);
    defer alloc.free(out);
    try expectEqualStrings("A, B - X (2024) [9780000000001].epub", out);
}

test "missing title fails fast" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .authors = &[_]meta.Author{mkAuthor("X", "Y")},
    };
    try expectError(Error.IncompleteMetadata, render(alloc, DEFAULT_TEMPLATE, md, .epub));
}

test "series-dir template generates subdirectory" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "Book",
        .authors = &[_]meta.Author{mkAuthor("Hobb", "Robin")},
        .series = "Farseer",
        .series_index = 1,
    };
    const out = try render(alloc, SERIES_DIR_TEMPLATE, md, .mobi);
    defer alloc.free(out);
    try expectEqualStrings("Hobb, Robin/Farseer/01 - Book.mobi", out);
}

test "series-dir falls back gracefully when series is missing" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "Augustus",
        .authors = &[_]meta.Author{mkAuthor("Williams", "John")},
    };
    const out = try render(alloc, SERIES_DIR_TEMPLATE, md, .epub);
    defer alloc.free(out);
    try expectEqualStrings("Williams, John/Augustus.epub", out);
}

test "renderFields builds a TV path with zero-padding" {
    const alloc = test_alloc;
    const fields = [_]Field{
        .{ .name = "series", .value = "Witch Hat Atelier" },
        .{ .name = "season", .value = "1" },
        .{ .name = "episode", .value = "12" },
        .{ .name = "title", .value = "The Shadow of Romonon" },
        .{ .name = "ext", .value = "mkv" },
    };
    const out = try renderFields(alloc, "TV/{series}/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("TV/Witch Hat Atelier/Season 01/Witch Hat Atelier - S01E12 - The Shadow of Romonon.mkv", out);
}

test "renderFields drops empty parenthesized year" {
    const alloc = test_alloc;
    const fields = [_]Field{
        .{ .name = "album_artist", .value = "Solo" },
        .{ .name = "album", .value = "NoYear" },
        .{ .name = "year", .value = "" },
        .{ .name = "track", .value = "1" },
        .{ .name = "title", .value = "Song" },
        .{ .name = "ext", .value = "mp3" },
    };
    const out = try renderFields(alloc, "Music/{album_artist}/{album} ({year})/{track:02} - {title}.{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("Music/Solo/NoYear/01 - Song.mp3", out);
}

test "renderFields drops empty year before extension" {
    const alloc = test_alloc;
    const fields = [_]Field{
        .{ .name = "title", .value = "The Matrix" },
        .{ .name = "year", .value = "" },
        .{ .name = "ext", .value = "mkv" },
    };
    const out = try renderFields(alloc, "Movies/{title} ({year})/{title} ({year}).{ext}", &fields);
    defer alloc.free(out);
    try expectEqualStrings("Movies/The Matrix/The Matrix.mkv", out);
}

test "unknown field renders literally" {
    const alloc = test_alloc;
    const md = meta.BookMetadata{
        .title = "X",
        .authors = &[_]meta.Author{mkAuthor("A", "B")},
    };
    const out = try render(alloc, "{nonsense} - {title}.{ext}", md, .epub);
    defer alloc.free(out);
    try expectEqualStrings("{nonsense} - X.epub", out);
}
