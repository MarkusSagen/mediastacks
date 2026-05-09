//! Jaro-Winkler similarity for fuzzy duplicate detection.
//!
//! Implementation follows the standard algorithm: matching chars are those
//! within match_distance positions of each other; transpositions count
//! pairs that are matched but in different order; Winkler bonus boosts
//! prefix matches up to 4 chars.

const std = @import("std");

pub fn jaro(a: []const u8, b: []const u8) f32 {
    if (a.len == 0 and b.len == 0) return 1;
    if (a.len == 0 or b.len == 0) return 0;

    const max_len = @max(a.len, b.len);
    const match_distance: usize = if (max_len > 1) max_len / 2 - 1 else 0;

    var a_match = std.heap.page_allocator.alloc(bool, a.len) catch return 0;
    defer std.heap.page_allocator.free(a_match);
    var b_match = std.heap.page_allocator.alloc(bool, b.len) catch return 0;
    defer std.heap.page_allocator.free(b_match);
    @memset(a_match, false);
    @memset(b_match, false);

    var matches: f32 = 0;
    for (a, 0..) |ca, i| {
        const start = if (i > match_distance) i - match_distance else 0;
        const end = @min(i + match_distance + 1, b.len);
        var j = start;
        while (j < end) : (j += 1) {
            if (b_match[j]) continue;
            if (ca != b[j]) continue;
            a_match[i] = true;
            b_match[j] = true;
            matches += 1;
            break;
        }
    }
    if (matches == 0) return 0;

    var t: f32 = 0;
    var k: usize = 0;
    for (a, 0..) |ca, i| {
        if (!a_match[i]) continue;
        while (!b_match[k]) k += 1;
        if (ca != b[k]) t += 1;
        k += 1;
    }
    t /= 2;

    const m = matches;
    return (m / @as(f32, @floatFromInt(a.len)) +
        m / @as(f32, @floatFromInt(b.len)) +
        (m - t) / m) / 3;
}

pub fn jaroWinkler(a: []const u8, b: []const u8) f32 {
    const j = jaro(a, b);
    if (j < 0.7) return j;
    var prefix: f32 = 0;
    const limit = @min(@min(a.len, b.len), 4);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (a[i] != b[i]) break;
        prefix += 1;
    }
    return j + prefix * 0.1 * (1 - j);
}

test "jaro identical strings is 1" {
    try std.testing.expectApproxEqRel(@as(f32, 1.0), jaro("hello", "hello"), 0.0001);
}

test "jaro completely different strings is 0" {
    try std.testing.expectEqual(@as(f32, 0), jaro("abc", "xyz"));
}

test "jaroWinkler boost for prefix match" {
    const j = jaro("dwayne", "duane");
    const jw = jaroWinkler("dwayne", "duane");
    try std.testing.expect(jw > j);
}

test "jaroWinkler classic example" {
    const score = jaroWinkler("MARTHA", "MARHTA");
    try std.testing.expect(score > 0.96);
}
