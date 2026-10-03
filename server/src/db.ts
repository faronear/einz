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
    -- 登记项：一次「安装 × 秘境」的登记（一套密钥对 + 一个身份 + 一个会话锚点）。
    -- 命名提醒（docs/GLOSSARY.md）：entrance_id 是**登记项**的 id，不是物理设备 id；
    -- 物理设备/安装那一层是下面的 install_uid。
    CREATE TABLE IF NOT EXISTS entrances (
      entrance_id   TEXT PRIMARY KEY,
      member_id   TEXT NOT NULL,
      public_key  TEXT NOT NULL,
      status      TEXT NOT NULL DEFAULT 'active',
      entrance_name TEXT,
      last_seen   INTEGER,
      -- 最后一次 WS 断开的时刻（ms）——"这条通道什么时候下的线"。
      -- 与 last_seen 分工：last_seen 是"最后活动证据"（心跳/REST 都会刷，
      -- 断开时归零），offline_since 只在断开那一刻落一次、建连时清空。
      -- 显示层取 max(last_seen, offline_since) 当离线时刻（见 entrances.listEntrances）。
      offline_since INTEGER,
      created_at  INTEGER NOT NULL,
      -- 客户端生成的**安装级**标识（多空间）：同一台物理设备上每个空间一个
      -- entrance_id，但它们的 install_uid 相同 → 服务端据此知道"这几行是同一台设备"。
      -- 存量行/未升级客户端为 NULL。**绝不出现在任何响应体里**（服务端内部认知）。
      install_uid  TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_entrances_uid ON entrances (install_uid);

    CREATE TABLE IF NOT EXISTS messages (
      message_id       TEXT PRIMARY KEY,
      space_id         TEXT NOT NULL,
      sender_entrance_id TEXT NOT NULL,
      sender_member_id TEXT,
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
      entrance_id  TEXT PRIMARY KEY REFERENCES entrances(entrance_id) ON DELETE CASCADE,
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
      entrance_id    TEXT NOT NULL,
      space_id     TEXT,  -- 目标 Space（v1 收敛后必填；NULL 只可能是存量旧行）
      challenge    TEXT NOT NULL,
      expires_at   INTEGER NOT NULL,
      used         INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS sessions (
      session_token TEXT PRIMARY KEY,
      entrance_id     TEXT NOT NULL,
      space_id      TEXT,  -- 绑定 Space（v1 收敛后必填；NULL 只可能是存量旧行）
      expires_at    INTEGER NOT NULL,
      created_at    INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    -- Multiverse（v2）：多租户空间与一次性加入凭证（docs/PROTOCOL_MULTIVERSE.md §3）
    -- 刻意**没有** display_name：v1 曾把创建者名字快照在这里，但它是只写不读的死字段，
    -- 且创建者改名（POST /members/name）不会同步 → 会与真实名字冲突。
    -- 人的名字唯一数据源是 space_members.display_name（老板 2026-09-16）。
    CREATE TABLE IF NOT EXISTS spaces (
      space_id         TEXT PRIMARY KEY,
      space_address    TEXT NOT NULL UNIQUE,
      space_public_key TEXT NOT NULL UNIQUE,
      status           TEXT NOT NULL DEFAULT 'waiting',  -- waiting | active | archived
      created_at       INTEGER NOT NULL,
      updated_at       INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS space_members (
      space_id     TEXT NOT NULL REFERENCES spaces(space_id),
      -- member_id 是身份锚点（同一身份多通道共享）；伴侣（slot=1）
      -- 预置时尚未加入 → 为 NULL，由首个加入该 slot 的通道生成（老板定稿）
      member_id    TEXT,
      slot INTEGER NOT NULL,
      display_name TEXT,
      gender       TEXT,
      status       TEXT NOT NULL DEFAULT 'active',
      -- 伴侣预置行未加入 → joined_at 为 NULL，激活时写入
      joined_at    INTEGER,
      -- 邮件通知的目标地址（NOT NULL 约束没有：未设置用 NULL，不用空串）。
      -- 写进来 ≠ 可发信：必须先点验证链接（见 notify_emails.verified_at）。
      email        TEXT,
      PRIMARY KEY (space_id, member_id),
      UNIQUE (space_id, slot)
    );

    CREATE TABLE IF NOT EXISTS join_tokens (
      space_id          TEXT NOT NULL REFERENCES spaces(space_id),
      token_hash        TEXT PRIMARY KEY,
      created_by_entrance TEXT NOT NULL,
      expires_at        INTEGER NOT NULL,
      used_at           INTEGER,
      created_at        INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_join_tokens_space ON join_tokens (space_id, used_at);

    -- 消息回执（已送达/已读）单调高水位：按 (space, member) 一行。
    -- 语义：我的消息 seq=S 已送达 ⟺ 对方 delivered_upto_seq ≥ S；已读 ⟺ read_upto_seq ≥ S。
    -- 按 member 记 → "该 member 至少一条通道已收到/已读"（不保证所有通道）。
    -- 不变式：只前进；delivered_upto_seq ≥ read_upto_seq（读隐含送达）。
    CREATE TABLE IF NOT EXISTS receipts (
      space_id           TEXT NOT NULL,
      member_id          TEXT NOT NULL,
      delivered_upto_seq INTEGER NOT NULL DEFAULT 0,
      read_upto_seq      INTEGER NOT NULL DEFAULT 0,
      updated_at         INTEGER NOT NULL,
      PRIMARY KEY (space_id, member_id)
    );

    -- ── 邮件通知（2026-10-01）——──────────────────────────────────────────────
    -- 起因：没进应用商店 → 没有后台推送；离线期间的来信对方完全不知道（上线才知道）。
    -- 手段：给离线的对方发一封邮件，借邮件系统自带的推送能力把他拉回来。
    --
    -- 三条不可动摇的边界：
    -- ① **邮件里永远不会有正文**——服务端只有 ciphertext，"谁、几条、几点"是全部信息。
    --    这不是妥协：邮件会明文躺在对方邮箱里好几年，安全等级低于 App 内的密文。
    -- ② **邮箱按地址**（不是按 member）聚合：member_id 是按空间生成的（spaces.ts），
    --    同一个人在别的空间是另一行；同一个地址可能挂在多个 member 上。去重发信的
    --    粒度因此必须是"地址"（跨空间合并成一封摘要），而不是"人"。
    -- ③ **未验证不发**：有人把别人的地址填进来就成了骚扰通道，所以必须以点击验证链接为本钱的
    --    准入闸门（verified_at IS NULL → 一律不发）。
    CREATE TABLE IF NOT EXISTS notify_emails (
      email           TEXT PRIMARY KEY,  -- 规范化后的小写全址（跨空间的自然键）
      verified_at     INTEGER,           -- 点过验证链接的时刻；NULL = 未验证 → 不发
      unsubscribe_at  INTEGER,           -- 退订（每一封邮件底部都有一次性去重专用链接）
      hard_bounce_at  INTEGER,           -- 硬退信（地址不存在等永久失败）→ 永久停发
      pause_until     INTEGER,           -- 软失败（连不上 SMTP 等）后的退避截止时刻（ms）
      last_sent_at    INTEGER,           -- 冷却判定用
      sent_day        TEXT,              -- 'YYYY-MM-DD'（UTC 日界）：日上限的计数字段
      sent_count      INTEGER NOT NULL DEFAULT 0,
      -- 邮件正文语言（'zh' | 'en'）：服务端无从知道收件人读哪种语言，只能由客户端
      -- （它知道自己的界面语言）在 PUT /notify/email 时顺手报上来。默认 zh。
      lang            TEXT,
      -- 同一批未读已重提的次数（"同一批"= 最新未读消息没变，见 notifier.ts）。
      -- 收件人一直不读 → 提到 remind_max 次就停，不无限轰炸。
      remind_count    INTEGER NOT NULL DEFAULT 0,
      -- 上次发信时那批未读的最新时刻（ms）：与本轮未读的 newestAt 比对，判断是不是同一批。
      reminded_at     INTEGER,
      created_at      INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS notify_tokens (
      token      TEXT PRIMARY KEY,
      email      TEXT NOT NULL,
      kind       TEXT NOT NULL,  -- verify（24h 有效，一次性）| unsubscribe（长期有效，复用）
      expires_at INTEGER NOT NULL,
      used_at    INTEGER,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_notify_tokens_email ON notify_tokens (email, kind);

    -- ── 审计表（只追加，永久保留；供"谁在哪条通道上、什么时候做了什么"回溯）──
    -- 不参与业务语义：删除或清空不影响聊天功能（老板 2026-09-13 要求详尽留痕）。

    -- 连接事件流：WS 每次连上/断开各一行（可算在线时长、掉线次数、断线原因）
    CREATE TABLE IF NOT EXISTS connection_events (
      event_id     INTEGER PRIMARY KEY AUTOINCREMENT,
      entrance_id    TEXT NOT NULL,
      space_id     TEXT,                  -- 连接绑定的 Space（legacy 为空串）
      event        TEXT NOT NULL,         -- connect | disconnect | heartbeat_timeout
      at_ms        INTEGER NOT NULL,      -- 事件时刻（ms）
      duration_ms  INTEGER,               -- disconnect 时填本次在线时长
      close_code   INTEGER,               -- WS 关闭码（1006=异常断开等）
      close_reason TEXT,
      ip           TEXT,                  -- 来源 IP（Caddy 反代下取 x-forwarded-for）
      user_agent   TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_conn_events_entrance_at ON connection_events (entrance_id, at_ms);
    CREATE INDEX IF NOT EXISTS idx_conn_events_space_at  ON connection_events (space_id, at_ms);

    -- 通道活动明细：sync 拉取进度 / 回执上报 / 消息发送 / push token 变更 / 登记撤销…
    -- detail 为 JSON，字段按 kind 各异（见 docs/DATABASE.md §2.1）
    CREATE TABLE IF NOT EXISTS entrance_activity (
      activity_id INTEGER PRIMARY KEY AUTOINCREMENT,
      entrance_id   TEXT NOT NULL,
      space_id    TEXT,
      kind        TEXT NOT NULL,
      at_ms       INTEGER NOT NULL,
      detail      TEXT,
      ip          TEXT,
      user_agent  TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_dev_act_entrance_at ON entrance_activity (entrance_id, at_ms);
    CREATE INDEX IF NOT EXISTS idx_dev_act_kind_at   ON entrance_activity (kind, at_ms);
    CREATE INDEX IF NOT EXISTS idx_dev_act_space_at  ON entrance_activity (space_id, at_ms);
  `);

  // 迁移：messages 表补充 sender_member_id（存量库 ALTER；新库 CREATE 已含该列 → 报错忽略）
  try {
    db.exec(`ALTER TABLE messages ADD COLUMN sender_member_id TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：entrances 表补充 entrance_name（通道名称，显示层用）
  try {
    db.exec(`ALTER TABLE entrances ADD COLUMN entrance_name TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：entrances 表补充 install_uid（安装级标识；存量行留 NULL，由客户端补登）
  try {
    db.exec(`ALTER TABLE entrances ADD COLUMN install_uid TEXT`);
    db.exec(`CREATE INDEX IF NOT EXISTS idx_entrances_uid ON entrances (install_uid)`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：entrances 表补充 offline_since（最后断开时刻；App/CLI 显示"离线 since 时刻"用）
  try {
    db.exec(`ALTER TABLE entrances ADD COLUMN offline_since INTEGER`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：space_members 补 email（邮件通知的目标地址；未设置是 NULL，不用空串）
  try {
    db.exec(`ALTER TABLE space_members ADD COLUMN email TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：notify_emails 补 lang（邮件正文语言；存量行 NULL → 按 zh 处理）
  try {
    db.exec(`ALTER TABLE notify_emails ADD COLUMN lang TEXT`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：notify_emails 补 remind_count / reminded_at（同一批未读的计次封顶，防"永远不读 → 永远通知"）
  try {
    db.exec(`ALTER TABLE notify_emails ADD COLUMN remind_count INTEGER NOT NULL DEFAULT 0`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  try {
    db.exec(`ALTER TABLE notify_emails ADD COLUMN reminded_at INTEGER`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 一次性回填 offline_since：此刻**已经离线**的通道，它的断线时刻只存在于审计表
  // `connection_events.at_ms`（disconnect / heartbeat_timeout 各记一行），新列是空的。
  // 不回填的话，这些通道要等各自重连一次才显示得出时间。
  //
  // 这是**唯一**一次从审计表取业务值的地方（迁移期的一次性历史回填，不是长期读路径）——
  // 审计表"不参与业务语义"的原则（见本文件 §审计表注释）仍然成立：清空 connection_events
  // 只会让下一次启动的回填少捞到一些值，不影响聊天与显示。
  // 幂等：只填 offline_since IS NULL 的行，重跑即空操作。
  const backfilled = db
    .prepare(
      `UPDATE entrances SET offline_since = (
         SELECT e.at_ms FROM connection_events e
          WHERE e.entrance_id = entrances.entrance_id
            AND e.event IN ('disconnect', 'heartbeat_timeout')
          ORDER BY e.at_ms DESC LIMIT 1
       )
       WHERE offline_since IS NULL
         AND status = 'active'
         AND (last_seen IS NULL OR last_seen = 0)
         AND EXISTS (
           SELECT 1 FROM connection_events e
            WHERE e.entrance_id = entrances.entrance_id
              AND e.event IN ('disconnect', 'heartbeat_timeout')
         )`
    )
    .run().changes;
  if (backfilled > 0) {
    console.log(`[einz] 迁移：回填 ${backfilled} 条已离线通道的 offline_since（取自 connection_events）`);
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
  // 迁移：spaces 补 mode（群聊一期 2026-10-03）：'duo' | 'group'。
  // duo=二人私密空间（上限 2、通话可用）；group=多人群空间（上限 maxMembersPerSpace、
  // 通话禁用）。创建一律落 'duo'，伴侣入网后签发 invite token 自动升格 'group'
  // （单向不可逆）。存量空间回填 'duo' → 现存情侣空间天然是严格二人空间，零迁移成本。
  try {
    db.exec(`ALTER TABLE spaces ADD COLUMN mode TEXT NOT NULL DEFAULT 'duo'`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：join_tokens 补 purpose（群聊一期 2026-10-03）：'invite' | 'channel'。
  // invite=邀请新成员（新身份）；channel=发起人在新设备加通道（绑定发起人 slot）。
  // 存量 token 无法追溯签发意图 → 回填 'channel'（保守侧：channel 校验更严，
  // 必须带 slot 且等于发起人 slot，不会误开新身份）。
  try {
    db.exec(`ALTER TABLE join_tokens ADD COLUMN purpose TEXT NOT NULL DEFAULT 'channel'`);
  } catch {
    // 列已存在（新库）→ 忽略
  }
  // 迁移：join_tokens 补 issuer_member_id（channel token 绑定发起人身份）。
  // created_by_entrance 存的是角色字面量（"creator"/"member"），追溯不到签发者
  // member → channel token 的"仅发起人本人可在新设备加通道"校验需要本列。
  // 存量行为 NULL：其 channel 校验退化为"slot 行已有人即可"（无绑定可查）。
  try {
    db.exec(`ALTER TABLE join_tokens ADD COLUMN issuer_member_id TEXT`);
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
          sender_entrance_id TEXT NOT NULL,
          sender_member_id TEXT,
          type             TEXT NOT NULL,
          key_version      INTEGER NOT NULL,
          nonce            TEXT NOT NULL,
          ciphertext       TEXT NOT NULL,
          server_sequence  INTEGER NOT NULL,
          created_at       INTEGER NOT NULL,
          UNIQUE (space_id, server_sequence)
        );
        INSERT INTO messages_new SELECT message_id, space_id, sender_entrance_id, sender_member_id, type, key_version, nonce, ciphertext, server_sequence, created_at FROM messages;
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
  // v1 的邀请码登记（/invites、/entrances/enroll）与 meta 名称表（person_name:* /
  // person_gender:* / creator_person_id）已删除；名称的唯一数据源是
  // space_members.display_name。此语句对已迁移库是空操作。
  db.exec(`DROP TABLE IF EXISTS invites`);
  const droppedMeta = db
    .prepare(`DELETE FROM meta WHERE key = 'creator_person_id' OR key LIKE 'person_name:%' OR key LIKE 'person_gender:%'`)
    .run().changes;
  if (droppedMeta > 0) {
    console.log(`[einz] v1 收敛迁移：清掉 ${droppedMeta} 条 meta 名称/创建者键（名称改用 space_members.display_name）`);
  }

  // 迁移（2026-09-16）：删掉 spaces.display_name（创建者名字的冗余快照）。
  // 它是只写不读的死字段，且创建者改名不同步 → 会与 space_members.display_name
  // 冲突。sqlite 3.35+ 支持 DROP COLUMN；先查 pragma 保证幂等（已删过则跳过）。
  const spaceCols = db.prepare(`PRAGMA table_info(spaces)`).all() as { name: string }[];
  if (spaceCols.some((c) => c.name === "display_name")) {
    db.exec(`ALTER TABLE spaces DROP COLUMN display_name`);
    console.log(`[einz] 迁移：删除 spaces.display_name（人的名字唯一数据源是 space_members.display_name）`);
  }

  // 迁移：sessions.session_token 由明文改为 sha256 十六进制（2026-09-15 评审 H4）。
  // 存量明文行既无法反推出哈希（伪造一个哈希也没有意义——查库时是拿客户端明文
  // 现算哈希），也**不能**保留：注释见 auth.resolveSession。会话本就 24h TTL、
  // 客户端冷启动会用通道私钥自动重新 challenge-response，故直接清掉。
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
