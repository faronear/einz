# Einz — 数据库设计（docs/DATABASE.md）

> **状态：** Draft v0.1（Phase 0 产出）
> **权威依据：** `aimemo/productLens.zhcn.md` §8.3（数据模型要点）、§7.4（客户端本地数据）
> **关联文档：** `docs/PROTOCOL.md`（API 与同步）、`docs/E2EE.md`（密文信封）

---

## 1. 总则

- 双端都用 SQLite：Server 用 `better-sqlite3`，客户端用 `drift`（Flutter/CLI 共用 `shared/` 中的 schema 定义）。
- **所有用户内容一律密文存储**：`ciphertext` / blob 字段，绝不出现明文。
- Server 端**无 `spaces` / `space_members` 表**：固定两人一空间由 `config.json` 表达（productLens §8.3）。
- 时间一律 Unix 毫秒（UTC）整数。
- ID 一律 UUIDv7（TEXT），不使用自增主键作为业务 ID。
- 迁移：版本化 migration 列表，只增不改（见 §5）。

---

## 2. Server SQLite（einz.sqlite.db）

```sql
-- 白名单设备（由 config.json 初始化，运行期可撤销）
CREATE TABLE devices (
    device_id   TEXT PRIMARY KEY,          -- UUIDv7
    person_id   TEXT NOT NULL,             -- "person-a" | "person-b"
    public_key  TEXT NOT NULL,             -- base64(X25519 公钥)
    status      TEXT NOT NULL DEFAULT 'active',  -- active | revoked
    last_seen   INTEGER,
    created_at  INTEGER NOT NULL
);

-- 消息（只存密文信封，见 E2EE.md §5）
CREATE TABLE messages (
    message_id       TEXT PRIMARY KEY,     -- UUIDv7（客户端生成，幂等键）
    space_id         TEXT NOT NULL,        -- 全系统唯一常量（config.json）
    sender_device_id TEXT NOT NULL,
    type             TEXT NOT NULL,        -- text|image|video|voice|system
    key_version      INTEGER NOT NULL,
    nonce            TEXT NOT NULL,        -- base64(24B)
    ciphertext       TEXT NOT NULL,        -- base64
    server_sequence  INTEGER NOT NULL UNIQUE,  -- per-space 单调递增，分配后不可变
    created_at       INTEGER NOT NULL
);

CREATE INDEX idx_messages_seq ON messages (space_id, server_sequence);

-- 附件元数据（blob 落盘于 /data/files/）
CREATE TABLE attachments (
    attachment_id TEXT PRIMARY KEY,        -- UUIDv7
    message_id    TEXT NOT NULL REFERENCES messages(message_id),
    space_id      TEXT NOT NULL,
    key_version   INTEGER NOT NULL,
    size          INTEGER NOT NULL,        -- 密文大小
    sha256        TEXT NOT NULL,           -- 密文哈希（base64）
    nonce         TEXT NOT NULL,           -- base64(24B)
    storage_path  TEXT NOT NULL,           -- files/xx/yy
    created_at    INTEGER NOT NULL
);

CREATE INDEX idx_attachments_msg ON attachments (message_id);

-- Push Token
CREATE TABLE push_tokens (
    device_id  TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
    platform   TEXT NOT NULL,              -- ios | android
    token      TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

-- 一次性挑战（防重放，5 分钟过期，清理任务定期删除）
CREATE TABLE challenges (
    challenge_id TEXT PRIMARY KEY,
    device_id    TEXT NOT NULL,
    challenge    TEXT NOT NULL,            -- 32B 随机（base64）
    expires_at   INTEGER NOT NULL,
    used         INTEGER NOT NULL DEFAULT 0
);

-- 会话令牌
CREATE TABLE sessions (
    session_token TEXT PRIMARY KEY,
    device_id     TEXT NOT NULL,
    expires_at    INTEGER NOT NULL,
    created_at    INTEGER NOT NULL
);
```

**说明：**

- `messages.server_sequence` 全局唯一（UNIQUE）：Server 分配即锁定，用于 `/sync?after=`。
- 附件必须先有 message（外键约束）。
- `challenges` / `sessions` 是短期数据：定期清理过期行（如每小时一次）。

