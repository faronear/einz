# Einz — 产品架构说明（productLens）

> 私密聊天与共享私人空间应用，仅供**两个确定的人**使用。
> 本文档是**产品视角**的架构事实与目标；协议、数据库、密钥的详细规格分别规划于 `docs/PROTOCOL.md`、`docs/DATABASE.md`、`docs/E2EE.md`（见 §14 路线图）。

- **文档状态：** Draft v2.0
- **最后更新：** 2026-08-28
- **统一命名：** Einz （曾用名 Only 或 OnlySpace）。

---

## 0. 文档约定

- 状态标记：`[待评审]`、`[待开发]`、`[已实现]` 区分设想与现实，避免混淆。
- 术语：Person = 人；Device = 设备；Space = 空间（一个 Space 恰含两个 Person）。
- 配套记忆文档：`aimemo/projectPlan.md`（开发计划）、`aimemo/worklog.md`（工作日志）、`aimemo/userProfile.md`（老板画像）。
- 每个事实只在本文档出现一次，详细规格一律下沉到 `docs/` 专项文档。

---

## 1. 产品概述

### 1.1 定位

Einz 是一个专门为**两个确定的人**设计的私密通信与共享私人空间应用。

它不是社交网络，不是面向公众的即时通讯平台，也不是商业化产品。它不做"小型微信"，而是：

> 用尽可能简单的技术，为两个人建立一个**长期、私密、可靠、可控制**的数据空间。

**部署形态（关键前提）：** 系统**只服务于固定的两个人、永远只有一个 Space、不对外分发**——设备由我们亲手安装配置，不存在"邀请陌生人加入"的场景。这一前提让架构可以大幅简化：配对流程整体删除，服务器退化为**静态白名单哑转发器**（见 §2.3、§5、§8）。

### 1.2 核心设计原则

1. **一个 Space 永远只属于两个人。**
   系统不设计通用的"好友 / 联系人 / 群组"模型；"两人"约束由**服务端静态白名单**强制保证（§2.3），不能只靠客户端 UI。
2. **隐私优先。**
   Server 是传输、同步和存储服务，**不是可信的内容读取者**。用户内容在客户端加密后上传，Server 原则上只保存密文，不需要知道消息正文、图片/视频/语音内容、私人笔记。
3. **Local-First。**
   客户端以本地 SQLite 为主，用户操作先落本地、后异步同步 Server；断网时应用照常可用，网络恢复后自动补发。
4. **基础设施保持简单。**
   系统只有两个用户，V1 使用 1 台 VPS + 单机服务，明确不引入 Kubernetes、微服务、PostgreSQL、Redis 集群、Kafka、Elasticsearch 等分布式复杂度，除非未来出现真实需求。

### 1.3 功能概览（V1）

| 类别   | 功能                                                     |
| ------ | -------------------------------------------------------- |
| 通信   | 文字消息、图片、视频、语音消息、已读状态                 |
| 空间   | 一次性人工配置（固定两人一空间）、纪念日、在一起的天数   |
| 内容   | 共同回忆、私人笔记                                       |
| 可靠性 | 离线发送、自动同步、Push Notification、消息历史          |
| 安全   | E2EE、服务端加密存储、设备密码学身份、设备撤销、加密备份 |
| 预留   | 一人多设备同步（V1 不实现，见 §2.2）                     |

### 1.4 分发方式

- Android：签名 APK；iOS：Ad Hoc 分发。
- **仅安装到固定的两台设备**（我们亲手配置），不向任何第三方分发。
- 不上架 Apple App Store / Google Play，不使用 Enterprise Certificate。
- 无广告、无订阅、无商业化、无公开用户发现机制。

---

## 2. 概念模型

### 2.1 实体

