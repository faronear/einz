# Einz — 通信协议（docs/PROTOCOL.md）

> **状态：** Draft v0.1（Phase 0 产出）
> **权威性：** 本文档是 REST + WebSocket 协议的**唯一权威定义**；Client 与 Server 必须按本文档实现，任何不一致以本文档为准。
> **关联文档：** `docs/E2EE.md`（密文信封与密钥）、`docs/DATABASE.md`（存储）、`aimemo/productLens.zhcn.md` §9（同步）、§13.3（时间）。
> **术语：** `entrance_id` 是"**登记项**"（安装 × 秘境）的 id，不是物理设备 id——见 `docs/GLOSSARY.md`。

---

## 1. 传输与版本

- 生产环境强制 HTTPS / WSS（Caddy 终结 TLS），禁止 HTTP / WS。
- 所有请求/帧携带 `X-Protocol-Version: 1`（或 WS 握手 query `?pv=1`）；版本不匹配 → `400 PROTOCOL_VERSION_MISMATCH`。
- 服务端与客户端必须校验对方版本；V1 阶段两端同时升级，不做多版本兼容矩阵。
  - **实现状态（2026-09-15 补）**：REST 由 `app.ts` 的 `assertProtocolVersion` 硬校验；
    `shared/lib/src/protocol/api_client.dart` 在所有请求上带该头（`ApiClient.protocolVersionHeader`）；
    WS 握手校验 `?pv=1`（不匹配关闭 4400）。
  - **豁免**：`GET /health`（外部监控 / curl 健康检查）与 `GET /join/:token`
    （浏览器打开的邀请落地页，无法自定义请求头）。

## 2. 通用约定

| 项 | 约定 |
| --- | --- |
| 时间 | 一律 Unix 毫秒（UTC），如 `1787900000000`；展示时客户端转本地 |
| ID | UUIDv7（消息、附件、空间、通道）；不使用 SQLite 自增作为跨端 ID |
| 二进制 | base64（无填充）编码后传输 |
| 鉴权 | `Authorization: Bearer <session_token>`（§3） |
| 请求体/响应体 | JSON（UTF-8） |
| 同步顺序 | `server_sequence`（per-space 单调递增，§5） |

## 3. 认证（challenge-response）

### POST /auth/challenge

```json
// 请求
{ "entrance_id": "dev-a1", "space_id": "…" }

// 响应 200
{
  "challenge_id": "uuidv7",
  "sealed_challenge": "base64(seal(challenge, 通道公钥))",
  "expires_in": 300
}
```

- challenge = 32 随机字节；Server 记录 `{challenge_id → challenge, entrance_id, space_id, 过期 5min, 一次性}`。
- **`space_id` 必填**（2026-09-15 v1 收敛后）：Multiverse 下所有数据按 space 隔离，会话必须绑定
  一个 space；缺省 → `400 INVALID_REQUEST`。v1 时代允许不带（签出"无 space 会话"），
  那类会话什么也访问不了，所以直接拒绝而不是让下游各自兜底。
- **仅 entrances 表内在册（且未撤销）的通道可发起**（E2EE.md §7.3、§8）。拒绝时**两种 code
  必须区分**（2026-09-16）：
  - 通道行存在但 `status='revoked'` → `403 ENTRANCE_REVOKED`（客户端据此清空本地数据）；
  - entrances 表**没有这一行**（库被清空/重置、从未登记）→ `403 FORBIDDEN`
    （客户端**只应警告**，绝不清空本地数据——运维失误不该导致客户端抹数据）。

### POST /auth/verify

```json
// 请求
{ "challenge_id": "…", "challenge_plaintext": "base64(解封后的 challenge)" }

// 响应 200
{ "session_token": "base64(32B)", "space_id": "…", "expires_in": 86400 }
```

- 校验：challenge_id 有效且未使用 → 明文与记录值一致 → 签发 session_token。
- challenge 一次性使用，成功后立即作废；失败 3 次该 challenge 失效。

## 4. REST API 一览

