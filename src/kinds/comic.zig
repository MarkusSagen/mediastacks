//! Comic filename parser. Pulls series + issue number + volume + year out of
//! the usual messy names ("Saga #12 (2018)", "Batman v2 001", "Witch Hat
//! Atelier v01"). The series is everything before the first marker, cleaned.

const std = @import("std");
const kind = @import("../core/kind.zig");
const textnorm = @import("../core/textnorm.zig");
const zip = @import("../ffi/miniz.zig");

pub const Comic = struct {
    series: []const u8,
    issue: ?f32 = null,
    volume: ?u32 = null,
    year: ?u32 = null,
    ext: []const u8,
};

fn isYear(n: u32) bool {
    return n >= 1900 and n <= 2099;
}

/// A leading "v"/"vol"/"vol."/"volume" + digits (in one token like "v01" or as
/// this token being the word and the number following) → volume number.
fn volumeOf(tok: []const u8) ?u32 {
    const prefixes = [_][]const u8{ "volume", "vol.", "vol", "v" };
    for (prefixes) |p| {
        if (tok.len > p.len and std.ascii.startsWithIgnoreCase(tok, p)) {
            const rest = tok[p.len..];
            if (rest.len > 0 and allDigits(rest)) return std.fmt.parseInt(u32, rest, 10) catch null;
        }
    }
    return null;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isNumberish(s: []const u8) bool {
    // digits with an optional single '.' (e.g. "012", "12.1")
    if (s.len == 0) return false;
    var dot = false;
    for (s) |c| {
        if (c == '.') {
            if (dot) return false;
            dot = true;
        } else if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Parse `basename` into a `Comic`. Series is never null (falls back to the
/// whole cleaned stem). All owned by `alloc`.
pub fn parse(alloc: std.mem.Allocator, basename: []const u8) !Comic {
    const ext_dot = std.fs.path.extension(basename);
    const ext = try alloc.dupe(u8, if (ext_dot.len > 0) ext_dot[1..] else ext_dot);
    const stem = basename[0 .. basename.len - ext_dot.len];

    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, stem, " ._-()[]");
    while (it.next()) |tok| try toks.append(alloc, tok);

    var issue: ?f32 = null;
    var volume: ?u32 = null;
    var year: ?u32 = null;
    var boundary: usize = toks.items.len; // first marker token index

    for (toks.items, 0..) |tok, i| {
        // #12 / #12.1 issue marker
        if (tok.len > 1 and tok[0] == '#' and isNumberish(tok[1..])) {
            if (issue == null) issue = std.fmt.parseFloat(f32, tok[1..]) catch null;
            if (i < boundary) boundary = i;
            continue;
        }
        // volume marker (v01 / vol.2 / volume 3-as-"volume"+next handled below)
        if (volumeOf(tok)) |v| {
            if (volume == null) volume = v;
            if (i < boundary) boundary = i;
            continue;
        }
        // bare 4-digit year
        if (tok.len == 4 and allDigits(tok)) {
            const n = std.fmt.parseInt(u32, tok, 10) catch 0;
            if (isYear(n)) {
                if (year == null) year = n;
                if (i < boundary) boundary = i;
                continue;
            }
        }
        // "vol"/"volume" word followed by a number token
        if ((std.ascii.eqlIgnoreCase(tok, "vol") or std.ascii.eqlIgnoreCase(tok, "volume")) and i + 1 < toks.items.len and allDigits(toks.items[i + 1])) {
            if (volume == null) volume = std.fmt.parseInt(u32, toks.items[i + 1], 10) catch null;
            if (i < boundary) boundary = i;
            continue;
        }
        // a standalone number after the series → issue (never at index 0, so a
        // series that starts with a number like "100 Bullets" survives)
        if (i > 0 and issue == null and isNumberish(tok)) {
            const n = std.fmt.parseInt(u32, tok, 10) catch blk: {
                issue = std.fmt.parseFloat(f32, tok) catch null;
                break :blk 0;
            };
            if (issue == null) issue = @floatFromInt(n);
            if (i < boundary) boundary = i;
            continue;
        }
    }

    const series_raw = if (boundary > 0) joinTokens(alloc, toks.items[0..boundary]) catch stem else stem;
    const series = try textnorm.clean(alloc, try kind.cleanName(alloc, series_raw));

    return Comic{ .series = series, .issue = issue, .volume = volume, .year = year, .ext = ext };
}

fn joinTokens(alloc: std.mem.Allocator, toks: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (toks, 0..) |tk, i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, tk);
    }
    return out.toOwnedSlice(alloc);
}

// ---- ComicInfo.xml (ComicRack standard; read by Komga/Kavita/Jellyfin) ----

fn xmlEsc(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(alloc, "&amp;"),
        '<' => try out.appendSlice(alloc, "&lt;"),
        '>' => try out.appendSlice(alloc, "&gt;"),
        '"' => try out.appendSlice(alloc, "&quot;"),
        else => try out.append(alloc, c),
    };
    return out.toOwnedSlice(alloc);
}

