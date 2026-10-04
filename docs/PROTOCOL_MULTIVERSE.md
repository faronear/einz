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
  member_id         TEXT NOT NULL,           -- 空间内 UUID
  slot      INTEGER NOT NULL,        -- 小整数槽位（UNIQUE(space_id, slot)）；
                                    -- 群聊一期（2026-10-03）开放为 N 槽：
                                    -- 新身份 join 分配最小空 slot，加通道复用已有行
  display_name      TEXT,
  gender            TEXT,
  status            TEXT NOT NULL DEFAULT 'active',
  joined_at         INTEGER NOT NULL,
  PRIMARY KEY (space_id, member_id)
)

spaces（群聊一期 2026-10-03 增列）
  mode  TEXT NOT NULL DEFAULT 'duo'  -- 'duo'=二人私密（上限 2、通话可用）；
                                     -- 'group'=群空间（上限 maxMembersPerSpace、通话禁用）
                                     -- 缺省 'duo'；**创建时选定，之后永不 UPDATE**
                                     -- **创建时选定、之后永不 UPDATE**（无升格）

join_tokens（群聊一期 2026-10-03 增列）
  purpose           TEXT NOT NULL DEFAULT 'channel',
                    -- 'invite'=开新身份；'attach'=进已有身份（旧值 'channel' 归一成它）
  issuer_member_id  TEXT,            -- 签发者身份（preflight 报"谁发的"；attach 存量兜底）
  target_member_id  TEXT,            -- attach 要进入的身份（== issuer 自己换设备；
                    --   == 别人 = 帮对方找回身份）；NULL = 退回 issuer
                                     -- 存量行为 NULL，退化按"slot 已有人"放行）
  created_by_entrance TEXT NOT NULL, -- 角色字面量（"creator"/"member"，非通道 id）
  token_hash        TEXT PRIMARY KEY,
  space_id          TEXT NOT NULL REFERENCES spaces(space_id),
  expires_at        INTEGER NOT NULL,
  used_at           INTEGER,                 -- NULL=未用
  created_at        INTEGER NOT NULL

entrances（v1 表增加空间归属）
  entrance_id         TEXT PRIMARY KEY,        -- UUIDv4（或保留 v1 现有 id 迁移）
  space_id          TEXT NOT NULL REFERENCES spaces(space_id),
  member_id         TEXT NOT NULL,
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
  只返回服务健康、协议版本、能力（不再返回全局 member 名称表）。
  响应示例：{ "status": "ok", "protocol_version": "v2-multiverse",
              "version": "<server 版本>", "uptime_sec": 123,
              "capabilities": [...] }
  **可选字段（2026-10-04，强制升级闸）**：配了才出现——
    · `min_app_version`：服务端支持的**最低 App 版本**，格式 `yymm.ddhh.mm`
      （UTC，与 App 打包注入的 CFBundleShortVersionString 同一个串）；
      客户端启动时核对，低于它 → 首屏弹**不可关闭**的升级窗口。
    · `app_download_url`：升级窗口里「下载新版本」按钮的 URL。
  两个字段都非密、无元数据风险（不含任何空间/成员信息）。空串 = 没配（不下发）。
  与 `protocol_version` 的分工：后者是 wire 兼容闸（服务端硬拒，REST 400 / WS 4400），
  前者是**产品级**闸（协议也许还能用，但某版本有缺陷/不可靠时，改配置即可把旧客户端
  挡在门外，不必改代码）。客户端实现见 `app/lib/widgets/version_gate.dart`。

POST /spaces
  创建 Space（首条通道自举，无 token）。
  请求：{ spaceAddress, spacePublicKey, creatorPublicKey, sealedSpaceKey,
          memberName?, customId?, mode? }
  （群聊一期 2026-10-03：peer_name/peer_gender 已删（v3）——create 不预置
    伴侣，partner 加入时自填名字。
    2026-10-04：新增 `mode`（'duo' 缺省 | 'group'）——**创建时选定、永不改变**
    （取消升格）；非法值一律回退 'duo'）
  响应：201 { spaceId, spaceAddress, joinToken }   ← 返回首个 join token
    （purpose='invite'——"邀请伴侣"链接；含链接）
  错误：DEVICE_ALREADY_BOUND / ADDRESS_TAKEN / INVALID_ADDRESS / SPACE_LIMIT_REACHED
       （SPACE_LIMIT_REACHED：现有空间数 ≥ serverConfig.json 的 maxSpaces，409）