| 方法 | 路径 | 用途 | 鉴权 |
| --- | --- | --- | --- |
| POST | /auth/challenge | 获取密封 challenge（`entrance_id` + `space_id`） | 通道公钥 |
| POST | /auth/verify | 提交明文换取 session | challenge |
| POST | /messages | 上传新消息密文 | Bearer |
| GET | /sync?after=<seq>&limit=<n> | 增量拉取（§5） | Bearer |
| POST | /attachments | 上传附件 blob（分片可选） | Bearer |
| GET | /attachments/:id | 下载附件 blob | Bearer |
| GET | /entrances | 通道列表 | Bearer |
| POST | /entrances/:id/revoke | 撤销**别人**的通道（§7.2，需共享口令） | Bearer |
| POST | /entrances/retire | **本机自助退役**（§7.2.1，无请求体，只认 session） | Bearer |
| POST | /push/register | 注册 Push Token | Bearer |
| DELETE | /push/register | 注销 Push Token | Bearer |
| GET | /space | 空间信息（space_id、成员通道） | Bearer |
| POST | /receipts | 上报自己的送达/已读高水位（§5.4） | Bearer |
| GET | /receipts | 拉取本 space 全部回执行（§5.4） | Bearer |
| GET | /messages/unread | 未读条数（服务端派生：消息 + 我的读取水位；多空间列表角标用） | Bearer |
| POST | /entrances/name | 改本通道显示名 | Bearer |
| POST | /entrances/install-uid | 补登安装级标识 `install_uid`（多空间：幂等，仅写本会话那一行） | Bearer |
| POST | /partners/name | 改本人显示名（同步 `space_members.display_name`） | Bearer |
| POST | /avatar | 上传本人头像 | Bearer |
| GET | /avatar/:partnerId | 取头像（免认证，公开可读） | — |
| GET | /join/:token | 邀请落地页（提示用 App 打开） | — |

**Multiverse（v2）空间端点**（详见 `PROTOCOL_MULTIVERSE.md` §4）：

| 方法 | 路径 | 用途 | 鉴权 |
| --- | --- | --- | --- |
| POST | /spaces | 创建空间（登记创建者通道 + 签发会话） | — （自举） |
| GET | /spaces/lookup?address= | 按地址定位空间（最小公开信息） | — |
| POST | /spaces/join/preflight | 校验 join token（**不消费**） | — |
| POST | /spaces/join | 用 join token 加入（登记通道 + 签发会话） | — |
| POST | /spaces/{id}/join-tokens | 生成一次性邀请链接 | **空间成员** |
| POST | /spaces/{id}/key-escrow | `{passphrase}` 取密文包（免认证）；`{package,…}` 上传/更新（**空间成员**） | 分支不同 |

> 无用户账号体系；空间与成员关系由上述端点自助建立（不再有静态配置文件）。
> **免鉴权端点白名单**及其理由写在 `server/src/app.ts` 的 `route()` 顶部注释里，新增免鉴权端点必须在那里登记。

## 5. 消息与同步

### 5.1 上传消息 POST /messages

```json
// 请求（信封见 E2EE.md §5.1）
{
  "v": 1,
  "type": "text",
  "key_version": 1,
  "message_id": "uuidv7",
  "sender_entrance_id": "dev-a1",
  "nonce": "base64(24B)",
  "ciphertext": "base64"
}

// 响应 200 —— 先持久化，再分配序号
{
  "message_id": "uuidv7",
  "server_sequence": 104,
  "created_at": 1787900000000
}
```

- **Server 不解析、不读取 ciphertext**，只透传存储并返回分配的 `server_sequence`。
- 同一 `message_id` 重复上传 → 返回原记录（幂等，不重复计数）。
  客户端据此实现「**验证并重发**」：发送状态卡在「发送中」（响应丢失，服务端其实
  已存）或标为「失败」时，点按状态图标即用**同一封消息**重发一次——
  服务端已存 → 返回原 seq → 转为已发送（**不会产生重复消息**）；
  未存 → 本次存入 → 转为已发送。
- **幂等是硬契约，不是优化**（2026-09-15 评审固化）：客户端传输层对瞬时网络错误
  （握手失败/连接断开/超时，见 `ApiClient._withRetry`）会**自动重发同一请求**，
  异步通知（WS `message.new`）也作为补充通道——两条都会造成同一 `message_id`
  到达服务端多次。服务端实现不得改成"重复即报错"，否则重试路径会整体失效。
- 幂等判定范围是 **`(message_id, space_id)`**（`messages.ts` 按 Space 查询），
  `server_sequence` 亦按 Space 独立递增。

### 5.1.1 消息载荷（ciphertext 解密后的明文形状）

