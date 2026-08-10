//! Pure recognizers for Jellyfin extras, images, and version/part labels.
//! No IO — all functions are total and unit-tested.

const std = @import("std");

pub const Extra = enum {
    behind_the_scenes,
    deleted_scenes,
    interviews,
    scenes,
    samples,
    shorts,
    featurettes,
    clips,
    trailers,
    theme_music,
    backdrops,
    extras,
    other,
};

const dir_names = [_]struct { name: []const u8, kind: Extra }{
    .{ .name = "behind the scenes", .kind = .behind_the_scenes },
    .{ .name = "deleted scenes", .kind = .deleted_scenes },
    .{ .name = "interviews", .kind = .interviews },
    .{ .name = "scenes", .kind = .scenes },
    .{ .name = "samples", .kind = .samples },
    .{ .name = "shorts", .kind = .shorts },
    .{ .name = "featurettes", .kind = .featurettes },
    .{ .name = "clips", .kind = .clips },
    .{ .name = "trailers", .kind = .trailers },
    .{ .name = "theme-music", .kind = .theme_music },
    .{ .name = "backdrops", .kind = .backdrops },
    .{ .name = "extras", .kind = .extras },
    .{ .name = "other", .kind = .other },
};

/// A Jellyfin extras subfolder name (case-insensitive) → its category.
pub fn extraFromDir(name: []const u8) ?Extra {
    for (dir_names) |d| if (std.ascii.eqlIgnoreCase(name, d.name)) return d.kind;
    return null;
}

/// Canonical destination subfolder for a category.
pub fn subdir(e: Extra) []const u8 {
    return switch (e) {
        .behind_the_scenes => "behind the scenes",
        .deleted_scenes => "deleted scenes",
        .interviews => "interviews",
        .scenes => "scenes",
        .samples => "samples",
        .shorts => "shorts",
        .featurettes => "featurettes",
        .clips => "clips",
        .trailers => "trailers",
        .theme_music => "theme-music",
        .backdrops => "backdrops",
        .extras => "extras",
        .other => "other",
    };
}

const suffixes = [_]struct { suf: []const u8, kind: Extra }{
    .{ .suf = "-behindthescenes", .kind = .behind_the_scenes },
    .{ .suf = "-deletedscene", .kind = .deleted_scenes },
    .{ .suf = "-deleted", .kind = .deleted_scenes },
    .{ .suf = "-interview", .kind = .interviews },
    .{ .suf = "-scene", .kind = .scenes },
    .{ .suf = "-sample", .kind = .samples },
    .{ .suf = "-short", .kind = .shorts },
    .{ .suf = "-featurette", .kind = .featurettes },
    .{ .suf = "-clip", .kind = .clips },
    .{ .suf = "-trailer", .kind = .trailers },
    .{ .suf = "-other", .kind = .other },
    .{ .suf = "-extra", .kind = .extras },
};

pub const SuffixMatch = struct { kind: Extra, base: []const u8 };

/// A recognized extra suffix on `stem` → its kind + the stem with the suffix
/// removed. Also matches the whole-name single-file forms "trailer"/"sample".
pub fn extraFromSuffix(stem: []const u8) ?SuffixMatch {
    if (std.ascii.eqlIgnoreCase(stem, "trailer")) return .{ .kind = .trailers, .base = "" };
    if (std.ascii.eqlIgnoreCase(stem, "sample")) return .{ .kind = .samples, .base = "" };
    for (suffixes) |s| {
        if (stem.len > s.suf.len and endsWithCi(stem, s.suf)) {
            return .{ .kind = s.kind, .base = stem[0 .. stem.len - s.suf.len] };
        }
    }
    return null;
}

pub const Image = enum { poster, backdrop, logo, thumb, banner };

/// A recognized Jellyfin image filename (any alias) → its canonical kind.
pub fn imageFromName(base: []const u8) ?Image {
    const ext = std.fs.path.extension(base);
    const is_img = eqCi(ext, ".jpg") or eqCi(ext, ".jpeg") or eqCi(ext, ".png") or eqCi(ext, ".webp");
    if (!is_img) return null;
    var stem = base[0 .. base.len - ext.len];
    if (std.mem.lastIndexOfScalar(u8, stem, '-')) |d| {
        if (allDigits(stem[d + 1 ..])) stem = stem[0..d];
    }
    const posters = [_][]const u8{ "poster", "cover", "folder", "default", "front", "albumart", "album" };
    for (posters) |n| if (eqCi(stem, n)) return .poster;
    const backdrops = [_][]const u8{ "backdrop", "fanart", "background", "art" };
    for (backdrops) |n| if (eqCi(stem, n)) return .backdrop;
    if (eqCi(stem, "logo") or eqCi(stem, "clearlogo")) return .logo;
    if (eqCi(stem, "thumb") or eqCi(stem, "landscape")) return .thumb;
    if (eqCi(stem, "banner")) return .banner;
    return null;
}

/// Canonical output name for an image kind (`poster.jpg`, `backdrop.jpg`, …).
pub fn imageOutName(alloc: std.mem.Allocator, e: Image, ext: []const u8) ![]u8 {
    const base = switch (e) {
        .poster => "poster",
        .backdrop => "backdrop",
        .logo => "logo",
        .thumb => "thumb",
        .banner => "banner",
    };
    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ base, ext });
}

pub const EditionMatch = struct { edition: []const u8, base: []const u8 };

