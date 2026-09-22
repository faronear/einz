# Einz 协议 Multiverse（多租户 Space 加入授权）

> 状态：`[已实现]`（空间创建/加入/成员鉴权/空间隔离已在服务端与双端落地；
> 2026-09-15 起 `/spaces/{id}/join-tokens` 与 `/spaces/{id}/key-escrow` 上传分支
> **要求该空间成员会话**——本节 §4.2 的"成员端点 / NOT_A_MEMBER"即此约定；
> 实现里错误码统一用服务端全局惯例的 `FORBIDDEN`/`UNAUTHORIZED`）
>
> 配套：`aimemo/upgradeToMultiverse.md`（总体架构升级计划）、本文聚焦**加入授权闭环**
> （含 join token、Space 定位、密钥分发、错误码），是 Multiverse 多租户的第一阶段协议。
>
> v1 单空间协议保持不变，标为 `v1-single-space`；本文标为 `v2-multiverse`。

## 1. 背景与目标

Multiverse 的目标是让一个 Server 承载多个 Space（每个 Space 始终最多两人），客户端
仍只绑定一个 Space（不需要空间列表/切换器）。本文只覆盖**加入授权**这个
最小闭环，其余（消息同步租户隔离、附件分目录、推送隔离等）见
`aimemo/upgradeToMultiverse.md` Phase U1/U2。

本文定稿的授权模型（与老板 2026-09-10 推敲确认）：

```text
加入 = Server 层门禁（一次性 join token）+ 密码学层（口令 escrow 解 Space Key）
        + 空间确认（展示名称/1-2 状态）+ 身份登记（名字/性别）+ PIN（本机）
```

- 加入授权与密钥分发分离：token 决定"能否加入该 Space"，口令 escrow 决定
  "能否解开 Space Key"（口令为空间级、两人共用，沿用 v1 机制）。
- 地址（`space_address`）只是**定位符**，不是授权凭证；用户感知的"分享链接"
  里实际内嵌一次性 token（体验等价于"地址即邀请"，机制上保留可撤销/过期/补救）。

## 2. 核心概念

| 概念 | 格式 | 用途 | 是否授权 |
| ---- | ---- | ---- | -------- |
| `space_id` | UUIDv4 | Server 内部主键 | 否 |
| `space_address` | `0x` + 40 hex（EIP-55 checksum），Keccak-256 派生 | 分享/二维码/精确查找（定位符） | 否（仅定位） |
| `join_token` | `e1_` + base58url(32B CSPRNG) | 一次性加入授权 | 是（单次、短时效） |
| `space_key` | 随机 32B 对称密钥 | 消息/附件内容加密（经 escrow 口令分发） | 密码学层 |
| `escrow_passphrase` | 空间级口令（创建时设定，两人共用） | 解开 key_escrow 密封包取 Space Key | 密码学层 |

### 2.1 join token 格式与生命周期

- 字符串格式：`e1_<base58url(32 bytes random)>`，示例
  `e1_9TbL3nzXkQvWpYhRjMfDgUcVsBqAoNiPeIuLwHsZaKc`.
- Server 只保存 `token_hash = SHA-256(token)`，不保存明文；数据库泄露不能
  反推 token。
- 一次性：消费（加入成功）后标记 `used_at`，再次使用返回 `TOKEN_USED`。
- 时效：默认 24 小时（产品可配 `joinTokenTtl`），过期返回 `TOKEN_EXPIRED`；
  创建者可刷新（旧 token 作废、发新 token）或撤销。
- 消费为**事务**：锁定 Space 行 → 校验 token 未用未过期 → 校验成员数 < 2 →
  标记 used → 插入第二个 member。并发两次加入只有一个成功
  （SQLite 需 WAL + busy_timeout）。

### 2.2 深链与 App 内输入

- 分享链接（二维码内码即此链接或纯 token）：`https://<host>/join/<token>`——
  host 由服务端按请求真实地址生成（Host + x-forwarded-proto），本地/自建服务器时
  与实际访问地址一致（如 `http://localhost:3000/join/<token>`），不硬编码（2026-09-11）；
- App 加入页输入框**同时接受**完整链接与纯 token（App 解析出 token 部分）；
  另有扫码入口（复用现有 mobile_scanner）。
- 系统深链（`einz://join/<token>` / universal link）列为上架后增强，MVP 不做。

## 3. 数据表（相对 v1 的新增/改动）