Server 从不解析 ciphertext，所以载荷形状是**客户端约定**，编解码见
`shared/lib/src/protocol/message_payload.dart`。两种形态：

```jsonc
// 1) 裸文本：无附加字段时就是用户输入的原文（旧版消息、文本消息）
"晚上吃啥？"

// 2) JSON：带引用或 meta 时包装成对象
{ "plaintext": "晚上吃啥？", "quote": { "messageId": "…", "preview": "…" },
  "meta": { "audioDurationSeconds": 25 } }
```

- `quote`：引用快照（谁引用了哪条、预览文本），随密文走，Server 不可见。
- `meta`：**通用扩展袋**——以后任何"目前未知的新数据"都放这里，扁平键、加前缀
  避免撞名（如 `audioDurationSeconds`）。新增键必须登记到下表 + 代码常量。

| meta 键                 | 类型 | 含义                                       | 引入 |
| ----------------------- | ---- | ------------------------------------------ | ---- |
| `audioDurationSeconds`  | int  | 语音（录音）/ 音频文件时长（秒）；气泡展示 | 2026-09-13 |

**兼容规则（双向）**：老客户端遇到未知键忽略（仍按 `plaintext` 显示）；新客户端
遇到缺键或裸文本按缺省处理。因此往 `meta` 加键是安全的渐进升级，**不需要**
协议版本号或服务端改动。

### 5.2 增量同步 GET /sync?after=102&limit=100

```json
// 响应 200
{
  "messages": [
    { "v":1, "type":"text", "key_version":1, "message_id":"…",
      "sender_entrance_id":"dev-b1", "nonce":"…", "ciphertext":"…",
      "server_sequence": 103, "created_at": … }
  ],
  "attachments_meta": [ /* 消息引用的附件元数据，§6 */ ],
  "last_sequence": 104,
  "has_more": false
}
```

- `after` 为客户端 `last_server_sequence`；返回大于该值的消息，按 `server_sequence` 升序。
- `has_more=true` 时客户端继续翻页；避免一次性拉取全量历史。
- 客户端把消息写入本地 SQLite 后，才推进 `last_server_sequence`。

### 5.3 顺序保证

- `server_sequence` 是**每个 Space 内**单调递增的全局序号，**不使用时间戳**排序（E2EE.md/产品文档 §9.2）。
- Server 先持久化（分配序号）→ 再广播给对端 WS / 触发推送（§8）。

### 5.4 消息回执（已送达 / 已读）

回执**不是逐条 ACK**，而是按 `(space_id, partner_id)` 存一条**单调高水位（HWM）**：

```sql
receipts(space_id, partner_id, delivered_upto_seq, read_upto_seq, updated_at)
  PRIMARY KEY (space_id, partner_id)
```

推导（客户端）：我的消息 `seq = S` ——

- **已送达** ⟺ 对方 `delivered_upto_seq ≥ S`
- **已读** ⟺ 对方 `read_upto_seq ≥ S`

不变式（**服务端强保证**，客户端无需信任对端）：

- 只前进：upsert 用 `MAX(...)`，回退的上报被忽略。
- `delivered_upto_seq ≥ read_upto_seq`：读隐含送达。
- 夹紧到本 space 真实 `MAX(server_sequence)`，防止有 bug 的客户端上报未来序号。

语义取舍（明确）：

- 按 **partner** 记 → "该 partner **至少一台**通道已收到/已读"，不保证其所有通道。
- HWM 是粗粒度：`read_upto_seq = N` 会把发送方所有 ≤N 的消息一并标为已读
  （与主流 IM 一致）。因此**上报侧必须严格把关**（见下），否则会虚标。

#### POST /receipts（上报自己的高水位）

```json
// 请求（两个字段都可缺省，未给的视为 0）
{ "delivered_upto_seq": 12, "read_upto_seq": 10 }
// 响应（服务端夹紧后的当前值）
{ "delivered_upto_seq": 12, "read_upto_seq": 10 }
```

#### GET /receipts（拉取本 space 全部回执行）

```json
{ "receipts": [ { "partner_id": "…", "delivered_upto_seq": 12, "read_upto_seq": 10, "updated_at": 1789215936509 } ] }
```

重连/补拉用；实时路径是 WS `receipt.updated`（§8）。

#### 上报时机（决定会不会虚标）

- **已送达**：本通道确实收到了 → `delivered_upto_seq = 本端同步锚点`。
  含首屏/断线回填，安全（"收到"是客观事实）。
