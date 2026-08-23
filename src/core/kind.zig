//! Media-kind taxonomy and release-noise cleaning shared by every
//! organizer parser.
//!
//! `cleanName` turns a messy release basename into a human title stub:
//! it drops `www.*` site prefixes, `[..]`/`(..)` tag groups, and the
//! release/quality/codec trailer, converts `.`/`_` separators to
//! spaces, and collapses whitespace. Season/episode markers (`S01E12`)
//! are preserved — the TV parser needs them.

const std = @import("std");

pub const MediaKind = enum {
    ebook,
    comic,
    movie,
    tv,
    music,
    audiobook,
    game,
    document,
    unknown,
};

/// Release/codec/source tokens that mark the start of the "junk" tail of
/// a scene-style name. Matched case-insensitively as whole tokens.
pub const NOISE = [_][]const u8{
    "web",   "webdl",    "web-dl",  "webrip", "bluray", "bdrip", "brrip",
    "hdtv",  "dvdrip",   "hdrip",   "x264",   "x265",   "h264",  "h265",
    "hevc",  "avc",      "xvid",    "divx",   "aac",    "ac3",   "dts",
    "ddp2",  "ddp5",     "dd5",     "flac",   "10bit",  "8bit",  "hdr",
    "sdr",   "remux",    "proper",  "repack", "internal", "limited",
    "cr",    "dual",     "multi",   "subbed", "dubbed", "uncut", "extended",
};

/// True for resolution tokens (`1080p`, `720p`, `2160p`) and any token in
/// `NOISE`.
pub fn isNoiseToken(tok: []const u8) bool {
    if (tok.len >= 3 and tok.len <= 5 and (tok[tok.len - 1] == 'p' or tok[tok.len - 1] == 'P')) {
        var all_digits = true;
        for (tok[0 .. tok.len - 1]) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return true;
    }
    for (NOISE) |n| {
        if (std.ascii.eqlIgnoreCase(tok, n)) return true;
    }
    return false;
}

/// True for `SxxExx` / `sNNeNN` season-episode tokens (1-2 digits each).
pub fn isSeasonEpisodeToken(tok: []const u8) bool {
    if (tok.len < 4) return false;
    if (tok[0] != 's' and tok[0] != 'S') return false;
    var i: usize = 1;
    var digits: usize = 0;
    while (i < tok.len and std.ascii.isDigit(tok[i])) : (i += 1) digits += 1;
    if (digits < 1 or digits > 2) return false;
    if (i >= tok.len or (tok[i] != 'e' and tok[i] != 'E')) return false;
    i += 1;
    var edigits: usize = 0;
    while (i < tok.len and std.ascii.isDigit(tok[i])) : (i += 1) edigits += 1;
    return edigits >= 1 and edigits <= 2 and i == tok.len;
}

/// Clean a raw basename (without extension) into a title stub. Owned by
/// `alloc`.
pub fn cleanName(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");

    // Strip a leading `www.<site>` prefix up to its `-` (or first space).
    if (s.len >= 4 and std.ascii.eqlIgnoreCase(s[0..4], "www.")) {
        if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
            s = std.mem.trim(u8, s[dash + 1 ..], " \t\r\n");
        } else if (std.mem.indexOfScalar(u8, s, ' ')) |sp| {
            s = std.mem.trim(u8, s[sp + 1 ..], " \t\r\n");
        }
    }

    // Drop `[...]` / `(...)` groups.
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(alloc);
    var depth: usize = 0;
    for (s) |c| {
        if (c == '[' or c == '(') {
            depth += 1;
            continue;
        }
        if (c == ']' or c == ')') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth == 0) try scratch.append(alloc, c);
    }

    // Tokenize on separators.
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(alloc);
    var it = std.mem.tokenizeAny(u8, scratch.items, " ._\t");
    while (it.next()) |tok| {
        if (tok.len == 1 and tok[0] == '-') continue;
        try tokens.append(alloc, tok);
    }

    // Everything after the first noise token (past the SxxExx boundary) is
    // release trailer; drop it.
    var boundary: usize = 0;
    for (tokens.items, 0..) |tok, i| {
        if (isSeasonEpisodeToken(tok)) {
            boundary = i;
            break;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (tokens.items, 0..) |tok, i| {
        if (i > boundary and isNoiseToken(tok)) break;
        if (out.items.len > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, tok);
    }
    return out.toOwnedSlice(alloc);
}

const t = std.testing;

test "cleanName strips site prefix, tokens, and dotted separators" {
    const a = t.allocator;
    const out = try cleanName(a, "witch.hat.atelier.s01e12.1080p.web.h264-skyanime[EZTVx.to]");
    defer a.free(out);
    try t.expectEqualStrings("witch hat atelier s01e12", out);
}

test "cleanName strips UIndex wrapper and codec noise" {
    const a = t.allocator;
    const out = try cleanName(a, "www.UIndex.org    -    Witch Hat Atelier S01E04 Meetings in Kalhn 1080p CR WEB-DL DUAL DDP2 0 H 264-Kitsune");
    defer a.free(out);
    try t.expectEqualStrings("Witch Hat Atelier S01E04 Meetings in Kalhn", out);
}

test "isSeasonEpisodeToken matches SxxExx" {
    try t.expect(isSeasonEpisodeToken("s01e12"));
    try t.expect(isSeasonEpisodeToken("S01E04"));
    try t.expect(!isSeasonEpisodeToken("season"));
    try t.expect(!isSeasonEpisodeToken("1080p"));
}
