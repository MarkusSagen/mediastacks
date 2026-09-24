//! Tiny wall-clock helper. In Zig 0.16 the canonical time source is
//! `Io.Timestamp.now(io, .real)`, but that requires threading an Io
//! through every catalog call. For audit timestamps (added_at,
//! updated_at, fetched_at) a direct libc `time()` call is good enough
//! and keeps the catalog API synchronous.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn time(t: ?*i64) i64;

/// Seconds since the Unix epoch.
pub fn nowSeconds() i64 {
    return time(null);
}

// Windows has no `nanosleep`/`timespec`; use kernel32 Sleep there. Referenced
// only on Windows, so the extern isn't analyzed on POSIX.
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Sleep for `ms` milliseconds (portable — used for HTTP throttling + job
/// backoff). The comptime `if/else` prunes the other platform's branch.
pub fn sleepMs(ms: u64) void {
    if (comptime builtin.os.tag == .windows) {
        Sleep(@intCast(@min(ms, std.math.maxInt(u32))));
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&req, null);
    }
}

extern "c" fn gettimeofday(tv: *std.c.timeval, tz: ?*anyopaque) c_int; // POSIX only (referenced under the else)
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// Milliseconds for throttle/backoff deltas. On POSIX this is wall-clock
/// (gettimeofday); on Windows it's monotonic ms since boot (GetTickCount64) —
/// both are fine since callers only ever compare two readings.
pub fn nowMs() i64 {
    if (comptime builtin.os.tag == .windows) return @intCast(GetTickCount64());
    var tv: std.c.timeval = undefined;
    if (gettimeofday(&tv, null) != 0) return 0;
    return @as(i64, @intCast(tv.sec)) * 1000 + @divTrunc(@as(i64, @intCast(tv.usec)), 1000);
}
