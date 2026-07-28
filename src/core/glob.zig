//! Minimal shell-style glob matcher (file-path level).
//!
//! Supports:
//!   *       any chars except `/`
//!   **      any chars including `/`
//!   ?       any single char except `/`
//!   [abc]   character class
//!   [!abc]  negated character class
//!   [a-z]   range
//!
//! Path separators are always `/` on input. No brace expansion.

const std = @import("std");

pub fn match(pattern: []const u8, path: []const u8) bool {
    return matchInner(pattern, path);
}

fn matchInner(pat: []const u8, str: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pat: ?usize = null;
    var star_str: usize = 0;

    while (si < str.len) {
        if (pi < pat.len) {
            const pc = pat[pi];

            if (pc == '*' and pi + 1 < pat.len and pat[pi + 1] == '*') {
                const after = pi + 2;
                const after_slash = if (after < pat.len and pat[after] == '/') after + 1 else after;
                var k: usize = si;
                while (k <= str.len) : (k += 1) {
                    if (matchInner(pat[after_slash..], str[k..])) return true;
                }
                return false;
            }

            if (pc == '?' and str[si] != '/') {
                pi += 1;
                si += 1;
                continue;
            }

            if (pc == '[') {
                var class_end = pi;
                if (matchCharClass(pat, &class_end, str[si])) {
                    pi = class_end;
                    si += 1;
                    continue;
                }
            } else if (pc == '*') {
                star_pat = pi + 1;
                star_str = si;
                pi += 1;
                continue;
            } else if (pc == str[si]) {
                pi += 1;
                si += 1;
                continue;
            }
        }
        if (star_pat) |sp| {
            if (str[star_str] == '/') return false;
            pi = sp;
            star_str += 1;
            si = star_str;
            continue;
        }
        return false;
    }
    while (pi < pat.len and pat[pi] == '*') {
        if (pi + 1 < pat.len and pat[pi + 1] == '*') {
            pi += 2;
        } else {
            pi += 1;
        }
    }
    return pi == pat.len;
}

fn matchCharClass(pat: []const u8, pi: *usize, ch: u8) bool {
    var idx = pi.* + 1;
    var negate = false;
    if (idx < pat.len and (pat[idx] == '!' or pat[idx] == '^')) {
        negate = true;
        idx += 1;
    }
    var hit = false;
    while (idx < pat.len and pat[idx] != ']') {
        const c = pat[idx];
        if (idx + 2 < pat.len and pat[idx + 1] == '-' and pat[idx + 2] != ']') {
            if (ch >= c and ch <= pat[idx + 2]) hit = true;
            idx += 3;
        } else {
            if (ch == c) hit = true;
            idx += 1;
        }
    }
    if (idx < pat.len and pat[idx] == ']') idx += 1;
    pi.* = idx;
    return if (negate) !hit else hit;
}

const t = std.testing;

test "exact literal" {
    try t.expect(match("foo.epub", "foo.epub"));
    try t.expect(!match("foo.epub", "bar.epub"));
}

test "single-star within a segment" {
    try t.expect(match("*.epub", "alice.epub"));
    try t.expect(!match("*.epub", "sub/alice.epub"));
}

test "double-star crosses segments" {
    try t.expect(match("**/*.epub", "sub/alice.epub"));
    try t.expect(match("**/*.epub", "a/b/c.epub"));
    try t.expect(match("epub/**", "epub/sub/x.epub"));
    try t.expect(match("**", "anything/at/all"));
}

test "single-star at start matches non-slash prefix" {
    try t.expect(match("*Hobb*", "Hobb, Robin"));
    try t.expect(!match("*Hobb*", "sub/Hobb"));
}

test "char class" {
    try t.expect(match("[Aa]lice", "Alice"));
    try t.expect(match("[Aa]lice", "alice"));
    try t.expect(!match("[Aa]lice", "blice"));
}

test "negated char class" {
    try t.expect(!match("[!a-z].txt", "a.txt"));
    try t.expect(match("[!a-z].txt", "A.txt"));
}

test "question mark wildcard" {
    try t.expect(match("foo.???", "foo.txt"));
    try t.expect(!match("foo.???", "foo.text"));
}

test "double-star folder filter then format" {
    try t.expect(match("**/Hobb*.mobi", "mobi/series/Hobb, Robin - The Farseer Trilogy 01.mobi"));
    try t.expect(!match("**/Hobb*.mobi", "mobi/series/Lee, Fonda - Jade City.mobi"));
}
