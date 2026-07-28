//! Safe-ish wrapper over a small slice of sqlite3.
//!
//! Connection lifecycle: open / close / exec.
//! Statement lifecycle: prepare / bind* / step / column* / finalize.
//! Higher-level repo helpers live in src/core/catalog.zig.

const std = @import("std");
const c = @import("c");

extern "c" fn booktool_bind_text(
    stmt: ?*c.sqlite3_stmt,
    idx: c_int,
    text: [*]const u8,
    len: c_int,
) c_int;

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    NoRow,
};

pub fn open(path: []const u8) !*c.sqlite3 {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return Error.OpenFailed;

    var db: ?*c.sqlite3 = null;
    const flags: c_int =
        c.SQLITE_OPEN_READWRITE |
        c.SQLITE_OPEN_CREATE |
        c.SQLITE_OPEN_FULLMUTEX;
    const rc = c.sqlite3_open_v2(path_z.ptr, &db, flags, null);
    if (rc != c.SQLITE_OK or db == null) {
        if (db) |d| _ = c.sqlite3_close(d);
        return Error.OpenFailed;
    }
    _ = c.sqlite3_exec(db.?, "PRAGMA journal_mode=WAL;PRAGMA foreign_keys=ON;", null, null, null);
    return db.?;
}

pub fn close(db: *c.sqlite3) void {
    _ = c.sqlite3_close(db);
}

pub fn exec(db: *c.sqlite3, sql: []const u8) !void {
    var sql_buf: [16 * 1024]u8 = undefined;
    const sql_z = std.fmt.bufPrintZ(&sql_buf, "{s}", .{sql}) catch return Error.ExecFailed;
    const rc = c.sqlite3_exec(db, sql_z.ptr, null, null, null);
    if (rc != c.SQLITE_OK) return Error.ExecFailed;
}

pub const Stmt = struct {
    db: *c.sqlite3,
    ptr: *c.sqlite3_stmt,

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.ptr);
    }

    /// 1-based parameter index (matches SQLite convention).
    pub fn bindText(self: *Stmt, idx: c_int, value: []const u8) !void {
        const rc = booktool_bind_text(self.ptr, idx, value.ptr, @intCast(value.len));
        if (rc != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindNullableText(self: *Stmt, idx: c_int, value: ?[]const u8) !void {
        if (value) |v| return self.bindText(idx, v);
        if (c.sqlite3_bind_null(self.ptr, idx) != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindInt64(self: *Stmt, idx: c_int, value: i64) !void {
        if (c.sqlite3_bind_int64(self.ptr, idx, value) != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindNullableInt64(self: *Stmt, idx: c_int, value: ?i64) !void {
        if (value) |v| return self.bindInt64(idx, v);
        if (c.sqlite3_bind_null(self.ptr, idx) != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindDouble(self: *Stmt, idx: c_int, value: f64) !void {
        if (c.sqlite3_bind_double(self.ptr, idx, value) != c.SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindNullableDouble(self: *Stmt, idx: c_int, value: ?f64) !void {
        if (value) |v| return self.bindDouble(idx, v);
        if (c.sqlite3_bind_null(self.ptr, idx) != c.SQLITE_OK) return Error.BindFailed;
    }

    /// Returns true if a row is available (SQLITE_ROW), false on done.
    pub fn step(self: *Stmt) !bool {
        return switch (c.sqlite3_step(self.ptr)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => Error.StepFailed,
        };
    }

    /// Reset for re-execution with new bindings.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.ptr);
    }

    /// Returns the column text as a slice into SQLite-owned memory.
    /// Caller MUST copy before next step/reset/finalize.
    pub fn columnText(self: *Stmt, col: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.ptr, col);
        if (ptr == null) return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.ptr, col));
        if (len == 0) return null;
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    pub fn columnInt64(self: *Stmt, col: c_int) i64 {
        return c.sqlite3_column_int64(self.ptr, col);
    }

    pub fn columnDouble(self: *Stmt, col: c_int) f64 {
        return c.sqlite3_column_double(self.ptr, col);
    }

    pub fn columnIsNull(self: *Stmt, col: c_int) bool {
        return c.sqlite3_column_type(self.ptr, col) == c.SQLITE_NULL;
    }
};

pub fn prepare(db: *c.sqlite3, sql: []const u8) !Stmt {
    var sql_buf: [16 * 1024]u8 = undefined;
    const sql_z = std.fmt.bufPrintZ(&sql_buf, "{s}", .{sql}) catch return Error.PrepareFailed;
    var stmt: ?*c.sqlite3_stmt = null;
    const rc = c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null);
    if (rc != c.SQLITE_OK or stmt == null) return Error.PrepareFailed;
    return .{ .db = db, .ptr = stmt.? };
}

pub fn lastInsertRowid(db: *c.sqlite3) i64 {
    return c.sqlite3_last_insert_rowid(db);
}

pub fn changes(db: *c.sqlite3) c_int {
    return c.sqlite3_changes(db);
}
