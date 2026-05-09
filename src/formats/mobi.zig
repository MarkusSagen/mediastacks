//! MOBI/AZW3 reader — pulls embedded metadata via libmobi.

const std = @import("std");
const ffi = @import("../ffi/libmobi.zig");
const meta = @import("../core/metadata.zig");

pub fn readMetadata(allocator: std.mem.Allocator, path: []const u8) !meta.BookMetadata {
    var book = try ffi.MobiBook.open(path);
    defer book.close();

    const title = try book.title(allocator);
    const author_raw = try book.author(allocator);
    const publisher = try book.publisher(allocator);
    const isbn = try book.isbn(allocator);
    const description = try book.description(allocator);
    const language = try book.language(allocator);
    const pubdate = try book.publishDate(allocator);

    var authors_buf: std.ArrayList(meta.Author) = .empty;
    if (author_raw) |raw| {
        const author = try meta.Author.fromDisplay(allocator, raw);
        try authors_buf.append(allocator, author);
        allocator.free(raw);
    }

    var year: ?u16 = null;
    if (pubdate) |pd| {
        defer allocator.free(pd);
        if (pd.len >= 4) {
            year = std.fmt.parseInt(u16, pd[0..4], 10) catch null;
        }
    }

    return .{
        .title = title,
        .authors = try authors_buf.toOwnedSlice(allocator),
        .publisher = publisher,
        .isbn = isbn,
        .description = description,
        .language = language,
        .published_year = year,
        .source = .embedded,
        .confidence = 0.9,
    };
}
