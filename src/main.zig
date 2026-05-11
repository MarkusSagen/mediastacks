const std = @import("std");
const booktool = @import("booktool");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buf);
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