---

## 3. Client SQLite（本地主库，Local-First）

客户端本地 SQLite 是**主存储**，结构与 Server 大体镜像，另加本地状态字段：

```sql
-- 消息（与 Server messages 同构 + 本地状态）
CREATE TABLE local_messages (
    message_id       TEXT PRIMARY KEY,
    space_id         TEXT NOT NULL,
    sender_device_id TEXT NOT NULL,
    type             TEXT NOT NULL,
    key_version      INTEGER NOT NULL,
    nonce            TEXT NOT NULL,
    ciphertext       TEXT NOT NULL,
    server_sequence  INTEGER,              -- NULL = 尚未同步（pending 或失败）
    created_at       INTEGER NOT NULL,
    status           TEXT NOT NULL DEFAULT 'pending',  -- pending|sent|delivered|read|failed
    local_created_at INTEGER NOT NULL
);

CREATE INDEX idx_local_messages_seq ON local_messages (server_sequence);

-- 附件元数据
CREATE TABLE local_attachments (
    attachment_id TEXT PRIMARY KEY,
    message_id    TEXT NOT NULL REFERENCES local_messages(message_id),
    key_version   INTEGER NOT NULL,
    size          INTEGER NOT NULL,
    sha256        TEXT NOT NULL,
    nonce         TEXT NOT NULL,
    local_path    TEXT,                    -- 解密缓存文件路径（App 私有目录，可清理）
    status        TEXT NOT NULL DEFAULT 'pending'  -- pending|uploaded|downloaded
);

-- 同步锚点（per-space 单调序列）
CREATE TABLE sync_state (
    space_id             TEXT PRIMARY KEY,
    last_server_sequence INTEGER NOT NULL DEFAULT 0
);

-- 草稿
CREATE TABLE drafts (
    message_id TEXT PRIMARY KEY,           -- 引用原消息（编辑场景）
    space_id   TEXT NOT NULL,
    content    TEXT NOT NULL,              -- 本地明文（仅存本机，不上传）
    updated_at INTEGER NOT NULL
);

-- 本地应用状态（设置等）
CREATE TABLE app_state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

**说明：**

- `status='pending'` 且 `server_sequence IS NULL` = 离线发送队列成员；收到 Server ACK 后写回 `server_sequence` 并置 `sent`。
- 同步：`last_server_sequence` 记录已落库的最大序号；`/sync?after=` 补缺。
- 明文（草稿）只存在于客户端本地库，**永不进入 Server**；若设备被攻破，本库可泄露已解密内容——这是设备信任模型的一部分（productLens §3.1）。

---

## 4. 客户端密钥存储（不在 SQLite）

密钥**不进 SQLite**，存入系统安全存储（Keychain / Keystore / flutter_secure_storage）：

```json
{
  "device": { "device_id": "…", "public_key": "…", "private_key": "…" },
  "space_keys": {
    "current":  { "key_version": 2, "key": "base64(32B)" },
    "archived": [ { "key_version": 1, "key": "base64(32B)" } ]
  }
}
```

- 身份私钥 + Space Key 明文只在此处；SQLite 中只存密文。
- 归档 Space Key 仅用于解密旧消息（E2EE.md §9.2）。

---

## 5. 迁移策略

- 双端各维护 `migrations/` 目录，按版本号递增（如 `0001_init.sql`、`0002_xxx.sql`）。
- 应用启动时执行未应用的迁移（记录 `schema_version` 表或 drift 内建机制），全部在事务内执行。
- **禁止修改已发布的历史迁移文件**；结构变更一律新增迁移。
- V1 阶段 Client/Server 一起发布，schema 变更不承诺跨版本兼容；但迁移脚本保证旧库可升级。

## 6. 备份（Server 侧）

- 备份 = `einz.sqlite.db`（用 SQLite 官方 Backup API，禁止直接复制正在写入的 db）+ `/data/files/` + config.json，产物加密归档到 `/data/backups/`（productLens §11.2）。
- 客户端备份见 E2EE.md §10（恢复码 + 加密导出，含本库与密钥归档）。