| 实体       | 定义                       | 关键约束                            |
| ---------- | -------------------------- | ----------------------------------- |
| Person     | Space 中的人，无账号体系   | V1 由设备密码学身份代表             |
| Device     | 物理设备，持有密钥对       | 属于某个 Person                     |
| Space      | 私有空间（全系统唯一）     | **恰好两个 Person**，静态白名单强制 |
| Message    | 消息                       | 密文存储                            |
| Attachment | 大文件附件（图/视频/语音） | 独立加密 blob，消息只存元数据       |

### 2.2 Person 与 Device 分离

Person 和 Device **不是同一个概念**，数据库设计不得合并：

```text
Space
├── Person A
│     ├── iPhone A1   ← V1：一人一机
│     └── Mac A2      ← 预留
└── Person B
      └── Android B1
```

- **V1 约束：一个 Person = 一个活跃 Device。**
- 预留扩展：一个 Person = 多个 Device（影响同步协议与密钥包装，见 §4、§9）。

### 2.3 "永远两个人"的服务端强制：静态白名单

固定两人一空间意味着**不需要动态成员管理**，改为**静态白名单**：

- Server 配置文件登记**两台设备**的公钥（及其所属 Person）。
- Server 启动时加载白名单：**不在白名单中的设备一律拒绝**认证、同步、上传——这比任何动态"拒绝第三人"逻辑都更硬。
- 原 `space_members` 表不再需要（§8.3）；Person ≠ Device 建模保留（§2.2），为未来多设备预留。

---

## 3. 信任模型与威胁模型

### 3.1 信任区域

```text
Device A ──(TLS)── Internet ──(TLS)── Server ──(TLS)── Internet ──(TLS)── Device B
   │                                                              │
   └──────────── E2EE：两端明文，中间只有密文 ────────────────────┘
```

- **完全信任：** 本地设备、密码学密钥。
- **不信任：** Internet、Server 存储、备份介质、网络基础设施（依赖 TLS + E2EE 双重防护）。

### 3.2 威胁列表与防护

| 威胁                       | 防护                                         |
| -------------------------- | -------------------------------------------- |
| 白名单外设备访问           | 静态白名单：配置之外一律拒绝（§2.3、§8.3）   |
| 手机丢失                   | 设备撤销 + Space Key 轮换（§4、§12）         |
| Server 被入侵 / 管理员看库 | 只见密文 + 元数据，不见明文（E2EE 核心价值） |
| Backup 泄露                | 备份保持加密，密钥不随备份明文保存（§11）    |
| Push 泄露正文              | 推送不含消息正文，仅提示（§10）              |

### 3.3 元数据边界

E2EE 不等于匿名。V1 承认 Server 可能知道：两个设备在通信、消息时间/大小/数量、附件大小、IP、Device ID、消息类型。**V1 不追求隐藏元数据**。

---

## 4. 密码学与密钥层级

### 4.1 密码学库

- 唯一来源：**libsodium**。
  - 客户端（Flutter）：`sodium_libs`，通过 dart:ffi 绑定原生 libsodium（编译进 App 二进制，无 WebView 中间层）。
  - 服务端（Node.js）：libsodium 官方/社区绑定。
- **绝对禁止**自行实现 AES、RSA、ECC、Diffie-Hellman、MAC、Key Derivation，或设计自定义加密算法与 construction。

### 4.2 密钥层级

```text
Device Identity Key（长期，X25519 keypair）
    │  私钥永远留在本机 Keychain / Keystore，永不离开设备
    │  公钥注册到 Server：用于认证（challenge-response）与密钥交换
    ▼
Space Key（长期，每 Space 一个，32 字节对称密钥）
    │  XChaCha20-Poly1305 加密 Space 内内容
    │  用双方 Device 公钥分别"密封"后存 Server（Server 只有包装密文）
    ├── HKDF(Space Key, message_id) ──► Message Key（每消息一个）
    └── HKDF(Space Key, attachment_id) ──► Attachment Key（每附件一个）
```

要点：

- **消息/附件密钥按需派生**：一个消息密钥泄露不影响其他消息；附件密钥独立于消息内容。
- **Space Key 分发**：一次性配置时生成，分别用两个 Device 公钥（X25519 sealed box）包装后由配置工具分发到两端（§5）；Server 永远接触不到 Space Key 明文。
- **key_version**：每条密文携带其密钥版本号，密钥轮换后旧密文仍可解密。

