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
      space_id     TEXT,  -- 目标 Space（v1 收敛后必填；NULL 只可能是存量旧行）
      challenge    TEXT NOT NULL,
      expires_at   INTEGER NOT NULL,
      used         INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS sessions (
      session_token TEXT PRIMARY KEY,
      device_id     TEXT NOT NULL,
      space_id      TEXT,  -- 绑定 Space（v1 收敛后必填；NULL 只可能是存量旧行）
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

    -- ── 审计表（只追加，永久保留；供"谁在哪台设备上、什么时候做了什么"回溯）──
    -- 不参与业务语义：删除或清空不影响聊天功能（老板 2026-09-13 要求详尽留痕）。

    -- 连接事件流：WS 每次连上/断开各一行（可算在线时长、掉线次数、断线原因）
    CREATE TABLE IF NOT EXISTS connection_events (
      event_id     INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id    TEXT NOT NULL,
      space_id     TEXT,                  -- 连接绑定的 Space（legacy 为空串）
      event        TEXT NOT NULL,         -- connect | disconnect | heartbeat_timeout
      at_ms        INTEGER NOT NULL,      -- 事件时刻（ms）
      duration_ms  INTEGER,               -- disconnect 时填本次在线时长
      close_code   INTEGER,               -- WS 关闭码（1006=异常断开等）
      close_reason TEXT,
      ip           TEXT,                  -- 来源 IP（Caddy 反代下取 x-forwarded-for）
      user_agent   TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_conn_events_device_at ON connection_events (device_id, at_ms);
    CREATE INDEX IF NOT EXISTS idx_conn_events_space_at  ON connection_events (space_id, at_ms);

    -- 设备活动明细：sync 拉取进度 / 回执上报 / 消息发送 / push token 变更 / 登记撤销…
    -- detail 为 JSON，字段按 kind 各异（见 docs/DATABASE.md §2.1）
    CREATE TABLE IF NOT EXISTS device_activity (
      activity_id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id   TEXT NOT NULL,
      space_id    TEXT,
      kind        TEXT NOT NULL,
      at_ms       INTEGER NOT NULL,
      detail      TEXT,
      ip          TEXT,
      user_agent  TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_dev_act_device_at ON device_activity (device_id, at_ms);
    CREATE INDEX IF NOT EXISTS idx_dev_act_kind_at   ON device_activity (kind, at_ms);
    CREATE INDEX IF NOT EXISTS idx_dev_act_space_at  ON device_activity (space_id, at_ms);
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

  // 迁移（2026-09-15 v1 收敛）：drop invites 表 + 清 meta 里的 v1 名称/创建者键。
  // v1 的邀请码登记（/invites、/devices/enroll）与 meta 名称表（person_name:* /
  // person_gender:* / creator_person_id）已删除；名称的唯一数据源是
  // space_members.display_name。此语句对已迁移库是空操作。
  db.exec(`DROP TABLE IF EXISTS invites`);
  const droppedMeta = db
    .prepare(`DELETE FROM meta WHERE key = 'creator_person_id' OR key LIKE 'person_name:%' OR key LIKE 'person_gender:%'`)
    .run().changes;
  if (droppedMeta > 0) {
    console.log(`[einz] v1 收敛迁移：清掉 ${droppedMeta} 条 meta 名称/创建者键（名称改用 space_members.display_name）`);
  }

  // 迁移：sessions.session_token 由明文改为 sha256 十六进制（2026-09-15 评审 H4）。
  // 存量明文行既无法反推出哈希（伪造一个哈希也没有意义——查库时是拿客户端明文
  // 现算哈希），也**不能**保留：注释见 auth.resolveSession。会话本就 24h TTL、
  // 客户端冷启动会用设备私钥自动重新 challenge-response，故直接清掉。
  // 判定：sha256 十六进制 = 64 位 [0-9a-f]。此语句对已迁移库是空操作。
  const droppedSessions = db
    .prepare(`DELETE FROM sessions WHERE length(session_token) != 64 OR session_token GLOB '*[^0-9a-f]*'`)
    .run().changes;
  if (droppedSessions > 0) {
    console.log(`[einz] 会话存储迁移：清掉 ${droppedSessions} 条明文 session（客户端会自动重新认证）`);
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
