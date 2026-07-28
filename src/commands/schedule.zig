//! `booktool schedule <subcommand>` — manage scheduled maintenance.
//!
//! Subcommands:
//!   list                   show every scheduled job
//!   add NAME SPEC TYPE     create a new job
//!   rm ID                  delete a job
//!   enable ID / disable ID toggle enabled flag
//!   run ID                 run a job now (synchronous)
//!   daemon                 run the scheduler loop without the HTTP server
//!
//! Spec forms: @hourly, @daily, @weekly, @monthly, "every Nm", "every Nh".
//! Types: rescan-all, enrich-missing, standardize-dry, backfill-paths.
//!
//! `serve` already runs the same loop in-process, so `daemon` is for
//! users who don't want to keep `booktool serve` running. The two
//! never run on the same catalog at the same time — both poll the
//! catalog every minute and would double-fire jobs. We don't enforce
//! that with a file lock (would surprise users behind a NAT mount);
//! it's documented and we recommend one OR the other.

const std = @import("std");
const cli = @import("../cli.zig");
const catalog_mod = @import("../core/catalog.zig");
const jobs = @import("../core/jobs.zig");
const job_runner = @import("../core/job_runner.zig");
const clock = @import("../util/clock.zig");

pub fn run(ctx: cli.Context, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try printHelp(ctx.stdout);
        return 1;
    }
    const sub = args[0];
    const rest = args[1..];

    const cat_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    var cat = try catalog_mod.Catalog.open(cat_path);
    defer cat.close();

    if (eq(sub, "list")) return cmdList(ctx, &cat);
    if (eq(sub, "add")) return cmdAdd(ctx, &cat, rest);
    if (eq(sub, "rm") or eq(sub, "remove") or eq(sub, "delete")) return cmdRemove(ctx, &cat, rest);
    if (eq(sub, "enable")) return cmdSetEnabled(ctx, &cat, rest, true);
    if (eq(sub, "disable")) return cmdSetEnabled(ctx, &cat, rest, false);
    if (eq(sub, "run")) return cmdRun(ctx, &cat, rest);
    if (eq(sub, "daemon")) return cmdDaemon(ctx, &cat);
    if (eq(sub, "help") or eq(sub, "-h") or eq(sub, "--help")) {
        try printHelp(ctx.stdout);
        return 0;
    }

    try ctx.stderr.print("unknown schedule subcommand: {s}\n", .{sub});
    try printHelp(ctx.stderr);
    return 1;
}

fn cmdList(ctx: cli.Context, cat: *catalog_mod.Catalog) !u8 {
    const all = try jobs.listAll(cat.db, ctx.arena);
    if (all.len == 0) {
        try ctx.stdout.print("(no scheduled jobs)\n", .{});
        return 0;
    }
    try ctx.stdout.print("{s:<4} {s:<24} {s:<12} {s:<18} {s:<10} {s:<24}\n", .{
        "id", "name", "spec", "type", "enabled", "next run",
    });
    for (all) |j| {
        try ctx.stdout.print("{d:<4} {s:<24} {s:<12} {s:<18} {s:<10} {s:<24}\n", .{
            j.id,
            j.name,
            j.spec,
            j.job_type.toString(),
            if (j.enabled) "yes" else "no",
            try formatTs(ctx.arena, j.next_run_at),
        });
    }
    return 0;
}

fn cmdAdd(ctx: cli.Context, cat: *catalog_mod.Catalog, args: []const []const u8) !u8 {
    if (args.len < 3) {
        try ctx.stderr.print("usage: booktool schedule add NAME SPEC TYPE\n", .{});
        return 1;
    }
    const name = args[0];
    const spec = args[1];
    const type_str = args[2];
    const jt = jobs.JobType.fromString(type_str) orelse {
        try ctx.stderr.print("unknown job type: {s}\n", .{type_str});
        try ctx.stderr.print("known: rescan-all, enrich-missing, standardize-dry, backfill-paths\n", .{});
        return 1;
    };
    _ = jobs.nextRunAt(spec, 0, clock.nowSeconds()) catch {
        try ctx.stderr.print(
            "bad spec: {s}\nuse @hourly | @daily | @weekly | @monthly | \"every Nm\" | \"every Nh\"\n",
            .{spec},
        );
        return 1;
    };
    const id = try jobs.create(cat.db, ctx.arena, .{
        .name = name,
        .spec = spec,
        .job_type = jt,
        .enabled = true,
    });
    try ctx.stdout.print("created job {d}: {s} ({s}, {s})\n", .{ id, name, spec, type_str });
    return 0;
}

