//! SQLite persistence for stored models.

use std::sync::{Mutex, MutexGuard};

use rusqlite::{params, Connection, OptionalExtension};

pub struct Store {
    conn: Mutex<Connection>,
}

impl Store {
    pub fn open(path: &str) -> rusqlite::Result<Store> {
        let conn = Connection::open(path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS models (
                 id   TEXT PRIMARY KEY,
                 body BLOB NOT NULL
             );",
        )?;
        Ok(Store { conn: Mutex::new(conn) })
    }

    /// The connection stays usable after a panic in another request: SQLite state is not affected by it.
    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Stores the model JSON exactly as received; returns its new id.
    pub fn insert(&self, body: &[u8]) -> rusqlite::Result<String> {
        let conn = self.conn();
        conn.query_row(
            "INSERT INTO models (id, body) VALUES (lower(hex(randomblob(8))), ?1) RETURNING id",
            params![body],
            |row| row.get(0),
        )
    }

    pub fn get(&self, id: &str) -> rusqlite::Result<Option<Vec<u8>>> {
        let conn = self.conn();
        conn.query_row("SELECT body FROM models WHERE id = ?1", params![id], |row| row.get(0)).optional()
    }
}
