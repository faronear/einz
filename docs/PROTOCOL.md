# Einz — 通信协议（docs/PROTOCOL.md）

> **状态：** Draft v0.1（Phase 0 产出）
> **权威性：** 本文档是 REST + WebSocket 协议的**唯一权威定义**；Client 与 Server 必须按本文档实现，任何不一致以本文档为准。
> **关联文档：** `docs/E2EE.md`（密文信封与密钥）、`docs/DATABASE.md`（存储）、`aimemo/productLens.zhcn.md` §9（同步）、§13.3（时间）。

---

## 1. 传输与版本

- 生产环境强制 HTTPS / WSS（Caddy 终结 TLS），禁止 HTTP / WS。
- 所有请求/帧携带 `X-Protocol-Version: 1`（或 WS 握手 query `?pv=1`）；版本不匹配 → `400 PROTOCOL_VERSION_MISMATCH`。
- 服务端与客户端必须校验对方版本；V1 阶段两端同时升级，不做多版本兼容矩阵。

## 2. 通用约定

| 项 | 约定 |
| --- | --- |
| 时间 | 一律 Unix 毫秒（UTC），如 `1787900000000`；展示时客户端转本地 |
| ID | UUIDv7（消息、附件、空间、设备）；不使用 SQLite 自增作为跨端 ID |
| 二进制 | base64（无填充）编码后传输 |
| 鉴权 | `Authorization: Bearer <session_token>`（§3） |
| 请求体/响应体 | JSON（UTF-8） |
| 同步顺序 | `server_sequence`（per-space 单调递增，§5） |

## 3. 认证（challenge-response）

### POST /auth/challenge

```json
// 请求
{ "device_id": "dev-a1" }

// 响应 200
{
  "challenge_id": "uuidv7",
  "sealed_challenge": "base64(seal(challenge, 白名单公钥))",
  "expires_in": 300
}
```

- challenge = 32 随机字节；Server 记录 `{challenge_id → challenge, device_id, 过期 5min, 一次性}`。
- **仅白名单内设备可发起**（E2EE.md §7.3、§8）。

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
| POST | /auth/challenge | 获取密封 challenge | 白名单公钥 |
| POST | /auth/verify | 提交明文换取 session | challenge |
| POST | /messages | 上传新消息密文 | Bearer |
| GET | /sync?after=<seq>&limit=<n> | 增量拉取（§5） | Bearer |
| POST | /attachments | 上传附件 blob（分片可选） | Bearer |
| GET | /attachments/:id | 下载附件 blob | Bearer |
| GET | /devices | 设备列表 | Bearer |
| DELETE | /devices/:id | 撤销设备（触发密钥轮换） | Bearer |
| POST | /push/register | 注册 Push Token | Bearer |
| DELETE | /push/register | 注销 Push Token | Bearer |
| GET | /space | 空间信息（space_id、成员设备） | Bearer |
| POST | /receipts | 上报自己的送达/已读高水位（§5.4） | Bearer |
| GET | /receipts | 拉取本 space 全部回执行（§5.4） | Bearer |

> V1 无用户账号、无动态配对、无空间管理 REST（配置在安装阶段完成，productLens §9.3）。

## 5. 消息与同步

### 5.1 上传消息 POST /messages

