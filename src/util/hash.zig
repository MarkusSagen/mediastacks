//! File hashing utilities. SHA-256 of full file contents — slow but
//! definitive for exact-duplicate detection.

const std = @import("std");

pub const HEX_LEN: usize = 64;

/// Stream-hash a file and write the hex-encoded digest into `out` (must
/// be `>= HEX_LEN` bytes). Returns the slice into `out` of length 64.
pub fn fileSha256Hex(io: std.Io, path: []const u8, out: []u8) ![]const u8 {
    if (out.len < HEX_LEN) return error.BufferTooSmall;

    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var bufs = [_][]u8{&buf};
    while (true) {
        const n = file.readStreaming(io, &bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out[0..HEX_LEN];
}

test "sha256 hex output is correctly formatted" {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var buf: [HEX_LEN]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &buf,
    );
}
