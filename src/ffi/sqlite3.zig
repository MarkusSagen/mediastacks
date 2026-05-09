//! Minimal sqlite3 wrapper sufficient for the catalog repo.
//!
//! Just open / close / exec for now. Prepared statements + binding will
//! be added when the repo needs them (post-skeleton).

const std = @import("std");
const c = @import("c");

pub const Error = error{
    OpenFailed,
    ExecFailed,
};

pub fn open(path: []const u8) !*c.sqlite3 {
    var path_z: [4096]u8 = undefined;
    if (path.len >= path_z.len) return Error.OpenFailed;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(@ptrCast(&path_z), &db);
    if (rc != c.SQLITE_OK or db == null) {
        if (db) |d| _ = c.sqlite3_close(d);
        return Error.OpenFailed;
    }
    return db.?;
}

pub fn close(db: *c.sqlite3) void {
    _ = c.sqlite3_close(db);
}

/// Run one or more SQL statements, ignoring any results.
pub fn exec(db: *c.sqlite3, sql: []const u8) !void {
    var sql_z: [16 * 1024]u8 = undefined;
    if (sql.len >= sql_z.len) return Error.ExecFailed;
    @memcpy(sql_z[0..sql.len], sql);
    sql_z[sql.len] = 0;

    var err_msg: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, @ptrCast(&sql_z), null, null, &err_msg);
    if (rc != c.SQLITE_OK) {
        if (err_msg != null) c.sqlite3_free(err_msg);
        return Error.ExecFailed;
    }
}