```sql
spaces (
  space_id          TEXT PRIMARY KEY,        -- UUIDv4
  space_address     TEXT NOT NULL UNIQUE,    -- EIP-55 地址，仅定位
  space_public_key  TEXT NOT NULL UNIQUE,    -- Space Identity 公钥（地址派生根）
  status            TEXT NOT NULL DEFAULT 'waiting',  -- waiting|active|archived
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
)
-- 注（2026-09-16）：原 display_name 列已删除——它只是创建者名字的冗余快照
-- （只写不读，且创建者改名后不同步）。人的名字唯一数据源是 space_members.display_name。

space_members (
  space_id          TEXT NOT NULL REFERENCES spaces(space_id),
  person_id         TEXT NOT NULL,           -- 空间内 UUID
  partner_slot      INTEGER NOT NULL,        -- 0/1，UNIQUE(space_id, partner_slot)
  display_name      TEXT,
  gender            TEXT,
  status            TEXT NOT NULL DEFAULT 'active',
  joined_at         INTEGER NOT NULL,
  PRIMARY KEY (space_id, person_id)
)

join_tokens (
  space_id          TEXT NOT NULL REFERENCES spaces(space_id),
  token_hash        TEXT PRIMARY KEY,
  created_by_device TEXT NOT NULL,
  expires_at        INTEGER NOT NULL,
  used_at           INTEGER,                 -- NULL=未用
  created_at        INTEGER NOT NULL
)

devices（v1 表增加空间归属）
  device_id         TEXT PRIMARY KEY,        -- UUIDv4（或保留 v1 现有 id 迁移）
  space_id          TEXT NOT NULL REFERENCES spaces(space_id),
  person_id         TEXT NOT NULL,
  public_key        TEXT NOT NULL UNIQUE,
  status            TEXT NOT NULL DEFAULT 'active',
  UNIQUE (space_id, public_key)
```

沿用 v1 且不动的表：`messages`、`attachments`（已有 space_id）、`key_escrow`
（按 space_id 存口令密封包）、`sessions`/`challenges`/`push_tokens`（v1
Phase U1 再补 space 归属，加入闭环第一阶段先不依赖）。

索引：`spaces.space_address`（UNIQUE）、`join_tokens.token_hash`（PK）、
`join_tokens(space_id, used_at)`、`messages(space_id, server_sequence)`。

## 4. API（Multiverse 加入授权相关端点）

路径为草案建议，最终以版本化协议为准。除 lookup 外均需认证（`Authorization:
Bearer <session_token>`），且鉴权上下文一律取自 session 的 `space_id`，
不接受请求体里客户端自报的 `space_id` 越权。

### 4.1 公共端点

```text
GET /health
  只返回服务健康、协议版本、能力（不再返回全局 person 名称表）。
  响应示例：{ "ok": true, "protocolVersion": "v2-multiverse", "capabilities": [...] }

POST /spaces
  创建 Space（首设备自举，无 token）。
  请求：{ spaceAddress, spacePublicKey, creatorPublicKey, sealedSpaceKey,
          personName?, partnerName?, customId? }   // personName=第一人名字（2026-09-16 由 displayName 改名）
  响应：201 { spaceId, spaceAddress, joinToken }   ← 返回首个 join token（含链接）
  错误：DEVICE_ALREADY_BOUND / ADDRESS_TAKEN / INVALID_ADDRESS

GET /spaces/lookup?address=... | ?custom_id=...
  精确查找，只返回最小公开信息：
  { spaceId, status, memberCount }   （1/2 状态；无空间名——2026-09-16 起）
  不返回成员姓名、性别、消息数量、设备信息。

POST /spaces/join
  用 join token 完成加入（第 3 步身份登记 + 取钥可在此前后拆分，见 §5）。
  请求：{ token, publicKey, deviceName?, partnerSlot?, gender? }
  （无名字字段：身份名取自 create 时为该 slot 预置的名字——2026-09-16）
  响应：200 { spaceId, personId, partnerSlot, sessionToken }
  错误：TOKEN_INVALID / TOKEN_EXPIRED / TOKEN_USED / SPACE_FULL / DEVICE_ALREADY_BOUND
```

### 4.2 成员端点（加入后/创建者）

