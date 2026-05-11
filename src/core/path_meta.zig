//! Derive metadata from a book's filename or path.
//!
//! Filenames in personal libraries usually encode more reliable series
//! info than any provider — Open Library has series data on only a
//! fraction of works, but a file called
//! `Hobb, Robin - The Farseer Trilogy 01 - Assassin's Apprentice.mobi`
//! tells us series and index unambiguously.
//!
//! Recognised patterns (basename, after stripping extension):
//!
//!   1. `Author - Series NN - Title`         (three " - " segments)
//!   2. `Author - Series #NN - Title`
//!   3. `Author - Title (Series NN)`         (trailing parens)
//!   4. `Author - Title (Series #NN)`
//!   5. `Series NN - Title`                  (two segments, leading
//!                                            block looks like a series)
//!
//! The Calibre folder layout `Author/Series/NN - Title.ext` is also
//! handled when the parent dir name doesn't look like an author.
//!
//! Pure parsing — no I/O, no allocation beyond duping the slices the
//! caller asks for. All strings in the returned struct are owned by the
//! caller-provided allocator.

const std = @import("std");

pub const Derived = struct {
    author: ?[]const u8 = null,
    title: ?[]const u8 = null,
    series: ?[]const u8 = null,
    series_index: ?f32 = null,
};

/// Walk the path's basename (and optionally its parents, for Calibre
/// layouts) and pull out what we can. Missing pieces stay null.
pub fn fromPath(allocator: std.mem.Allocator, path: []const u8) !Derived {
    const basename = std.fs.path.basename(path);
    const ext_dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = std.mem.trim(u8, basename[0..ext_dot], " ");

    // Try patterns 1+2: "Author - Series NN - Title" (or " - " separated
    // into 3 or 4 pieces). We split with a max of 4 to stay defensive
    // against titles that happen to contain " - ".
    var pieces: [4][]const u8 = undefined;
    const nparts = splitOn(stem, " - ", &pieces);

    if (nparts == 3) {
        const author_part = std.mem.trim(u8, pieces[0], " ");
        const middle = std.mem.trim(u8, pieces[1], " ");
        const title_part = std.mem.trim(u8, pieces[2], " ");

        const split = extractTrailingIndex(middle);
        if (split) |s| {
            return .{
                .author = if (author_part.len > 0) try allocator.dupe(u8, author_part) else null,
                .title = if (title_part.len > 0) try allocator.dupe(u8, title_part) else null,
                .series = try allocator.dupe(u8, s.name),
                .series_index = s.index,
            };
        }
    }

    // Pattern 3+4: "Author - Title (Series NN)". Look for trailing
    // parens with a series-and-number inside.
    if (extractTrailingParens(stem)) |paren| {
        const inner_split = extractTrailingIndex(paren.inner);
        if (inner_split) |s| {
            // What's before the parens is "Author - Title" or just "Title".
            const before = std.mem.trim(u8, stem[0..paren.start], " ");
            const sub = splitTwo(before, " - ");
            return .{
                .author = if (sub.lhs) |l| try allocator.dupe(u8, l) else null,
                .title = if (sub.rhs) |r|
                    try allocator.dupe(u8, r)
                else if (before.len > 0)
                    try allocator.dupe(u8, before)
                else
                    null,
                .series = try allocator.dupe(u8, s.name),
                .series_index = s.index,
            };
        }
    }

    // Pattern 5: "Series NN - Title" (two segments, leading block has
    // a trailing number).
    if (nparts == 2) {
        const first = std.mem.trim(u8, pieces[0], " ");
        const second = std.mem.trim(u8, pieces[1], " ");
        if (extractTrailingIndex(first)) |s| {
            return .{
                .title = if (second.len > 0) try allocator.dupe(u8, second) else null,
                .series = try allocator.dupe(u8, s.name),
                .series_index = s.index,
            };
        }
    }

    return .{};
}

/// Choose between two series candidates. The user's request: when both
/// a filename-derived and an OL-derived series exist, prefer the
/// filename one. Among multiple OL candidates we'd prefer the longest
/// (most specific) name — meta-series like "Realm of the Elderlings"
/// are usually shorter than the sub-series like "The Farseer Trilogy".
///
/// Returns the slice that should be used. Both inputs may be null.
pub fn pickPrimarySeries(from_path: ?[]const u8, from_provider: ?[]const u8) ?[]const u8 {
    if (from_path) |p| return p;
    return from_provider;
}

// ---- Internal -----------------------------------------------------------

