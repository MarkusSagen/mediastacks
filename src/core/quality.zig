//! Quality scoring used by dedup to pick the best copy.
//!
//! Heuristic (higher = better):
//!   format          EPUB > AZW3 > MOBI > PDF
//!   metadata        +5 per populated key field (ISBN, year, series, cover)
//!   size            log2(bytes) — bigger files almost always carry more content
//!   confidence      direct add of source confidence
//!
//! Tweakable from one place; dedup just calls scoreBook().

const std = @import("std");
const meta = @import("metadata.zig");
const catalog_mod = @import("catalog.zig");

pub fn scoreBook(b: catalog_mod.Book) f32 {
    var score: f32 = 0;
    score += formatScore(b.format);
    if (b.metadata.isbn != null) score += 5;
    if (b.metadata.published_year != null) score += 5;
    if (b.metadata.series != null) score += 3;
    if (b.metadata.cover_path != null) score += 3;
    if (b.metadata.description != null) score += 2;
    score += @log2(@as(f32, @floatFromInt(@max(b.size, 1))));
    score += b.metadata.confidence * 5;
    return score;
}

fn formatScore(fmt: meta.Format) f32 {
    return switch (fmt) {
        .epub => 30,
        .azw3 => 25,
        .mobi => 20,
        .pdf => 10,
        .cbz, .cbr, .cb7, .cbt => 10,
        .unknown => 0,
    };
}

const t = std.testing;

fn book(fmt: meta.Format, isbn: ?[]const u8, size: u64) catalog_mod.Book {
    return .{
        .id = 0,
        .path = "",
        .sha256 = "",
        .size = size,
        .format = fmt,
        .mtime = 0,
        .metadata = .{ .isbn = isbn, .confidence = 0.5 },
    };
}

test "EPUB beats MOBI when all else equal" {
    const a = book(.epub, null, 1_000_000);
    const b = book(.mobi, null, 1_000_000);
    try t.expect(scoreBook(a) > scoreBook(b));
}

test "metadata gap narrows the format gap" {
    const epub_no_isbn = book(.epub, null, 500_000);
    const mobi_with_isbn = book(.mobi, "9780000000001", 500_000);
    const gap_no_isbn = scoreBook(book(.epub, null, 500_000)) - scoreBook(book(.mobi, null, 500_000));
    const gap_with_isbn = scoreBook(epub_no_isbn) - scoreBook(mobi_with_isbn);
    try t.expect(gap_with_isbn < gap_no_isbn);
}

test "larger size as final tiebreaker" {
    const small = book(.epub, "9780000000001", 100_000);
    const big = book(.epub, "9780000000001", 10_000_000);
    try t.expect(scoreBook(big) > scoreBook(small));
}
