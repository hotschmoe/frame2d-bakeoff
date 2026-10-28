//! SQLite model store for `/models` (SPEC 5.4). One serialized connection guarded by a mutex.
const std = @import("std");
const c = @import("sqlite_c");

pub const Store = struct {
    db: *c.sqlite3,
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    pub fn open(io: std.Io, path: [:0]const u8) !Store {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) return error.SqliteOpen;
        var s = Store{ .db = db.?, .io = io };
        try s.exec("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS models (id TEXT PRIMARY KEY, body TEXT NOT NULL);");
        return s;
    }

    fn bind(st: ?*c.sqlite3_stmt, i: c_int, text: []const u8) !void {
        if (c.sqlite3_bind_text(st, i, text.ptr, @intCast(text.len), c.SQLITE_STATIC) != c.SQLITE_OK) return error.SqliteBind;
    }

    fn exec(s: *Store, sql: [:0]const u8) !void {
        if (c.sqlite3_exec(s.db, sql.ptr, null, null, null) != c.SQLITE_OK) return error.SqliteExec;
    }

    pub fn put(s: *Store, id: []const u8, body: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(s.db, "INSERT OR REPLACE INTO models (id, body) VALUES (?1, ?2)", -1, &st, null) != c.SQLITE_OK) return error.SqlitePrepare;
        defer _ = c.sqlite3_finalize(st);
        try bind(st, 1, id);
        try bind(st, 2, body);
        if (c.sqlite3_step(st) != c.SQLITE_DONE) return error.SqliteStep;
    }

    /// Returns an owned copy of the stored body, or null.
    pub fn get(s: *Store, gpa: std.mem.Allocator, id: []const u8) !?[]u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var st: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(s.db, "SELECT body FROM models WHERE id = ?1", -1, &st, null) != c.SQLITE_OK) return error.SqlitePrepare;
        defer _ = c.sqlite3_finalize(st);
        try bind(st, 1, id);
        switch (c.sqlite3_step(st)) {
            c.SQLITE_ROW => {},
            c.SQLITE_DONE => return null,
            else => return error.SqliteStep,
        }
        // column_text is null on OOM (body is NOT NULL, so never for a real row)
        const p: [*]const u8 = @ptrCast(c.sqlite3_column_text(st, 0) orelse return error.SqliteNoMem);
        const n: usize = @intCast(c.sqlite3_column_bytes(st, 0));
        return try gpa.dupe(u8, p[0..n]);
    }
};