- **已读**：**只在用户真的看着对话时**上报——补拉/首屏同步的历史**不算已读**
  （高水位的 read_upto=N 会把 ≤N 全部标已读，若补拉即上报，对方离线期间的历史
  会在他一上线就被整段标成"已读"，不合理。老板 2026-09-12 定）。
  - App：仅 ①WS **实时**到达 + 用户前台看着对话，或 ②`resumed` 到前台且列表贴底
    时才推进；且只统计**已渲染到屏幕上**的对方消息（post-frame 判定，不用 DB 最大值）。
  - CLI/TUI：仅 WS **实时**到达（用户正看着终端）推进；`sync` 补拉只上报送达。
  - 当前 UI **不**展示已读（与已送达同显示为双勾），是否展示留作开关。
- 单调 + 本地防抖：未前进就不发；重复上报因服务端夹紧是幂等 no-op。

> 当前状态：回执已在协议/服务端/两端客户端打通并落库，但 **UI 暂不展示**
> （气泡状态图标仍只有「发送中 / 已发送 / 失败」三种），展示待后续启用。

---

## 6. 附件（图片 / 视频 / 语音）

### 6.1 上传 POST /attachments

```json
// 请求（multipart 或原始字节流，头字段携带元数据）
{
  "message_id": "uuidv7",
  "attachment_id": "uuidv7",
  "key_version": 1,
  "size": 12345,
  "sha256": "base64(密文哈希)",
  "nonce": "base64(24B)"
}
// body: 加密 blob（二进制）

// 响应 200
{ "attachment_id": "uuidv7", "storage_path": "files/01/…", "created_at": … }
```

- 只接受加密 blob；Server 校验 `size` 与 `sha256` 后落盘。
- **两阶段上传（先 blob 后消息）**：客户端先 `POST /attachments` 上传 blob（此时对应
  message 可尚不存在，Server 不要求 message 先存在），blob 就位后再 `POST /messages`
  建立关联。避免"消息已广播但对端 blob 缺失"：消息一旦上链就会被 WS 推送/同步到对端，
  若 blob 后传失败对端将看到打不开的附件。
- 孤儿清理：blob 已传但消息未发出（上传成功后 `POST /messages` 失败）的孤儿附件，
  超过 10 分钟仍无对应 message 时由 Server 定期清理（随每小时清理任务）。

### 6.2 下载 GET /attachments/:id

- 鉴权 + 白名单校验后返回加密 blob（二进制流）。
- 客户端解密后缓存于 App 私有目录（E2EE.md §6）。

## 7. 通道与推送

### 7.1 通道列表 GET /entrances

**范围：只返回本会话所属空间成员名下的通道**（2026-09-15 评审 C2）——entrances 表本身是
全局表，此前直出会跨空间泄漏 partner、在线状态与公钥。**不返回 `public_key`**
（2026-09-15 评审 C5：列表接口没有消费它的场景，challenge 由服务端用公钥密封）。

```json
// 响应 200
{ "entrances": [
    { "entrance_id": "…", "partner_id": "…", "status": "active", "last_seen": 1787900000000,
      "entrance_name": "MacBook", "connected_at": 1787900000000, "online_since": 1787900000000 }
] }
```

- `last_seen` 只由 WS 连接/心跳/断开维护（轮询端点不刷新它，否则调用方会让自己"永远新鲜"）；
  `connected_at` = 当前 WS 连接的建立时刻（离线为 null）；
  `online_since` = 进入**在线态**的时刻（离线为 null）——与 `connected_at` 的区别是
  **重连不刷新**（被新连接踢掉后又连上不算重新上线），客户端据此按上线顺序排列
  对端的多台在线通道（最新上线在最前）。

### 7.2 撤销通道 POST /entrances/:id/revoke

```json
{ "passphrase": "<共享口令>" }
```

- **授权（2026-09-16 定稿）**：
  1. **同 space 内可互撤**——不限于"同一 partner 的另一条通道"：A 的手机丢了又没有第二台
     通道时，伴侣 B 也能替他撤掉那台（早期实现是"任何在册通道能撤任何通道"，连空间都不
     校验；文档当时写的是"仅限同 partner"，代码比文档更宽，现已按本规则收口）；
  2. **每次撤销都必须校验共享口令**（argon2id，与取包同一套校验与失败限速）。撤销会让
     对方客户端**自毁本地数据**，属不可逆的破坏性操作，必须由口令持有者授权——这样伴侣
     的一条通道即便被入侵，仅凭 session 也清不掉另一方的通道。
  3. 不能撤自己 → `400 INVALID_REQUEST`。
