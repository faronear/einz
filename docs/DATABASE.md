# Einz — 数据库设计（docs/DATABASE.md）

> **状态：** Draft v0.1（Phase 0 产出）
> **权威依据：** `aimemo/productLens.zhcn.md` §8.3（数据模型要点）、§7.4（客户端本地数据）
> **关联文档：** `docs/PROTOCOL.md`（API 与同步）、`docs/E2EE.md`（密文信封）、
> **`docs/GLOSSARY.md`（术语：物理设备 / 安装 / 登记项 三层怎么分，先读它）**

---

## 1. 总则

- 双端都用 SQLite：Server 用 `better-sqlite3`，客户端用 `drift`（Flutter/CLI 共用 `shared/` 中的 schema 定义）。
- **所有用户内容一律密文存储**：`ciphertext` / blob 字段，绝不出现明文。
- **多空间（Multiverse）**：Server 端有 `spaces` / `space_members` / `join_tokens` 表——一个
  Server 可承载多个互不可见的双人空间，成员与身份锚点都在库里（`config.json` 只留
  `maxSpaces` 这类运维开关）。所有按 space 隔离的读写都必须带 space 过滤（见 `guard.ts`）。
- **会话必须绑定 space**（2026-09-15 v1 收敛后）：不再存在"无 space 会话"这种形态。
- 时间一律 Unix 毫秒（UTC）整数。
- ID 一律 UUIDv7（TEXT），不使用自增主键作为业务 ID。
- 迁移：版本化 migration 列表，只增不改（见 §5）。

---

## 2. Server SQLite（einz.sqlite.db）

