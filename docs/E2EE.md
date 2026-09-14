# Einz — E2EE 设计（docs/E2EE.md）

> **状态：** Draft v0.1（Phase 0 产出）
> **权威依据：** `aimemo/productLens.zhcn.md` §4（密码学与密钥层级）、§5（一次性配置）
> **阅读对象：** 客户端与服务端开发者；实现时必须与本文档逐条对齐。

---

## 1. 目标与范围

本文档定义 Einz 的端到端加密协议：密钥层级、密钥派生、一次性配置分发、消息/附件加密格式、认证、密钥轮换、备份恢复。

**目标：**

- Server 永远只接触密文与元数据，无法读取消息正文、图片、视频、语音、笔记。
- 设备凭证 = 密码学公钥；私钥永不离开设备。
- 固定两人一空间（静态白名单），无动态配对。

**范围外（明确不做）：**

- **前向保密（Forward Secrecy）：不做。** 已决策采用"简单派生"（见 §11.1）：消息密钥由 Space Key 派生，若 Space Key 泄露则历史消息可解。理由：私钥存于 Keychain/Keystore 难以提取；两人固定空间无高频密钥协商需求；双棘轮（Signal 式）复杂度对 V1 不成比例。
- 隐藏元数据：不做（Server 可见时间、大小、数量等，见 productLens §3.3）。
- 消息删除的密码学级保证：删除是服务端语义行为，不提供"不可恢复"的密码学承诺。

---

## 2. 密码学库与原语

**唯一库：libsodium。** 客户端（Flutter/CLI）经 `sodium_libs`（dart:ffi）；服务端（Node.js）用对应绑定。

| 用途                       | 原语                                         | libsodium 函数                             |
| -------------------------- | -------------------------------------------- | ------------------------------------------ |
| 设备凭证密钥               | X25519 密钥对                                | `crypto_box_keypair`                       |
| Space Key 包装（配置分发） | 匿名发送方加密（X25519 + XSalsa20-Poly1305） | `crypto_box_seal` / `crypto_box_seal_open` |
| 消息/附件加密              | XChaCha20-Poly1305（AEAD）                   | `crypto_aead_xchacha20poly1305_ietf_*`     |
| 密钥派生（消息/附件）      | 带密钥 BLAKE2b-256                           | `crypto_generichash`（keyed 模式）         |
| 恢复码派生备份密钥         | Argon2id                                     | `crypto_pwhash`                            |
| 随机数                     | CSPRNG                                       | `randombytes_buf`                          |

**禁止：** 自研算法、自定义 construction、使用密码学原语做非标准组合、nonce 复用。

---

## 3. 密钥层级

```text
Device Identity Key（长期，X25519 keypair，每台设备一对）
    │  私钥：仅存本机 Keychain / Keystore，永不离开设备，永不写入磁盘明文
    │  公钥：登记进 Server 静态白名单（config.json）
    ▼
Space Key（长期，每 Space 一个，32 字节对称密钥）
    │  明文：仅存在于两端设备的安全存储中；Server 永不接触明文
    │  分发：用两端设备公钥分别 crypto_box_seal 后写入配置产物（§7）
    ├── crypto_generichash(key=SpaceKey, input="m:"‖message_id) ──► Message Key（每消息一个）
    └── crypto_generichash(key=SpaceKey, input="a:"‖attachment_id) ──► Attachment Key（每附件一个）
```

**生命周期：**

| 密钥                | 生成时机           | 销毁                 | 轮换                        |
| ------------------- | ------------------ | -------------------- | --------------------------- |
| Device Identity Key | 设备首次启动       | 随设备撤销废弃       | 换机时重新生成（§10）       |
| Space Key           | 一次性配置阶段     | 设备撤销时（§9）     | 撤销触发 `key_version` 递增 |
| Message Key         | 每条消息发送时派生 | 用完即弃（不持久化） | 无                          |
| Attachment Key      | 每个附件加密时派生 | 用完即弃             | 无                          |

**要点：**

- 消息/附件密钥按需派生、用完即弃：一个消息密钥泄露不影响其他消息。
- `key_version` 随每条密文记录；轮换后旧密文仍用旧版本密钥解密（设备保留归档密钥，§9）。
- Server 只保存包装后的 Space Key 密文与每条密文；永远没有解密所需的任何密钥。

---

## 4. 密钥派生

### 4.1 Message Key

```text
MessageKey = crypto_generichash(
    out_len = 32,
    key     = SpaceKey,
    input   = "m:" ‖ message_id_utf8,     // 前缀 "m:" 隔离命名空间
)
```

