//! Model store on SQLite (amalgamation compiled by build.zig). Hand-written extern bindings for the few
//! functions needed. The connection runs in serialized threading mode, so it can be shared by threads.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Db = opaque {};
const Stmt = opaque {};

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Db, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close(db: *Db) c_int;
extern fn sqlite3_exec(db: *Db, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: *Db, sql: [*]const u8, n: c_int, stmt: *?*Stmt, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_step(stmt: *Stmt) c_int;
extern fn sqlite3_finalize(stmt: *Stmt) c_int;
extern fn sqlite3_bind_blob(stmt: *Stmt, idx: c_int, data: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_bind_int64(stmt: *Stmt, idx: c_int, v: i64) c_int;
extern fn sqlite3_column_blob(stmt: *Stmt, col: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *Stmt, col: c_int) c_int;
extern fn sqlite3_last_insert_rowid(db: *Db) i64;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const OPEN_READWRITE_CREATE_FULLMUTEX = 0x00000002 | 0x00000004 | 0x00010000;
/// SQLITE_TRANSIENT: sqlite copies the bound data immediately.
const transient: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub const Store = struct {
    db: *Db,

    pub const Error = error{Sqlite} || Allocator.Error;

    /// `path` must be NUL terminated; use ":memory:" for a throwaway store.
    pub fn open(path: [:0]const u8) Error!Store {
        var db: ?*Db = null;
        if (sqlite3_open_v2(path.ptr, &db, OPEN_READWRITE_CREATE_FULLMUTEX, null) != SQLITE_OK) {
            if (db) |d| _ = sqlite3_close(d);
            return error.Sqlite;
        }
        const s = Store{ .db = db.? };
        if (sqlite3_exec(s.db, "CREATE TABLE IF NOT EXISTS models(id INTEGER PRIMARY KEY AUTOINCREMENT, body BLOB NOT NULL)", null, null, null) != SQLITE_OK)
            return error.Sqlite;
        return s;
    }

    pub fn close(self: Store) void {
        _ = sqlite3_close(self.db);
    }

    fn prepare(self: Store, sql: []const u8) Error!*Stmt {
        var st: ?*Stmt = null;
        if (sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &st, null) != SQLITE_OK) return error.Sqlite;
        return st.?;
    }

    /// Stores a model document and returns its id.
    pub fn put(self: Store, body: []const u8) Error!i64 {
        const st = try self.prepare("INSERT INTO models(body) VALUES(?1)");
        defer _ = sqlite3_finalize(st);
        if (sqlite3_bind_blob(st, 1, body.ptr, @intCast(body.len), transient) != SQLITE_OK) return error.Sqlite;
        if (sqlite3_step(st) != SQLITE_DONE) return error.Sqlite;
        return sqlite3_last_insert_rowid(self.db);
    }

    /// Returns a copy of the stored document (caller frees), or null when the id is unknown.
    pub fn get(self: Store, gpa: Allocator, id: i64) Error!?[]u8 {
        const st = try self.prepare("SELECT body FROM models WHERE id = ?1");
        defer _ = sqlite3_finalize(st);
        if (sqlite3_bind_int64(st, 1, id) != SQLITE_OK) return error.Sqlite;
        switch (sqlite3_step(st)) {
            SQLITE_ROW => {
                const n: usize = @intCast(sqlite3_column_bytes(st, 0));
                const out = try gpa.alloc(u8, n);
                if (n > 0) @memcpy(out, sqlite3_column_blob(st, 0).?[0..n]);
                return out;
            },
            SQLITE_DONE => return null,
            else => return error.Sqlite,
        }
    }
};