GET /spaces/lookup?address=... | ?custom_id=...
  精确查找，只返回最小公开信息：
  { spaceId, status, memberCount }   （1/2 状态；无空间名——2026-09-16 起）
  不返回成员姓名、性别、消息数量、通道信息。

POST /spaces/join/preflight
  轻量校验 token（不消费），返回空间公开信息 + 分流向导用字段：
  响应：{ spaceId, status, mode, memberCount, purpose, inviterName, targetName,
          targetIsIssuer, slots }
  （mode='duo'|'group'；purpose='invite'|'attach'——客户端据此走"新成员自填名"
    或"进已有身份"向导，不再有身份选择页；inviterName 是**签发者本人**的名字
    （按 issuer_member_id 查，查不到才退回"第一个有名字的成员"）；
    targetName = attach 要进入的身份的显示名（invite 恒 null）；
    targetIsIssuer = 目标是签发者自己（true="我换设备"，false="别人帮我找回"））

POST /spaces/join
  用 join token 完成加入（群聊一期 2026-10-03，v3：slot 显式语义）。
  请求：{ token, publicKey, entranceName?, installUid?,
          memberName?, memberGender? }    // invite 新成员自填（attach 不带）
  slot 语义：
  - invite token：不带 slot（服务端分配最小空 slot、生成新 member_id）；
    带 slot → 400
  - attach token：**不需要**带 slot——服务端按 token 的 target_member_id 自动
    解析那个身份的槽位；客户端显式带 slot 且不一致 → 403（防错用）
  响应：200 { spaceId, memberId, slot, sessionToken, entranceId, spaceAddress,
              isNewMember }
    isNewMember=true 仅当这次 join **新建了身份**（false = 已有成员加通道）——
    服务端据此决定是否广播 member.joined；

  错误：TOKEN_INVALID / TOKEN_EXPIRED / TOKEN_USED / DEVICE_ALREADY_BOUND /
       ENTRANCE_LIMIT_REACHED（通道数上限，409）/
       SPACE_FULL（group 成员数达 maxMembersPerSpace，409）/
       DUO_FULL（duo 已满 2 人——双人秘境不许第三个身份，409）
```

### 4.2 成员端点（加入后/创建者）

```text
POST /spaces/{spaceId}/join-tokens
  现有成员生成一次性开通码（join token，可刷新/撤销）。
  请求：{ purpose: 'invite' | 'attach', target_member_id?, passphrase? }
  （**必填语义**——两种码语义相反，漏传会让"邀请伴侣"变成"把自己身份送出去"，
    故客户端必须显式传；服务端把未知值归一成 'attach'）
  - invite：邀请新成员（新身份）。**仅 group 空间可签发**——duo 已满 2 人时
    409 DUO_FULL（双人秘境不会有第三个人）；签发无任何空间级副作用。
  - attach：进**已有身份**——token 记 target_member_id：
    · 缺省 / == 签发者 → 我在另一台设备接入（会话即所有权，不要口令）
    · == 别的成员 → 帮对方找回身份（他丢了设备）——**路由层校验共享口令**
      （与撤销别人通道同档）；目标必须是本空间成员，否则 400
  → 201 { joinToken, link: "https://<host>/join/<token>", expiresAt }
  错误：NOT_A_MEMBER / DUO_FULL（duo 满 2 人签 invite，409）/ INVALID_REQUEST（400：
       invite 带 target、attach 无目标、目标不属于本空间）/ ESCROW_VERIFY_FAILED（401：
       attach 指向他人但口令错）/ PASSPHRASE_NOT_SET（409：未托管口令）

DELETE /spaces/{spaceId}/join-tokens/{tokenHash}
  撤销未用 token（创建者补救手段）。

POST /spaces/{spaceId}/key-escrow   （沿用 v1 escrow 语义，按空间隔离）
  口令托管密封包读写；加入方验证口令后取回 Space Key 密封包。
```

## 5. 加入流程（join）API 序列

对应 App 向导（2026-10-03/04 起按 purpose 分流，身份选择页已删）：

```text
① 输入 token/粘贴链接/扫码        → POST /spaces/join/preflight
     前置校验：TOKEN_INVALID/EXPIRED/USED 在此拦截（fail fast，不消费 token）；
     返回 purpose/inviterName/targetName/targetIsIssuer/mode/memberCount 供确认页展示