```text
POST /spaces/{spaceId}/join-tokens
  现有成员生成一次性令牌（join token，可刷新/撤销）。
  请求：{ }  →  201 { joinToken, link: "https://<host>/join/<token>", expiresAt }
  错误：NOT_A_MEMBER / SPACE_FULL（满员后不再生成）

DELETE /spaces/{spaceId}/join-tokens/{tokenHash}
  撤销未用 token（创建者补救手段）。

POST /spaces/{spaceId}/key-escrow   （沿用 v1 escrow 语义，按空间隔离）
  口令托管密封包读写；加入方验证口令后取回 Space Key 密封包。
```

## 5. 加入流程（join）API 序列

对应 App 向导五步（与老板 2026-09-10 确认的顺序）：

```text
① 输入 token/粘贴链接/扫码        → POST /spaces/join（带 token，未带身份）
     前置校验：TOKEN_INVALID/EXPIRED/USED/SPACE_FULL 在此拦截（fail fast）
② 空间确认                        → GET /spaces/lookup?address=...（或 join 响应
     携带的 spaceId/名称/状态）
③ 身份登记（名字/性别）           → POST /spaces/join（补 identity 字段，
     服务端事务：锁 Space 行 → 校验 token → 校验成员数 → 标记 used →
     插入第二个 member）
④ 口令 escrow 取 Space Key        → POST /spaces/{spaceId}/key-escrow/verify
     （提交口令，解开创建者托管的口令密封包，返回 space_key 密封内容）
⑤ 设置 PIN                       → 本机操作（AppLock），无服务端调用
→ 进入 ChatPage
```

实现说明：
- ① 与 ③ 可以合并为一次 `POST /spaces/join`（请求同时带 token + 身份），
  也可以拆两次（先验 token、后提交身份）——取决于 App 是否想先展示空间确认
  再让用户填身份；协议层两个字段都是可选组，服务端在 ③ 时做事务提交。
- ① 的 fail-fast 校验要求服务端能按 token 查出 Space 状态且不消费 token
  （新增轻量 `POST /spaces/join/preflight` 或复用 lookup 语义）。
- create（首设备）流程不变：身份 → 设口令（escrow）→ PIN，无 token。

## 6. 错误码（Multiverse 加入相关）

| 错误码 | 含义 | HTTP |
| ------ | ---- | ---- |
| `TOKEN_INVALID` | token 格式错误或不存在（hash 不匹配） | 400 |
| `TOKEN_EXPIRED` | token 已超过 expires_at | 410 |
| `TOKEN_USED` | token 已被消费（一次性） | 410 |
| `SPACE_FULL` | Space 已有 2 人，第三人不接受 | 409 |
| `SPACE_NOT_FOUND` | 空间不存在/已归档 | 404 |
| `NOT_A_MEMBER` | 当前 session 不是该 Space 成员 | 403 |
| `DEVICE_ALREADY_BOUND` | 该设备已绑定一个 Space，拒绝再创建/加入 | 409 |
| `ADDRESS_TAKEN` | space_address 冲突（碰撞），需重新生成 Identity Key | 409 |
| `INVALID_ADDRESS` | EIP-55 校验失败或格式错误 | 400 |
| `ESCROW_VERIFY_FAILED` | 口令 escrow 验证失败（口令错误；取包与撤销设备共用） | 401 |
| `ESCROW_RATE_LIMITED` | 口令尝试过多（按 space 计失败次数，滑窗内超限） | 429 |
| `PASSPHRASE_NOT_SET` | 该空间未托管共享口令，无法做二次校验（撤销设备要求先设置口令） | 409 |
| `DEVICE_REVOKED` | 本设备已被明确撤销（`/auth/challenge`、会话校验）：客户端应清空本地数据后重新入网 | 403 |
| `FORBIDDEN` | 设备未登记（含服务端库被清空/重置）：客户端**只应警告**，不得清空本地数据 | 403 |

## 7. 安全要求与待定项

- token 只存 hash；lookup/join 有频率限制；custom_id 精确匹配、保留字过滤、
  长度限制、抢注限制。
- 满员检查必须事务化（锁 Space 行），并发加入只能一个成功。
- 已绑 Space 的设备再创建/加入一律 `DEVICE_ALREADY_BOUND`（一台客户端
  只属于一个 Space）。
- join token 与口令的分工明确：token 管"能否加入"，口令管"能否解 Space Key"；
  两者都不应被地址替代（地址只定位）。
- 已定（2026-09-10 老板拍板）：token 默认 TTL = 24 小时；第一版**不做创建者
  确认（模型 B）**，`join_requests` 暂不建表（将来需要时再补）；口令 escrow
  MVP 保持空间级口令（不做分设备密封包）。

