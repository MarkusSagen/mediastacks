//! `shelve organize DIR [flags]` — build a reorganization plan and, with
//! `--apply`, execute it. The dry-run plan is always printed first.

const std = @import("std");
const cli = @import("../cli.zig");
const config = @import("../core/config.zig");
const group = @import("../core/group.zig");
const plan_mod = @import("../core/plan.zig");
const apply_mod = @import("../core/apply.zig");

const Opts = struct {
    dir: ?[]const u8 = null,
    to: ?[]const u8 = null,
    apply: bool = false,
    plan_out: ?[]const u8 = null,
    from: ?[]const u8 = null,
    on_conflict: apply_mod.OnConflict = .skip,
};

fn parseConflict(s: []const u8) ?apply_mod.OnConflict {
    if (std.mem.eql(u8, s, "skip")) return .skip;
    if (std.mem.eql(u8, s, "suffix")) return .suffix;
    if (std.mem.eql(u8, s, "overwrite")) return .overwrite;
    return null;
}

fn parseArgs(args: []const []const u8) !Opts {
    var o: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.to = args[i];
        } else if (std.mem.eql(u8, a, "--apply")) {
            o.apply = true;
        } else if (std.mem.eql(u8, a, "--plan")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.plan_out = args[i];
        } else if (std.mem.eql(u8, a, "--from")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.from = args[i];
        } else if (std.mem.eql(u8, a, "--on-conflict")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            o.on_conflict = parseConflict(args[i]) orelse return error.BadConflict;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else if (o.dir == null) {
            o.dir = a;
        }
    }
    return o;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var pz: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&pz, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        try buf.appendSlice(alloc, chunk[0..n]);
    }
    return buf.toOwnedSlice(alloc);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var pz: [4096]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&pz, "{s}", .{path});
    const fp = std.c.fopen(path_z.ptr, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(fp);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) return error.WriteFailed;
}

fn printPlan(w: *std.Io.Writer, p: plan_mod.Plan) !void {
    var moves: usize = 0;
    var trash: usize = 0;
    var dup: usize = 0;
    for (p.groups) |g| {
        try w.print("[{s}] {s}\n", .{ @tagName(g.kind), g.title });
        for (g.items) |it| {
            switch (it.role) {
                .primary, .sidecar => {
                    try w.print("   -> {s}\n", .{it.dst orelse "?"});
                    moves += 1;
                },
                .duplicate => {
                    try w.print("   [dup] {s}\n", .{it.src});
                    dup += 1;
                },
                .junk => {
                    try w.print("   [junk] {s}\n", .{it.src});
                    trash += 1;
                },
            }
        }
    }
    try w.print(
        "\ngroups={d} move={d} trash={d} dup={d} unclassified={d}\n",
        .{ p.groups.len, moves, trash, dup, p.unclassified.len },
    );
}

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    const opts = parseArgs(args) catch |err| {
        try ctx.stderr.print("bad arguments: {s}\n", .{@errorName(err)});
        try ctx.stderr.print("usage: shelve organize DIR [--to LIB] [--apply] [--plan FILE] [--from FILE] [--on-conflict skip|suffix|overwrite]\n", .{});
        return 1;
    };

    var cfg = try config.load(ctx.arena, ctx.env);
    if (opts.to) |to| cfg.library_root = to;

    const p: plan_mod.Plan = blk: {
        if (opts.from) |fp| {
            const bytes = readFile(ctx.arena, fp) catch |err| {
                try ctx.stderr.print("cannot read plan {s}: {s}\n", .{ fp, @errorName(err) });
                return 2;
            };
            break :blk plan_mod.fromJson(ctx.arena, bytes) catch |err| {
                try ctx.stderr.print("cannot parse plan {s}: {s}\n", .{ fp, @errorName(err) });
                return 2;
            };
        }
        const dir = opts.dir orelse {
            try ctx.stderr.print("usage: shelve organize DIR [flags]\n", .{});
            return 1;
        };
        break :blk group.buildPlan(ctx.arena, ctx.io, dir, cfg) catch |err| {
            try ctx.stderr.print("cannot scan {s}: {s}\n", .{ dir, @errorName(err) });
            return 2;
        };
    };

    if (opts.plan_out) |op| {
        const j = try plan_mod.toJson(ctx.arena, p);
        writeFile(op, j) catch |err| {
            try ctx.stderr.print("cannot write plan {s}: {s}\n", .{ op, @errorName(err) });
            return 2;
        };
        try ctx.stdout.print("wrote plan to {s}\n", .{op});
    }

    try printPlan(ctx.stdout, p);

    if (opts.apply) {
        const res = apply_mod.apply(ctx.arena, p, opts.on_conflict, ctx.env) catch |err| {
            try ctx.stderr.print("apply failed: {s}\n", .{@errorName(err)});
            return 2;
        };
        try ctx.stdout.print(
            "\napplied: moved={d} trashed={d} skipped={d}\njournal: {s}\n",
            .{ res.moved, res.trashed, res.skipped, res.journal_path },
        );
    }
    return 0;
}

const t = std.testing;

test "parseArgs reads flags" {
    const args = [_][]const u8{ "/downloads/show", "--to", "/lib", "--apply", "--on-conflict", "suffix" };
    const opts = try parseArgs(args[0..]);
    try t.expectEqualStrings("/downloads/show", opts.dir.?);
    try t.expectEqualStrings("/lib", opts.to.?);
    try t.expect(opts.apply);
    try t.expectEqual(apply_mod.OnConflict.suffix, opts.on_conflict);
}

test "parseArgs defaults: dry-run, skip conflicts" {
    const args = [_][]const u8{"/x"};
    const opts = try parseArgs(args[0..]);
    try t.expect(!opts.apply);
    try t.expectEqual(apply_mod.OnConflict.skip, opts.on_conflict);
    try t.expect(opts.from == null);
}