```sql
-- 设备（v2：由 POST /spaces / POST /spaces/join 登记；表本身是全局表，
-- 归属空间靠 devices.person_id → space_members 推导）
CREATE TABLE devices (
    device_id   TEXT PRIMARY KEY,          -- UUIDv7（服务端生成）
    person_id   TEXT NOT NULL,             -- 空间内身份 UUID（v2；见 space_members.person_id）
    public_key  TEXT NOT NULL,             -- base64(X25519 公钥)
    status      TEXT NOT NULL DEFAULT 'active',  -- active | revoked
    device_name TEXT,                      -- 设备显示名（TUI/App 可改）
    last_seen   INTEGER,                   -- 只由 WS 连接/心跳/断开维护
    created_at  INTEGER NOT NULL,
    device_uid  TEXT                       -- 安装级设备标识（客户端生成；同一物理设备各空间同名）
                                           -- 存量行/未升级客户端为 NULL，由 POST /devices/uid 补登。
                                           -- **只做服务端内部认知**（运维/审计/将来"整机退役"），
                                           -- 不参与授权或破坏性操作范围判断，**绝不进任何响应体**。
);

-- 空间（Multiverse；space_address 由 space_public_key 经 Keccak-256 + EIP-55 派生）
-- 注（2026-09-16）：原 display_name 列已删除（创建者名字的冗余快照，只写不读且改名不同步）
CREATE TABLE spaces (
    space_id         TEXT PRIMARY KEY,
    space_address    TEXT NOT NULL UNIQUE,
    space_public_key TEXT NOT NULL UNIQUE,
    status           TEXT NOT NULL DEFAULT 'waiting',  -- waiting | active | archived
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL
);

-- 空间成员（两个身份槽位：0=创建者/第一人，1=伴侣/第二人。
-- person_id 是身份锚点，同一身份多设备共享；伴侣预置行 person_id 为 NULL 直到加入）
-- 名称的唯一数据源就是这里的 display_name（v1 的 meta person_name:* 已删除）
CREATE TABLE space_members (
    space_id     TEXT NOT NULL REFERENCES spaces(space_id),
    person_id    TEXT,
    partner_slot INTEGER NOT NULL,
    display_name TEXT,
    gender       TEXT,                     -- male | female
    status       TEXT NOT NULL DEFAULT 'active',  -- active | pending
    joined_at    INTEGER,
    PRIMARY KEY (space_id, person_id),
    UNIQUE (space_id, partner_slot)
);

-- 一次性加入凭证（邀请链接里的 token；**只存 SHA-256 hash**，24h 过期、用后作废）
CREATE TABLE join_tokens (
    space_id          TEXT NOT NULL REFERENCES spaces(space_id),
    token_hash        TEXT PRIMARY KEY,
    created_by_device TEXT NOT NULL,
    expires_at        INTEGER NOT NULL,
    used_at           INTEGER,
    created_at        INTEGER NOT NULL
);
CREATE INDEX idx_join_tokens_space ON join_tokens (space_id, used_at);

-- 口令托管包（Server 只存密文，不解析；按 space 一份，UPSERT 最新者胜）
CREATE TABLE key_escrow (
    space_id        TEXT PRIMARY KEY,
    package         TEXT NOT NULL,         -- JSON：{format,salt,nonce,ciphertext}
    passphrase_hash TEXT,                  -- argon2id（crypt_pwhash_str，自含盐）
    updated_at      INTEGER NOT NULL
);

-- 消息（只存密文信封，见 E2EE.md §5）
CREATE TABLE messages (
    message_id       TEXT PRIMARY KEY,     -- UUIDv7（客户端生成，幂等键）
    space_id         TEXT NOT NULL,
    sender_device_id TEXT NOT NULL,
    sender_person_id TEXT,
    type             TEXT NOT NULL,        -- text|image|video|voice|audio|file|system
    key_version      INTEGER NOT NULL,
    nonce            TEXT NOT NULL,        -- base64(24B)
    ciphertext       TEXT NOT NULL,        -- base64
    server_sequence  INTEGER NOT NULL,     -- 按 Space 独立递增；UNIQUE(space_id, server_sequence)
    created_at       INTEGER NOT NULL,
    UNIQUE (space_id, server_sequence)     -- Multiverse：序号按 Space 独立（不是全局）
);

CREATE INDEX idx_messages_seq ON messages (space_id, server_sequence);

-- 附件元数据（blob 落盘于 /data/files/<space_id>/<前两位>/<attachment_id>；
--   2026-09-23 起按空间分片——per-space 备份/销毁/用量统计都靠它。
--   读路径取本行的 storage_path，故分片前的旧行（<前两位>/<id>）照常可读，无需迁移）
-- 注：message_id **没有**外键约束——两阶段上传（先传 blob 后发消息，PROTOCOL.md §6.1）
CREATE TABLE attachments (
    attachment_id TEXT PRIMARY KEY,        -- UUIDv7
    message_id    TEXT NOT NULL,
    space_id      TEXT NOT NULL,
    key_version   INTEGER NOT NULL,
    size          INTEGER NOT NULL,        -- 密文大小
    sha256        TEXT NOT NULL,           -- 密文哈希（base64）
    nonce         TEXT NOT NULL,           -- base64(24B)
    storage_path  TEXT NOT NULL,           -- <前两位>/<attachment_id>
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
-- space_id 必填（v1 收敛后）：签出的会话绑定该空间
CREATE TABLE challenges (
    challenge_id TEXT PRIMARY KEY,
    device_id    TEXT NOT NULL,
    space_id     TEXT,
    challenge    TEXT NOT NULL,            -- 32B 随机（base64）
    expires_at   INTEGER NOT NULL,
    used         INTEGER NOT NULL DEFAULT 0
);

-- 会话令牌（**只存 sha256(token)**，明文只回给客户端；2026-09-15 评审 H4）
-- 同一设备同一 space 同时只有一个会话（重新认证即清旧行）
CREATE TABLE sessions (
    session_token TEXT PRIMARY KEY,        -- sha256 十六进制
    device_id     TEXT NOT NULL,
    space_id      TEXT,                    -- 会话绑定的空间（新会话必填）
    expires_at    INTEGER NOT NULL,
    created_at    INTEGER NOT NULL
);

-- 消息回执（已送达/已读）单调高水位，按 (space, person) 一行（PROTOCOL.md §5.4）
CREATE TABLE receipts (
    space_id           TEXT NOT NULL,
    person_id          TEXT NOT NULL,
    delivered_upto_seq INTEGER NOT NULL DEFAULT 0,
    read_upto_seq      INTEGER NOT NULL DEFAULT 0,
    updated_at         INTEGER NOT NULL,
    PRIMARY KEY (space_id, person_id)
);

-- 键值（目前只用于 schema_version 标记；v1 的 person_name:* / person_gender:*/
-- creator_person_id 已随 v1 收敛删除，启动迁移会清掉存量行）
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

### 2.1 审计表（只追加，永久保留）

业务表只保存"当前状态"（`devices.last_seen` 会被覆盖、`receipts` 是 person 级
高水位），无法回答"谁在哪台设备上、什么时候做了什么"。以下两张表专为此补上历史，
**只追加、不更新、不删除**，且**不参与业务语义**——清空它们不影响聊天功能。

```sql
-- 连接事件流：WS 每次连上/断开各一行（可算在线时长、掉线次数、断线原因）
CREATE TABLE connection_events (
    event_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id    TEXT NOT NULL,
    space_id     TEXT,                  -- 连接绑定的 Space（legacy 为空串）
    event        TEXT NOT NULL,         -- connect | disconnect | heartbeat_timeout
    at_ms        INTEGER NOT NULL,      -- 事件时刻（ms）
    duration_ms  INTEGER,               -- disconnect/timeout 时填本次在线时长
    close_code   INTEGER,               -- WS 关闭码（1000 正常、1006 异常、4408 被顶掉）
    close_reason TEXT,
    ip           TEXT,                  -- x-forwarded-for 链首（Caddy 反代）→ socket 地址
    user_agent   TEXT
);

