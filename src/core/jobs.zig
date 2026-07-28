//! Scheduled maintenance jobs.
//!
//! Stored in `scheduled_jobs` (see core/catalog.zig::initSchema).
//! This module owns the CRUD + the spec parser + the executor that
//! turns "rescan-all" / "enrich-missing" / etc. into actual catalog
//! mutations. The scheduler loop (in web/scheduler.zig) calls into
//! here once per minute; the `booktool schedule daemon` CLI uses
//! the same loop without the HTTP server.

const std = @import("std");
const sql = @import("../ffi/sqlite3.zig");
const c = @import("c");
const catalog_mod = @import("catalog.zig");
const clock = @import("../util/clock.zig");

const log = std.log.scoped(.jobs);

/// Job types the executor knows how to run. Stored in `job_type` as
/// the string form so we can add new ones without schema migrations.
pub const JobType = enum {
    rescan_all,
    enrich_missing,
    standardize_dry,
    backfill_paths,

    pub fn fromString(s: []const u8) ?JobType {
        if (std.mem.eql(u8, s, "rescan-all")) return .rescan_all;
        if (std.mem.eql(u8, s, "enrich-missing")) return .enrich_missing;
        if (std.mem.eql(u8, s, "standardize-dry")) return .standardize_dry;
        if (std.mem.eql(u8, s, "backfill-paths")) return .backfill_paths;
        return null;
    }
    pub fn toString(self: JobType) []const u8 {
        return switch (self) {
            .rescan_all => "rescan-all",
            .enrich_missing => "enrich-missing",
            .standardize_dry => "standardize-dry",
            .backfill_paths => "backfill-paths",
        };
    }
};

pub const RunStatus = enum {
    ok,
    err,
    running,

    pub fn toString(self: RunStatus) []const u8 {
        return switch (self) {
            .ok => "ok",
            .err => "error",
            .running => "running",
        };
    }
};

pub const Job = struct {
    id: i64,
    name: []const u8,
    spec: []const u8,
    job_type: JobType,
    params_json: ?[]const u8,
    enabled: bool,
    created_at: i64,
    updated_at: i64,
    last_run_at: ?i64,
    last_run_status: ?[]const u8,
    last_run_summary: ?[]const u8,
    next_run_at: i64,
};

pub const NewJob = struct {
    name: []const u8,
    spec: []const u8,
    job_type: JobType,
    params_json: ?[]const u8 = null,
    enabled: bool = true,
};

pub const SpecError = error{BadSpec};

/// Compute the next run-at timestamp (UTC seconds) given a spec
/// and the previous run-at (or, on first run, the current time).
pub fn nextRunAt(spec: []const u8, last_run_at: i64, now: i64) !i64 {
    const base = if (last_run_at > 0) last_run_at else now;

    if (std.mem.eql(u8, spec, "@hourly")) return alignTo(base, 3600);
    if (std.mem.eql(u8, spec, "@daily")) return alignToDay(base, 3 * 3600);
    if (std.mem.eql(u8, spec, "@weekly")) return alignToWeek(base, 3 * 3600);
    if (std.mem.eql(u8, spec, "@monthly")) return alignToMonth(base, 3 * 3600);

    if (std.mem.startsWith(u8, spec, "every ")) {
        const tail = spec["every ".len..];
        if (tail.len < 2) return SpecError.BadSpec;
        const unit = tail[tail.len - 1];
        const num_str = tail[0 .. tail.len - 1];
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, num_str, " "), 10) catch return SpecError.BadSpec;
        if (n <= 0) return SpecError.BadSpec;
        const delta_sec: i64 = switch (unit) {
            'm' => n * 60,
            'h' => n * 3600,
            else => return SpecError.BadSpec,
        };
        return base + delta_sec;
    }

    return SpecError.BadSpec;
}

/// Snap `t` UP to the next multiple of `interval` seconds. Used to
/// align "@hourly" to top-of-hour from any starting point.
fn alignTo(t: i64, interval: i64) i64 {
    const next = (@divFloor(t, interval) + 1) * interval;
    return next;
}

/// Snap `t` to the next 03:00 (UTC) at or after `t + 1`. "Off-peak"
/// hour so daily jobs don't compete with morning use.
fn alignToDay(t: i64, hour_offset: i64) i64 {
    const day = @divFloor(t, 86400);
    const candidate = day * 86400 + hour_offset;
    return if (candidate > t) candidate else candidate + 86400;
}