② 身份分支（按 preflight 的 purpose）：
   - invite（新成员）：填写自己的名字/性别
   - attach（进已有身份）：无此步——身份由 token 的 target 决定，服务端自动解析
     （文案：targetIsIssuer=true = 「我在另一台设备接入」；false = 「XX 帮你找回
     身份（<targetName>）」——丢了设备的人靠这条回来）
③ 口令 escrow 取 Space Key        → POST /spaces/{spaceId}/key-escrow
     （提交口令，解开创建者托管的口令密封包，返回 space_key 密封内容）
④ join 提交                       → POST /spaces/join（真正消费 token）
     服务端事务：锁 Space 行 → 校验 purpose×slot → 标记 used →
     invite 分配最小空 slot/新 member_id；attach 复用 target 的 slot/member_id；
     新身份时按创建时定死的 mode 查上限（duo 恒 2 / group 看 maxMembersPerSpace）
⑤ 设置 PIN                       → 本机操作（AppLock），无服务端调用
→ 进入 ChatPage
```

实现说明：
- App 实现为一次 `POST /spaces/join` 合并提交（token + 名字/性别）；协议层
  字段都是可选组，服务端在 ④ 时做事务提交。
- create（首条通道）流程：创建者名字 → 设口令（escrow）→ PIN，无 token；
  create 回传的首张 join token purpose='invite'（"邀请伴侣"链接）；
  duo 满 2 人后签不出 invite，但 attach 永远可用——这是"伴侣丢了设备"的归路。

## 6. 错误码（Multiverse 加入相关）

| 错误码 | 含义 | HTTP |
| ------ | ---- | ---- |
| `TOKEN_INVALID` | token 格式错误或不存在（hash 不匹配） | 400 |
| `TOKEN_EXPIRED` | token 已超过 expires_at | 410 |
| `TOKEN_USED` | token 已被消费（一次性） | 410 |
| `SPACE_LIMIT_REACHED` | 空间数量已达上限（serverConfig.json 的 maxSpaces；与"成员/通道数"无关） | 409 |
| `ENTRANCE_LIMIT_REACHED` | 该空间的通道（登记项）数量已达上限（serverConfig.json 的 maxEntrancesPerSpace；**计数含已撤销**——销毁不退额度，防反复开通/销毁刷量） | 409 |
| `SPACE_FULL` | group 空间成员（身份）数已达上限（serverConfig.json 的 maxMembersPerSpace；同身份多通道不重复计数） | 409 |
| `DUO_FULL` | duo 空间已满 2 人（双人秘境不允许第三个身份；签发 invite 与 join 两处都会落到此码） | 409 |

| `SPACE_NOT_FOUND` | 空间不存在/已归档 | 404 |
| `NOT_A_MEMBER` | 当前 session 不是该 Space 成员 | 403 |
| `DEVICE_ALREADY_BOUND` | 该通道已绑定一个 Space，拒绝再创建/加入 | 409 |
| `ADDRESS_TAKEN` | space_address 冲突（碰撞），需重新生成 Identity Key | 409 |
| `INVALID_ADDRESS` | EIP-55 校验失败或格式错误 | 400 |
| `ESCROW_VERIFY_FAILED` | 口令 escrow 验证失败（口令错误；取包与撤销通道共用） | 401 |
| `ESCROW_RATE_LIMITED` | 口令尝试过多（按 space 计失败次数，滑窗内超限） | 429 |
| `PASSPHRASE_NOT_SET` | 该空间未托管共享口令，无法做二次校验（撤销通道要求先设置口令） | 409 |
| `ENTRANCE_REVOKED` | 本通道已被明确撤销（`/auth/challenge`、会话校验）：客户端应清空本地数据后重新入网 | 403 |
| `FORBIDDEN` | 通道未登记（含服务端库被清空/重置）：客户端**只应警告**，不得清空本地数据 | 403 |

## 7. 安全要求与待定项

- token 只存 hash；lookup/join 有频率限制；custom_id 精确匹配、保留字过滤、
  长度限制、抢注限制。
- 满员检查必须事务化（锁 Space 行），并发加入只能一个成功。
- 已绑 Space 的通道再创建/加入一律 `DEVICE_ALREADY_BOUND`（一台客户端
  只属于一个 Space）。
- join token 与口令的分工明确：token 管"能否加入"，口令管"能否解 Space Key"；
  两者都不应被地址替代（地址只定位）。
- 已定（2026-09-10 老板拍板）：token 默认 TTL = 24 小时；第一版**不做创建者
  确认（模型 B）**，`join_requests` 暂不建表（将来需要时再补）；口令 escrow
  MVP 保持空间级口令（不做分通道密封包）。