- `message_id` 为发送方生成的 UUIDv7（产品文档 §57），同一 Space 内全局唯一。
- 派生是确定性的：接收方用相同输入得到相同密钥。

### 4.2 Attachment Key

```text
AttachmentKey = crypto_generichash(
    out_len = 32,
    key     = SpaceKey,
    input   = "a:" ‖ attachment_id_utf8,  // 前缀 "a:" 隔离命名空间
)
```

### 4.3 恢复码派生备份密钥（§10）

```text
BackupKey = crypto_pwhash(
    out_len = 32,
    passwd  = recovery_code_utf8,          // 12 词助记词或二维码内容
    salt    = random_16B（存入备份头）,
    opslimit / memlimit = libsodium 交互式默认
)
```

---

## 5. 消息加密格式

### 5.1 密文信封（客户端 ↔ Server 传输，Server 只透传/存储）

```json
{
  "v": 1,
  "type": "text",
  "key_version": 1,
  "message_id": "0192…",
  "sender_device_id": "dev-a1",
  "nonce": "base64(24B)",
  "ciphertext": "base64"
}
```

| 字段               | 说明                                              |
| ------------------ | ------------------------------------------------- |
| `v`                | 协议版本（=1）                                    |
| `type`             | text / image / video / voice / system             |
| `key_version`      | 加密所用 Space Key 版本（解密时选择归档密钥）     |
| `message_id`       | UUIDv7，派生 Message Key 的输入之一               |
| `sender_device_id` | 发送设备                                          |
| `nonce`            | 24 字节随机 nonce，**每条消息重新生成，禁止复用** |
| `ciphertext`       | AEAD 密文（含 16 字节 tag）                       |

### 5.2 加密过程

```text
明文 = UTF-8(消息正文)
nonce = randombytes(24)
AAD  = "einz-v1" ‖ space_id ‖ message_id ‖ sender_device_id ‖ type ‖ key_version
ciphertext = crypto_aead_xchacha20poly1305_ietf_encrypt(
                 message = 明文, aad = AAD, nonce = nonce, key = MessageKey)
```

### 5.3 解密过程

```text
MessageKey = 派生(§4.1, 使用该消息的 message_id 与对应 key_version 的 SpaceKey)
明文 = crypto_aead_xchacha20poly1305_ietf_decrypt(
           ciphertext, aad = AAD（与加密端完全一致）, nonce, key = MessageKey)
```

- AAD 绑定 space/message/sender/type/version：防止密文被跨空间、跨消息、跨类型替换。
- 解密失败（tag 校验不过）视为数据损坏或篡改，丢弃并记日志（不崩溃）。

---

## 6. 附件加密（图片 / 视频 / 语音）

### 6.1 加密

```text
AttachmentKey = 派生(§4.2, attachment_id)
nonce = randombytes(24)
AAD   = "einz-v1" ‖ space_id ‖ attachment_id ‖ key_version
blob  = crypto_aead_xchacha20poly1305_ietf_encrypt(原始文件字节, aad, nonce, AttachmentKey)
sha256 = SHA-256(blob)              // 密文哈希，用于完整性校验（base64，与 Server 校验一致）
```

### 6.2 元数据（存 SQLite，不含任何可读内容）

```json
{
  "id": "UUIDv7",
  "message_id": "…",
  "key_version": 1,
  "size": 12345,
  "sha256": "base64(密文哈希)",
  "nonce": "base64(24B)"
}
```

- 原始文件只在客户端存在；上传的永远是加密 blob。
- 下载后客户端解密，缓存于 App 私有目录，用完清理；用户明确要求才写入系统相册。

---

## 7. 一次性配置分发

系统固定两人一空间、无动态配对（productLens §5），密钥建立由**一次性人工配置**完成。

### 7.1 配置产物格式（einz-config-v1）

配置阶段生成一个 JSON 产物，包含 Space Key 的两种密封副本与元数据：

```json
{
  "format": "einz-config-v1",
  "space_id": "UUIDv7",
  "key_version": 1,
  "sealed_space_keys": [
    {
      "device_id": "dev-a1",
      "sealed": "base64(crypto_box_seal(SpaceKey, pubKeyA))"
    },
    {
      "device_id": "dev-b1",
      "sealed": "base64(crypto_box_seal(SpaceKey, pubKeyB))"
    }
  ]
}
```

- `crypto_box_seal` 为匿名发送方加密：只有对应私钥持有者能打开。
- **Server 只保存整个产物的密文部分，永不接触 Space Key 明文。**

### 7.2 配置流程（对应 productLens §5.1）