### 4.3 消息加密格式

```text
{ version, type, key_version, nonce, ciphertext }
```

- nonce 与密文一并上传（Server 只存不用）；明文永不出现。
- 详细字段定义下沉到 `docs/E2EE.md`、`docs/PROTOCOL.md`。

### 4.4 密钥轮换

- **触发条件：** 设备撤销（§12）。
- **流程：** 生成新 Space Key → 用剩余设备公钥重新包装 → 新消息使用新 key_version；旧消息继续用旧 key_version 解密。
- 轮换是"撤销"真正生效的前提——被撤销设备持有旧 Space Key，若不做轮换，撤销形同虚设。

### 4.5 恢复模型（已决策）

- **V1：纯本地恢复（模型 A）。**
  - 用户离线保存**恢复码**（如 12 词助记词 / 可打印二维码），换机时凭恢复码解密本地加密备份（§11）。
  - Server 不接触任何恢复材料。
  - 代价：**两台设备同时丢失 = 数据永久丢失**（恢复码是最后一道保险，须用户妥善保存）。
- **预留：服务器托管加密恢复（模型 B，Signal PIN 模式）。**
  - 恢复密钥用用户口令加密后存 Server，新设备 + 口令即可恢复。
  - V1 不实现，但密钥层级保留派生路径，不阻塞未来演进。

---

## 5. 一次性人工配置（替代配对流程）

系统固定为**两人一空间、不分发**（§1.1），不存在"邀请陌生人加入"的场景。因此**配对流程整体删除**，改为由开发者（我们）亲手完成的一次性人工配置。

### 5.1 配置流程

```text
1. 手机 1（Person A）首次启动，生成 Device Identity Key（私钥留本机）
2. 手机 2（Person B）首次启动，生成 Device Identity Key（私钥留本机）
3. 配置阶段生成 Space Key
   ├── 用 A 的公钥密封一份
   └── 用 B 的公钥密封一份
4. 把两台设备的公钥写入 Server 配置文件（静态白名单，§2.3）
5. 把各自密封的 Space Key 导入对应手机（Server 只存密封密文）
```

### 5.2 为什么可以这样做

- 原配对四步握手（创建 → 扫码 → 确认 → 转交密钥）解决的是"两个互不认识、服务器也不认识"的人安全建立关系的问题。
- 现在设备由我们亲手安装、公钥由我们亲手登记，**信任在配置现场建立**，不需要协议级握手。
- 服务器退化为"只认两张白名单的哑转发器"（§8）。

### 5.3 配置产物

- Server：`config.json`（两台设备的 device_id + public_key + 所属 Person，§8.3）。
- 客户端：导入自己的密封 Space Key；身份私钥不出设备。
- 配置只做一次；未来增加设备（预留的多设备能力）时，用已有可信设备作保（§16）。

---

## 6. 消息与媒体加密

### 6.1 消息

```text
输入明文 ──► 客户端加密（Message Key）──► 密文上传 Server ──► 对方客户端解密
```

- Server 数据库中只出现密文；消息类型、大小、时间作为元数据可见（§3.3）。
- Server 先持久化密文，再向对端广播/推送（§9）。

### 6.2 附件（图片 / 视频 / 语音）

```text
拍摄/选择 ──► 客户端加密成 blob（Attachment Key）──► 上传 Server
```

- SQLite 只保存附件元数据：storage_path、encrypted_size、**密文 sha256**、key_version。
- 实际 blob 存 Server 加密文件目录（`/data/files/`，按 id 分片）。
- 下载后解密缓存于 **App 私有目录**（加密缓存、用完清理），不写公共目录；用户明确要求时才存入系统相册。
- 附件访问必须校验：设备已认证 + 在白名单内（§2.3）。

---

## 7. 客户端架构（Flutter）