/// Next Monday 03:00 UTC after `t`. Epoch (1970-01-01) was a Thursday,
/// so Monday = (epoch_day + 4) % 7 == 0.
fn alignToWeek(t: i64, hour_offset: i64) i64 {
    const day = @divFloor(t, 86400);
    const dow = @mod(day + 4, 7);
    var days_to_mon: i64 = if (dow == 0) 7 else 7 - dow;
    var candidate = (day + days_to_mon) * 86400 + hour_offset;
    if (candidate <= t) {
        days_to_mon += 7;
        candidate = (day + days_to_mon) * 86400 + hour_offset;
    }
    return candidate;
}

/// Next 1st-of-month 03:00 UTC after `t`. Calendar-aware via
/// std.time.epoch helpers.
fn alignToMonth(t: i64, hour_offset: i64) i64 {
    const day_of_epoch = @divFloor(t, 86400);
    const ymd = (std.time.epoch.EpochDay{ .day = @intCast(day_of_epoch) }).calculateYearDay();
    var year = ymd.year;
    var month = (ymd.calculateMonthDay()).month.numeric();
    month += 1;
    if (month > 12) {
        month = 1;
        year += 1;
    }
    return daysUntil(year, month, 1) * 86400 + hour_offset;
}

fn daysUntil(year: u16, month: u4, day: u8) i64 {
    var total: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) total += if (isLeap(y)) 366 else 365;
    var m: u4 = 1;
    while (m < month) : (m += 1) total += daysInMonth(y, m);
    total += @intCast(day - 1);
    return total;
}
fn isLeap(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}
fn daysInMonth(y: u16, m: u4) i64 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) @as(i64, 29) else @as(i64, 28),
        else => unreachable,
    };
}

pub fn create(db: *c.sqlite3, allocator: std.mem.Allocator, new: NewJob) !i64 {
    const now = clock.nowSeconds();
    const next = try nextRunAt(new.spec, 0, now);
    _ = allocator;
    var stmt = try sql.prepare(
        db,
        "INSERT INTO scheduled_jobs " ++
            "(name, spec, job_type, params_json, enabled, created_at, updated_at, next_run_at) " ++
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    );
    defer stmt.finalize();
    try stmt.bindText(1, new.name);
    try stmt.bindText(2, new.spec);
    try stmt.bindText(3, new.job_type.toString());
    try stmt.bindNullableText(4, new.params_json);
    try stmt.bindInt64(5, if (new.enabled) 1 else 0);
    try stmt.bindInt64(6, now);
    try stmt.bindInt64(7, now);
    try stmt.bindInt64(8, next);
    _ = try stmt.step();
    return @import("../ffi/sqlite3.zig").lastInsertRowid(db);
}

pub fn delete(db: *c.sqlite3, id: i64) !void {
    var stmt = try sql.prepare(db, "DELETE FROM scheduled_jobs WHERE id = ?");
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    _ = try stmt.step();
}

pub fn setEnabled(db: *c.sqlite3, id: i64, enabled: bool) !void {
    var stmt = try sql.prepare(db, "UPDATE scheduled_jobs SET enabled = ?, updated_at = ? WHERE id = ?");
    defer stmt.finalize();
    try stmt.bindInt64(1, if (enabled) 1 else 0);
    try stmt.bindInt64(2, clock.nowSeconds());
    try stmt.bindInt64(3, id);
    _ = try stmt.step();
}

const COL_SELECT = "id, name, spec, job_type, params_json, enabled, created_at, updated_at, last_run_at, last_run_status, last_run_summary, next_run_at";

fn rowToJob(allocator: std.mem.Allocator, stmt: *sql.Stmt) !Job {
    return .{
        .id = stmt.columnInt64(0),
        .name = try allocator.dupe(u8, stmt.columnText(1) orelse ""),
        .spec = try allocator.dupe(u8, stmt.columnText(2) orelse ""),
        .job_type = JobType.fromString(stmt.columnText(3) orelse "") orelse .rescan_all,
        .params_json = if (stmt.columnText(4)) |s| try allocator.dupe(u8, s) else null,
        .enabled = stmt.columnInt64(5) != 0,
        .created_at = stmt.columnInt64(6),
        .updated_at = stmt.columnInt64(7),
        .last_run_at = if (stmt.columnIsNull(8)) null else stmt.columnInt64(8),
        .last_run_status = if (stmt.columnText(9)) |s| try allocator.dupe(u8, s) else null,
        .last_run_summary = if (stmt.columnText(10)) |s| try allocator.dupe(u8, s) else null,
        .next_run_at = stmt.columnInt64(11),
    };
}

