//! Process-wide graceful-shutdown coordination.
//!
//! Single global atomic that the SIGINT/SIGTERM handler flips. Every
//! long-running loop in the process (HTTP accept loop, batch workers,
//! prewarm thread, scan thread, batch enrich) polls `isRequested()`
//! between units of work so a `Ctrl+C` lets in-flight work finish
//! gracefully rather than corrupt state by being killed mid-flight.
//!
//! Pressing Ctrl+C a second time bypasses the graceful path and exits
//! immediately — useful when a worker is stuck on a slow HTTP call.

const std = @import("std");

var g_requested: std.atomic.Value(bool) = .init(false);
var g_first_signal: std.atomic.Value(bool) = .init(true);

pub fn isRequested() bool {
    return g_requested.load(.monotonic);
}

pub fn request() void {
    g_requested.store(true, .monotonic);
}

/// Signal-safe handler. Avoid anything that could touch the heap,
/// take a mutex, or interact with stdio buffering. write(2) is on
/// the async-signal-safe list, so a direct fixed-string write is OK.
fn handler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    g_requested.store(true, .monotonic);
    if (g_first_signal.swap(false, .monotonic)) {
        const msg = "\nshutdown requested — finishing in-flight work (Ctrl+C again to force exit)\n";
        _ = std.c.write(2, msg.ptr, msg.len);
    } else {
        const msg = "\nforce exit\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        std.c.exit(130);
    }
}

/// Install handlers for SIGINT and SIGTERM. Call once at process
/// start (typically in main / before serve()).
pub fn install() !void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}