/// Split `s` on `sep`, writing up to `out.len` segments into `out`.
/// Returns the number of segments produced (1 if `sep` doesn't occur).
fn splitOn(s: []const u8, sep: []const u8, out: *[4][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i + sep.len <= s.len) : (i += 1) {
        if (!std.mem.eql(u8, s[i .. i + sep.len], sep)) continue;
        if (n + 1 >= out.len) {
            // Last slot consumes the remainder so we never lose tail bytes.
            out[n] = s[start..i];
            n += 1;
            out[n] = s[i + sep.len ..];
            return n + 1;
        }
        out[n] = s[start..i];
        n += 1;
        start = i + sep.len;
        i = start - 1; // -1 so the for-loop's +1 lands us on `start`
    }
    out[n] = s[start..];
    return n + 1;
}

const TwoParts = struct { lhs: ?[]const u8, rhs: ?[]const u8 };

fn splitTwo(s: []const u8, sep: []const u8) TwoParts {
    if (std.mem.indexOf(u8, s, sep)) |idx| {
        const lhs = std.mem.trim(u8, s[0..idx], " ");
        const rhs = std.mem.trim(u8, s[idx + sep.len ..], " ");
        return .{
            .lhs = if (lhs.len > 0) lhs else null,
            .rhs = if (rhs.len > 0) rhs else null,
        };
    }
    return .{ .lhs = null, .rhs = null };
}

const TrailingIndex = struct { name: []const u8, index: f32 };

/// Given "The Farseer Trilogy 01", return name="The Farseer Trilogy"
/// and index=1. Returns null if the input doesn't end in a number.
/// Handles optional '#' prefix and decimal points (so "Book 2.5" works).
fn extractTrailingIndex(s: []const u8) ?TrailingIndex {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    if (end == 0) return null;

    // Walk back over digits/dots.
    var num_start = end;
    while (num_start > 0) {
        const c = s[num_start - 1];
        if (std.ascii.isDigit(c) or c == '.') num_start -= 1 else break;
    }
    if (num_start == end) return null;

    // Optional '#' immediately before the digits.
    var name_end = num_start;
    while (name_end > 0 and s[name_end - 1] == ' ') name_end -= 1;
    if (name_end > 0 and s[name_end - 1] == '#') name_end -= 1;
    while (name_end > 0 and s[name_end - 1] == ' ') name_end -= 1;
    if (name_end == 0) return null;

    const num_str = s[num_start..end];
    const idx = std.fmt.parseFloat(f32, num_str) catch return null;
    return .{ .name = s[0..name_end], .index = idx };
}

const Parens = struct { start: usize, inner: []const u8 };

fn extractTrailingParens(s: []const u8) ?Parens {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') end -= 1;
    if (end == 0 or s[end - 1] != ')') return null;
    var depth: i32 = 1;
    var i = end - 1;
    while (i > 0) {
        i -= 1;
        const c = s[i];
        if (c == ')') depth += 1;
        if (c == '(') {
            depth -= 1;
            if (depth == 0) {
                return .{ .start = i, .inner = s[i + 1 .. end - 1] };
            }
        }
    }
    return null;
}

// ---- Tests --------------------------------------------------------------

test "fromPath: Author - Series NN - Title" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "tests/Hobb, Robin - The Farseer Trilogy 01 - Assassin's Apprentice.mobi");
    defer if (d.author) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    defer if (d.series) |x| a.free(x);
    try std.testing.expectEqualStrings("Hobb, Robin", d.author.?);
    try std.testing.expectEqualStrings("The Farseer Trilogy", d.series.?);
    try std.testing.expectEqual(@as(f32, 1), d.series_index.?);
    try std.testing.expectEqualStrings("Assassin's Apprentice", d.title.?);
}

test "fromPath: hash-prefixed index" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "Sanderson, Brandon - Stormlight Archive #4 - Rhythm of War.epub");
    defer if (d.author) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    defer if (d.series) |x| a.free(x);
    try std.testing.expectEqualStrings("Stormlight Archive", d.series.?);
    try std.testing.expectEqual(@as(f32, 4), d.series_index.?);
}

test "fromPath: trailing parens" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "Martin, George R. R. - A Game of Thrones (A Song of Ice and Fire 1).epub");
    defer if (d.author) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    defer if (d.series) |x| a.free(x);
    try std.testing.expectEqualStrings("Martin, George R. R.", d.author.?);
    try std.testing.expectEqualStrings("A Song of Ice and Fire", d.series.?);
    try std.testing.expectEqual(@as(f32, 1), d.series_index.?);
    try std.testing.expectEqualStrings("A Game of Thrones", d.title.?);
}

test "fromPath: fractional index" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "Author - Series 2.5 - Novella.epub");
    defer if (d.series) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    try std.testing.expectEqualStrings("Series", d.series.?);
    try std.testing.expectEqual(@as(f32, 2.5), d.series_index.?);
}

test "fromPath: ignores plain Author - Title" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "Adams, Douglas - Hitchhiker's Guide.epub");
    try std.testing.expect(d.series == null);
    try std.testing.expect(d.series_index == null);
}
