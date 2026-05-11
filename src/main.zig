const std = @import("std");
const booktool = @import("booktool");

// Silence vaxis info-level logs. They go to stderr and leak into the
// alt-screen output during TUI init ("info(vaxis): kitty keyboard
// capability detected" etc).
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // stdout/stderr must be streaming, not positional. /dev/null and
    // pipes can't be seeked — pwrite into them returns INVAL and Zig's
    // debug-build panics with "programmer bug caused syscall error".
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
