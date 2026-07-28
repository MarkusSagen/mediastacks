//! Small wrapper around `std.process.Child` for running external
//! programs and capturing stdout. Used by the comic-archive handlers
//! that shell out to `7zz`; reusable for any future "we need this
//! external binary but don't want to link a C lib" path.

const std = @import("std");

pub const RunResult = struct {
    /// Captured stdout. Owned by the caller (use the allocator passed
    /// to `runCaptureStdout`).
    stdout: []u8,
    /// Process exit code. -1 when the child was terminated by signal
    /// or crashed (in which case `stdout` may still hold whatever it
    /// managed to write before death).
    exit_code: i32,
};

pub const Error = error{
    SpawnFailed,
    ReadFailed,
    KilledBySignal,
};

/// Run `argv` and return its stdout + exit code. Stderr is discarded
/// — callers that need diagnostics should log them at the call site
/// (the std.log.warn pattern). Set `max_output` to bound the read so
/// a runaway child can't OOM us; defaults to 32MB which is generous
/// for any cover/metadata extraction.
pub fn runCaptureStdout(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    max_output: usize,
) !RunResult {
    const limit: std.Io.Limit = .limited(max_output);
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = limit,
        .stderr_limit = limit,
    }) catch return Error.SpawnFailed;
    allocator.free(result.stderr);
    return .{
        .stdout = result.stdout,
        .exit_code = switch (result.term) {
            .exited => |c| @intCast(c),
            else => -1,
        },
    };
}

/// True iff `name` is a binary we can execute (resolves via PATH).
/// Implemented as a `which` shell-out — cheap and avoids re-implementing
/// PATH lookup in Zig. Returns false when the lookup fails for any
/// reason (binary missing, PATH unset, signal).
pub fn isExecutableInPath(allocator: std.mem.Allocator, io: std.Io, name: []const u8) bool {
    const r = runCaptureStdout(allocator, io, &.{ "which", name }, 1024) catch return false;
    defer allocator.free(r.stdout);
    return r.exit_code == 0 and r.stdout.len > 0;
}