### 7.1 技术栈

| 层         | 技术                                                        |
| ---------- | ----------------------------------------------------------- |
| UI 框架    | Flutter（Dart，AOT 原生编译，无 WebView）                   |
| 加密       | `sodium_libs`（dart:ffi 绑定原生 libsodium）                |
| 安全存储   | `flutter_secure_storage`（iOS Keychain / Android Keystore） |
| 本地数据库 | `drift`（SQLite，类型安全，支持迁移）                       |
| 推送       | FCM（Android）/ APNs（iOS）+ `flutter_local_notifications`  |
| 后台       | `workmanager`（同步重试、清理）                             |
| 媒体       | `camera`（拍摄）、`image_picker`（相册）                    |

### 7.2 分层

```text
UI（页面 / 组件）
   │
   ▼
Application State（stores：space / chat / device）
   │
   ▼
Domain Services（chat / sync / crypto / media / config / push）
   │
   ▼
Persistence（SQLite / Secure Key Storage / 本地文件）
```

**共享核心（shared/）：** 加密、协议、同步状态机等**纯 Dart、不依赖 Flutter** 的代码放入 `shared/` 包，由 App 与 CLI 测试端共同依赖——保证"CLI 测的就是 App 跑的逻辑"（§7.5）。

### 7.3 客户端职责

- 生成 Device Identity Key；私钥只存 Keychain / Keystore，**永不离开设备**。
- 一次性配置：生成/导入密钥材料、登记设备公钥、导入密封 Space Key（§5）。
- 加密 / 解密消息与媒体（依赖 libsodium，密钥不落入普通内存缓存）。
- 本地 SQLite 管理、离线发送队列、同步状态跟踪。
- WebSocket 实时连接、Push 注册与处理。
- 平台差异隔离：推送、安全存储、相机、麦克风、后台任务、文件系统收敛到 `platform/` 层，业务代码跨端共享。

### 7.4 本地数据（Client SQLite）

本地消息、密文内容、附件元数据、同步状态（last_server_sequence）、草稿、本地应用状态。

### 7.5 CLI 测试端（开发工具）

V1 只做手机端；电脑端暂缓。但在开发期提供一个 **Dart CLI**（`cli/`，`dart run`，无 UI）作为测试驱动：

- 与 App 共享 `shared/` 核心代码（加解密、协议、同步逻辑），可脚本化、自动化测试。
- 充当"第二台设备"，端到端验证：一次性配置、E2EE、收发消息、离线队列、增量同步、媒体上传、撤销轮换。
- 未来可演进为正式电脑端（加 TUI/界面即用），届时再评估 Flutter 桌面端；**不做 Web 客户端**（浏览器代码由服务器下发，破坏 E2EE 信任模型，见 worklog 决策）。

---

## 8. 服务端架构

### 8.1 技术栈

| 层          | 技术                               |
| ----------- | ---------------------------------- |
| 语言/运行时 | Node.js + TypeScript               |
| HTTP / 实时 | REST + WebSocket（WSS）            |
| 数据库      | SQLite3（better-sqlite3）          |
| 文件存储    | 本地加密文件目录（`/data/files/`） |
| 反向代理    | Caddy（TLS、证书、反代）           |
| 部署        | Docker Compose（单机）             |

### 8.2 分层与职责

```text
HTTP / WSS
   │
   ▼
Routes / Gateway
   │
   ▼
Application Services
   ├── Authentication（challenge-response，白名单内公钥验证签名）
   ├── Config（加载静态白名单：两台设备公钥）
   ├── Messaging（消息持久化、广播）
   ├── Synchronization（per-space 单调序列，增量拉取）
   ├── Attachments（加密 blob 存取、白名单校验）
   ├── Push（APNs / FCM 转发，不含正文）
   └── Devices（列表、撤销）
   │
   ▼
Repositories（SQLite + File Storage）
```

### 8.3 服务端要点

