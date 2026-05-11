//! Tiny wall-clock helper. In Zig 0.16 the canonical time source is
//! `Io.Timestamp.now(io, .real)`, but that requires threading an Io
//! through every catalog call. For audit timestamps (added_at,
//! updated_at, fetched_at) a direct libc `time()` call is good enough
//! and keeps the catalog API synchronous.

const std = @import("std");

extern "c" fn time(t: ?*i64) i64;

/// Seconds since the Unix epoch.
pub fn nowSeconds() i64 {
    return time(null);
}
