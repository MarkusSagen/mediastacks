//! Subtitle sidecar language/flag detection → Jellyfin naming.
//!
//! Jellyfin selects external subtitles by a language + flag suffix on the file
//! name that matches the video, e.g. `Dune (2021).en.srt`, `Dune (2021).en.forced.srt`,
//! `Dune (2021).en.sdh.srt`. We derive that suffix from the *original* subtitle
//! file name (which usually carries a trailing language token from the release,
//! like `...x264-GRP.en.srt` or `Movie.English.forced.srt`) and hand back the
//! `<lang>[.forced][.sdh].<ext>` segment that `naming.dstFor` appends after the
//! video's canonical base name. Pure — no I/O.

const std = @import("std");

pub const SubInfo = struct {
    /// Normalized ISO 639-1 (2-letter) code, or null when no language was
    /// confidently detected (then the sidecar keeps a bare `<base>.<ext>` name).
    lang: ?[]const u8 = null,
    forced: bool = false,
    sdh: bool = false, // hearing-impaired / SDH / CC
};

const subtitle_exts = [_][]const u8{ "srt", "ass", "ssa", "vtt", "sub", "idx" };

/// True for a subtitle file extension (no leading dot).
pub fn isSubtitleExt(ext: []const u8) bool {
    for (subtitle_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

// name / 2- / 3-letter code → ISO 639-1. A common subset; unknown tokens are
// treated as "not a language" so release-name noise never becomes a false tag.
const Lang = struct { key: []const u8, code: []const u8 };
const langs = [_]Lang{
    .{ .key = "en", .code = "en" },  .{ .key = "eng", .code = "en" },     .{ .key = "english", .code = "en" },
    .{ .key = "es", .code = "es" },  .{ .key = "spa", .code = "es" },     .{ .key = "spanish", .code = "es" },
    .{ .key = "fr", .code = "fr" },  .{ .key = "fra", .code = "fr" },     .{ .key = "fre", .code = "fr" }, .{ .key = "french", .code = "fr" },
    .{ .key = "de", .code = "de" },  .{ .key = "deu", .code = "de" },     .{ .key = "ger", .code = "de" }, .{ .key = "german", .code = "de" },
    .{ .key = "it", .code = "it" },  .{ .key = "ita", .code = "it" },     .{ .key = "italian", .code = "it" },
    .{ .key = "pt", .code = "pt" },  .{ .key = "por", .code = "pt" },     .{ .key = "portuguese", .code = "pt" },
    .{ .key = "nl", .code = "nl" },  .{ .key = "dut", .code = "nl" },     .{ .key = "nld", .code = "nl" }, .{ .key = "dutch", .code = "nl" },
    .{ .key = "sv", .code = "sv" },  .{ .key = "swe", .code = "sv" },     .{ .key = "swedish", .code = "sv" },
    .{ .key = "no", .code = "no" },  .{ .key = "nor", .code = "no" },     .{ .key = "norwegian", .code = "no" },
    .{ .key = "da", .code = "da" },  .{ .key = "dan", .code = "da" },     .{ .key = "danish", .code = "da" },
    .{ .key = "fi", .code = "fi" },  .{ .key = "fin", .code = "fi" },     .{ .key = "finnish", .code = "fi" },
    .{ .key = "pl", .code = "pl" },  .{ .key = "pol", .code = "pl" },     .{ .key = "polish", .code = "pl" },
    .{ .key = "ru", .code = "ru" },  .{ .key = "rus", .code = "ru" },     .{ .key = "russian", .code = "ru" },
    .{ .key = "ja", .code = "ja" },  .{ .key = "jpn", .code = "ja" },     .{ .key = "japanese", .code = "ja" },
    .{ .key = "ko", .code = "ko" },  .{ .key = "kor", .code = "ko" },     .{ .key = "korean", .code = "ko" },
    .{ .key = "zh", .code = "zh" },  .{ .key = "chi", .code = "zh" },     .{ .key = "zho", .code = "zh" }, .{ .key = "chinese", .code = "zh" },
    .{ .key = "ar", .code = "ar" },  .{ .key = "ara", .code = "ar" },     .{ .key = "arabic", .code = "ar" },
    .{ .key = "hi", .code = "hi" },  .{ .key = "hin", .code = "hi" },     .{ .key = "hindi", .code = "hi" },
};

fn langOf(tok: []const u8) ?[]const u8 {
    for (langs) |l| if (std.ascii.eqlIgnoreCase(tok, l.key)) return l.code;
    return null;
}

fn isForced(tok: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tok, "forced");
}
fn isSdh(tok: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tok, "sdh") or std.ascii.eqlIgnoreCase(tok, "cc") or std.ascii.eqlIgnoreCase(tok, "hi");
}

