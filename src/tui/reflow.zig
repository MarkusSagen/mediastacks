//! Text reflow for the TUI reader: word-wrap a plaintext body into
//! lines of at most `width` cells, preserving paragraph breaks.
//!
//! Pagination: chop the line array into pages of `height` lines.
//! Trivial but enough for v1; refining (justification, hyphenation,
//! widow control) is a future polish.

const std = @import("std");

pub fn wrap(allocator: std.mem.Allocator, text: []const u8, width: usize) ![][]const u8 {
    if (width < 8) return error.WidthTooSmall;
    var lines: std.ArrayList([]const u8) = .empty;

    var paragraphs = std.mem.splitSequence(u8, text, "\n\n");
    var first_para = true;
    while (paragraphs.next()) |para_raw| {
        const para = std.mem.trim(u8, para_raw, " \t\r\n");
        if (para.len == 0) continue;
        if (!first_para) try lines.append(allocator, try allocator.dupe(u8, ""));
        first_para = false;
        try wrapParagraph(allocator, &lines, para, width);
    }
    return lines.toOwnedSlice(allocator);
}

fn wrapParagraph(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    text: []const u8,
    width: usize,
) !void {
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        const sep_len: usize = if (current.items.len == 0) 0 else 1;
        if (current.items.len + sep_len + word.len <= width) {
            if (sep_len > 0) try current.append(allocator, ' ');
            try current.appendSlice(allocator, word);
            continue;
        }
        if (current.items.len > 0) {
            try out.append(allocator, try allocator.dupe(u8, current.items));
            current.clearRetainingCapacity();
        }
        if (word.len > width) {
            var i: usize = 0;
            while (i + width <= word.len) : (i += width) {
                try out.append(allocator, try allocator.dupe(u8, word[i .. i + width]));
            }
            if (i < word.len) try current.appendSlice(allocator, word[i..]);
        } else {
            try current.appendSlice(allocator, word);
        }
    }
    if (current.items.len > 0) {
        try out.append(allocator, try allocator.dupe(u8, current.items));
    }
}

pub fn paginate(lines: []const []const u8, height: usize) usize {
    if (height == 0) return 1;
    const pages = (lines.len + height - 1) / height;
    return @max(pages, 1);
}

test "wrap respects width and preserves paragraph breaks" {
    const alloc = std.testing.allocator;
    const lines = try wrap(
        alloc,
        "The quick brown fox jumps over the lazy dog.\n\nThis is paragraph two of the test.",
        20,
    );
    defer {
        for (lines) |l| alloc.free(l);
        alloc.free(lines);
    }
    try std.testing.expect(lines.len >= 5);
    for (lines) |l| try std.testing.expect(l.len <= 20);
    var found_blank = false;
    for (lines) |l| if (l.len == 0) {
        found_blank = true;
        break;
    };
    try std.testing.expect(found_blank);
}

test "wrap breaks very long words" {
    const alloc = std.testing.allocator;
    const lines = try wrap(alloc, "supercalifragilisticexpialidocious", 10);
    defer {
        for (lines) |l| alloc.free(l);
        alloc.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    for (lines) |l| try std.testing.expect(l.len <= 10);
}

test "paginate counts pages" {
    const lines = [_][]const u8{ "a", "b", "c", "d", "e" };
    try std.testing.expectEqual(@as(usize, 2), paginate(&lines, 3));
    try std.testing.expectEqual(@as(usize, 1), paginate(&lines, 10));
    try std.testing.expectEqual(@as(usize, 5), paginate(&lines, 1));
}