- 失败码：缺口令 → `400 INVALID_REQUEST`；目标不在本空间 → `403 FORBIDDEN`；
  口令错 → `401 ESCROW_VERIFY_FAILED`；尝试过多 → `429 ESCROW_RATE_LIMITED`；
  该空间未托管口令（从未设置或被 `DELETE /key-escrow` 清除）→ `409 PASSPHRASE_NOT_SET`
  （**拒绝放行**，不放宽成"无需口令"）。
- Server 把通道标记为 `revoked`、清除其 Push Token 与活动会话，并关闭其 WS 连接；**不**通知 Space Key 轮换
  （轮换方案 2026-09-14 决定不做，见 `SECURITY.md` §3）。
- 注：早期版本是 `DELETE /entrances/:id` 且**无需口令**——该形态已移除（口令要求无法可靠地
  放在 DELETE 请求体里，且旧形态允许空间内任意通道远程抹掉别人的数据）。
- 被撤销的通道随后：在线 → 收到 `entrance.revoked` 帧 + close `4403`；离线/重连 → 会话已被删
  返回 `401 UNAUTHORIZED`，重认证时挑战返回 `403 ENTRANCE_REVOKED`。**这两个信号（帧 / 该 code）
  是客户端唯一被授权清空本地数据的依据**；`403 FORBIDDEN`（未登记）与网络故障都只应警告。

### 7.2.1 自助退役 POST /entrances/retire（本机注销，2026-09-21）

无请求体——身份与目标都由 Bearer 会话决定，**目标恒为自己**。

- **为什么单独一个端点**：客户端"重置本机"原先纯本地清数据，服务端这条通道的注册表项、
  Push Token 与会话全都留着，对方 `/entrances` 里是一台永远在线的幽灵；而 §7.2 禁止自撤，
  谁也删不掉它。
- **为什么不校验共享口令**（与 §7.2 的关键差异）：这里是"注销我自己"，session 即所有权
  证明；而且客户端在调用之前已经过了本地闸门（输入本机通道名 + 本机锁屏码）。共享口令是
  **共享**给伴侣的加入凭证，不该获得销毁我这条通道的权力；校验它还必须联网，会让"本机
  身份属于一台已经连不上的服务器"这个最常见的重置场景直接自锁。
- 服务端动作：通道置 `revoked`（**行保留**，否则它被当成"未登记"而非"已退役"，
  且 `messages.sender_entrance_id` 会失去归属）+ `last_seen = 0`，清除其 Push Token、
  活动会话与未被消费的 challenge，并把它的 WS 连接移出在线表。审计 kind 为
  `entrance.retire`（区别于被人撤销的 `entrance.revoke`）。
- **退役绝不发 `entrance.revoked` 帧，也不主动关闭 WS**（`ws.forgetEntranceConnection`）：
  那帧是客户端自毁本地数据的授权信号，而本端点只认 session——若由它发出，偷到 session
  的人就能远程擦通道，等于给 §7.2 的口令闸门挖了一条旁路。取而代之的是给对端广播一次
  `peer.offline`，让对方立刻看到这条通道下线。
- 失败码：无/失效 token → `401 UNAUTHORIZED`；已撤销通道的会话 → `403 ENTRANCE_REVOKED`。
  客户端约定：**先调它、再清本地数据**（token 就存在本地，清完就调不动了）；调用失败时
  是否仍清本地由客户端决定——现实现是照清，并如实提示"服务端可能仍有残留"。

### 7.3 Push Token POST /push/register

```json
// 请求
{ "platform": "ios" | "android", "token": "…" }

// 响应 200
{ "ok": true }
```

- 通道撤销时其 Token 一并清除。
- **推送永不携带消息正文**，只发 `{ "type": "new_message", "space_id": "…" }` 提示（productLens §10）。

### 7.4 密钥托管 POST/GET/DELETE /key-escrow（口令托管）