```text
1. 设备 A 首次启动 → 生成 X25519 身份密钥对 → 导出公钥
2. 设备 B 首次启动 → 生成 X25519 身份密钥对 → 导出公钥
3. 配置工具：生成 Space Key → 分别 crypto_box_seal 给 A、B 公钥
4. 配置工具：生成 config.json（space_id + 两台设备的 device_id / 公钥 / person 映射）
5. 设备 A：导入配置产物 → crypto_box_seal_open 自己的密封副本 → Space Key 存入安全存储
6. 设备 B：同上
7. Server：加载 config.json 为静态白名单（§8）
```

- 身份私钥始终在设备内生成、设备内保管；公钥外传。
- 密封副本只在配置现场流转一次；此后设备各自持有 Space Key 明文。

### 7.3 服务器静态白名单（config.json）

```json
{
  "space_id": "UUIDv7",
  "devices": [
    {
      "device_id": "dev-a1",
      "person_id": "person-a",
      "public_key": "base64(X25519公钥)",
      "status": "active"
    },
    {
      "device_id": "dev-b1",
      "person_id": "person-b",
      "public_key": "base64(X25519公钥)",
      "status": "active"
    }
  ]
}
```

- 不在白名单中的设备一律拒绝认证、同步、上传（productLens §2.3）。

### 7.4 两种密钥分发方案：seal 密封交换 vs escrow 口令托管

系统提供**两条并列的 Space Key 分发路径**，按场景选用；默认走 escrow，可选 sealed envelope 为线下/CLI 路径。

**方案一：seal 密封交换（§7.1-7.2，CLI `config`/`import`、app「线下导入」）**

```text
A 生成 Space Key → 用 B 的设备公钥 crypto_box_seal → 密封副本离线给 B → B 用自己私钥打开
```

- 前置条件：**双方公钥已互知**（先 init 导出公钥、写入白名单 config.json）。
- 密钥传递**不经 Server**（离线文件/二维码），Server 泄露不影响该路径。
- 安全边界：依赖对方私钥保管。

**方案二：escrow 口令托管（KEY_ESCROW.md §4，app「创建/加入」默认路径）**

```text
A 生成 Space Key → 用口令（Argon2id 派生）加密包上传 /key-escrow → 把 space_id+口令 离线告知 B
B（白名单内设备）拉取密文包 → 用同一口令解密得 Space Key
```

- 前置条件：**无需对方公钥**——只需一个口令（经其他途径离线告知）。
- Server 只存被口令加密的包（`{format,salt,nonce,ciphertext}`），无口令解不开。
- 安全边界：依赖**口令强度** + 口令的离线告知渠道。

**为什么默认走 escrow：** 首设备初次创建空间时**不存在第二个使用者的公钥**，无法 seal；
口令托管只要求一个口令，公钥可事后补（加入白名单是独立环节），对小白最友好。
seal 密封交换在双方公钥互知后才可用，保留为 CLI 与「app 线下导入」选项。

| 维度            | seal 密封交换                    | escrow 口令托管           |
| --------------- | -------------------------------- | ------------------------- |
| 前置条件        | 双方公钥已互知                   | 无（仅需口令）            |
| 密钥传递途径    | 离线文件/二维码，**不经 Server** | 口令加密包**托管 Server** |
| Server 泄露影响 | 无（sealed 副本不在 Server）     | 拿到密文包，无口令解不开  |
| 安全边界        | 对方私钥保管                     | 口令强度 + 离线告知渠道   |
| 使用方          | CLI / app 线下导入               | **app 默认**（创建/加入） |

> 两者均不替代设备白名单：无论哪条路径，B 都需先被 A 加入 VPS `config.json`（§7.3）才能认证与拉取。

### 7.5 多设备加入与口令泄漏应对

**口令是空间级、共享的**（`server/src/escrow.ts` 按 `space_id` 存**一份**密文包，任何白名单内设备可拉取）：
后续所有新设备（第一/第二使用者的任何设备）都凭**同一口令**接入，但每台设备必须**先加入白名单**。

```text
新设备接入：生成身份密钥对 → 公钥加入白名单(config.json 重启) → 认证 → GET /key-escrow
           → 输入口令(Argon2id 派生)解密 → 获得 Space Key
```

**双重关卡**：拿到口令 ≠ 能接入——攻击者还需让设备进入白名单（A 手动改 VPS，可拦截）。

| 关卡                           | 作用                   | 控制者                 |
| ------------------------------ | ---------------------- | ---------------------- |
| 设备白名单（`isActiveDevice`） | 能否认证 / 拉取 escrow | A 手动维护 config.json |
| 口令（Argon2id 解密密文包）    | 能否解出 Space Key     | A 离线告知             |

