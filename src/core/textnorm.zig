//! Repair garbled title/tag text so names, tags, and NFO all read cleanly.
//! Pure, total, no IO. Pipeline (see `clean`):
//!   HTML entities → mojibake → quote/apostrophe fold → strip invisibles +
//!   collapse whitespace.
//! Only ever fixes clearly-wrong characters; legitimate accented text and
//! intentional dashes are left untouched.

const std = @import("std");

/// Clean `s`. Owned by `alloc`.
pub fn clean(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const a = try decodeEntities(alloc, s);
    const b = try fixMojibake(alloc, a);
    const c = try foldQuotes(alloc, b);
    return finalizeWhitespace(alloc, c);
}

// ---- HTML entities ----------------------------------------------------

fn decodeEntities(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (matchEntity(s[i..])) |m| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(m.cp, &buf) catch 0;
                if (n > 0) {
                    try out.appendSlice(alloc, buf[0..n]);
                    i += m.consumed;
                    continue;
                }
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

const EntityMatch = struct { cp: u21, consumed: usize };

fn matchEntity(s: []const u8) ?EntityMatch {
    const named = [_]struct { name: []const u8, cp: u21 }{
        .{ .name = "&amp;", .cp = '&' },
        .{ .name = "&lt;", .cp = '<' },
        .{ .name = "&gt;", .cp = '>' },
        .{ .name = "&quot;", .cp = '"' },
        .{ .name = "&apos;", .cp = '\'' },
        .{ .name = "&nbsp;", .cp = ' ' },
        .{ .name = "&mdash;", .cp = 0x2014 },
        .{ .name = "&ndash;", .cp = 0x2013 },
        .{ .name = "&hellip;", .cp = 0x2026 },
    };
    for (named) |e| {
        if (std.mem.startsWith(u8, s, e.name)) return .{ .cp = e.cp, .consumed = e.name.len };
    }
    // Numeric: &#DDD; or &#xHH;
    if (s.len >= 4 and s[1] == '#') {
        const semi = std.mem.indexOfScalar(u8, s, ';') orelse return null;
        if (semi > 3 and semi <= 12) {
            const hex = s[2] == 'x' or s[2] == 'X';
            const digits = s[if (hex) 3 else 2 .. semi];
            if (digits.len == 0) return null;
            const v = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
            if (v == 0 or v > 0x10FFFF) return null;
            return .{ .cp = v, .consumed = semi + 1 };
        }
    }
    return null;
}

// ---- Mojibake ---------------------------------------------------------

fn fixMojibake(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // (a) The common Windows-1252 double-encodings (all begin "â€…").
    const table = [_]struct { needle: []const u8, repl: []const u8 }{
        .{ .needle = "\u{e2}\u{20ac}\u{2122}", .repl = "'" }, // ’
        .{ .needle = "\u{e2}\u{20ac}\u{02dc}", .repl = "'" }, // ‘
        .{ .needle = "\u{e2}\u{20ac}\u{0153}", .repl = "\"" }, // “
        .{ .needle = "\u{e2}\u{20ac}\u{9d}", .repl = "\"" }, // ”
        .{ .needle = "\u{e2}\u{20ac}\u{a6}", .repl = "\u{2026}" }, // …
        .{ .needle = "\u{e2}\u{20ac}\u{201d}", .repl = "\u{2014}" }, // —
        .{ .needle = "\u{e2}\u{20ac}\u{201c}", .repl = "\u{2013}" }, // –
    };
    var cur = try alloc.dupe(u8, s);
    for (table) |e| cur = try replaceAll(alloc, cur, e.needle, e.repl);
    // (b) Latin-1 double-encoding (Ã©→é): re-interpret codepoints as bytes.
    if (try latin1Redecode(alloc, cur)) |r| return r;
    return cur;
}

/// If every codepoint of `s` is ≤ 0xFF, re-interpret those low bytes and, when
/// they form valid UTF-8 different from the input, return the decoded text.
/// The validity gate means legitimate accented text (not mojibake) is left
/// alone (its low-byte form is invalid UTF-8).
fn latin1Redecode(alloc: std.mem.Allocator, s: []const u8) !?[]u8 {
    const view = std.unicode.Utf8View.init(s) catch return null;
    var it = view.iterator();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    while (it.nextCodepoint()) |cp| {
        if (cp > 0xFF) return null;
        try bytes.append(alloc, @intCast(cp));
    }
    if (std.mem.eql(u8, bytes.items, s)) return null; // pure ASCII, unchanged
    if (!std.unicode.utf8ValidateSlice(bytes.items)) return null;
    return try alloc.dupe(u8, bytes.items);
}

fn replaceAll(alloc: std.mem.Allocator, s: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    if (needle.len == 0 or std.mem.indexOf(u8, s, needle) == null) return alloc.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + needle.len <= s.len and std.mem.eql(u8, s[i .. i + needle.len], needle)) {
            try out.appendSlice(alloc, repl);
            i += needle.len;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

// ---- Quote / apostrophe fold -----------------------------------------

fn isApostrophe(cp: u21) bool {
    return switch (cp) {
        0x2018, 0x2019, 0x02BC, 0x2032, 0x2035, 0x00B4, 0x0060 => true,
        else => false,
    };
}
fn isQuote(cp: u21) bool {
    return switch (cp) {
        0x201C, 0x201D, 0x201E, 0x2033, 0x2036, 0x00AB, 0x00BB => true,
        else => false,
    };
}

fn foldQuotes(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const view = std.unicode.Utf8View.init(s) catch return alloc.dupe(u8, s);
    var it = view.iterator();
    var out: std.ArrayList(u8) = .empty;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch {
            try out.appendSlice(alloc, slice);
            continue;
        };
        if (isApostrophe(cp)) {
            try out.append(alloc, '\'');
        } else if (isQuote(cp)) {
            try out.append(alloc, '"');
        } else {
            try out.appendSlice(alloc, slice);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ---- Strip invisibles + collapse whitespace --------------------------

fn isZeroWidth(cp: u21) bool {
    return cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF;
}
fn isControl(cp: u21) bool {
    // C0 (minus the whitespace we normalize) + DEL + C1
    if (cp == '\t' or cp == '\n' or cp == '\r') return false;
    return cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F);
}
fn isSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x00A0 or (cp >= 0x2000 and cp <= 0x200A);
}

fn finalizeWhitespace(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const view = std.unicode.Utf8View.init(s) catch return alloc.dupe(u8, s);
    var it = view.iterator();
    var out: std.ArrayList(u8) = .empty;
    var prev_space = false;
    while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch {
            try out.appendSlice(alloc, slice);
            prev_space = false;
            continue;
        };
        if (isZeroWidth(cp) or isControl(cp)) continue;
        if (isSpace(cp)) {
            if (!prev_space and out.items.len > 0) try out.append(alloc, ' ');
            prev_space = true;
        } else {
            try out.appendSlice(alloc, slice);
            prev_space = false;
        }
    }
    var end = out.items.len;
    while (end > 0 and out.items[end - 1] == ' ') end -= 1;
    out.shrinkRetainingCapacity(end);
    return out.toOwnedSlice(alloc);
}

const t = std.testing;

fn expectClean(a: std.mem.Allocator, in: []const u8, want: []const u8) !void {
    const got = try clean(a, in);
    try t.expectEqualStrings(want, got);
}

test "folds apostrophes and quotes to ASCII" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectClean(a, "Don\u{00B4}t", "Don't"); // acute accent
    try expectClean(a, "Don`t", "Don't"); // backtick
    try expectClean(a, "Rock\u{2019}n\u{2019}Roll", "Rock'n'Roll"); // curly '
    try expectClean(a, "\u{201C}Live\u{201D}", "\"Live\""); // curly "
}

test "fixes mojibake without harming valid accents" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectClean(a, "Communiqu\u{00C3}\u{00A9}", "Communiqu\u{00E9}"); // Ã© → é
    try expectClean(a, "Naïve", "Naïve"); // valid accent untouched
    try expectClean(a, "Caf\u{00E9}", "Caf\u{00E9}"); // valid é untouched
    try expectClean(a, "Na\u{00EF}ve \u{e2}\u{20ac}\u{2122}99", "Naïve '99"); // cp1252 ’
}

test "decodes HTML entities" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectClean(a, "AC&amp;DC", "AC&DC");
    try expectClean(a, "Rock &#39;n&#39; Roll", "Rock 'n' Roll"); // numeric → apostrophe
    try expectClean(a, "a &lt;b&gt;", "a <b>");
}

test "strips invisibles and collapses whitespace" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectClean(a, "  A   Title  ", "A Title");
    try expectClean(a, "Song\u{200B}", "Song"); // zero-width space
    try expectClean(a, "A\u{00A0}B", "A B"); // NBSP → space
}

test "clean text is unchanged" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectClean(a, "The Matrix", "The Matrix");
    try expectClean(a, "AC/DC - Back in Black", "AC/DC - Back in Black"); // dashes/slashes kept
}