- **无账号体系 + 静态白名单**：不设 username / password / email；身份 = 白名单内的 Device 公钥（由配置文件定义，§5）。认证 = 证明持有对应私钥（challenge-response）。
- **数据模型要点：**（固定两人一空间，`spaces` / `space_members` 表不再需要，由配置文件表达）

```text
config.json：{ space_id, devices: [{device_id, person_id, public_key, status}] }
messages(id, space_id, sender_device_id, type, key_version, nonce, ciphertext,
         created_at, server_sequence)   ← server_sequence 为 per-space 单调序列
attachments(id, message_id, storage_path, encrypted_size, sha256, key_version, created_at)
push_tokens(device_id, platform, token, updated_at)
sync_state(...)                          ← 客户端增量同步锚点
```

- **两条硬规则：** ① Server 先持久化消息，再广播/推送；② 任何消息、附件读取都先校验"设备已认证 + 在白名单内"。
- **防护：** 对认证、附件上传、API、WebSocket 做基本限流；日志禁止包含任何用户内容与密钥；错误响应不暴露内部实现细节（如 SQL、路径）。

---

## 9. 同步与离线

### 9.1 Local-First 数据流

```text
用户操作 → 本地 SQLite（立即生效）→ 异步同步 Server（网络恢复后补发）
```

- 网络断开不丢消息；离线发送进入本地队列，标记 `pending`，收到 Server ACK 后清除。

### 9.2 同步顺序：Server 单调序列

- 每个 Space 维护单调递增的 `server_sequence`；**不使用时间戳**作为同步顺序（设备时间可能不准、不一致、可被修改）。
- 客户端记录 `last_server_sequence`；重连后 `GET /sync?after=<seq>` 增量拉取，写入本地 SQLite。

### 9.3 实时通道

- WebSocket 用于实时消息、同步事件、投递状态；REST 用于认证、初次同步、附件上传下载、设备管理、备份（一次性配置在安装阶段完成，不走运行时 API）。
- 顺序保证：Server 先持久化，再广播（§8.3）。

---

## 10. 推送

- 目的：App 在后台/被杀时通知新消息到来。架构：Server ──► APNs（iOS）/ FCM（Android）。
- **推送永不包含消息正文**，只发"Einz 有新消息"类提示；App 收到提示后自行从 Server 拉取密文并解密。
- 设备安装/登录时注册 Push Token（`push_tokens` 表），撤销设备时移除 Token。

---

## 11. 备份与恢复

### 11.1 数据价值

Einz 的数据具有长期价值，备份是 V1 必须项。备份内容：

- Client SQLite（密文 + 元数据）
- 附件加密 blob
- 必要密钥材料（恢复码/恢复包）

备份始终保持在**加密状态**。

### 11.2 Server 备份（运维侧）

- 定期备份 `app.db`（使用 SQLite 官方 Backup API，**禁止直接复制正在写入的 db 文件**）+ 加密文件目录 + 元数据，产物落入 `/data/backups/`。
- 恢复流程必须经过演练并写入运维文档。

### 11.3 客户端备份 / 换机恢复（V1：纯本地，模型 A）

- App 内可导出**加密备份**，密钥由用户**离线保存的恢复码**派生（助记词 / 打印二维码）。
- 新设备：安装 → 输入恢复码 → 解密导入备份 → 重新生成设备身份并登记入白名单（§5 配置流程）。
- 责任边界：恢复码是"两台设备同时丢失"时的最后保险，须明确提示用户妥善保存；**Server 不接触恢复材料**。

### 11.4 预留（模型 B，Signal PIN 模式）

未来可让恢复密钥用用户口令加密后存 Server，新设备 + 口令即可恢复；V1 不实现，架构不阻塞（§4.5）。

---

## 12. 设备管理

- 客户端可查看设备列表（最后活跃时间），可**撤销**设备。
- 撤销语义：被撤销设备无法再认证、同步、发送。
- **撤销必须触发 Space Key 轮换**（§4.4），否则被撤销设备仍持有旧 Space Key。
- 撤销设备同时清除其 Push Token。

