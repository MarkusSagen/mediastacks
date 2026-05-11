//! Canonical book metadata model.
//!
//! Every format reader, provider, and command speaks `BookMetadata`.
//! Strings are owned by the caller-provided allocator (typically an arena).

const std = @import("std");

pub const Source = enum {
    embedded, // From the file's own metadata block
    openlibrary,
    google_books,
    goodreads,
    manual,
    derived, // Computed from filename/path heuristics

    pub fn rank(self: Source) u8 {
        // Higher = trusted more during merge
        return switch (self) {
            .manual => 100,
            .embedded => 80,
            .openlibrary => 60,
            .google_books => 55,
            .goodreads => 70, // Best for series
            .derived => 20,
        };
    }
};

pub const Author = struct {
    last: []const u8,
    first: []const u8,
    sort: []const u8, // "Last, First" — pre-computed for sorting

    pub fn fromDisplay(allocator: std.mem.Allocator, display_name: []const u8) !Author {
        const trimmed = std.mem.trim(u8, display_name, " \t\r\n");
        if (std.mem.indexOfScalar(u8, trimmed, ',')) |comma| {
            // "Last, First" — already in sort order
            const last = std.mem.trim(u8, trimmed[0..comma], " \t");
            const first = std.mem.trim(u8, trimmed[comma + 1 ..], " \t");
            return .{
                .last = try allocator.dupe(u8, last),
                .first = try allocator.dupe(u8, first),
                .sort = try allocator.dupe(u8, trimmed),
            };
        } else if (std.mem.lastIndexOfScalar(u8, trimmed, ' ')) |sp| {
            // "First [Middle] Last" — split on last space
            const first = std.mem.trim(u8, trimmed[0..sp], " \t");
            const last = std.mem.trim(u8, trimmed[sp + 1 ..], " \t");
            const sort = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ last, first });
            return .{
                .last = try allocator.dupe(u8, last),
                .first = try allocator.dupe(u8, first),
                .sort = sort,
            };
        } else {
            // Single token
            const dup = try allocator.dupe(u8, trimmed);
            return .{ .last = dup, .first = "", .sort = dup };
        }
    }
};

pub const Format = enum {
    epub,
    mobi,
    azw3,
    pdf,
    unknown,

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .epub => "epub",
            .mobi => "mobi",
            .azw3 => "azw3",
            .pdf => "pdf",
            .unknown => "",
        };
    }

    pub fn fromExtension(ext: []const u8) Format {
        const lower_buf = ext;
        if (std.ascii.eqlIgnoreCase(lower_buf, "epub")) return .epub;
        if (std.ascii.eqlIgnoreCase(lower_buf, "mobi")) return .mobi;
        if (std.ascii.eqlIgnoreCase(lower_buf, "azw")) return .azw3;
        if (std.ascii.eqlIgnoreCase(lower_buf, "azw3")) return .azw3;
        if (std.ascii.eqlIgnoreCase(lower_buf, "prc")) return .mobi;
        if (std.ascii.eqlIgnoreCase(lower_buf, "pdf")) return .pdf;
        return .unknown;
    }
};

