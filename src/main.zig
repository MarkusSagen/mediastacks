const std = @import("std");
const builtin = @import("builtin");
const booktool = @import("booktool");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
    },
    .logFn = customLogFn,
};

const debug_state_unchecked: u8 = 0;
const debug_state_enabled: u8 = 1;
const debug_state_disabled: u8 = 2;

/// Latched on first `customLogFn` call to avoid hitting getenv on every
/// log line. Initial `0` means "not yet checked"; transitions to `1` or
/// `2` after we've consulted `BOOKTOOL_DEBUG`. Race between threads is
/// benign: every caller deterministically observes the same env value
/// and the same final state.
var debug_env_state: std.atomic.Value(u8) = .init(debug_state_unchecked);

/// Returns true iff `.debug` lines should reach the writer for this build.
/// - Debug builds always emit (matches "you're developing — show me
///   everything" expectation).
/// - Release builds emit only when `BOOKTOOL_DEBUG` is set to any
///   non-empty value (so `BOOKTOOL_DEBUG=1`, `BOOKTOOL_DEBUG=ol`, etc
///   all turn it on — we don't try to scope by value).
fn debugEmitEnabled() bool {
    if (builtin.mode == .Debug) return true;
    var state = debug_env_state.load(.acquire);
    if (state == debug_state_unchecked) {
        const present = std.c.getenv("BOOKTOOL_DEBUG") != null;
        state = if (present) debug_state_enabled else debug_state_disabled;
        debug_env_state.store(state, .release);
    }
    return state == debug_state_enabled;
}

fn customLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (level == .debug and !debugEmitEnabled()) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    booktool.shutdown.install() catch |err| {
        std.debug.print("signal handler install failed: {s}\n", .{@errorName(err)});
    };

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const exit_code = booktool.cli.run(.{
        .arena = arena,
        .io = init.io,
        .args = args,
        .env = init.environ_map,
        .stdout = stdout,
        .stderr = stderr,
    }) catch |err| {
        stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(2);
    };

    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(exit_code);
}