fn isSep(c: u8) bool {
    return c == '.' or c == ' ' or c == '_' or c == '-';
}

/// Parse language + flags from a subtitle file's stem (name without extension).
/// Scans trailing tokens and stops at the first that isn't a language/flag, so
/// tokens from the title/release (years, codecs, group names) are never mistaken
/// for a language.
pub fn parse(stem: []const u8) SubInfo {
    // collect token [start,end) boundaries
    var starts: [64]usize = undefined;
    var ends: [64]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < stem.len and n < starts.len) {
        while (i < stem.len and isSep(stem[i])) i += 1;
        if (i >= stem.len) break;
        const s = i;
        while (i < stem.len and !isSep(stem[i])) i += 1;
        starts[n] = s;
        ends[n] = i;
        n += 1;
    }

    var info = SubInfo{};
    var k = n;
    while (k > 0) : (k -= 1) {
        const tok = stem[starts[k - 1]..ends[k - 1]];
        if (isForced(tok)) {
            info.forced = true;
        } else if (isSdh(tok)) {
            info.sdh = true;
        } else if (langOf(tok)) |code| {
            if (info.lang == null) info.lang = code;
        } else break; // not a language/flag token → stop scanning
    }
    return info;
}

/// The Jellyfin sidecar suffix `naming.dstFor` appends after the video base:
/// `<lang>[.forced][.sdh].<ext>`, or bare `<ext>` when no language was detected.
pub fn destExt(arena: std.mem.Allocator, info: SubInfo, ext: []const u8) ![]const u8 {
    if (info.lang == null and !info.forced and !info.sdh) return ext;
    var b: std.ArrayList(u8) = .empty;
    if (info.lang) |l| {
        try b.appendSlice(arena, l);
        try b.append(arena, '.');
    }
    if (info.forced) try b.appendSlice(arena, "forced.");
    if (info.sdh) try b.appendSlice(arena, "sdh.");
    try b.appendSlice(arena, ext);
    return b.toOwnedSlice(arena);
}

test "parse detects trailing language + flags, ignoring release noise" {
    const t = std.testing;
    try t.expectEqualStrings("en", parse("Dune.2021.1080p.BluRay.x264-GRP.en").lang.?);
    try t.expectEqualStrings("en", parse("Movie Name (2021) English").lang.?);
    try t.expectEqualStrings("es", parse("Pelicula_2020_spanish").lang.?);
    const forced = parse("Dune.2021.en.forced");
    try t.expectEqualStrings("en", forced.lang.?);
    try t.expect(forced.forced);
    const sdh = parse("Show.S01E01.eng.sdh");
    try t.expectEqualStrings("en", sdh.lang.?);
    try t.expect(sdh.sdh);
    // no trailing language token → null (don't mislabel)
    try t.expectEqual(@as(?[]const u8, null), parse("Dune.2021.1080p.x264").lang);
    try t.expectEqual(@as(?[]const u8, null), parse("Just A Movie").lang);
}

test "destExt builds the Jellyfin suffix" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("en.srt", try destExt(a, .{ .lang = "en" }, "srt"));
    try t.expectEqualStrings("en.forced.srt", try destExt(a, .{ .lang = "en", .forced = true }, "srt"));
    try t.expectEqualStrings("en.sdh.srt", try destExt(a, .{ .lang = "en", .sdh = true }, "srt"));
    try t.expectEqualStrings("srt", try destExt(a, .{}, "srt")); // undetected → bare ext
}

test "isSubtitleExt" {
    try std.testing.expect(isSubtitleExt("srt"));
    try std.testing.expect(isSubtitleExt("ASS"));
    try std.testing.expect(isSubtitleExt("vtt"));
    try std.testing.expect(!isSubtitleExt("nfo"));
    try std.testing.expect(!isSubtitleExt("mkv"));
}