> 口令托管密钥（KEY_ESCROW.md §4）：客户端用**口令**（Argon2id）派生密钥把
> `{space_key, space_id, key_version}` 加密成密文包后托管到 Server。Server 只存
> **被口令加密的密文包**，不解析内容——没有口令任何一方（含 Server 本身）都无法解开。
> 用途：换通道/朋友新接入时凭口令拉取解密，免 sealed 副本离线传递。

```json
// POST /key-escrow（上传/更新，按 space 一份，UPSERT）
{ "package": { "format": "backup-v1", "salt": "b64", "nonce": "b64", "ciphertext": "b64" } }
// 可选附 passphrase_hash（argon2id，加入方取包时校验口令用）与 rotated
{ "package": { "…" }, "passphrase_hash": "…", "rotated": true }
// 响应 200
{ "ok": true }

// GET /key-escrow（拉取；在册通道可读，按会话绑定的 space 取那一份）
// 响应 200（未托管时为空对象）
{ "package": { "format": "backup-v1", "salt": "b64", "nonce": "b64", "ciphertext": "b64" } }

// DELETE /key-escrow（清除）
{ "ok": true }
```

- 鉴权：Bearer session_token（challenge-response 后）；通道须在 entrances 表内且未撤销（403）。
  包按**会话绑定的 space** 存取（`escrowSpaceId`）——Multiverse 下同一台服务器有多个空间，
  各存各的一份（2026-09-12 修的 space_id 错位 bug，见 escrow.ts 注释）。
- 包结构校验仅限字段类型（`format`/`salt`/`nonce`/`ciphertext` 均为非空 base64 字符串，400 拒绝坏字段）；**Server 永不解析包内容**。
- 口令校验**在服务端**（`/spaces/{id}/key-escrow` 带 `passphrase` 分支：argon2id 哈希比对，
  失败按 space 计次限速 → `429 ESCROW_RATE_LIMITED`，默认 10 次/15 分钟）；客户端解包失败
  仍等价于口令错（AEAD tag 校验）。密文包内容 Server 永不解析。
  （早先版本文档写的"验证在客户端、Server 无法限速"已作废——2026-09-14 改为服务端校验 + 限速。）
- 客户端接入流程（v2）：口令取钥（`POST /spaces/{id}/key-escrow`，免认证）→ 加入空间
  → 认证 → `GET /key-escrow` → 口令解密 → 进入空间。客户端**不本地缓存共享口令**
  （服务器为唯一真相源，KEY_ESCROW.md §12）；无解锁自动重传。口令重设/密保箱重建走
  App「修改口令」或 TUI `/passphrase`：**服务器已有箱**时须先验旧口令（解箱成功）才覆盖；**服务器无箱**时跳过旧口令校验、用新口令直接重建（通道已认证且持有 Space Key，不新增权限）。
- **`/recover`（全丢恢复）已整体移除**（2026-09-13，Server 端点 + TUI 入口 + 客户端方法
  全部删除）。理由：① 它按 `space_id=''` 那一行读包，Multiverse 下本就永远读不到；
  ② 它的撤销逻辑是**全库范围**的（`UPDATE entrances … WHERE status='active'`、
  `DELETE FROM sessions/push_tokens/invites` 都无 space 过滤）——修好 ① 反而会把该
  服务器上**所有空间**的通道全部撤销；③ "仅凭口令定位空间"做不到：服务端每个 space
  只存一份 argon2id 哈希，遍历校验既慢又是放大攻击面。产品结论：双方通道全丢 =
  双方放弃该空间，重新建一个即可（v1 只有一个空间才不得不支持恢复）。
  新通道接入仍走：**一次性 join token（邀请链接）/ 共享口令 / 密保信封**
  （KEY_ESCROW.md §13；v1 的 20 位邀请码与 `/invites` 已随 2026-09-15 收敛删除）。

## 8. WebSocket（实时通道）

### 8.1 连接

```text
wss://host/ws?pv=1
Authorization: Bearer <session_token>
```

- **`session_token` 走握手请求头**（`Authorization: Bearer …`），**不放 URL query**
  （2026-09-15 评审 H4：URL 会进反代 access log / 代理缓存 / 浏览器历史）。
  服务端不再接受 `?token=`。
- 握手失败（token 无效/过期/非白名单）→ 连接建立后关闭并返回 4401。
- 连接期间 Server 持续校验 token 有效期。

### 8.2 帧格式（JSON 文本帧）

```json
{ "id": 1, "type": "…", "payload": { … } }
```

