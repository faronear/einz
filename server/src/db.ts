import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

let db: Database.Database | null = null;

// 用 fileURLToPath 兼容旧 Node（import.meta.dirname 需 Node 20.11+）
const HERE = dirname(fileURLToPath(import.meta.url));

/** 打开（或创建）SQLite，按 DATABASE.md §2 建表。 */
export function openDb(path = process.env.EINZ_DB ?? resolve(HERE, "../data/app.db")): Database.Database {
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
      device_name TEXT,
      last_seen   INTEGER,
      created_at  INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS messages (
      message_id       TEXT PRIMARY KEY,
      space_id         TEXT NOT NULL,
      sender_device_id TEXT NOT NULL,
      sender_person_id TEXT,
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
      message_id    TEXT NOT NULL,
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

    CREATE TABLE IF NOT EXISTS key_escrow (
      space_id   TEXT PRIMARY KEY,
      package    TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS challenges (
      challenge_id TEXT PRIMARY KEY,
      device_id    TEXT NOT NULL,
      challenge    TEXT NOT NULL,
      expires_at   INTEGER NOT NULL,
      used         INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS invites (
      invite_code TEXT PRIMARY KEY,
      person_id   TEXT NOT NULL,
      status      TEXT NOT NULL DEFAULT 'pending',  -- pending | used | expired
      created_at  INTEGER NOT NULL,
      expires_at  INTEGER NOT NULL,
      used_by     TEXT,
      used_at     INTEGER
    );

    CREATE TABLE IF NOT EXISTS sessions (
      session_token TEXT PRIMARY KEY,
      device_id     TEXT NOT NULL,
      expires_at    INTEGER NOT NULL,
      created_at    INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  `);

  // 迁移：messages 表补充 sender_person_id（存量库 ALTER；新库 CREATE 已含该列 → 报错忽略）
  try {
    db.exec(`ALTER TABLE messages ADD COLUMN sender_person_id TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：devices 表补充 device_name（设备名称，显示层用）
  try {
    db.exec(`ALTER TABLE devices ADD COLUMN device_name TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：attachments.message_id 去掉外键（两阶段上传：blob 可先于 message 存在，
  // PROTOCOL.md §6.1）。SQLite 无法 ALTER 删除外键，检测到旧 schema 则重建表。
  const attFks = db.pragma("foreign_key_list(attachments)") as unknown as Array<{ table: string }>;
  if (attFks.some((f) => f.table === "messages")) {
    db.pragma("foreign_keys = OFF");
    db.exec(`
      BEGIN;
      CREATE TABLE attachments_new (
        attachment_id TEXT PRIMARY KEY,
        message_id    TEXT NOT NULL,
        space_id      TEXT NOT NULL,
        key_version   INTEGER NOT NULL,
        size          INTEGER NOT NULL,
        sha256        TEXT NOT NULL,
        nonce         TEXT NOT NULL,
        storage_path  TEXT NOT NULL,
        created_at    INTEGER NOT NULL
      );
      INSERT INTO attachments_new SELECT attachment_id, message_id, space_id, key_version, size, sha256, nonce, storage_path, created_at FROM attachments;
      DROP TABLE attachments;
      ALTER TABLE attachments_new RENAME TO attachments;
      CREATE INDEX idx_attachments_msg ON attachments (message_id);
      COMMIT;
    `);
    db.pragma("foreign_keys = ON");
  }
  return db;
}

export function getDb(): Database.Database {
  if (!db) throw new Error("db 未初始化，先调用 openDb()");
  return db;
}

/** 读取 meta（key-value 配置，如 space_id）；不存在返回 null。 */
export function getMeta(key: string): string | null {
  const row = getDb()
    .prepare(`SELECT value FROM meta WHERE key = ?`)
    .get(key) as { value: string } | undefined;
  return row?.value ?? null;
}

/** 写入 meta（UPSERT）。 */
export function setMeta(key: string, value: string): void {
  getDb()
    .prepare(`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
    .run(key, value);
}
