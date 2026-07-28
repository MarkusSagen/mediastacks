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

const log = std.log.scoped(.path_meta);

pub const Derived = struct {
    author: ?[]const u8 = null,
    title: ?[]const u8 = null,
    series: ?[]const u8 = null,
    series_index: ?f32 = null,
};

/// Walk the path's basename (and optionally its parents, for Calibre
/// layouts) and pull out what we can. Missing pieces stay null.
pub fn fromPath(allocator: std.mem.Allocator, path: []const u8) !Derived {
    var result = try fromPathInner(allocator, path);
    try augmentFromParents(allocator, path, &result);
    log.debug(
        "fromPath \"{s}\" pattern={s} title={?s} author={?s} series={?s} idx={?d:.1}",
        .{
            std.fs.path.basename(path),
            result.pattern,
            result.derived.title,
            result.derived.author,
            result.derived.series,
            result.derived.series_index,
        },
    );
    return result.derived;
}

const Tagged = struct { derived: Derived, pattern: []const u8 };

fn fromPathInner(allocator: std.mem.Allocator, path: []const u8) !Tagged {
    const basename = std.fs.path.basename(path);
    const ext_dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    const stem = std.mem.trim(u8, basename[0..ext_dot], " ");

    var pieces: [4][]const u8 = undefined;
    const nparts = splitOn(stem, " - ", &pieces);

    if (nparts == 3) {
        const author_part = std.mem.trim(u8, pieces[0], " ");
        const middle = std.mem.trim(u8, pieces[1], " ");
        const title_part = std.mem.trim(u8, pieces[2], " ");

        const split = extractTrailingIndex(middle);
        if (split) |s| {
            return .{
                .derived = .{
                    .author = if (author_part.len > 0) try allocator.dupe(u8, author_part) else null,
                    .title = if (title_part.len > 0) try allocator.dupe(u8, title_part) else null,
                    .series = try allocator.dupe(u8, s.name),
                    .series_index = s.index,
                },
                .pattern = "author-series-title",
            };
        }
    }

    if (extractTrailingParens(stem)) |paren| {
        const inner_split = extractTrailingIndex(paren.inner);
        if (inner_split) |s| {
            const before = std.mem.trim(u8, stem[0..paren.start], " ");
            const sub = splitTwo(before, " - ");
            return .{
                .derived = .{
                    .author = if (sub.lhs) |l| try allocator.dupe(u8, l) else null,
                    .title = if (sub.rhs) |r|
                        try allocator.dupe(u8, r)
                    else if (before.len > 0)
                        try allocator.dupe(u8, before)
                    else
                        null,
                    .series = try allocator.dupe(u8, s.name),
                    .series_index = s.index,
                },
                .pattern = "title-paren-series",
            };
        }
    }

    if (nparts == 2) {
        const first = std.mem.trim(u8, pieces[0], " ");
        const second = std.mem.trim(u8, pieces[1], " ");
        if (extractTrailingIndex(first)) |s| {
            return .{
                .derived = .{
                    .title = if (second.len > 0) try allocator.dupe(u8, second) else null,
                    .series = try allocator.dupe(u8, s.name),
                    .series_index = s.index,
                },
                .pattern = "series-title",
            };
        }
    }

    if (findByInsensitive(stem)) |idx| {
        const title_part = std.mem.trim(u8, stem[0..idx], " ");
        const author_part = std.mem.trim(u8, stem[idx + 4 ..], " ");
        if (title_part.len > 0 and author_part.len > 0) {
            return .{
                .derived = .{
                    .title = try allocator.dupe(u8, title_part),
                    .author = try allocator.dupe(u8, author_part),
                },
                .pattern = "title-by-author",
            };
        }
    }

    if (extractLeadingIndex(stem)) |lead| {
        if (lead.rest.len > 0) {
            return .{
                .derived = .{
                    .title = try allocator.dupe(u8, lead.rest),
                    .series_index = lead.index,
                },
                .pattern = "leading-index-title",
            };
        }
    }

    if (stem.len > 0) {
        return .{
            .derived = .{ .title = try allocator.dupe(u8, stem) },
            .pattern = "bare-title",
        };
    }

    return .{ .derived = .{}, .pattern = "none" };
}

