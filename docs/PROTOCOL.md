# OnlySpace — 通信协议（docs/PROTOCOL.md）

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
- 上传前必须先有对应 message（先 POST /messages 再传附件）。

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
| S→C | `delivery` | `{ "message_id": "…", "status": "delivered" }` | 投递状态 |
| S→C | `key.rotation` | `{ "key_version": 2 }` | 触发客户端执行 Space Key 轮换 |
| S→C | `device.revoked` | `{ "device_id": "…" }` | 本设备被撤销 → 客户端退出会话 |

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