pub fn listAll(db: *c.sqlite3, allocator: std.mem.Allocator) ![]Job {
    var stmt = try sql.prepare(db, "SELECT " ++ COL_SELECT ++ " FROM scheduled_jobs ORDER BY name COLLATE NOCASE");
    defer stmt.finalize();
    var out: std.ArrayList(Job) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, try rowToJob(allocator, &stmt));
    }
    return out.toOwnedSlice(allocator);
}

pub fn get(db: *c.sqlite3, allocator: std.mem.Allocator, id: i64) !?Job {
    var stmt = try sql.prepare(db, "SELECT " ++ COL_SELECT ++ " FROM scheduled_jobs WHERE id = ?");
    defer stmt.finalize();
    try stmt.bindInt64(1, id);
    if (!try stmt.step()) return null;
    return try rowToJob(allocator, &stmt);
}

/// Find every job whose `next_run_at <= now` AND `enabled = 1`. The
/// scheduler loop calls this once per tick to gather work.
pub fn listDue(db: *c.sqlite3, allocator: std.mem.Allocator, now: i64) ![]Job {
    var stmt = try sql.prepare(
        db,
        "SELECT " ++ COL_SELECT ++ " FROM scheduled_jobs " ++
            "WHERE enabled = 1 AND next_run_at <= ? ORDER BY next_run_at",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, now);
    var out: std.ArrayList(Job) = .empty;
    while (try stmt.step()) {
        try out.append(allocator, try rowToJob(allocator, &stmt));
    }
    return out.toOwnedSlice(allocator);
}

pub fn markRunning(db: *c.sqlite3, id: i64, at: i64) !void {
    var stmt = try sql.prepare(
        db,
        "UPDATE scheduled_jobs SET last_run_at = ?, last_run_status = 'running' WHERE id = ?",
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, at);
    try stmt.bindInt64(2, id);
    _ = try stmt.step();
}

/// Mark a job complete: status + summary + recompute next_run_at.
pub fn markComplete(
    db: *c.sqlite3,
    job: Job,
    status: RunStatus,
    summary: []const u8,
    now: i64,
) !void {
    const next = nextRunAt(job.spec, now, now) catch (now + 3600);
    var stmt = try sql.prepare(
        db,
        "UPDATE scheduled_jobs SET last_run_status = ?, last_run_summary = ?, next_run_at = ?, updated_at = ? WHERE id = ?",
    );
    defer stmt.finalize();
    try stmt.bindText(1, status.toString());
    try stmt.bindText(2, summary);
    try stmt.bindInt64(3, next);
    try stmt.bindInt64(4, now);
    try stmt.bindInt64(5, job.id);
    _ = try stmt.step();
}

test "spec @hourly aligns to top of hour" {
    const now: i64 = 1_700_000_000;
    const next = try nextRunAt("@hourly", 0, now);
    try std.testing.expect(next > now);
    try std.testing.expectEqual(@as(i64, 0), @mod(next, 3600));
}

test "spec @daily next run is at 03:00 UTC and at least 1s in future" {
    const now: i64 = 1_700_000_000;
    const next = try nextRunAt("@daily", 0, now);
    try std.testing.expect(next > now);
    const hour_in_day = @mod(next, 86400);
    try std.testing.expectEqual(@as(i64, 3 * 3600), hour_in_day);
}

test "spec every 30m advances by exactly 1800 seconds" {
    const base: i64 = 1_700_000_000;
    const next = try nextRunAt("every 30m", base, base);
    try std.testing.expectEqual(base + 1800, next);
}

test "spec every 6h advances by exactly 21600 seconds" {
    const base: i64 = 1_700_000_000;
    const next = try nextRunAt("every 6h", base, base);
    try std.testing.expectEqual(base + 21600, next);
}

test "spec parser rejects garbage" {
    try std.testing.expectError(SpecError.BadSpec, nextRunAt("bogus", 0, 0));
    try std.testing.expectError(SpecError.BadSpec, nextRunAt("every", 0, 0));
    try std.testing.expectError(SpecError.BadSpec, nextRunAt("every 5z", 0, 0));
    try std.testing.expectError(SpecError.BadSpec, nextRunAt("every 0h", 0, 0));
    try std.testing.expectError(SpecError.BadSpec, nextRunAt("every -1h", 0, 0));
}

test "JobType round-trips through string form" {
    const cases = [_]JobType{ .rescan_all, .enrich_missing, .standardize_dry, .backfill_paths };
    for (cases) |jt| {
        const back = JobType.fromString(jt.toString()) orelse unreachable;
        try std.testing.expectEqual(jt, back);
    }
}