/// Build a ComicInfo.xml document. Owned by `alloc`.
pub fn buildComicInfo(alloc: std.mem.Allocator, series: []const u8, issue: ?f32, volume: ?u32, year: ?u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ComicInfo>\n");
    if (series.len > 0) {
        const e = try xmlEsc(alloc, series);
        try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  <Series>{s}</Series>\n", .{e}));
    }
    if (issue) |iss| {
        if (@floor(iss) == iss) {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  <Number>{d}</Number>\n", .{@as(u32, @intFromFloat(iss))}));
        } else {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  <Number>{d}</Number>\n", .{iss}));
        }
    }
    if (volume) |v| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  <Volume>{d}</Volume>\n", .{v}));
    if (year) |y| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "  <Year>{d}</Year>\n", .{y}));
    try out.appendSlice(alloc, "</ComicInfo>\n");
    return out.toOwnedSlice(alloc);
}

const NameList = struct { alloc: std.mem.Allocator, names: *std.ArrayList([]const u8) };
fn collectName(ctx: NameList, idx: u32, name: []const u8, size: u64) anyerror!void {
    _ = idx;
    _ = size;
    if (std.mem.endsWith(u8, name, "/")) return; // skip directory entries
    try ctx.names.append(ctx.alloc, try ctx.alloc.dupe(u8, name));
}

pub const WriteError = error{ OpenFailed, WriteFailed, OutOfMemory };

/// Repack the cbz at `path` with a fresh `ComicInfo.xml` (replacing any
/// existing one). Writes a temp archive then atomically renames. cbz only.
pub fn writeComicInfo(alloc: std.mem.Allocator, path: []const u8, series: []const u8, issue: ?f32, volume: ?u32, year: ?u32) WriteError!void {
    const xml = buildComicInfo(alloc, series, issue, volume, year) catch return WriteError.OutOfMemory;

    var reader: zip.ZipReader = .{};
    reader.open(path) catch return WriteError.OpenFailed;
    defer reader.close();

    var names: std.ArrayList([]const u8) = .empty;
    reader.forEachMember(NameList{ .alloc = alloc, .names = &names }, collectName) catch return WriteError.OpenFailed;

    const tmp = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return WriteError.OutOfMemory;
    var writer: zip.ZipWriter = .{};
    writer.create(tmp) catch return WriteError.WriteFailed;
    var ok = false;
    defer if (!ok) writer.abort();

    for (names.items) |nm| {
        if (std.ascii.eqlIgnoreCase(nm, "ComicInfo.xml")) continue; // replace
        const bytes = reader.readMember(alloc, nm) catch continue;
        writer.addBytes(nm, bytes, .best) catch return WriteError.WriteFailed;
    }
    writer.addBytes("ComicInfo.xml", xml, .best) catch return WriteError.WriteFailed;
    writer.finalizeAndClose() catch return WriteError.WriteFailed;
    ok = true;

    var tz: [4096]u8 = undefined;
    var pz: [4096]u8 = undefined;
    if (tmp.len >= tz.len or path.len >= pz.len) return WriteError.WriteFailed;
    const tzp = std.fmt.bufPrintZ(&tz, "{s}", .{tmp}) catch return WriteError.WriteFailed;
    const pzp = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return WriteError.WriteFailed;
    if (std.c.rename(tzp.ptr, pzp.ptr) != 0) {
        _ = std.c.unlink(tzp.ptr);
        return WriteError.WriteFailed;
    }
}

const t = std.testing;

test "buildComicInfo emits series/number/volume/year, escapes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try buildComicInfo(a, "Saga & Co", 12, 2, 2018);
    try t.expect(std.mem.indexOf(u8, s, "<Series>Saga &amp; Co</Series>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<Number>12</Number>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<Volume>2</Volume>") != null);
    try t.expect(std.mem.indexOf(u8, s, "<Year>2018</Year>") != null);
}

fn expectComic(basename: []const u8, series: []const u8, issue: ?f32, volume: ?u32, year: ?u32) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), basename);
    try t.expectEqualStrings(series, c.series);
    try t.expectEqual(issue, c.issue);
    try t.expectEqual(volume, c.volume);
    try t.expectEqual(year, c.year);
}

test "parse common comic names" {
    try expectComic("Saga #12 (2018).cbz", "Saga", 12, null, 2018);
    try expectComic("Batman_v2_001.cbr", "Batman", 1, 2, null);
    try expectComic("Witch Hat Atelier v01.cbz", "Witch Hat Atelier", null, 1, null);
    try expectComic("Some Series 012.cbz", "Some Series", 12, null, null);
    try expectComic("100 Bullets #5.cbz", "100 Bullets", 5, null, null);
    try expectComic("Plain Title.cbz", "Plain Title", null, null, null);
}