fn cmdRemove(ctx: cli.Context, cat: *catalog_mod.Catalog, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: booktool schedule rm ID\n", .{});
        return 1;
    }
    const id = std.fmt.parseInt(i64, args[0], 10) catch {
        try ctx.stderr.print("bad id: {s}\n", .{args[0]});
        return 1;
    };
    try jobs.delete(cat.db, id);
    try ctx.stdout.print("deleted job {d}\n", .{id});
    return 0;
}

fn cmdSetEnabled(ctx: cli.Context, cat: *catalog_mod.Catalog, args: []const []const u8, enabled: bool) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: booktool schedule {s} ID\n", .{if (enabled) "enable" else "disable"});
        return 1;
    }
    const id = std.fmt.parseInt(i64, args[0], 10) catch {
        try ctx.stderr.print("bad id: {s}\n", .{args[0]});
        return 1;
    };
    try jobs.setEnabled(cat.db, id, enabled);
    try ctx.stdout.print("job {d} {s}\n", .{ id, if (enabled) "enabled" else "disabled" });
    return 0;
}

fn cmdRun(ctx: cli.Context, cat: *catalog_mod.Catalog, args: []const []const u8) !u8 {
    if (args.len < 1) {
        try ctx.stderr.print("usage: booktool schedule run ID\n", .{});
        return 1;
    }
    const id = std.fmt.parseInt(i64, args[0], 10) catch {
        try ctx.stderr.print("bad id: {s}\n", .{args[0]});
        return 1;
    };
    const job = (try jobs.get(cat.db, ctx.arena, id)) orelse {
        try ctx.stderr.print("job {d} not found\n", .{id});
        return 1;
    };
    try ctx.stdout.print("running job {d} '{s}' ({s})…\n", .{ job.id, job.name, job.job_type.toString() });
    _ = try job_runner.runJob(ctx.arena, ctx.io, cat, job);
    const refreshed = (try jobs.get(cat.db, ctx.arena, id)) orelse unreachable;
    try ctx.stdout.print("  status: {s}\n  summary: {s}\n", .{
        refreshed.last_run_status orelse "(none)",
        refreshed.last_run_summary orelse "(none)",
    });
    return 0;
}

fn cmdDaemon(ctx: cli.Context, cat: *catalog_mod.Catalog) !u8 {
    const cat_path = try catalog_mod.defaultPath(ctx.arena, ctx.env);
    try ctx.stdout.print("scheduler daemon starting (catalog={s}); Ctrl+C to stop\n", .{cat_path});
    job_runner.loop(ctx.arena, ctx.io, cat, .{}) catch |err| {
        try ctx.stderr.print("scheduler exited with error: {s}\n", .{@errorName(err)});
        return 2;
    };
    return 0;
}

fn formatTs(arena: std.mem.Allocator, ts: i64) ![]const u8 {
    if (ts == 0) return arena.dupe(u8, "—");
    const now = clock.nowSeconds();
    const delta = ts - now;
    if (delta < 0) return std.fmt.allocPrint(arena, "{d}s ago", .{-delta});
    if (delta < 60) return std.fmt.allocPrint(arena, "in {d}s", .{delta});
    if (delta < 3600) return std.fmt.allocPrint(arena, "in {d}m", .{@divFloor(delta, 60)});
    if (delta < 86400) return std.fmt.allocPrint(arena, "in {d}h", .{@divFloor(delta, 3600)});
    return std.fmt.allocPrint(arena, "in {d}d", .{@divFloor(delta, 86400)});
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage: booktool schedule <subcommand>
        \\
        \\Subcommands:
        \\  list                       Show every scheduled job
        \\  add NAME SPEC TYPE         Create a new job
        \\  rm ID                      Delete a job
        \\  enable ID | disable ID     Toggle whether a job runs on its tick
        \\  run ID                     Run a job NOW (synchronous, ignores schedule)
        \\  daemon                     Run the scheduler loop without the HTTP server
        \\
        \\Specs:
        \\  @hourly | @daily | @weekly | @monthly
        \\  every Nm | every Nh        (every N minutes / hours, N >= 1)
        \\
        \\Types:
        \\  rescan-all      Walk every tracked library source
        \\  enrich-missing  Fetch Open Library metadata for incomplete rows
        \\  standardize-dry Preview-only canonical rename plan
        \\  backfill-paths  Parse series / index from filenames
        \\
        \\Examples:
        \\  booktool schedule add nightly-rescan @daily rescan-all
        \\  booktool schedule add every-6h-backfill "every 6h" backfill-paths
        \\
    );
}