-- 设备活动明细：sync 拉取进度 / 回执上报 / 消息发送 / push token 变更 / 登记撤销…
CREATE TABLE device_activity (
    activity_id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id   TEXT NOT NULL,
    space_id    TEXT,
    kind        TEXT NOT NULL,
    at_ms       INTEGER NOT NULL,
    detail      TEXT,                   -- JSON，字段按 kind 各异（见下表）
    ip          TEXT,
    user_agent  TEXT
);
```

`device_activity.kind` 一览：

| kind              | 触发点                    | detail 主要字段                                                              |
| ----------------- | ------------------------- | ---------------------------------------------------------------------------- |
| `auth.login`      | `POST /auth/verify`       | `expires_in`                                                                 |
| `message.post`    | `POST /messages`          | `message_id`、`server_sequence`、`type`（**发送**证据，设备级）              |
| `sync`            | `GET /sync`               | `after_sequence`、`last_sequence`、`received`、`has_more`（**接收**证据）      |
| `receipt`         | `POST /receipts`          | `reported_delivered`、`reported_read`、`delivered_upto_seq`、`read_upto_seq` |
| `push.register`   | `POST /push/register`     | `platform`、`token_prefix`（**只落前 8 位**，不落完整推送凭证）              |
| `push.unregister` | `DELETE /push/register`   | —                                                                            |
| `device.rename`   | `POST /devices/name`      | `device_name`                                                                |
| `person.rename`   | `POST /devices/person-name` | `person_name`                                                              |
| `device.revoke`   | `POST /devices/:id/revoke` | `target_device_id`（**不记口令**）                                          |
| `device.retire`   | `POST /devices/retire`     | —（自助退役，目标即自己，无需 detail）                                      |

**说明：**

- `sync` **只在 `last_sequence` 前进时记**（=真正拉到新消息）。没新结果的例行
  轮询不产生记录——轮询频率是 App WS 在线 30s / 离线 3s 起退避到 60s、TUI 固定
  30s，全量记录绝大部分行都是重复值。设备"还在不在"由 `connection_events` 与
  `devices.last_seen` 负责。
- 回执语义**未改**：`receipts` 表仍是 person 级 HWM（"该 person 至少一台设备
  已读"），`device_activity.receipt` 只是额外记下"是哪台设备上报的"。
- 红线：审计表只记元数据，**绝不含密文 / nonce / 明文 / 完整 push token**
  （`test/audit.test.ts` 有断言守着）。
- 查询：`npm run audit -- devices | timeline <device_id> | online <space_id> [天] |
  activity [n] | receipts | search <device_id>`。

**业务表说明：**

- `messages.server_sequence` 全局唯一（UNIQUE）：Server 分配即锁定，用于 `/sync?after=`。
- 附件必须先有 message（外键约束）。
- `challenges` / `sessions` 是短期数据：定期清理过期行（如每小时一次）。
- `receipts` 只前进：上报用 `MAX()` upsert（回退值被忽略），且
  `delivered_upto_seq ≥ read_upto_seq`（读隐含送达），并夹紧到本 space 真实
  `MAX(server_sequence)`。按 person 记 = "该 person 至少一台设备已收到/已读"。

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
    -- **出站流水线**语义：
    --   pending = 还没确认（离线队列 / 在途 / 响应丢失）→ 由 sync 幂等补发自动收敛
    --   sent    = 服务端已收下（拿到 server_sequence）
    --   failed  = **服务端明确拒绝**（4xx：信封不合法 / 未授权 / 设备被撤销）→ 需用户点按重发
    --   注：网络异常、连接/响应超时、5xx **不**标 failed，保持 pending 自动重试；
    --       只有服务端明确拒绝才 failed（老板 2026-09-13 定）
    -- 注意：sync() 会把**入站**（对方）消息写成 'delivered'——那是历史遗留的
    --   "我收到了"标记，与"对方收到了我的消息"无关；真正的送达/已读回执不在这
    --   张表里，见下方 peer_receipts 与服务端 receipts（PROTOCOL.md §5.4）。
    status           TEXT NOT NULL DEFAULT 'pending',
    local_created_at INTEGER NOT NULL
);

CREATE INDEX idx_local_messages_seq ON local_messages (server_sequence);

-- 阅后即焚 / 本地墓碑（后续版本增列）：burn_after_seconds、expires_at、
--   burn_manual、deleted_at
-- 语义（老板 2026-09-13 明确）：**删除/焚毁只是"在本设备隐藏正文"**——打
--   `deleted_at` 本地墓碑、行与信封保留，不通知服务端、也不改变消息在服务器与
--   对方那里的路径。因此：
--   · 尚未确认（pending）的墓碑消息**仍会继续补发**，气泡里的状态小标照旧显示
--     且可点按重发（删除不阻断在途路径）；
--   · 焚毁时长是本机策略（收到消息时按本机设置决定），不随消息传到对方。

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

-- 对方回执（已送达/已读）单调高水位（App v6 起；本协议只落库，UI 暂不展示）
CREATE TABLE peer_receipts (
    space_id           TEXT NOT NULL,
    person_id          TEXT NOT NULL,      -- 对方身份锚点（同人多设备共享一行）
    delivered_upto_seq INTEGER NOT NULL DEFAULT 0,
    read_upto_seq      INTEGER NOT NULL DEFAULT 0,
    updated_at         INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (space_id, person_id)
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
  "space_key": { "key_version": 1, "key": "base64(32B)" }
}
```

