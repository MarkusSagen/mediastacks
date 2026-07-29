//! Kind-agnostic "best copy" scoring for the organizer's dedup step.
//!
//! `core/quality.zig` / `core/score.zig` score `catalog.Book`
//! (ISBN/series/format) — book-specific. This is the video equivalent:
//! resolution tier first, file size as the tiebreaker.

const std = @import("std");

fn tierScore(quality: ?[]const u8) f32 {
    const q = quality orelse return 0;
    if (eq(q, "2160p") or eq(q, "4k")) return 40;
    if (eq(q, "1080p")) return 30;
    if (eq(q, "720p")) return 20;
    if (eq(q, "480p")) return 10;
    return 0;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Higher is better. Resolution tier dominates; size breaks ties within a
/// tier.
pub fn videoScore(quality: ?[]const u8, size: u64) f32 {
    return tierScore(quality) + @log2(@as(f32, @floatFromInt(@max(size, 1))));
}

const t = std.testing;

test "1080p beats 720p at equal size" {
    try t.expect(videoScore("1080p", 1_000_000) > videoScore("720p", 1_000_000));
}
test "larger file breaks ties within a tier" {
    try t.expect(videoScore("1080p", 10_000_000) > videoScore("1080p", 1_000_000));
}
test "unknown quality still scores by size" {
    try t.expect(videoScore(null, 10_000_000) > videoScore(null, 1_000_000));
}
