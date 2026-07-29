const std = @import("std");
const builtin = @import("builtin");
const stacks = @import("stacks");

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

var debug_env_state: std.atomic.Value(u8) = .init(debug_state_unchecked);

fn debugEmitEnabled() bool {
    if (builtin.mode == .Debug) return true;
    var state = debug_env_state.load(.acquire);
    if (state == debug_state_unchecked) {
        const present = std.c.getenv("STACKS_DEBUG") != null;
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
    stacks.shutdown.install() catch |err| {
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

    const exit_code = stacks.shelve_cli.run(.{
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