| 方向 | type | payload | 说明 |
| --- | --- | --- | --- |
| S→C | `hello` | `{ "entrance_id": "…", "space_id": "…", "last_sequence": 104 }` | 连接确认 |
| S→C | `message.new` | `{ "message": {…信封…}, "server_sequence": 105 }` | 对端新消息（已持久化后广播） |
| C→S | `ping` / S→C `pong` | — | 心跳（30s 间隔） |
| S→C | `sync.advance` | `{ "last_sequence": 105 }` | 提示有新数据，可拉 /sync |
| S→C | `receipt.updated` | `{ "partner_id": "…", "delivered_upto_seq": 12, "read_upto_seq": 10 }` | 对方回执（已送达/已读）高水位更新（§7） |
| S→C | `entrance.revoked` | `{ "entrance_id": "…" }` | 本通道被撤销 → 客户端退出会话。**只由 §7.2 的撤销发出**；自助退役（§7.2.1）刻意不发此帧，改发 `peer.offline` |
| S→C | `peer.online` | `{ "entrance_id": "dev1", "partner_id": "per1", "online_since": 1787900000000 }` | 对端通道上线（WS 连接建立时广播；**不发给同 partner 的通道**——自己的另一台不是"对方"）。`online_since` 同 §7.1：进入在线态时刻，重连不刷新 |
| S→C | `peer.offline` | `{ "entrance_id": "dev1", "partner_id": "per1" }` | 对端通道下线（WS 断开时广播——App 立即更新对方在线状态；同样跳过同 partner 通道） |
| S→C | `passphrase.rotated` | `{ "entrance_id": "dev1" }` | 空间口令已被重设（客户端收到后只发通知不弹窗；生成开通码/改口令时按需检测 updated_at 再要求输入新口令） |

### 8.3 顺序与重连

- **先持久化、后广播**：`message.new` 仅在消息落库并分配 `server_sequence` 后发送。
- 断线重连：客户端以 `last_server_sequence` 重新 `/sync` 补齐断线期间消息，再继续监听 WS（不依赖 WS 保证消息不丢，WS 只是实时加速）。

## 9. 错误格式

所有错误响应统一结构：

```json
{ "error": { "code": "UNAUTHORIZED", "message": "session expired" } }
```

| code | HTTP | 含义 |
| --- | --- | --- |
| PROTOCOL_VERSION_MISMATCH | 400 | 协议版本不匹配 |
| INVALID_REQUEST | 400 | 请求格式错误 |
| UNAUTHORIZED | 401 | 未认证 / token 失效 |
| FORBIDDEN | 403 | 通道不在白名单（**未登记**，含服务端库被清空/重置；客户端只警告，**不得**清空本地数据） |
| ENTRANCE_REVOKED | 403 | 本通道已被**明确撤销**（`status='revoked'`，涉嫌被盗用；客户端应清空本地数据后重新入网） |
| ESCROW_VERIFY_FAILED | 401 | 共享口令错误（取包 / 撤销通道的二次校验） |
| ESCROW_RATE_LIMITED | 429 | 口令尝试过多（按 space 计失败次数，滑窗内超限） |
| PASSPHRASE_NOT_SET | 409 | 该空间未托管共享口令，无法校验（撤销通道要求先设置口令） |
| NOT_FOUND | 404 | 资源不存在 |
| CONFLICT | 409 | 重复 / 状态冲突 |
| RATE_LIMITED | 429 | 触发限流 |
| INTERNAL | 500 | 内部错误（不暴露细节） |

- 内部细节（SQL、路径、堆栈）只进受保护 Server 日志，禁止返回给客户端。

## 10. 限流与日志

- 限流（令牌桶算法 token bucket）：`/auth/*` 每分钟 10 次/通道；`/messages`、`/attachments` 每分钟 60 次/通道；WS 连接数 ≤ 每通道 3。
- 日志**禁止包含**：消息明文、附件内容、密钥、私钥、Space Key（允许：entrance authenticated、message sequence=123、attachment uploaded、sync completed）。

## 11. 版本演进

- `X-Protocol-Version` / `?pv=1` 为硬校验；不匹配拒绝服务。
- V1 阶段 Client 与 Server 一起发布、一起升级，不承诺跨版本兼容。
- 未来若需兼容：只允许向后兼容的字段新增（未知字段忽略），结构性变更必须升 `pv` 并双端同步上线。
