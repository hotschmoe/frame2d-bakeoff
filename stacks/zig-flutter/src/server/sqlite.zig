//! Minimal SQLite binding: just what the model store needs (open, exec, insert text, select text).
//! The amalgamation is compiled by build.zig; the handful of C functions used are declared here directly.
const std = @import("std");

const Db = opaque {};
const Stmt = opaque {};

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Db, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close(db: *Db) c_int;
extern fn sqlite3_exec(db: *Db, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: *Db, sql: [*]const u8, n: c_int, stmt: *?*Stmt, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_bind_text(stmt: *Stmt, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_bind_int64(stmt: *Stmt, idx: c_int, v: i64) c_int;
extern fn sqlite3_step(stmt: *Stmt) c_int;
extern fn sqlite3_column_text(stmt: *Stmt, col: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *Stmt, col: c_int) c_int;
extern fn sqlite3_finalize(stmt: *Stmt) c_int;
extern fn sqlite3_last_insert_rowid(db: *Db) i64;
extern fn sqlite3_busy_timeout(db: *Db, ms: c_int) c_int;
extern fn sqlite3_free(p: ?*anyopaque) void;

const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const OPEN_READWRITE_CREATE_FULLMUTEX = 0x00000002 | 0x00000004 | 0x00010000;
/// SQLITE_TRANSIENT: sqlite copies the bound text immediately.
const TRANSIENT: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub const Error = error{ SqliteOpen, SqliteExec, SqlitePrepare, SqliteStep, OutOfMemory };

/// A single shared connection opened in serialized mode, so any thread may use it.
pub const Store = struct {
    db: *Db,

    pub fn open(path: [:0]const u8) Error!Store {
        var db: ?*Db = null;
        if (sqlite3_open_v2(path.ptr, &db, OPEN_READWRITE_CREATE_FULLMUTEX, null) != 0 or db == null) return error.SqliteOpen;
        _ = sqlite3_busy_timeout(db.?, 5000);
        var errmsg: ?[*:0]u8 = null;
        const rc = sqlite3_exec(db.?, "CREATE TABLE IF NOT EXISTS models (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL)", null, null, &errmsg);
        if (errmsg) |e| sqlite3_free(@ptrCast(e));
        if (rc != 0) return error.SqliteExec;
        return .{ .db = db.? };
    }

    pub fn close(s: Store) void {
        _ = sqlite3_close(s.db);
    }

    /// Stores a model document and returns its new id.
    pub fn insert(s: Store, body: []const u8) Error!i64 {
        const sql = "INSERT INTO models (body) VALUES (?1)";
        var stmt: ?*Stmt = null;
        if (sqlite3_prepare_v2(s.db, sql, sql.len, &stmt, null) != 0) return error.SqlitePrepare;
        defer _ = sqlite3_finalize(stmt.?);
        if (sqlite3_bind_text(stmt.?, 1, body.ptr, @intCast(body.len), TRANSIENT) != 0) return error.SqliteExec;
        if (sqlite3_step(stmt.?) != SQLITE_DONE) return error.SqliteStep;
        return sqlite3_last_insert_rowid(s.db);
    }

    /// Returns the stored document (caller frees) or null when the id is unknown.
    pub fn get(s: Store, gpa: std.mem.Allocator, id: i64) Error!?[]u8 {
        const sql = "SELECT body FROM models WHERE id = ?1";
        var stmt: ?*Stmt = null;
        if (sqlite3_prepare_v2(s.db, sql, sql.len, &stmt, null) != 0) return error.SqlitePrepare;
        defer _ = sqlite3_finalize(stmt.?);
        if (sqlite3_bind_int64(stmt.?, 1, id) != 0) return error.SqliteExec;
        const rc = sqlite3_step(stmt.?);
        if (rc == SQLITE_DONE) return null;
        if (rc != SQLITE_ROW) return error.SqliteStep;
        const n: usize = @intCast(sqlite3_column_bytes(stmt.?, 0));
        const p = sqlite3_column_text(stmt.?, 0) orelse return error.SqliteStep;
        return try gpa.dupe(u8, p[0..n]);
    }
};
