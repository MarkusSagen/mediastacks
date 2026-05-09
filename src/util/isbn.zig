//! ISBN normalization and checksum validation.

const std = @import("std");

/// Strip dashes/spaces, uppercase. Returns owned slice.
pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (raw) |ch| {
        if (ch == '-' or ch == ' ' or ch == '\t') continue;
        try buf.append(allocator, std.ascii.toUpper(ch));
    }
    return buf.toOwnedSlice(allocator);
}

pub fn isValidIsbn13(s: []const u8) bool {
    if (s.len != 13) return false;
    var sum: u32 = 0;
    for (s, 0..) |ch, i| {
        if (!std.ascii.isDigit(ch)) return false;
        const d = ch - '0';
        sum += if (i % 2 == 0) d else d * 3;
    }
    return sum % 10 == 0;
}

pub fn isValidIsbn10(s: []const u8) bool {
    if (s.len != 10) return false;
    var sum: u32 = 0;
    for (s, 0..) |ch, i| {
        const d: u32 = if (i == 9 and (ch == 'X' or ch == 'x'))
            10
        else if (std.ascii.isDigit(ch))
            ch - '0'
        else
            return false;
        sum += d * @as(u32, @intCast(10 - i));
    }
    return sum % 11 == 0;
}

test "normalize strips dashes" {
    const alloc = std.testing.allocator;
    const out = try normalize(alloc, "978-0-545-01022-1");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("9780545010221", out);
}

test "isValidIsbn13 accepts valid" {
    try std.testing.expect(isValidIsbn13("9780545010221"));
}

test "isValidIsbn13 rejects bad checksum" {
    try std.testing.expect(!isValidIsbn13("9780545010222"));
}

test "isValidIsbn10 accepts valid with X" {
    try std.testing.expect(isValidIsbn10("043942089X"));
}