**口令泄漏应对（按严重程度递进）：**

| 级别 | 措施                 | 操作                                                                                                          | 适用                       |
| ---- | -------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------- |
| 轻   | 换口令               | 新口令重新加密包并 `POST /key-escrow` 覆盖（UPSERT 最新者胜），旧口令立即失效；CLI `escrow upload` 可随时重传 | 口令可能外泄、设备面可控   |
| 重   | 轮换 Space Key（§9） | 轮换后旧密文包作废（解出的是旧密钥），客户端**自动**用新 Space Key 重传密文包（app `_syncEscrow`）            | 怀疑密钥已实际落入他人之手 |
| 定向 | 撤销设备（§9.3）     | `device.revoked` 踢出白名单并通知其清理本地数据                                                               | 已知攻击设备已加入白名单   |

**风险点：**

- **口令共享**：双方同一口令，无法区分"A/B 的口令"；私用两人场景可接受，但应**区别于 App 锁 PIN**。
- **口令即权限**（KEY_ESCROW.md §6）：口令熵要足够（Argon2id 慢哈希兜底暴力破解）；口令丢失用 12 词恢复码互补兜底。

---

## 8. 认证（challenge-response）

身份 = 白名单内的设备公钥；认证 = 证明持有对应私钥。

### 8.1 握手

```text
Client                     Server
  │  POST /auth/challenge    │
  │  {device_id}             │
  │                          │ challenge = randombytes(32)
  │                          │ 记录 {device_id → challenge, 过期 5min, 一次性}
  │  ← {challenge_id,        │
  │     sealed_challenge=     │
  │     seal(challenge,pubKey)}│
  │                          │
  │  crypto_box_seal_open    │
  │  得到 challenge 明文      │
  │  POST /auth/verify       │
  │  {challenge_id,          │
  │   challenge_plaintext}   │
  │                          │ 校验: challenge_id 有效?
  │                          │       明文 == 记录值?  → 通过
  │  ← {session_token,       │
  │     space_id}            │
```

- **为什么 Server 把 challenge 密封而不是明文发送：** 只有持有私钥的设备能打开并回传，Server 据此确认"你确实拥有这把私钥"。
- challenge 一次性、5 分钟过期；防止重放。
- 通过后签发 `session_token`（随机 32 字节，Server 侧记录过期时间），REST/WS 后续请求携带。

### 8.2 会话

- REST：`Authorization: Bearer <session_token>`。
- WebSocket：连接建立时携带 session_token；Server 校验通过后绑定 device_id。
- 会话过期 → 重新 challenge-response。

---

## 9. 密钥轮换（**不做**；2026-09-14 决策）

> **状态：不做。** 收益矩阵、成本分析、替代方案与"若恢复的前置条件"见 `SECURITY.md` §3。
> 本节只保留两件事：① `key_version` 这个字段为什么还在；② 归档密钥的只读语义。

### 9.1 决策摘要

- 撤销的效力来自**白名单**（`/sync` 要求白名单设备 → 被撤销设备取不到新密文）+
  被撤销设备的**上线自毁**，不依赖轮换；
- 轮换唯一独占的能力是"让**已泄露**的密钥对**未来**消息失效"；该场景（越狱/镜像泄露）
  低频，用「**重建空间**」止损更便宜（零新代码：create/join 已具备）；
- 轮换的成本集中在**分发**：新密钥要在不给被撤销设备的前提下送到剩余设备，需要设备公钥
  通道 + 可靠投递 + 归档缺口补偿 + 轮换协调，任一环失败 = 消息**永久不可解**。

### 9.2 密钥版本与归档（**只读保留**）

设备本地保存一个**只读归档**：

```json
{
  "current": { "key_version": 2, "space_key": "…" },
  "archived": [{ "key_version": 1, "space_key": "…" }]
}
```

- 解密某条消息时：按消息携带的 `key_version` 选择密钥 → 该字段与"按版本取密钥"的读路径
  保留（`cli/lib/store.dart` `spaceKeyForVersion`、`app/lib/data/message_repository.dart`
  `_keyForVersion`）；
- 归档只用于解密旧数据，不参与新加密；字段也出现在备份/恢复载荷（`archived_space_keys`），
  保持格式兼容；
- **产生**轮换状态的入口已全部撤除（`SpaceKeyRing`、`einz rotate`、`rotateSpaceKey()`、
  服务端 `key.rotation` 广播与 `key_rotation_required`）——原实现见 git 历史。

### 9.3 撤销语义（现行）