/// Walk up to two parent directories and fill in any nulls the basename
/// patterns couldn't supply. Never overwrites a value already present —
/// the filename is the authoritative source. Each parent name must pass
/// the `looksAuthorish` / `looksSeriesish` guard before we adopt it, so
/// generic folders (`Downloads/`, `Books/`, `inbox/`) can't poison the
/// result.
///
/// Patterns covered:
///   - `Author/Title.ext`                    → author from parent
///   - `Author/Series/NN - Title.ext`        → series from parent, author from grandparent
///   - `Title by Author EPUB/Title.ext`      → re-runs "title by author" on the format-stripped parent name
fn augmentFromParents(
    allocator: std.mem.Allocator,
    path: []const u8,
    result: *Tagged,
) !void {
    const parent_dir = std.fs.path.dirname(path) orelse return;
    const parent_name = std.fs.path.basename(parent_dir);
    if (parent_name.len == 0) return;

    if (result.derived.title == null or result.derived.author == null) {
        const cleaned_parent = stripFormatTag(parent_name);
        if (findByInsensitive(cleaned_parent)) |idx| {
            const t = std.mem.trim(u8, cleaned_parent[0..idx], " ");
            const a = std.mem.trim(u8, cleaned_parent[idx + 4 ..], " ");
            if (t.len > 0 and a.len > 0) {
                if (result.derived.title == null) {
                    result.derived.title = try allocator.dupe(u8, t);
                }
                if (result.derived.author == null) {
                    result.derived.author = try allocator.dupe(u8, a);
                }
                result.pattern = "parent-title-by-author";
            }
        }
    }

    if (result.derived.author == null and looksAuthorish(parent_name)) {
        result.derived.author = try allocator.dupe(u8, parent_name);
        if (std.mem.eql(u8, result.pattern, "bare-title") or
            std.mem.eql(u8, result.pattern, "leading-index-title"))
        {
            result.pattern = "parent-author";
        }
    }

    if (result.derived.series == null and result.derived.series_index != null) {
        if (looksSeriesish(parent_name)) {
            result.derived.series = try allocator.dupe(u8, parent_name);
            if (result.derived.author == null) {
                if (std.fs.path.dirname(parent_dir)) |gp_dir| {
                    const gp_name = std.fs.path.basename(gp_dir);
                    if (gp_name.len > 0 and looksAuthorish(gp_name)) {
                        result.derived.author = try allocator.dupe(u8, gp_name);
                    }
                }
            }
            result.pattern = "parent-series-author";
        }
    }
}

/// Strip a trailing format-tag suffix from a folder name. Matches
/// ` EPUB`, ` MOBI`, ` AZW3`, ` AZW`, ` PDF` and the lowercase variants.
/// Returns the input unchanged when no tag is present.
fn stripFormatTag(name: []const u8) []const u8 {
    const tags = [_][]const u8{ " EPUB", " MOBI", " AZW3", " AZW", " PDF" };
    for (tags) |tag| {
        if (name.len > tag.len and std.ascii.endsWithIgnoreCase(name, tag)) {
            return std.mem.trim(u8, name[0 .. name.len - tag.len], " ");
        }
    }
    return name;
}