pub const BookMetadata = struct {
    title: ?[]const u8 = null,
    authors: []const Author = &.{},
    series: ?[]const u8 = null,
    series_index: ?f32 = null,
    publisher: ?[]const u8 = null,
    published_year: ?u16 = null,
    isbn: ?[]const u8 = null,
    language: ?[]const u8 = null,
    description: ?[]const u8 = null,
    cover_path: ?[]const u8 = null,
    /// Genre / category labels (BISAC subjects from the OPF, or
    /// libmobi's subject getter). Free-form strings.
    subjects: []const []const u8 = &.{},
    source: Source = .embedded,
    confidence: f32 = 0.5,

    /// True if every field a renamed file needs is present.
    pub fn isComplete(self: BookMetadata) bool {
        return self.title != null and
            self.authors.len > 0 and
            self.published_year != null;
    }

    /// True specifically for the rename feature (needs author + title; series optional).
    pub fn isRenameable(self: BookMetadata) bool {
        return self.title != null and self.authors.len > 0;
    }

    /// Produce the canonical sort key for the primary author, "Last, First".
    pub fn primaryAuthorSort(self: BookMetadata) []const u8 {
        if (self.authors.len == 0) return "Unknown";
        return self.authors[0].sort;
    }

    /// Field-by-field merge: pick the higher-confidence value at each field.
    /// `out` is allocated using `allocator`. Inputs are not freed.
    pub fn merge(allocator: std.mem.Allocator, a: BookMetadata, b: BookMetadata) !BookMetadata {
        const a_w = a.confidence * @as(f32, @floatFromInt(a.source.rank()));
        const b_w = b.confidence * @as(f32, @floatFromInt(b.source.rank()));
        const prefer_b = b_w > a_w;
        const lo: BookMetadata = if (prefer_b) a else b;
        const hi: BookMetadata = if (prefer_b) b else a;
        _ = allocator;

        // The "winner" provides everything it has; loser fills nulls.
        return .{
            .title = hi.title orelse lo.title,
            .authors = if (hi.authors.len > 0) hi.authors else lo.authors,
            .series = hi.series orelse lo.series,
            .series_index = hi.series_index orelse lo.series_index,
            .publisher = hi.publisher orelse lo.publisher,
            .published_year = hi.published_year orelse lo.published_year,
            .isbn = hi.isbn orelse lo.isbn,
            .language = hi.language orelse lo.language,
            .description = hi.description orelse lo.description,
            .cover_path = hi.cover_path orelse lo.cover_path,
            .subjects = if (hi.subjects.len > 0) hi.subjects else lo.subjects,
            .source = hi.source,
            .confidence = @max(hi.confidence, lo.confidence),
        };
    }
};

// ---- Tests --------------------------------------------------------------

test "Author.fromDisplay handles 'Last, First'" {
    const alloc = std.testing.allocator;
    const a = try Author.fromDisplay(alloc, "Tolkien, J.R.R.");
    defer alloc.free(a.last);
    defer alloc.free(a.first);
    defer alloc.free(a.sort);
    try std.testing.expectEqualStrings("Tolkien", a.last);
    try std.testing.expectEqualStrings("J.R.R.", a.first);
    try std.testing.expectEqualStrings("Tolkien, J.R.R.", a.sort);
}

test "Author.fromDisplay handles 'First Last'" {
    const alloc = std.testing.allocator;
    const a = try Author.fromDisplay(alloc, "Brandon Sanderson");
    defer alloc.free(a.last);
    defer alloc.free(a.first);
    defer alloc.free(a.sort);
    try std.testing.expectEqualStrings("Sanderson", a.last);
    try std.testing.expectEqualStrings("Brandon", a.first);
    try std.testing.expectEqualStrings("Sanderson, Brandon", a.sort);
}

test "Author.fromDisplay handles single token" {
    const alloc = std.testing.allocator;
    const a = try Author.fromDisplay(alloc, "Homer");
    defer alloc.free(a.last);
    try std.testing.expectEqualStrings("Homer", a.last);
    try std.testing.expectEqualStrings("Homer", a.sort);
}

test "Format roundtrips via extension" {
    try std.testing.expectEqual(Format.epub, Format.fromExtension("epub"));
    try std.testing.expectEqual(Format.epub, Format.fromExtension("EPUB"));
    try std.testing.expectEqual(Format.mobi, Format.fromExtension("prc"));
    try std.testing.expectEqual(Format.azw3, Format.fromExtension("azw"));
    try std.testing.expectEqual(Format.unknown, Format.fromExtension("txt"));
}

test "BookMetadata.merge prefers higher-ranked source" {
    const a = BookMetadata{
        .title = "Old",
        .source = .derived,
        .confidence = 1.0,
    };
    const b = BookMetadata{
        .title = "New",
        .source = .openlibrary,
        .confidence = 0.7,
    };
    const merged = try BookMetadata.merge(std.testing.allocator, a, b);
    try std.testing.expectEqualStrings("New", merged.title.?);
}

test "BookMetadata.isRenameable" {
    const author = Author{ .last = "X", .first = "Y", .sort = "X, Y" };
    try std.testing.expect(!(BookMetadata{}).isRenameable());
    try std.testing.expect((BookMetadata{
        .title = "T",
        .authors = &[_]Author{author},
    }).isRenameable());
}