- 被撤销设备：无法再认证（白名单移除）、无法同步、无法发送；其旧 Push Token 一并清除；
- 被撤销设备**上线即自毁本地数据**（App `chat_page._onDeviceRevoked`；`SECURITY.md` §2）；
- 被撤销设备已持有的历史密文无法收回——这是设备端已解密数据的固有属性，非协议漏洞；
- 事件处置手册见 `SECURITY.md` §4。

---

## 10. 备份与恢复（模型 A：纯本地）

### 10.1 备份导出

```text
1. 用户设置/查看恢复码（12 词助记词或打印二维码）——离线保存，Server 不接触
2. BackupKey = crypto_pwhash(恢复码, salt)（§4.3）
3. 备份内容 = Client SQLite 密文库 + 附件加密 blob + 密钥归档（含 Space Key 明文）
4. 整体用 BackupKey 加密（XChaCha20-Poly1305，随机 nonce），写入备份文件头 {format, salt, nonce}
```

### 10.2 换机恢复

```text
1. 新设备安装 App → 输入恢复码
2. BackupKey = crypto_pwhash(恢复码, 备份头中的 salt)
3. 解密备份 → 恢复 SQLite、附件、Space Key 归档
4. 新设备生成新的 X25519 身份密钥 → 公钥加入 Server 白名单（重新配置）
5. 完成：历史消息与密钥全部恢复
```

### 10.3 责任边界

- 恢复码是"两台设备同时丢失"时的最后保险，UI 必须明确提示用户妥善保存。
- **Server 不保存任何恢复材料**；丢失恢复码 = 无法恢复（模型 A 的固有代价）。
- 未来模型 B（Signal PIN 式托管恢复）预留派生路径，V1 不实现（productLens §4.5、§11.4）。

---

## 11. 决策记录与禁止清单

### 11.1 前向保密决策（ADR 关联：productLens §15）

| 决策点       | 结论                                                              | 理由                                                                                |
| ------------ | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| 消息密钥生成 | **简单派生**（Space Key → 每消息派生），不做双棘轮                | 私钥在 Keychain/Keystore 难以提取；两人固定空间无高频密钥协商；复杂度与收益不成比例 |
| 代价         | 若 Space Key 泄露，历史消息可解                                   | 已接受；通过密钥轮换 + 安全存储缓解                                                 |
| 未来路径     | 如未来需要，可在 `key_version` 机制上叠加棘轮，不破坏现有密文格式 | 留有余地                                                                            |

### 11.2 禁止清单（密码学专属）

- 禁止自己实现加密算法或自定义 construction（只用 libsodium 标准原语）。
- 禁止 nonce 复用（每条消息/附件/备份都必须重新生成 nonce）。
- 禁止将 Space Key / 身份私钥以明文写入日志、错误信息、数据库。
- 禁止在 Server 保存 Space Key 明文或身份私钥。
- 禁止使用密码/恢复码直接作为消息加密密钥（必须经 Argon2id 派生）。
- 禁止信任客户端自报的成员资格（服务端按白名单校验）。
- 禁止将密文与明文混合存储（附件 blob 一律密文；本地明文缓存仅限 App 私有目录）。

### 附录：密钥命名对照（防混淆）

Einz 涉及多个"密钥"概念，命名与用途对照如下：

| 名称                   | 实体类型                                 | 用途                                                                                   | 谁持有                                    |
| ---------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------- |
| **Space Key**          | 32B 对称密钥                             | 消息/附件 E2EE 加密（§5/§6）；key_version 轮换 + 归档（§9.2）                          | 双方设备（App 锁 PIN 包 / 口令托管保管）  |
| **口令派生密钥**       | 无独立实体（口令经 Argon2id 派生，§4.3） | CLI backup/restore 备份文件、App 锁 PIN/恢复码、口令密保箱加密（三处复用 backup.dart） | 口令持有者（恢复码 / PIN / 接入口令）     |
| **EINZ_DB_BACKUP_KEY** | Server 部署环境变量（base64 32B）        | Server 数据库备份文件加密（backup.ts）；未设置拒绝备份（防误备份明文）                 | 部署者（deployment/.env，gitignore 保护） |

> 注：Server 备份密钥 2026-08 起从 `EINZ_BACKUP_KEY` 更名为 `EINZ_DB_BACKUP_KEY`，
> 避免与 CLI 的 backup（口令派生）概念混淆；旧部署升级需同步改 `.env` 变量名（docs/updateServer.md §5）。
>
> 层次关系：**Space Key 管"说话内容"（消息/附件密文），口令派生密钥管"保管手段"（备份/锁包/口令密保箱），
> DB 备份密钥管"运维备份"（Server 数据库文件）**——三层独立，互相解不开。