/// Conservative "does this folder name look like a person's name?" test.
/// True positives: "Hobb, Robin", "George R. R. Martin", "Joe Abercrombie".
/// True negatives: "Downloads", "Books", "Calibre Library", "inbox",
/// single-word lowercase names, names with digits.
///
/// Heuristic: must contain at least 2 alphabetic words, no digits, and
/// not be in a known-generic blacklist. A comma is a strong author
/// signal ("Last, First") so we accept those even if otherwise short.
fn looksAuthorish(name: []const u8) bool {
    if (name.len < 4) return false;

    const generic = [_][]const u8{
        "downloads", "download", "books",   "ebooks",  "library",
        "calibre",   "inbox",    "archive", "volumes", "documents",
        "desktop",   "tmp",      "temp",    "media",   "audiobooks",
        "to read",   "to-read",  "wip",
    };
    var lower_buf: [128]u8 = undefined;
    if (name.len < lower_buf.len) {
        for (name, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        const lower = lower_buf[0..name.len];
        for (generic) |g| {
            if (std.mem.eql(u8, lower, g)) return false;
        }
    }

    if (std.mem.indexOfScalar(u8, name, ',')) |comma| {
        const lhs = std.mem.trim(u8, name[0..comma], " ");
        const rhs = std.mem.trim(u8, name[comma + 1 ..], " ");
        if (isAlphaWord(lhs) and rhs.len >= 2) {
            for (rhs) |c| if (std.ascii.isDigit(c)) return false;
            return true;
        }
    }

    var word_count: usize = 0;
    var any_lower_word = false;
    var it = std.mem.tokenizeAny(u8, name, " \t");
    while (it.next()) |word| {
        var w = word;
        while (w.len > 0 and w[w.len - 1] == '.') w = w[0 .. w.len - 1];
        if (w.len == 0) continue;
        for (w) |c| if (std.ascii.isDigit(c)) return false;
        if (!isAlphaWord(w)) return false;
        if (!std.ascii.isUpper(w[0])) any_lower_word = true;
        word_count += 1;
    }
    if (word_count < 2) return false;
    return !any_lower_word;
}

/// "Does this folder name look like it names a book series?"
/// Used to decide whether to adopt a parent dir as the series name when
/// the basename already gave us a numeric index. More permissive than
/// `looksAuthorish` — a series can be a single word ("Dune"), can
/// contain "The"/"A", but still shouldn't be a generic folder name.
fn looksSeriesish(name: []const u8) bool {
    if (name.len < 2) return false;
    const generic = [_][]const u8{
        "downloads", "download", "books",   "ebooks",  "library",
        "calibre",   "inbox",    "archive", "volumes", "documents",
        "desktop",   "tmp",      "temp",    "media",
    };
    var lower_buf: [128]u8 = undefined;
    if (name.len < lower_buf.len) {
        for (name, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        const lower = lower_buf[0..name.len];
        for (generic) |g| {
            if (std.mem.eql(u8, lower, g)) return false;
        }
    }
    if (extractTrailingIndex(name) != null) return false;
    var any_upper = false;
    for (name) |c| if (std.ascii.isUpper(c)) {
        any_upper = true;
        break;
    };
    return any_upper;
}

fn isAlphaWord(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphabetic(c) or c == '\'' or c == '-' or c == '.')) return false;
    }
    return true;
}

const LeadingIndex = struct { index: f32, rest: []const u8 };

/// Pull a leading numeric index out of strings like `01 - Title` or
/// `1.5 Title` or `12.Title`. The separator can be ` - `, ` `, `.`,
/// `_`, or empty. Returns null when the string doesn't start with digits.
fn extractLeadingIndex(s: []const u8) ?LeadingIndex {
    var end: usize = 0;
    var saw_dot = false;
    while (end < s.len) : (end += 1) {
        const c = s[end];
        if (std.ascii.isDigit(c)) continue;
        if (c == '.' and !saw_dot and end + 1 < s.len and std.ascii.isDigit(s[end + 1])) {
            saw_dot = true;
            continue;
        }
        break;
    }
    if (end == 0) return null;
    const num_str = s[0..end];
    const idx = std.fmt.parseFloat(f32, num_str) catch return null;

    var rest_start = end;
    while (rest_start < s.len) : (rest_start += 1) {
        const c = s[rest_start];
        if (c == ' ' or c == '-' or c == '.' or c == '_') continue;
        break;
    }
    const rest = std.mem.trim(u8, s[rest_start..], " ");
    return .{ .index = idx, .rest = rest };
}

