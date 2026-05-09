//! Confidence + completeness scoring for `BookMetadata`.

const std = @import("std");
const meta = @import("metadata.zig");

/// Fraction of "important" fields populated, in [0, 1].
pub fn completeness(md: meta.BookMetadata) f32 {
    var present: f32 = 0;
    var total: f32 = 0;

    inline for ([_]bool{
        md.title != null,
        md.authors.len > 0,
        md.series != null,
        md.series_index != null,
        md.published_year != null,
        md.isbn != null,
        md.publisher != null,
        md.language != null,
        md.cover_path != null,
        md.description != null,
    }) |populated| {
        total += 1;
        if (populated) present += 1;
    }
    return present / total;
}

pub fn missingFields(allocator: std.mem.Allocator, md: meta.BookMetadata) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (md.title == null) try out.append(allocator, "title");
    if (md.authors.len == 0) try out.append(allocator, "authors");
    if (md.series == null) try out.append(allocator, "series");
    if (md.series_index == null) try out.append(allocator, "series_index");
    if (md.published_year == null) try out.append(allocator, "published_year");
    if (md.isbn == null) try out.append(allocator, "isbn");
    if (md.cover_path == null) try out.append(allocator, "cover");
    return out.toOwnedSlice(allocator);
}

test "completeness on empty metadata is zero" {
    try std.testing.expectEqual(@as(f32, 0), completeness(.{}));
}

test "completeness on fully-populated metadata is one" {
    const author = meta.Author{ .last = "X", .first = "Y", .sort = "X, Y" };
    const md = meta.BookMetadata{
        .title = "T",
        .authors = &[_]meta.Author{author},
        .series = "S",
        .series_index = 1,
        .publisher = "P",
        .published_year = 2026,
        .isbn = "9780000000001",
        .language = "en",
        .description = "D",
        .cover_path = "/tmp/c.jpg",
    };
    try std.testing.expectEqual(@as(f32, 1), completeness(md));
}
