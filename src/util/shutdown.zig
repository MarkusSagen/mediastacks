//! Process-wide graceful-shutdown coordination.
//!
//! Single global atomic that the SIGINT/SIGTERM handler (POSIX) or console
//! Ctrl+C handler (Windows) flips. Every long-running loop in the process
//! (HTTP accept loop, batch workers, prewarm thread, scan thread, batch
//! enrich) polls `isRequested()` between units of work so a `Ctrl+C` lets
//! in-flight work finish gracefully rather than corrupt state by being killed
//! mid-flight.
//!
//! Pressing Ctrl+C a second time bypasses the graceful path and exits
//! immediately — useful when a worker is stuck on a slow HTTP call.

const std = @import("std");
const builtin = @import("builtin");

var g_requested: std.atomic.Value(bool) = .init(false);
var g_first_signal: std.atomic.Value(bool) = .init(true);

pub fn isRequested() bool {
    return g_requested.load(.monotonic);
}

pub fn request() void {
    g_requested.store(true, .monotonic);
}

/// Install the shutdown handler. Call once at process start.
pub fn install() !void {
    if (comptime builtin.os.tag == .windows) return windows_impl.install();
    return posix_impl.install();
}

const FIRST = "\nshutdown requested — finishing in-flight work (Ctrl+C again to force exit)\n";
const FORCE = "\nforce exit\n";

// ── POSIX: SIGINT / SIGTERM via sigaction ──────────────────────────────
const posix_impl = struct {
    /// Signal-safe handler. Avoid anything that could touch the heap, take a
    /// mutex, or interact with stdio buffering. write(2) is async-signal-safe.
    fn handler(sig: std.c.SIG) callconv(.c) void {
        _ = sig;
        g_requested.store(true, .monotonic);
        if (g_first_signal.swap(false, .monotonic)) {
            _ = std.c.write(2, FIRST.ptr, FIRST.len);
        } else {
            _ = std.c.write(2, FORCE.ptr, FORCE.len);
            std.c.exit(130);
        }
    }

    fn install() !void {
        var act = std.posix.Sigaction{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
};

// ── Windows: console Ctrl handler via SetConsoleCtrlHandler ─────────────
const windows_impl = struct {
    const win = std.os.windows;
    // Not exposed by std.os.windows.kernel32 in Zig 0.16, so declare it here.
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (win.DWORD) callconv(.winapi) win.BOOL,
        add: win.BOOL,
    ) callconv(.winapi) win.BOOL;

    /// Runs on a dedicated OS thread (not an interrupt), so it can safely write
    /// to stderr and lock. Returning TRUE marks the event handled.
    fn handler(ctrl_type: win.DWORD) callconv(.winapi) win.BOOL {
        _ = ctrl_type;
        g_requested.store(true, .monotonic);
        if (g_first_signal.swap(false, .monotonic)) {
            std.debug.print("{s}", .{FIRST});
            return .TRUE;
        }
        std.debug.print("{s}", .{FORCE});
        std.process.exit(130);
    }

    fn install() !void {
        if (SetConsoleCtrlHandler(&handler, .TRUE) == .FALSE) return error.InstallFailed;
    }
};