/// Case-insensitive search for " by " surrounded by word boundaries.
/// Returns the byte index of the first match, or null. Skips matches
/// where the preceding/following char is alnum (so "Tuesday" doesn't
/// trigger on the trailing 'by').
fn findByInsensitive(s: []const u8) ?usize {
    if (s.len < 6) return null;
    var i: usize = 1;
    while (i + 4 <= s.len) : (i += 1) {
        const c1 = s[i];
        const c2 = s[i + 1];
        const c3 = s[i + 2];
        const c4 = s[i + 3];
        if (c1 != ' ') continue;
        if ((c2 != 'b' and c2 != 'B') or (c3 != 'y' and c3 != 'Y')) continue;
        if (c4 != ' ') continue;
        return i;
    }
    return null;
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

/// Split `s` on `sep`, writing up to `out.len` segments into `out`.
/// Returns the number of segments produced (1 if `sep` doesn't occur).
fn splitOn(s: []const u8, sep: []const u8, out: *[4][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i + sep.len <= s.len) : (i += 1) {
        if (!std.mem.eql(u8, s[i .. i + sep.len], sep)) continue;
        if (n + 1 >= out.len) {
            out[n] = s[start..i];
            n += 1;
            out[n] = s[i + sep.len ..];
            return n + 1;
        }
        out[n] = s[start..i];
        n += 1;
        start = i + sep.len;
        i = start - 1;
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

    var num_start = end;
    while (num_start > 0) {
        const c = s[num_start - 1];
        if (std.ascii.isDigit(c) or c == '.') num_start -= 1 else break;
    }
    if (num_start == end) return null;

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

test "fromPath: parent dir is the author (Calibre flat)" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "/lib/Hobb, Robin/Assassin's Apprentice.epub");
    defer if (d.author) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    try std.testing.expectEqualStrings("Assassin's Apprentice", d.title.?);
    try std.testing.expectEqualStrings("Hobb, Robin", d.author.?);
}

test "fromPath: Calibre nested layout — Author/Series/NN - Title" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "/lib/Hobb, Robin/The Farseer Trilogy/01 - Assassin's Apprentice.epub");
    defer if (d.author) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    defer if (d.series) |x| a.free(x);
    try std.testing.expectEqualStrings("Assassin's Apprentice", d.title.?);
    try std.testing.expectEqualStrings("Hobb, Robin", d.author.?);
    try std.testing.expectEqualStrings("The Farseer Trilogy", d.series.?);
    try std.testing.expectEqual(@as(f32, 1), d.series_index.?);
}

test "fromPath: 'Title by Author EPUB' folder strips format tag" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "/Downloads/A Little Hatred by Joe Abercrombie EPUB/whatever.epub");
    defer if (d.author) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    try std.testing.expectEqualStrings("A Little Hatred", d.title.?);
    try std.testing.expectEqualStrings("Joe Abercrombie", d.author.?);
}

test "fromPath: rejects 'Downloads' as author" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "/Users/me/Downloads/Hyperion.epub");
    defer if (d.title) |x| a.free(x);
    try std.testing.expectEqualStrings("Hyperion", d.title.?);
    try std.testing.expect(d.author == null);
}

test "fromPath: rejects single-word lowercase parent" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "/var/inbox/Hyperion.epub");
    defer if (d.title) |x| a.free(x);
    try std.testing.expectEqualStrings("Hyperion", d.title.?);
    try std.testing.expect(d.author == null);
}

test "fromPath: parent author preserved alongside basename title" {
    const a = std.testing.allocator;
    const d = try fromPath(a, "/lib/Hobb, Robin/Assassin's Apprentice by Robin Hobb.epub");
    defer if (d.author) |x| a.free(x);
    defer if (d.title) |x| a.free(x);
    try std.testing.expectEqualStrings("Assassin's Apprentice", d.title.?);
    try std.testing.expectEqualStrings("Robin Hobb", d.author.?);
}

test "looksAuthorish: positive cases" {
    try std.testing.expect(looksAuthorish("Hobb, Robin"));
    try std.testing.expect(looksAuthorish("Joe Abercrombie"));
    try std.testing.expect(looksAuthorish("George R. R. Martin"));
}

test "looksAuthorish: negative cases" {
    try std.testing.expect(!looksAuthorish("Downloads"));
    try std.testing.expect(!looksAuthorish("books"));
    try std.testing.expect(!looksAuthorish("Calibre Library"));
    try std.testing.expect(!looksAuthorish("inbox"));
    try std.testing.expect(!looksAuthorish("Volume 1"));
    try std.testing.expect(!looksAuthorish("Hobb"));
}

test "extractLeadingIndex" {
    const a = extractLeadingIndex("01 - Title").?;
    try std.testing.expectEqual(@as(f32, 1), a.index);
    try std.testing.expectEqualStrings("Title", a.rest);

    const b = extractLeadingIndex("1.5 Novella").?;
    try std.testing.expectEqual(@as(f32, 1.5), b.index);
    try std.testing.expectEqualStrings("Novella", b.rest);

    try std.testing.expect(extractLeadingIndex("Title") == null);
    try std.testing.expect(extractLeadingIndex("") == null);
}

test "stripFormatTag" {
    try std.testing.expectEqualStrings("A Little Hatred by Joe Abercrombie", stripFormatTag("A Little Hatred by Joe Abercrombie EPUB"));
    try std.testing.expectEqualStrings("Some Book", stripFormatTag("Some Book MOBI"));
    try std.testing.expectEqualStrings("Already Clean", stripFormatTag("Already Clean"));
}
