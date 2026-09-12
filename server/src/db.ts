import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

let db: Database.Database | null = null;

// 用 fileURLToPath 兼容旧 Node（import.meta.dirname 需 Node 20.11+）
const HERE = dirname(fileURLToPath(import.meta.url));

/** 打开（或创建）SQLite，按 DATABASE.md §2 建表。 */
export function openDb(path = process.env.EINZ_DB ?? resolve(HERE, "../data/einz.sqlite.db")): Database.Database {
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
      server_sequence  INTEGER NOT NULL,
      created_at       INTEGER NOT NULL,
      UNIQUE (space_id, server_sequence)  -- Multiverse：序号按 Space 独立递增
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
      space_id        TEXT PRIMARY KEY,
      package         TEXT NOT NULL,
      passphrase_hash TEXT,
      updated_at      INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS challenges (
      challenge_id TEXT PRIMARY KEY,
      device_id    TEXT NOT NULL,
      space_id     TEXT,  -- Multiverse：目标 Space（NULL=legacy v1 认证）
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
      space_id      TEXT,  -- Multiverse：绑定 Space（NULL=legacy v1 会话）
      expires_at    INTEGER NOT NULL,
      created_at    INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    -- Multiverse（v2）：多租户空间与一次性加入凭证（docs/PROTOCOL_MULTIVERSE.md §3）
    CREATE TABLE IF NOT EXISTS spaces (
      space_id         TEXT PRIMARY KEY,
      space_address    TEXT NOT NULL UNIQUE,
      space_public_key TEXT NOT NULL UNIQUE,
      display_name     TEXT,
      status           TEXT NOT NULL DEFAULT 'waiting',  -- waiting | active | archived
      created_at       INTEGER NOT NULL,
      updated_at       INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS space_members (
      space_id     TEXT NOT NULL REFERENCES spaces(space_id),
      -- person_id 是身份锚点（同一身份多设备共享）；伴侣（partner_slot=1）
      -- 预置时尚未加入 → 为 NULL，由首个加入该 slot 的设备生成（老板定稿）
      person_id    TEXT,
      partner_slot INTEGER NOT NULL,
      display_name TEXT,
      gender       TEXT,
      status       TEXT NOT NULL DEFAULT 'active',
      -- 伴侣预置行未加入 → joined_at 为 NULL，激活时写入
      joined_at    INTEGER,
      PRIMARY KEY (space_id, person_id),
      UNIQUE (space_id, partner_slot)
    );

    CREATE TABLE IF NOT EXISTS join_tokens (
      space_id          TEXT NOT NULL REFERENCES spaces(space_id),
      token_hash        TEXT PRIMARY KEY,
      created_by_device TEXT NOT NULL,
      expires_at        INTEGER NOT NULL,
      used_at           INTEGER,
      created_at        INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_join_tokens_space ON join_tokens (space_id, used_at);

    -- 消息回执（已送达/已读）单调高水位：按 (space, person) 一行。
    -- 语义：我的消息 seq=S 已送达 ⟺ 对方 delivered_upto_seq ≥ S；已读 ⟺ read_upto_seq ≥ S。
    -- 按 person 记 → "该 person 至少一台设备已收到/已读"（不保证所有设备）。
    -- 不变式：只前进；delivered_upto_seq ≥ read_upto_seq（读隐含送达）。
    CREATE TABLE IF NOT EXISTS receipts (
      space_id           TEXT NOT NULL,
      person_id          TEXT NOT NULL,
      delivered_upto_seq INTEGER NOT NULL DEFAULT 0,
      read_upto_seq      INTEGER NOT NULL DEFAULT 0,
      updated_at         INTEGER NOT NULL,
      PRIMARY KEY (space_id, person_id)
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
  // 迁移：key_escrow 表补充 passphrase_hash（口令哈希，恢复接口验证用；存量库 ALTER）
  try {
    db.exec(`ALTER TABLE key_escrow ADD COLUMN passphrase_hash TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：sessions/challenges 补 space_id（Multiverse：session 绑定 Space；存量库 ALTER）
  try {
    db.exec(`ALTER TABLE sessions ADD COLUMN space_id TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  try {
    db.exec(`ALTER TABLE challenges ADD COLUMN space_id TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：messages.server_sequence 由全局 UNIQUE 改为 (space_id, server_sequence)
  // 复合唯一（Multiverse：序号按 Space 独立递增，PROTOCOL_MULTIVERSE.md §3.6）。
  // SQLite 无法 ALTER 删除 UNIQUE，检测到旧的"单列 server_sequence 唯一自动索引"
  // 则重建表（重建后的复合唯一不满足该检测，不会循环重建）。
  {
    const indexes = db.pragma("index_list(messages)") as unknown as Array<{ name: string; unique: number }>;
    // 用 for 循环而非回调：回调内引用模块级 `db` 会丢非 null 推断（TS18047）
    let hasOldSeqUnique = false;
    for (const i of indexes) {
      if (!i.name.startsWith("sqlite_autoindex_messages_") || i.unique !== 1) continue;
      const cols = db.pragma(`index_info(${JSON.stringify(i.name)})`) as unknown as Array<{ name: string }>;
      if (cols.length === 1 && cols[0].name === "server_sequence") {
        hasOldSeqUnique = true;
        break;
      }
    }
    if (hasOldSeqUnique) {
      db.pragma("foreign_keys = OFF");
      db.exec(`
        BEGIN;
        CREATE TABLE messages_new (
          message_id       TEXT PRIMARY KEY,
          space_id         TEXT NOT NULL,
          sender_device_id TEXT NOT NULL,
          sender_person_id TEXT,
          type             TEXT NOT NULL,
          key_version      INTEGER NOT NULL,
          nonce            TEXT NOT NULL,
          ciphertext       TEXT NOT NULL,
          server_sequence  INTEGER NOT NULL,
          created_at       INTEGER NOT NULL,
          UNIQUE (space_id, server_sequence)
        );
        INSERT INTO messages_new SELECT message_id, space_id, sender_device_id, sender_person_id, type, key_version, nonce, ciphertext, server_sequence, created_at FROM messages;
        DROP TABLE messages;
        ALTER TABLE messages_new RENAME TO messages;
        CREATE INDEX idx_messages_seq ON messages (space_id, server_sequence);
        COMMIT;
      `);
      db.pragma("foreign_keys = ON");
    }
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
  // Multiverse：schema version 标记（首次启动写入 2，后续保持；供能力探测与迁移）
  db.prepare(`INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '2')`).run();
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
