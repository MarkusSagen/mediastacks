//! Deterministic media-kind classification from a basename.
//!
//! Extension decides the broad family; for video files a season-episode
//! marker distinguishes `.tv` from `.movie`. Sidecar/junk basenames
//! (`.nfo`, `.srt`, `.DS_Store`) classify as `.unknown` here — the
//! grouper handles them separately.

const std = @import("std");
const kind = @import("kind.zig");

const VIDEO_EXT = [_][]const u8{ ".mkv", ".mp4", ".avi", ".m4v", ".mov", ".wmv", ".ts", ".webm" };
const AUDIO_EXT = [_][]const u8{ ".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wma" };
const EBOOK_EXT = [_][]const u8{ ".epub", ".mobi", ".azw3" };
const COMIC_EXT = [_][]const u8{ ".cbz", ".cbr", ".cb7", ".cbt" };
const GAME_EXT = [_][]const u8{ ".nes", ".sfc", ".smc", ".gba", ".gb", ".gbc", ".n64", ".z64", ".iso", ".chd", ".rom", ".gg", ".md" };
const DOC_EXT = [_][]const u8{ ".pdf", ".txt", ".docx", ".md" };

fn extIn(ext: []const u8, set: []const []const u8) bool {
    for (set) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// True if `stem` contains an `SxxExx` or `NxNN` season-episode marker.
pub fn hasSeasonEpisode(stem: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, stem, " ._-\t");
    while (it.next()) |tok| {
        if (kind.isSeasonEpisodeToken(tok)) return true;
    }
    // `1x12` style anywhere in the stem.
    var i: usize = 0;
    while (i + 2 < stem.len) : (i += 1) {
        if ((stem[i] == 'x' or stem[i] == 'X') and i > 0 and
            std.ascii.isDigit(stem[i - 1]) and std.ascii.isDigit(stem[i + 1]))
        {
            return true;
        }
    }
    return false;
}

pub fn classify(basename: []const u8, is_dir: bool) kind.MediaKind {
    if (is_dir) return .unknown;

    const ext = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext.len];

    if (extIn(ext, &VIDEO_EXT)) {
        return if (hasSeasonEpisode(stem)) .tv else .movie;
    }
    if (extIn(ext, &AUDIO_EXT)) return .music;
    if (extIn(ext, &EBOOK_EXT)) return .ebook;
    if (extIn(ext, &COMIC_EXT)) return .comic;
    if (extIn(ext, &GAME_EXT)) return .game;
    if (extIn(ext, &DOC_EXT)) return .document;
    return .unknown;
}

const t = std.testing;

test "classify detects tv from SxxExx video file" {
    try t.expectEqual(kind.MediaKind.tv, classify("witch.hat.atelier.s01e12.1080p.web.h264-skyanime.mkv", false));
}
test "classify detects movie from plain video file" {
    try t.expectEqual(kind.MediaKind.movie, classify("Blade Runner 2049 (2017) 1080p.mkv", false));
}
test "classify detects music from audio extensions" {
    try t.expectEqual(kind.MediaKind.music, classify("03 - Layla.mp3", false));
    try t.expectEqual(kind.MediaKind.music, classify("song.flac", false));
    try t.expectEqual(kind.MediaKind.music, classify("x.m4a", false));
}

test "classify routes ebook, comic, and pdf" {
    try t.expectEqual(kind.MediaKind.ebook, classify("book.epub", false));
    try t.expectEqual(kind.MediaKind.comic, classify("issue.cbz", false));
    try t.expectEqual(kind.MediaKind.document, classify("paper.pdf", false));
}
test "classify returns unknown for directories and sidecars" {
    try t.expectEqual(kind.MediaKind.unknown, classify("Some Show", true));
    try t.expectEqual(kind.MediaKind.unknown, classify("episode.nfo", false));
}
