import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

let db: Database.Database | null = null;

/** 打开（或创建）SQLite，按 DATABASE.md §2 建表。 */
export function openDb(path = process.env.ONLYSPACE_DB ?? resolve(import.meta.dirname, "../data/app.db")): Database.Database {
  mkdirSync(dirname(path), { recursive: true });
  db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");

  db.exec(`
    CREATE TABLE IF NOT EXISTS devices (
      device_id   TEXT PRIMARY KEY,
      person_id   TEXT NOT NULL,
      public_key  TEXT NOT NULL,
      status      TEXT NOT NULL DEFAULT 'active',
      last_seen   INTEGER,
      created_at  INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS messages (
      message_id       TEXT PRIMARY KEY,
      space_id         TEXT NOT NULL,
      sender_device_id TEXT NOT NULL,
      type             TEXT NOT NULL,
      key_version      INTEGER NOT NULL,
      nonce            TEXT NOT NULL,
      ciphertext       TEXT NOT NULL,
      server_sequence  INTEGER NOT NULL UNIQUE,
      created_at       INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_messages_seq ON messages (space_id, server_sequence);

    CREATE TABLE IF NOT EXISTS attachments (
      attachment_id TEXT PRIMARY KEY,
      message_id    TEXT NOT NULL REFERENCES messages(message_id),
      space_id      TEXT NOT NULL,
      key_version   INTEGER NOT NULL,
      size          INTEGER NOT NULL,
      sha256        TEXT NOT NULL,
      nonce         TEXT NOT NULL,
      storage_path  TEXT NOT NULL,
      created_at    INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_attachments_msg ON attachments (message_id);

    CREATE TABLE IF NOT EXISTS push_tokens (
      device_id  TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
      platform   TEXT NOT NULL,
      token      TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS challenges (
      challenge_id TEXT PRIMARY KEY,
      device_id    TEXT NOT NULL,
      challenge    TEXT NOT NULL,
      expires_at   INTEGER NOT NULL,
      used         INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS sessions (
      session_token TEXT PRIMARY KEY,
      device_id     TEXT NOT NULL,
      expires_at    INTEGER NOT NULL,
      created_at    INTEGER NOT NULL
    );
  `);
  return db;
}

export function getDb(): Database.Database {
  if (!db) throw new Error("db 未初始化，先调用 openDb()");
  return db;
}