---

## 13. 分发与部署

### 13.1 客户端分发

- Android：签名 APK（`einz.apk`）。签名 Key 必须妥善保存，后续所有更新必须使用同一签名 Key。
- iOS：Ad Hoc 分发（Apple Developer 账号注册设备 UDID → 构建 → Ad Hoc Provisioning → IPA）。不使用 Enterprise Certificate，不依赖第三方非官方签名服务。

### 13.2 服务端部署

```text
Internet ──► Caddy（HTTPS/WSS、证书、反代）──► Node.js（SQLite + 加密文件）
```

- 单机 Docker Compose 管理；生产环境强制 HTTPS/WSS，禁止 HTTP/WS。
- 生产 Secret（APNs/FCM 凭证、Server secret、签名 Key 等）禁止提交 Git。

### 13.3 运行守则

- 日志禁止包含用户内容与密钥（允许：device authenticated、message sequence=123 等元数据）。
- 错误响应只返回通用信息（如 Internal Server Error），详细错误进受保护日志。
- 全部时间统一 UTC / Unix 毫秒存储，客户端负责本地化显示。

---

## 14. 路线图

### 14.1 V1 范围

**核心（必须）：**

1. 一次性人工配置（静态白名单 + Space Key 分发）
2. 设备身份认证（challenge-response）
3. E2EE（密钥层级、消息与媒体加密）
4. 文字消息
5. 图片 / 视频 / 语音消息
6. 离线发送 + 自动同步（Local-First）
7. Push Notification（不泄正文）
8. 设备管理（列表 / 撤销 / 密钥轮换）
9. 备份与恢复（模型 A：本地加密备份 + 恢复码）

**可选（V1 内按优先级）：** 共同回忆、私人笔记、纪念日 / 在一起的天数。

**开发工具：** CLI 测试端（与 App 共享 `shared/` 核心代码，用于 Phase 0–4 的协议与流程验证，§7.5）。

**明确不做（V1 非目标）：** 好友/关注/群聊/公开主页/搜索/Feed/评论点赞；支付/订阅/广告；App Store / Google Play 上架；音视频通话；一人多设备同步；动态配对/邀请（无此场景）；Web 客户端（破坏 E2EE 信任模型）；电脑端正式客户端（暂缓，V2 再评估）。

### 14.2 V2 候选（按需评估）

共享相册、日历、富笔记、位置共享、消息表情回应、贴纸、主题、一人多设备、设备间密钥迁移、搜索、语音/视频通话（WebRTC + STUN/TURN，成熟方案，不自研）、正式电脑端（CLI 加 TUI 升级，或 Flutter 桌面端）。**明确不采用 Web 客户端**（浏览器代码由服务器下发，E2EE 降级）。

### 14.3 开发阶段（估算）

| 阶段    | 内容                                                                                              | 估算    |
| ------- | ------------------------------------------------------------------------------------------------- | ------- |
| Phase 0 | 架构 + 密码学 PoC（`shared/` 核心包 + CLI 测试端，设备密钥、一次性配置、Space Key、加解密、认证） | 2–5 天  |
| Phase 1 | 消息 MVP（Server + CLI 收发验证 + SQLite/REST/WebSocket/文字/Sync/离线队列）                      | 5–10 天 |
| Phase 2 | 媒体（图/视频/语音，加密上传下载、本地缓存）                                                      | 3–7 天  |
| Phase 3 | 移动端集成（APNs/FCM、Keychain/Keystore、相机/麦克风、权限）                                      | 3–7 天  |
| Phase 4 | 加固（撤销+轮换、备份恢复、安全/离线/重启测试）                                                   | 3–7 天  |

总计约 16–36 天（有经验全栈 + AI 辅助），现实目标：4–6 周完成可长期使用的 iOS + Android MVP。若先只做文字 + 一次性配置 + E2EE + 同步，可明显更快（配置流程替代配对，进一步减少工作量）。

### 14.4 配套文档计划（编码前优先完成）