```json
// 请求（信封见 E2EE.md §5.1）
{
  "v": 1,
  "type": "text",
  "key_version": 1,
  "message_id": "uuidv7",
  "sender_device_id": "dev-a1",
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

### 5.2 增量同步 GET /sync?after=102&limit=100

```json
// 响应 200
{
  "messages": [
    { "v":1, "type":"text", "key_version":1, "message_id":"…",
      "sender_device_id":"dev-b1", "nonce":"…", "ciphertext":"…",
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

回执**不是逐条 ACK**，而是按 `(space_id, person_id)` 存一条**单调高水位（HWM）**：

```sql
receipts(space_id, person_id, delivered_upto_seq, read_upto_seq, updated_at)
  PRIMARY KEY (space_id, person_id)
```

推导（客户端）：我的消息 `seq = S` ——

- **已送达** ⟺ 对方 `delivered_upto_seq ≥ S`
- **已读** ⟺ 对方 `read_upto_seq ≥ S`

不变式（**服务端强保证**，客户端无需信任对端）：

- 只前进：upsert 用 `MAX(...)`，回退的上报被忽略。
- `delivered_upto_seq ≥ read_upto_seq`：读隐含送达。
- 夹紧到本 space 真实 `MAX(server_sequence)`，防止有 bug 的客户端上报未来序号。

语义取舍（明确）：

- 按 **person** 记 → "该 person **至少一台**设备已收到/已读"，不保证其所有设备。
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
{ "receipts": [ { "person_id": "…", "delivered_upto_seq": 12, "read_upto_seq": 10, "updated_at": 1789215936509 } ] }
```

重连/补拉用；实时路径是 WS `receipt.updated`（§8）。

#### 上报时机（决定会不会虚标）

- **已送达**：本设备确实收到了 → `delivered_upto_seq = 本端同步锚点`。
  含首屏/断线回填，安全（"收到"是客观事实）。
- **已读**：只在用户真的看到时上报。
  - App：`AppLifecycleState.resumed` **且**聊天页是最上层 **且**列表贴底，
    且只统计**已渲染到屏幕上**的对方消息（post-frame 判定，不用 DB 最大值）。
  - CLI/TUI：终端全程可见且总滚到最新，故 sync/WS 上屏后即上报（与 App 的
    "在前台 + 看到最新"同一语义）。代价：离线期间的历史在下次启动同步后会被
    标为已读——高水位模型的固有语义（主流 IM 相同）。
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

## 7. 设备与推送

### 7.1 设备列表 GET /devices

```json
// 响应 200
{ "devices": [
    { "device_id": "dev-a1", "person_id": "person-a", "status": "active", "last_seen": 1787900000000 }
] }
```

### 7.2 撤销设备 DELETE /devices/:id

- 仅允许撤销"同 person 的另一台设备"（V1 一人一机时主要用于异常场景）。
- Server 将设备移出白名单、清除其 Push Token，并返回 `key_rotation_required: true` 通知剩余设备执行 Space Key 轮换（E2EE.md §9）。

### 7.3 Push Token POST /push/register

```json
// 请求
{ "platform": "ios" | "android", "token": "…" }

// 响应 200
{ "ok": true }
```

- 设备撤销时其 Token 一并清除。
- **推送永不携带消息正文**，只发 `{ "type": "new_message", "space_id": "…" }` 提示（productLens §10）。

### 7.4 密钥托管 POST/GET/DELETE /key-escrow（口令托管）

> 口令托管密钥（KEY_ESCROW.md §4）：客户端用**口令**（Argon2id）派生密钥把
> `{space_key, space_id, key_version}` 加密成密文包后托管到 Server。Server 只存
> **被口令加密的密文包**，不解析内容——没有口令任何一方（含 Server 本身）都无法解开。
> 用途：换设备/朋友新接入时凭口令拉取解密，免 sealed 副本离线传递。

```json
// POST /key-escrow（上传/更新，按 space 一份，UPSERT）
{ "package": { "format": "backup-v1", "salt": "b64", "nonce": "b64", "ciphertext": "b64" } }
// 可选附 passphrase_hash（argon2id，/recover 恢复校验用）与 rotated
{ "package": { "…" }, "passphrase_hash": "…", "rotated": true }
// 响应 200
{ "ok": true }

// GET /key-escrow（拉取；白名单内任一设备可读）
// 响应 200（未托管时为空对象）
{ "package": { "format": "backup-v1", "salt": "b64", "nonce": "b64", "ciphertext": "b64" } }

// DELETE /key-escrow（清除）
{ "ok": true }
```

- 鉴权：Bearer session_token（challenge-response 后）；设备须在白名单（403）。
- 包结构校验仅限字段类型（`format`/`salt`/`nonce`/`ciphertext` 均为非空 base64 字符串，400 拒绝坏字段）；**Server 永不解析包内容**。
- 口令验证发生在客户端（解密失败 = 口令错，AEAD tag 校验），Server 无法限速 → 依赖 Argon2id 慢哈希 + 口令熵要求 + 客户端本地错误处理。
- 客户端接入流程：生成身份 → 白名单登记 → 认证 → `GET /key-escrow` → 口令解密 → 进入空间。密钥轮换后客户端解锁时自动重传新密文包（KEY_ESCROW.md §7）。
- `/recover`（口令重置空间，撤销全部设备）**仅 TUI 客户端调用**——App 已移除该入口（2026-09-08 决策：仅凭口令召回所有设备并重置整个空间对 App 用户太危险；App 侧备份/恢复一并取消，新设备用邀请码/口令/密保信封接入）。

## 8. WebSocket（实时通道）

### 8.1 连接

```text
wss://host/ws?pv=1&token=<session_token>
```

- **`token` 必须 URL 编码**（session_token 为标准 base64，含 `+`/`=` 等字符，直接拼接会被查询串解析破坏）。
- 握手失败（token 无效/过期/非白名单）→ 关闭并返回 4401。
- 连接期间 Server 持续校验 token 有效期。

### 8.2 帧格式（JSON 文本帧）

```json
{ "id": 1, "type": "…", "payload": { … } }
```

| 方向 | type | payload | 说明 |
| --- | --- | --- | --- |
| S→C | `hello` | `{ "device_id": "…", "space_id": "…", "last_sequence": 104 }` | 连接确认 |
| S→C | `message.new` | `{ "message": {…信封…}, "server_sequence": 105 }` | 对端新消息（已持久化后广播） |
| C→S | `ping` / S→C `pong` | — | 心跳（30s 间隔） |
| S→C | `sync.advance` | `{ "last_sequence": 105 }` | 提示有新数据，可拉 /sync |
| S→C | `receipt.updated` | `{ "person_id": "…", "delivered_upto_seq": 12, "read_upto_seq": 10 }` | 对方回执（已送达/已读）高水位更新（§7） |
| S→C | `key.rotation` | `{ "key_version": 2 }` | 触发客户端执行 Space Key 轮换 |
| S→C | `device.revoked` | `{ "device_id": "…" }` | 本设备被撤销 → 客户端退出会话 |
| S→C | `peer.online` | `{ "device_id": "dev1" }` | 对端设备上线（WS 连接建立时广播） |
| S→C | `peer.offline` | `{ "device_id": "dev1" }` | 对端设备下线（WS 断开时广播——App 立即更新对方在线状态） |
| S→C | `passphrase.rotated` | `{ "device_id": "dev1" }` | 空间口令已被重设（客户端收到后只发通知不弹窗；生成邀请码/改口令时按需检测 updated_at 再要求输入新口令） |

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
| FORBIDDEN | 403 | 设备不在白名单 |
| NOT_FOUND | 404 | 资源不存在 |
| CONFLICT | 409 | 重复 / 状态冲突 |
| RATE_LIMITED | 429 | 触发限流 |
| INTERNAL | 500 | 内部错误（不暴露细节） |

- 内部细节（SQL、路径、堆栈）只进受保护 Server 日志，禁止返回给客户端。

## 10. 限流与日志

- 限流（令牌桶）：`/auth/*` 每分钟 10 次/设备；`/messages`、`/attachments` 每分钟 60 次/设备；WS 连接数 ≤ 每设备 3。
- 日志**禁止包含**：消息明文、附件内容、密钥、私钥、Space Key（允许：device authenticated、message sequence=123、attachment uploaded、sync completed）。

## 11. 版本演进

- `X-Protocol-Version` / `?pv=1` 为硬校验；不匹配拒绝服务。
- V1 阶段 Client 与 Server 一起发布、一起升级，不承诺跨版本兼容。
- 未来若需兼容：只允许向后兼容的字段新增（未知字段忽略），结构性变更必须升 `pv` 并双端同步上线。