/// A trailing ` - <label>` or `[<label>]` version/edition on `stem` →
/// { edition, base } with the label removed. ` - ` form only matches known
/// edition labels (resolutions, "Directors Cut", …); `[...]` matches any label.
pub fn parseEdition(stem: []const u8) ?EditionMatch {
    if (stem.len > 2 and stem[stem.len - 1] == ']') {
        if (std.mem.lastIndexOfScalar(u8, stem, '[')) |o| {
            const label = std.mem.trim(u8, stem[o + 1 .. stem.len - 1], " ");
            const base = std.mem.trim(u8, stem[0..o], " ");
            if (label.len > 0 and base.len > 0) return .{ .edition = label, .base = base };
        }
    }
    if (std.mem.lastIndexOf(u8, stem, " - ")) |sep| {
        const label = std.mem.trim(u8, stem[sep + 3 ..], " ");
        const base = std.mem.trim(u8, stem[0..sep], " ");
        if (label.len > 0 and base.len > 0 and isEditionLabel(label)) return .{ .edition = label, .base = base };
    }
    return null;
}

pub const PartMatch = struct { part: u32, base: []const u8 };

/// A trailing `-cd1`/`-part2`/`-disc1`/`-pt3` (any separator or none) →
/// { part, base } with the part token removed.
pub fn parsePart(stem: []const u8) ?PartMatch {
    const kinds = [_][]const u8{ "part", "disc", "disk", "cd", "pt" };
    var i = stem.len;
    while (i > 0 and std.ascii.isDigit(stem[i - 1])) : (i -= 1) {}
    if (i == stem.len) return null; // no trailing digits
    const digits = stem[i..];
    for (kinds) |k| {
        if (i < k.len) continue;
        const kstart = i - k.len;
        if (!std.ascii.eqlIgnoreCase(stem[kstart..i], k)) continue;
        var base_end = kstart;
        if (base_end > 0 and (stem[base_end - 1] == ' ' or stem[base_end - 1] == '.' or stem[base_end - 1] == '-' or stem[base_end - 1] == '_')) base_end -= 1;
        const part = std.fmt.parseInt(u32, digits, 10) catch continue;
        return .{ .part = part, .base = stem[0..base_end] };
    }
    return null;
}

fn isEditionLabel(s: []const u8) bool {
    if (s.len >= 3 and (s[s.len - 1] == 'p' or s[s.len - 1] == 'i' or s[s.len - 1] == 'P' or s[s.len - 1] == 'I')) {
        var all = true;
        for (s[0 .. s.len - 1]) |c| if (!std.ascii.isDigit(c)) {
            all = false;
            break;
        };
        if (all) return true;
    }
    const words = [_][]const u8{ "directors cut", "director's cut", "extended", "unrated", "theatrical", "remastered", "imax", "final cut", "uncut" };
    for (words) |w| if (containsCi(s, w)) return true;
    return false;
}

fn eqCi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn endsWithCi(h: []const u8, n: []const u8) bool {
    return h.len >= n.len and std.ascii.eqlIgnoreCase(h[h.len - n.len ..], n);
}
fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
fn containsCi(h: []const u8, n: []const u8) bool {
    if (n.len == 0 or n.len > h.len) return false;
    var i: usize = 0;
    outer: while (i + n.len <= h.len) : (i += 1) {
        for (n, 0..) |c, j| if (std.ascii.toLower(h[i + j]) != std.ascii.toLower(c)) continue :outer;
        return true;
    }
    return false;
}

const t = std.testing;

test "extraFromDir/suffix" {
    try t.expectEqual(Extra.trailers, extraFromDir("Trailers").?);
    try t.expectEqual(@as(?Extra, null), extraFromDir("Season 01"));
    const s = extraFromSuffix("Film-behindthescenes").?;
    try t.expectEqual(Extra.behind_the_scenes, s.kind);
    try t.expectEqualStrings("Film", s.base);
    try t.expectEqual(Extra.trailers, extraFromSuffix("trailer").?.kind);
    try t.expectEqual(@as(?SuffixMatch, null), extraFromSuffix("Film"));
}

test "imageFromName canonicalizes" {
    try t.expectEqual(Image.poster, imageFromName("cover.jpg").?);
    try t.expectEqual(Image.backdrop, imageFromName("fanart.png").?);
    try t.expectEqual(Image.backdrop, imageFromName("backdrop-2.jpg").?);
    try t.expectEqual(Image.logo, imageFromName("clearlogo.png").?);
    try t.expectEqual(@as(?Image, null), imageFromName("random.jpg"));
    var a = std.heap.ArenaAllocator.init(t.allocator);
    defer a.deinit();
    try t.expectEqualStrings("poster.jpg", try imageOutName(a.allocator(), .poster, "jpg"));
}

test "parseEdition / parsePart" {
    const e = parseEdition("The Matrix - Directors Cut").?;
    try t.expectEqualStrings("Directors Cut", e.edition);
    try t.expectEqualStrings("The Matrix", e.base);
    try t.expectEqual(@as(?EditionMatch, null), parseEdition("Plain Title"));
    const p = parsePart("Movie-cd2").?;
    try t.expectEqual(@as(u32, 2), p.part);
    try t.expectEqualStrings("Movie", p.base);
    try t.expectEqual(@as(?PartMatch, null), parsePart("Movie2"));
}