```text
docs/E2EE.md      ← 最高优先级：密钥层级、派生、一次性配置的密钥分发、轮换、恢复细节
docs/SETUP.md     ← 一次性配置手册（两台设备 + 服务器白名单的操作步骤）
docs/PROTOCOL.md  ← 协议唯一权威（REST + WebSocket 消息格式、版本化）
docs/DATABASE.md  ← 双端 SQLite schema 与迁移
docs/ARCHITECTURE.md ← 部署与运维（含备份演练）
```

理由：密钥层级一旦进入生产数据，事后修改代价极高，必须先定死。

---

## 15. ADR 关键决策记录

| #   | 决策          | 选择                                           | 理由                                                                                                                                                                          |
| --- | ------------- | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Server 数据库 | SQLite                                         | 两用户、并发极低、部署/备份/运维简单                                                                                                                                          |
| 2   | Server 语言   | Node.js + TypeScript                           | 熟悉、WebSocket 生态成熟、开发快                                                                                                                                              |
| 3   | 客户端框架    | **Flutter**（替换原 UniApp）                   | dart:ffi 直接绑原生 libsodium，无 WebView 中间层；flutter_secure_storage / drift / camera / 推送生态成熟；单代码库。原 UniApp 在 WebView 跑 WASM + 自研原生插件，安全边界最弱 |
| 4   | E2EE          | V1 即启用                                      | 避免日后明文数据与协议迁移的灾难性成本                                                                                                                                        |
| 5   | 身份          | 设备密码学身份                                 | 无账号体系，私钥不出设备；challenge-response 认证                                                                                                                             |
| 6   | 实时/请求     | REST + WebSocket 结合                          | 请求-响应用 REST，实时事件用 WS                                                                                                                                               |
| 7   | 恢复模型      | V1 纯本地（模型 A），预留托管（模型 B）        | 保持简单；密钥层级保留 B 的派生路径                                                                                                                                           |
| 8   | 多设备        | 预留，V1 一人一机                              | Person ≠ Device 分开建模，不阻塞未来                                                                                                                                          |
| 9   | 部署形态      | **固定两人一空间**（删除配对流程，静态白名单） | 只服务固定两人、不分发；服务器退化为哑转发器，砍掉约 40–50% 服务端代码                                                                                                        |
| 10  | CLI 测试端    | **Dart CLI + `shared/` 核心包**                | 与 App 共享加解密/协议/同步代码，"CLI 测的就是 App 跑的逻辑"；无 UI 可脚本化，作为 Phase 0–4 的测试驱动；未来可升级为正式电脑端                                               |

---

## 16. Open Questions（待评审）

- [ ] 一次性配置的具体操作形式：命令行工具 / 配置界面 / 二维码，及其产物格式（→ SETUP.md）。
- [ ] 消息删除语义：本地删 / 双方删 / 服务端删 的具体规则（V1 先定义清楚再实现）。
- [ ] 已读回执的粒度（sent / delivered / read）与展示方式。
- [ ] 模型 B（托管恢复）的密钥派生路径细节（仅设计预留，不实现）。
- [ ] 一人多设备时，新设备加入的"可信设备作保"流程（V2 前再定，§5.3）。
- [ ] 音视频通话的 WebRTC 方案选型（V2 再评估）。

---

## 17. 禁止清单

- 禁止 Server 保存消息明文。
- 禁止 Server 保存任何 Private Key。
- 禁止使用密码直接作为 Encryption Key。
- 禁止自己实现加密算法或自定义 construction（只用 libsodium 标准原语）。
- 禁止把媒体明文放进公共存储。
- 禁止在 Push Notification 中发送消息正文。
- 禁止相信客户端自报的 Space 成员资格（服务端按白名单校验，§2.3）。
- 禁止只靠 UI 限制"两个人"（服务端静态白名单强制）。
- 禁止直接复制正在运行的 SQLite 文件作为备份（用官方 Backup API）。
- 禁止使用 iOS Enterprise Certificate 做私有分发。