- 身份私钥 + Space Key 明文只在此处；SQLite 中只存密文。
- **一个 Space 一把 Space Key**（`key_version` 恒为 1）：轮换不做，故无归档密钥层
  （2026-09-14 决策与撤除清单见 `SECURITY.md` §3；`key_version` 字段本身保留在信封/AAD 里）。

### 4.1 安全存储的生存周期（平台差异，老板 2026-09-14 决策）

安全存储条目**不随 App 卸载消失**（iOS/macOS Keychain、Linux libsecret），而 drift 库会。
两条防线（实现见 `app/lib/data/secure_store.dart`、`app/lib/data/app_lock.dart`）：

- **无障碍级别用 `..._this_device`**：iOS/macOS 默认的 `unlocked` 条目会被**加密备份 /
  换机恢复**带到新设备（用户换机还原备份即可读旧消息）；`first_unlock_this_device`
  变体不迁移。`synchronizable=false`（不走 iCloud Keychain 同步）是库默认值，保持。
- **卸载即重置**：drift `app_state` 的 `app_lock.install_id` 记录本次安装的随机标记。
  启动时（`AppLockService.ensureFreshInstall()`，**在读取锁包之前**）若标记缺失
  = 沙盒被清过 = 全新安装 → 清空 `einz.secure.` 下本 App 的条目，再落新标记。
  iOS"卸载 App（保留数据）"与整机/iCloud 备份恢复都会把沙盒带回来（标记仍在）→ 不误清。
  后果：重装 = 重新接入（与"设了 PIN"的用户行为一致——其加密锁包在 drift，本来就随卸载
  消失）；"跳过 PIN"用户此前靠 Keychain 里的明文包被直接拖进聊天，现已消除。

---

## 5. 迁移策略

- 双端各维护 `migrations/` 目录，按版本号递增（如 `0001_init.sql`、`0002_xxx.sql`）。
- 应用启动时执行未应用的迁移（记录 `schema_version` 表或 drift 内建机制），全部在事务内执行。
- **禁止修改已发布的历史迁移文件**；结构变更一律新增迁移。
- V1 阶段 Client/Server 一起发布，schema 变更不承诺跨版本兼容；但迁移脚本保证旧库可升级。

## 6. 备份（Server 侧）

- 备份 = `einz.sqlite.db`（用 SQLite 官方 Backup API，禁止直接复制正在写入的 db）+ `/data/files/`，产物加密归档到 `/data/backups/`（productLens §11.2）。v1 的静态白名单 `config.json` 已删（设备与空间都在库里），备份里不再有该条目。
- **单空间备份**（`npm run backup -- --space <id>`，2026-09-23）：只导出该空间的行 + `/data/files/<space_id>/`，恢复时只覆盖该空间，别的空间与库文件不动；不含审计表。详见 DEPLOYMENT.md §5.1。
- 客户端备份见 E2EE.md §10（恢复码 + 加密导出，含本库与密钥归档）。
