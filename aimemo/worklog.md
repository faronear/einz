# Einz — 工作日志（worklog）

> 事件视角：按时间线记录工作过程与重要变化。持续追加，不覆写历史。

---

## 2026-08-28

### 架构评审与 productLens 重构（v1.0 → v2.0）

**背景：** 老板要求评估 `aimemo/productLens.zhcn.md`（原 2164 行 Draft v1.0），继续讨论 Einz 架构，允许大幅删改。

**评审发现：**

- 方向正确（E2EE 从 V1 开始、Server 只存密文、设备密码学身份、Local-First、两人约束服务端强制），骨架保留。
- 形式问题：大量重复（E2EE 流程图出现 3+ 次）、Markdown 标题/表格损坏（§2.2 起大量小节标题丢失 `##`）、文件末尾残留多余代码块、命名不一致（Only Space / Einz / private-space）。
- 架构空白：① 密钥层级与恢复模型未定义（丢机/换机如何恢复）；② 设备撤销后未定义 Space Key 轮换；③ 配对握手顺序未定死；④ 消息 schema 缺 nonce/key_version；⑤ server_sequence 作用域未明确（应为 per-space）。

**老板决策（2026-08-28）：**

| 决策点 | 结论 |
| --- | --- |
| 恢复模型 | V1 纯本地备份+恢复码（模型 A），架构预留服务器托管（模型 B） |
| 多设备 | Person≠Device 分开建模，V1 一人一机，预留扩展 |
| 技术栈 | **放弃 UniApp**，改用 **Flutter**（dart:ffi 绑原生 libsodium，无 WebView 中间层；flutter_secure_storage / drift / camera 生态成熟） |
| 文档 | 确认按新结构大幅重写，统一命名 Einz |

**产出：**

- `aimemo/productLens.zhcn.md` 重写为 Draft v2.0（2164 行 → ~520 行，17 章，每个事实只写一次；详细规格下沉至 docs/ 专项文档）。
- 初始化 `aimemo/projectPlan.md`（5 阶段计划）、`aimemo/worklog.md`（本文件）、`aimemo/userProfile.md`。
- 2026-08-28 老板决定将记忆目录统一为 `aimemo/`（实际目录已从 `memo/` 改名，文中引用同步更新）。

**遗留事项：**

- ~~AGENTS.md 中记忆目录写的是 `@aimemo/`，实际目录为 `memo/`~~ —— 已统一为 `aimemo/`（老板决定，见上文）。
- 编码前优先完成 `docs/E2EE.md`（密钥层级一旦进生产数据，事后修改代价极高）。

### 第二轮：部署形态确定"固定两人一空间"（v2.0 → v2.1）

**背景：** 对话式讲解架构（E2EE 全称、密钥层级、无账号多设备、配对流程）后，老板补充关键前提：**应用只给自己和另一个人用，不分发，整个系统永远只有一个 Space**。

**讨论结论：**

- 砍掉"产品化通用层"，保留"可靠性核心层"：配对流程整体删除，改为**一次性人工配置**；服务器退化为**静态白名单哑转发器**（只认 config.json 里两台设备的公钥）；`spaces` / `space_members` 表删除，由配置文件表达。
- 不可砍：E2EE 密钥层级（自己就是服务器管理员，E2EE 才是灵魂）、Local-First、同步序列、加密附件、推送、备份恢复、TLS。
- 明确不做无服务器方案（WebRTC 直连）：异步消息、离线补发、历史同步、推送都需要存储转发。
- 量化：服务端代码砍约 40–50%，客户端砍约 15–20%，配对/邀请类测试全部删除。

**老板决策（第二轮）：**

| 决策点 | 结论 |
| --- | --- |
| 配对方案 | **一次性人工配置**（静态白名单，删除配对流程） |
| 多设备预留 | **保留**（Person≠Device 建模不变，V1 一人一机） |
| 文档更新 | 先 commit 当前状态，再更新文档 |

**产出：**

- 初始化 git 仓库，首次提交 `c6f4bfd`（目录改名 + 文档重写）。
- `aimemo/productLens.zhcn.md` 更新至 v2.1：§1.1 部署形态前提、§2.3 静态白名单、§3.2 威胁表收窄、§5 改"一次性人工配置"、§8.2/8.3 服务端哑化（config.json 白名单）、§14/15/16/17 同步更新。
- `aimemo/projectPlan.md` 同步：Phase 0 增加 `docs/SETUP.md` 与一次性配置工具任务，删除配对任务。

### 第三轮：Web/电脑端探讨与 CLI 测试端决策

**背景：** 老板询问"Flutter 能否支持 Web 客户端"，展开客户端形态讨论。

**讨论结论：**

- Flutter 技术上支持 Web（WASM+JS），但 **Web 会破坏 E2EE 核心信任模型**：浏览器每次从服务器下载代码，服务器被攻破即可注入恶意代码读取明文/密钥，E2EE 降级为"传输加密 + 服务器诚实"。这是所有 Web E2EE（WhatsApp/Telegram/Signal Web）的固有缺陷。
- 若需求是"在电脑上用"，**Flutter 桌面端**优于 Web：dart:ffi + `sodium_libs` + 系统 Keychain 全可用，几乎零额外适配。
- 老板真实需求：电脑端需要但可后置，**先用 CLI 验证功能与流程**（无 UI，可脚本化）。

**老板决策（第三轮）：**

| 决策点 | 结论 |
| --- | --- |
| Web 客户端 | **不做**（破坏 E2EE 信任模型，明确写入非目标） |
| 电脑端 | 暂缓（V2 再评估：CLI 加 TUI 升级，或 Flutter 桌面端） |
| CLI 测试端 | **Dart CLI + `shared/` 核心包**，Phase 0–4 作为测试驱动 |

**产出：**

- `aimemo/productLens.zhcn.md`：补回 §7.2 共享核心（shared/）、新增 §7.5 CLI 测试端、§14.1 开发工具与非目标、§14.2 V2 候选（明确不采用 Web）、§14.3 Phase 0/1 含 CLI、§15 ADR 第 10 条。
- `aimemo/projectPlan.md`：monorepo 骨架增加 `cli/` 与 `shared/`，Phase 0 增加 shared 核心包与 CLI 任务，Phase 1 增加 CLI 双端收发验证与自动化测试脚本。
- 提交：`86ea7d1`（第二轮）后，本轮修改待提交。

### Phase 0 启动：设计文档 + Server 先行（待装 Dart SDK）

**决策：** 前向保密采用 **A. 简单派生**（Space Key → 每消息派生 Message Key，不做双棘轮；代价=Space Key 泄露则历史可解，已接受）。环境检查：Node 22 ✅ / Dart ❌ / Flutter ❌。老板决定**暂不装 Dart，先做 Server**。

**产出（Server 先行阶段，待提交）：**

- `docs/`：`E2EE.md`（11 章：密钥层级/派生/配置分发/认证/轮换/恢复/决策记录）、`PROTOCOL.md`（11 章：REST/同步/附件/设备/推送/WS/错误/限流/版本）、`DATABASE.md`（双端 schema+迁移）、`SETUP.md`（一次性配置手册）。
- `server/`：Node+TS 实现——静态白名单 config.json、challenge-response 认证、消息持久化（server_sequence 幂等）、增量同步、加密附件存取、设备撤销、推送占位、WebSocket 网关（hello/message.new/ping 心跳）。
- `server/test/smoke.test.ts` 冒烟测试**全部通过**：白名单 403 / 认证 / E2EE 密文 / 幂等 / 同步 / **明文隔离（响应与 DB 均无明文）** / WS 实时。
- 踩坑记录：libsodium-wrappers 的 ESM 入口在 Node ESM 下损坏（缺 libsodium.mjs）→ 用 `createRequire` 强制 CJS 构建；测试客户端 envelope 的 v/key_version 必须为 number（与 Server 校验一致）。
- `deployment/`：docker-compose（server + Caddy）+ Caddyfile + server/Dockerfile（node:22-slim，better-sqlite3 原生模块避免 Alpine）。
- monorepo 骨架：`shared/`、`cli/` pubspec 已建（未装 Dart 未验证）；`app/` 占位。

**遗留：** Dart SDK 安装后继续 shared 核心包 → CLI → 一次性配置工具 → 端到端验收（任务 #12–#15）。

### Phase 0 客户端完成：shared 核心包 + CLI + 端到端验收（Dart 3.11 已装）

**背景：** Server 先行阶段提交后，老板选择"装 Dart 继续 Phase 0"。安装 Dart SDK 3.11.0（brew install dart-sdk，注意公式名为 dart-sdk 而非 dart）。

**产出（全部验证通过）：**

- `shared/`：纯 Dart 核心包——`sodium.dart`（跨平台加载 libsodium：`LIBSODIUM_PATH` env / macOS Homebrew 路径）、`keys.dart`（DeviceKeyPair / seal/sealOpen / 派生）、`message_crypto.dart`（MessageEnvelope + XChaCha20-Poly1305 加解密 + AAD 绑定）、`attachment_crypto.dart`、`protocol/types.dart`、`sync/sync_state.dart`。`dart analyze` 无警告，8 项单元测试全过（密封闭环 / 错误私钥 / 加密解密 / 派生确定性 / AAD 绑定 / 附件 / 配置产物 / 同步锚点）。
- `cli/`：Dart CLI 测试端（bin/onlyspace.dart）——`init` / `pubkey` / `config`（生成 Space Key + 密封双方 + 产出服务器 config.json）/ `import` / `auth` / `send` / `sync`。`dart analyze` 无警告。
- `cli/test/e2e.sh`：**端到端验收全部通过**——init(A/B) → config → import → 启动 Server → 双端认证 → A 发密文 → B 同步解密出明文 → DB 明文隔离检查 → 白名单外 403。
- `docs/PROTOCOL.md`：补充 §8.1 WS token 必须 URL 编码（session_token 为标准 base64 含 +/=）。

**关键踩坑（跨语言互通）：**

1. **base64 变体不兼容（500 INTERNAL）**：Dart `base64Encode` 输出标准 base64（带 `=` 填充），而 libsodium-wrappers 默认变体是 URL-safe 无填充 → `from_base64` 报 "incomplete input"。修复：Server `crypto.ts` 与冒烟测试统一显式使用 `sodium.base64_variants.ORIGINAL`。
2. **WS token URL 编码**：session_token 含 `+`/`=`，直接拼进 `wss://...?token=` 被查询串解析破坏 → 必须 `encodeURIComponent`。
3. **sync 响应缺 `v` 字段**：`v` 是协议常量未入库，`/sync` 需补齐 `v:1`（PROTOCOL.md §5.2），否则 Dart 客户端解析崩溃。

**遗留：** 任务 #16 Flutter app/ 骨架待装 Flutter SDK。

### 跨机器交接（老板换电脑继续）

**背景：** 本机安装 Flutter 因**磁盘空间不足**失败（数据卷 199/228 GiB，仅剩 5.8GiB；Flutter 需 6–7GiB+）。Google storage 与 GitHub 均不可达，Flutter 中国镜像（storage.flutter-io.cn）可用且已下载 2.0GB SDK 包，但解压时磁盘写满。老板决定**换一台电脑继续安装 Flutter**。

**交接动作：**

- 确认 git：工作树干净，5 个提交（HEAD `ece01e8`），**无远程仓库**。
- 产出 `docs/HANDOFF.md`：仓库搬运方式（git bundle / 建远程）、新电脑环境依赖表（Node 22 / Dart SDK 3.11 / libsodium / Flutter 镜像安装）、Phase 0 完成状态与验证命令、续接步骤（#16 Flutter app/ 骨架 → Phase 1）、已知踩坑备忘（base64 ORIGINAL 变体、WS token URL 编码、sync 补 v 字段、LIBSODIUM_PATH、libsodium-wrappers ESM 坑）。
- 生成 `onlyspace.bundle`（单文件全历史，便于跨机搬运）。
- 任务状态：**#16 保持待办**（新电脑装 Flutter 后完成），其余 Phase 0 任务全部完成。

**待新电脑确认环境后：** 运行 HANDOFF.md §4 的验证命令 → 完成任务 #16 → 进入 Phase 1 消息 MVP。

### 跨机器续接完成（Windows：环境安装 + 全量验证 + #16 app 骨架）

**背景：** 按 `docs/HANDOFF.md` 在 Windows 新机器续接。本机环境：Node v20.20.0（手册要求 ≥22，实测冒烟全过）、Dart / Flutter / libsodium 均未装。

**环境安装（Windows 途径）：**

- Dart SDK 3.12.2（stable）：winget 无 Dart 包，改为中国镜像下载 zip → 解压至 `D:\devtools\dart-sdk\dart-sdk`，用户 PATH 已加。
- libsodium：`download.libsodium.org` 的 msvc 包（Win64 Release v143 dynamic libsodium.dll）→ `D:\devtools\libsodium\...`，测试需设 `LIBSODIUM_PATH` 指向该 DLL（对应 HANDOFF 踩坑 #4）。
- Flutter 3.47.2（stable，2026-08-26）：中国镜像 `storage.flutter-io.cn` 下载 `flutter_windows_3.47.2-stable.zip`（1.8GB）→ `D:\devtools\flutter\flutter`，用户 PATH 已加。

**验证与修复（HANDOFF §4 全流程跑通）：**

- server：`npm install && npm run build && npm test` ✅ 冒烟全过。**修复 Windows EBUSY**：测试 finally 中 `kill` 后立刻 `rmSync` 会撞上未释放的 app.db 句柄 → 改为等子进程退出（3s 超时强杀）+ 重试清理（`server/test/smoke.test.ts`）。
- shared：`dart analyze` 无警告 + 8 项单测全过（设 LIBSODIUM_PATH 后）。
- cli：`dart analyze` 无警告 + `e2e.sh` 全过。**修复两处 Windows 问题**：① 内嵌 `node -e` 脚本里的 POSIX 路径（`/d/...`、`/tmp/...`）Windows Node 无法解析——MSYS 只自动转换环境变量与纯路径参数，脚本字符串不转换 → 用 `cygpath -m` 显式转 Windows 格式；② cleanup 的 `rm -rf` 同样遇 EBUSY → 加重试。
- 恢复 `cli/test/e2e.sh` 可执行位（跨机器拷贝时 755→644 丢失）。

**任务 #16 完成（Flutter app/ 骨架）：**

- `flutter create . --platforms=ios,android --project-name onlyspace`（在 `app/` 内，Flutter 3.47.2）。
- `app/pubspec.yaml` 接入 `einz_shared: path: ../shared`。
- `app/lib/main.dart` 重写为 Einz 首屏骨架：接入 shared 的 `DeviceKeyPair.generate()` 作为"生成设备密钥"自检入口（libsodium 懒加载，测试不触发）。
- `app/test/widget_test.dart` 改为骨架首屏渲染测试。
- **顺手补移动端加载分支**：`shared/src/sodium.dart` 增加 Android `libsodium.so` / iOS `libsodium.dylib` 候选（此前只有 macOS/Linux/Windows，真机必然加载失败；原生库打包归 Phase 3）。
- 验证：`dart analyze` 无警告（注：`flutter analyze` 的 analysis server 在含中文的路径下 LSP 通信报错，改用 `dart analyze` 绕过）、`flutter test` 全过、shared 回归 8 项全过。

**遗留：** `flutter analyze` 在中文路径下的 LSP 异常待查（不阻塞开发）；Phase 1 消息 MVP 为下一步。`onlyspace.bundle`（96K 交接产物）未入库，HANDOFF 完成后可删。

### Phase 1 消息 MVP：离线队列 + 自动同步 + WS 实时（CLI 测试端）

**背景：** 老板确认删除 `onlyspace.bundle`（交接产物，删除后工作树干净），继续 Phase 1。探索结论：**server 已满足 Phase 1 全部契约**（`/sync` 分页 + has_more、WS message.new 广播、message_id 幂等），改动集中在 CLI 测试端。

**实现（`cli/`，全部 `dart analyze` 无警告）：**

- `lib/store.dart` 扩展：**pending 离线发送队列**（MessageEnvelope JSON 落盘，幂等入队/出队）+ **history 本地消息历史**（按 message_id 幂等 upsert，seq 升序展示）+ `advanceAnchor`（锚点只前进不倒退，与 shared SyncState 语义一致）。
- `bin/onlyspace.dart`：
  - `send`：**先入队再尝试立即发送**——离线时（server 不可达/无 session）消息留队不丢；`--server` 可省略（纯离线模式）。
  - `_flushPending`：补发队列，成功一条出队一条 + 写历史 + 推进锚点；网络失败停止本轮留队。
  - `sync`：**has_more 翻页拉全量**（`_syncIncremental`）→ 落盘历史 → 推进锚点 → 补发队列；`--after` 默认取本地锚点。
  - `listen`（新命令）：WS 实时接收 `message.new`，实时落盘 + 解密打印；断线 2s 自动重连，重连前先 `/sync` 补齐 + 补发（PROTOCOL §8.3 语义：WS 只是实时加速，不依赖它保证不丢）。
- `test/phase1_e2e.sh`（新）：**Phase 1 自动化验收全过**——停 Server 模拟离线 → A 发 3 条全部留队（队列=3）→ 重启 Server → A sync 自动补发（补发=3 队列剩余=0）→ B sync 收到 3 条**无重复无乱序**（seq 升序）→ 二次 sync 新增=0（幂等）→ B listen WS 实时收到新消息。

**踩坑（Windows / Git Bash）：** ① `(cmd) &` 的 `$!` 是 subshell PID，`kill` 只杀 bash 外壳、node 变孤儿继续跑（"离线"不生效）→ `start_server` 改用 `exec env ...` 使 `$!` 直接是 node 进程；② Windows 原生 python 不认 `/tmp/...` MSYS 路径 → 脚本里用 `cygpath -m` 转换。

**验证：** server 冒烟全过、shared 8 单测全过、cli analyze 无警告、`e2e.sh`（Phase 0 回归）与 `phase1_e2e.sh` 双双通过。

**Phase 1 剩余：** drift 客户端 SQLite 入库（DATABASE.md §3 local_messages/sync_state）留待移动端集成（Phase 3）时随 app 一起做——CLI 测试端已用 JSON 落盘等价验证了状态机。

### Phase 2 媒体：附件加密上传/下载/解密闭环（CLI 测试端）

**背景：** 老板确认继续 Phase 2 媒体。探索结论：server 的附件存储（attachments.ts）与 shared 的附件加密（attachment_crypto.dart）骨架已在 Phase 0 建好，差距在**协议对齐 + CLI 端命令 + 消息↔附件关联**。

**修复的协议偏差（实现与文档对齐）：**

1. **sha256 编码不统一（500/sha256 mismatch）**：server 用 Node `digest("base64")`，而 shared/CLI 用 hex `toString()` → 统一为 **base64(32B)**（PROTOCOL.md §6.1）。同时把 E2EE.md §6.1 的"BLAKE2b-256"更正为 SHA-256（实现即 SHA-256，文档写错）。
2. **附件 AAD 未绑定空间上下文**：shared 原实现 AAD 只有 `"onlyspace-v1-a"+attachment_id`，与 E2EE.md §6.1（须绑定 space_id + key_version）不符 → 补上 `spaceId`/`keyVersion` 参数，AAD = `"onlyspace-v1"+space_id+attachment_id+key_version`，并新增"换 space_id 无法解密"单测。

**实现（`shared/` + `server/` + `cli/`）：**

- shared `attachment_crypto.dart`：`encryptAttachment` 返回密文+nonce+**sha256(base64)**+size；加解密均绑定 space_id/key_version；新增 `crypto` 依赖。9 项单测全过（新增 AAD 绑定测试）。
- server `messages.ts`：`/sync` 响应补 **`attachments_meta`**（随本页消息返回附件元数据，PROTOCOL.md §5.2；复用 attachments.ts 的 `attachmentsForMessages`）。
- cli：
  - `client.dart`：`postAttachment`（x-attachment-meta 头 + 密文 blob）、`getAttachment`（下载密文）；`sync` 返回 `attachmentsMeta`。
  - `store.dart`：附件元数据存储（`upsertAttachment`/`attachmentMeta`，幂等）。
  - `onlyspace.dart`：**`attach`** 命令（加密文件 → 先发附件消息 type=image/video/voice → 再上传 blob，类型按扩展名推断）；**`fetch`** 命令（下载 → 校验 sha256 → 解密 → 写本地文件，防传输损坏）。
- `test/phase2_e2e.sh`（新）：**验收全过**——A attach 上传含明文字符串的测试文件 → **明文隔离检查**（attachments 表与 files/ blob 均无明文）→ B sync 收到消息 + attachments_meta 落盘 → B fetch 下载解密 → **与原文件逐字节一致**（cmp）。

**验证：** server 冒烟全过、shared 9 单测全过、cli analyze 无警告、三个 e2e 脚本（Phase 0/1/2）全部通过（回归无破坏）。

**Phase 2 剩余：** 附件分片上传、本地解密缓存目录管理（App 私有目录）留待移动端集成（Phase 3）。

### Phase 3 移动端集成（Windows：工具链 + drift 本地库 + 签名 APK；iOS 跳过）

**范围确认（老板决策）：** ① 安装 Android 工具链做完整签名 APK 构建；② 推送**不接 FCM**（FCM 在中国大陆不可达，与产品定位矛盾）→ 决策 **WS 兜底 + Server 推送占位**（APNs 大陆可用，留待 iOS 上线；厂商推送需各家开发者账号，暂不接）；③ **iOS 明确跳过**（Windows 无 Xcode，APNs/Ad Hoc 留待 Mac 环境）。

**环境安装（Windows，中国镜像）：**

- JDK 17.0.20.1（Temurin，清华 Adoptium 镜像）→ `D:\devtools\jdk`，JAVA_HOME 已设。
- Android SDK：cmdline-tools（dl.google.com 可达）+ platform-tools + platforms;android-35/36 + build-tools;35.0.0 + NDK/CMake → `D:\Android\Sdk`，ANDROID_HOME 已设，flutter doctor 全绿。

**实现：**

- `shared/`：**ApiClient 从 cli 上移 shared**（`src/protocol/api_client.dart`，App/CLI 共用），cli/client.dart 改为 re-export。
- `app/`：
  - `data/local_database.dart`：**drift SQLite 本地库**（DATABASE.md §3：local_messages / local_attachments / sync_state / drafts / app_state），build_runner 生成（**踩坑：build_runner 的 AOT 编译在中文路径写入失败 → 用 `--force-jit`**；`library;` 指令必须在 import 之前）。
  - `data/message_repository.dart`：**MessageRepository**（发送=加密→落库 pending→尝试上传；同步=has_more 翻页→落库→推进锚点→补发队列；历史=解密展示），把 Phase 1 的 CLI 状态机完整搬到 drift 上。**6 项单测全过**（离线入队/在线发送/翻页同步/补发无重复/锚点不倒退/widget 骨架）。
  - Android：Manifest 声明 INTERNET/CAMERA/RECORD_AUDIO（uses-feature 非必需）；keystore（D:\devtools\android-keystore，不入库）+ key.properties（app/android/，.gitignore 忽略）+ build.gradle.kts 签名配置（无 key.properties 时回退 debug 签名）。

**APK 构建（Phase 3 关键验证）与中文路径大坑：**

- 中文路径（`product-产品`）导致 Flutter AOT 工具链全线失败：`flutter analyze` LSP 崩、build_runner AOT 写入失败、**`gen_snapshot` 读 app.dill 时路径乱码**、Gradle 的 `libdartjni.so` "expected output but none"（文件其实已生成）。尝试 `chcp 65001`、8.3 短路径（`PRODUC~1`）、junction（`D:\only-build`）**均无效**——flutter.bat 内部解析回真实中文路径。
- **解决方案（老板批准外部临时构建）**：复制仓库到纯 ASCII 路径 `D:\build-onlyspace` 构建 → `flutter build apk --release` 成功产出 **50MB app-release.apk** → apksigner 验证签名（CN=Einz）→ 产物拷回 `app/build/` → 删除临时目录。
- 其余踩坑：Gradle 9.3.1 distribution 从 services.gradle.org 下载失败 → 腾讯云镜像；`android.overridePathCheck=true` 放行非 ASCII 路径；build.gradle.kts 需 `import java.util.Properties`（Kotlin DSL）。

**验证（全部通过）：** server 冒烟、shared 9 单测、cli analyze + 三 e2e 脚本回归、app dart analyze + flutter test 6 项、签名 APK 构建。

**遗留：** 真机验证（权限流/WS 长连接/后台保活）待 Android 真机；iOS（Info.plist 权限声明、APNs、Ad Hoc）留待 Mac 环境；`flutter analyze`/`flutter build` 在中文路径的已知缺陷 → 老板已决定以后迁移到无中文路径。

### Phase 4 加固：设备撤销/密钥轮换 + 备份恢复 + 安全韧性测试

**背景：** 老板确认继续 Phase 4 加固。探索结论：撤销路由（devices.ts + notifyRevoked）已在 Phase 0 建好，但 **key.rotation WS 通知未接**（app.ts 注释明说留到 Phase 4）、shared 无 pwhash/备份封装、Server 无备份脚本。

**shared（新增 2 文件 + 4 单测，13 项全过）：**

- `src/crypto/backup.dart`：恢复码（12 词助记词表）+ `deriveBackupKey`（**Argon2id**，`sodium_sumo` 的 pwhash——注意普通 `sodium()` 实例的 pwhash 被 deprecated，须用 `SodiumSumoInit.init2`）+ `encryptBackup/decryptBackup`（XChaCha20-Poly1305，文件头 {format, salt, nonce, ciphertext}，E2EE.md §10）。**踩坑：** 初版 encryptBackup 由调用方传 backupKey、内部另生成 salt 导致解密密钥不匹配 → 改为内部统一生成 salt 派生密钥。
- `src/crypto/keyring.dart`：`SpaceKeyRing`（current + archived 归档结构，E2EE.md §9.2），`rotate()` 递增 key_version 并归档旧密钥，`keyForVersion()` 按版本取密钥。

**Server（备份 + 撤销感知修复）：**

- `src/backup.ts` + `scripts/backup.ts` / `scripts/restore.ts`（npm run backup/restore）：**SQLite 官方 Backup API** 在线备份 app.db（读写中可安全备份）+ files/ + config.json → **AES-256-GCM 加密归档**到 backups/（密钥 EINZ_BACKUP_KEY，base64 32B）。**演练通过**：产生 2 条消息 → 备份（verify 校验）→ 删 app.db → restore → 重启 server → B 同步出全部消息。
- **发现并修复撤销不生效的 bug**：`isActiveDevice` 原来只查静态 config.json，撤销只改数据库 → 被撤销设备仍能认证。修复：① server 启动时 `syncWhitelistToDb` 把白名单登记进 devices 表（INSERT OR IGNORE，撤销状态不被覆盖）；② `isActiveDevice` 叠加数据库 status 校验（revoked 即拒）。**同时修正 key.rotation 通知方向**：应发给"除被撤销设备外"的剩余设备（含撤销发起者），不是排除发起者。

**CLI（撤销/轮换/备份/历史命令）：**

- `rotate` 命令：当前 Space Key 归档（key_version+1）+ 新密钥 seal 给对方（E2EE.md §9.1）；`import` 支持 `--key-version`（轮换导入自动归档旧密钥）；`history` 命令：本地历史按 key_version 选密钥解密（归档 v1 解旧消息、当前 v2 解新消息）；`backup/restore` 命令；listen 处理 `key.rotation` / `device.revoked` 帧。
- **发现并修复 key_version 未传递 bug**：`send` 调 encryptMessage 未传 keyVersion（默认 1）→ 轮换后新消息仍标 v1、解密错拿归档密钥 → 补 `keyVersion: store.keyVersion`。
- `test/phase4_e2e.sh`（新）：**验收全过**——段 A：撤销 B → A 收 key.rotation 通知 → B 认证 403 / sync 401；段 B：A 轮换（v1→v2 归档）→ history 双版本解密成功；段 C：离线入队→恢复补发（回归）；段 D：服务重启后 sync 正常 + 本地历史完好；段 E：白名单外 403；段 F：篡改检测（shared 单测 AAD 绑定 + fetch sha256 校验覆盖）。

**验证（全部通过）：** server 冒烟、shared 13 单测、cli analyze 无警告、四个 e2e 脚本（Phase 0/1/2/4）全部通过。

**遗留：** 备份加密密钥（EINZ_BACKUP_KEY）的保管与轮换策略待部署文档明确；附件解密缓存清理策略；真机/iOS 待环境（同 Phase 3 遗留）。

### V1 发布前代码审查（deep+verify，全项目 c6f4bfd..134d4b4）+ 24 项发现修复

**背景：** 老板确认做 V1 发布前代码审查/安全检查。code_review 工具（deep+verify，10 提交/124 文件/+13844 行）产出 **24 项发现**（dedup 后），老板确认**全修（P1+P2+P3）**。

**P1 修复（路径遍历，2 项同根因）：**

- `server/src/attachments.ts`：`attachment_id` 来自客户端 `x-attachment-meta` 头且无校验，直接拼进存储路径 → 白名单内失陷设备可写/读服务器任意文件（容器 root 运行）。修复：`assertSafeId`（仅允许 hex+连字符 8–64 位，拒绝 `/ . \`）+ `assertInsideFilesRoot`（resolve 后必须位于 FILES_ROOT 内），**storeAttachment 与 getAttachmentBlob 读写双侧生效**。**踩坑：** 初版 root 用 `"/"` 拼接，Windows 上 `resolve()` 返回 `\` 导致误判 phase2 附件上传失败 → 改用平台 `sep`。

**P2 修复（5 项）：**

| 发现 | 修复 |
| --- | --- |
| 撤销后不关闭被撤销设备的 WS | `notifyRevoked` 发帧后 `close(4403)` + 移出 conns（否则 revoked 设备继续收新消息解密） |
| app `_uuidv7` 时间戳伪随机 + 格式非法 | 改 `Random.secure()` CSPRNG + 正确 8-4-4-4-12 UUIDv7 |
| `MessageRepository.history()` 固定密钥解密 | 注入 `archivedKeys`（key_version→密钥），按 `env.keyVersion` 选密钥（对齐 CLI `spaceKeyForVersion`）；缺密钥时抛明确 StateError |
| 发送推进锚点跳过未同步历史 | **锚点只在 /sync 响应推进**：`_markSent`/CLI `_flushPending` 不再推进（PROTOCOL.md §5.2），避免新设备未同步先发消息 → 对方历史被永久跳过 |
| `x-attachment-meta` 缺失/坏 JSON → 500 | 显式校验 → 400 INVALID_REQUEST（协议 §9） |

**P3 修复（3 项）：** `decryptMessage` 移除死参数 keyVersion（AAD 用 env.keyVersion，误导调用方；全部调用方同步更新）；历史排序 null-last（未同步排最后，app + CLI store 双修）；Gradle 腾讯云镜像加 `distributionSha256Sum`（官方 9.3.1-all checksum，防供应链）；顺带 main.dart `_generateDeviceKey` 加 mounted 检查（防 setState-after-dispose）。

**回归验证（全部通过）：** server 冒烟、shared 13 单测、cli analyze、**四个 e2e 脚本**（e2e/phase1/phase2/phase4）、app flutter test 6 项。phase4 段 D 断言随锚点语义更新（重启后 sync 拉待同步数据 + 本地历史完好）；app 两处单测断言更新（send/补发不推进锚点）。

**遗留：** 审查未覆盖的浅层项（UI 细节、性能微优化）未列；Gradle 正式环境建议改回 services.gradle.org 官方地址（当前腾讯云镜像 + checksum 锁定）。

### 部署手册（docs/DEPLOYMENT.md）+ 试用指引

**背景：** V1 审查修复完成后，老板要求整理部署手册并指导试用。

**产出：**

- `docs/DEPLOYMENT.md`（v1.0，命令全部本机实测）：§1 部署形态速览 → §2 **本机 5 分钟快速试用**（init/config/import/auth/send/sync/listen/attach/fetch + CLI 命令总览表）→ §3 生产部署（Docker Compose + Caddy，含 `EINZ_BACKUP_KEY` 注入与验证）→ §4 一次性配置命令级实作（替代 SETUP.md "[待开发]" 标注）→ §5 运维（Server 备份/恢复、客户端恢复码、撤销+轮换）→ §6 安全边界清单 → §7 故障排查 → §8 验收清单。
- `README.md`：设计文档表加 DEPLOYMENT.md 链接；SETUP.md 标注改为"设计稿，命令级实作见 DEPLOYMENT.md"。
- **验证**：按手册 §2 命令链完整跑通（init/config/import → 启动 server → auth 双端 → send → B sync 解出明文 → B listen 实时收到 → history 2 条完整）。**踩坑记录：** ① 跨 bash 会话的后台 server 会被清理 → 验证需单会话内完成；② server 须在 config.json 生成**之后**启动（否则 loadConfig 失败退出）。

**遗留：** docker-compose.yml 未预置 EINZ_BACKUP_KEY（部署时注入）；生产环境建议按手册 §3 补 environment；App 真机验证仍待环境。

### 正式部署完成（2026-08-28，only.tic.cc）

老板按 DEPLOYMENT.md 分步部署（8 步全通）：VPS + Docker Compose + Caddy（TLS 自动签发）→ CLI 生成白名单 config.json（dev-a1/dev-b1）→ 上传 `/opt/onlyspace` → 注入 EINZ_BACKUP_KEY（.env）→ `docker compose up -d --build` → 验证 HTTPS/403 → CLI 远程双端认证收发闭环（B 同步解出明文）。

**踩坑：** 部署教学中第 3 步漏了 B 的 `import`（sealed-b.txt 导入）——A 生成 Space Key 后 B 必须导入才有密钥解密；auth 只需身份密钥所以能过，sync 需要 Space Key 才报"设备尚未导入 Space Key"。已补。

**部署事实：** 域名 only.tic.cc；服务器 /opt/onlyspace；白名单 deployment/config/config.json；备份密钥 deployment/.env；本地设备 store 在 C:\deploy\{a,b}.json，sealed-b.txt 待交给对方。

**运维提醒：** ① 备份密钥（.env）务必留档；② 每日 `npm run backup`（cron）；③ 对方设备导入 sealed-b.txt + b.json 后即可互聊；④ App 真机验证仍待环境。

### App 真机版：最小可用 UI + libsodium Android 集成 + 签名 APK（2026-08-29）

老板选择"装 App 到真机"。调研：app 原为 Phase 0 骨架（仅密钥自检页），MessageRepository 已实现但未被 UI 使用；签名配置完好（keystore + key.properties）。

**补齐最小可用 UI（app/lib/）：**

- `setup_page.dart`：一次性配置页（设备 ID/服务器/space_id 输入 → 生成设备密钥展示公钥 → 粘贴 sealed 副本 → challenge-response 认证 → 进聊天页）
- `chat_page.dart`：聊天页（MessageRepository 历史/发送 + 每 3 秒轮询 sync 准实时；正式版换 WS listen）
- `main.dart` 入口改为 SetupPage；widget_test 更新匹配新 UI（6 项测试全过）

**关键坑（libsodium Android 集成）：**

- shared 的 loadDynamicLibrary Android 分支 `open('libsodium.so')`，需要 APK 自带 .so
- 尝试 `sodium_libs ^2.2.1+6`（sodium 官方推荐 Flutter 加载方式）→ **工具链不兼容**：该包用 AGP 7.3.0 + Kotlin 1.7.10 + compileSdk 33（Built-in Kotlin 迁移失败 + AAR metadata 15 项不兼容），补丁 compileSdk 也无法绕过 Kotlin 编译 → 放弃
- 尝试 NDK 交叉编译 libsodium（Git Bash 下 configure 失败）→ 放弃
- **最终方案**：直接从 sodium_libs 包提取预编译的 `android/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}/libsodium.so` 拷入 app jniLibs（绕开其 Gradle 插件），移除 sodium_libs 依赖 → 构建成功

**CLI 补 seal 命令**：`seal --store <s> --peer-pubkey <b64> --out <f>`——用本机 Space Key 密封给新设备公钥（App 真机一次性配置需要"对 App 公钥的 sealed 副本"，原 CLI 无此命令），实测通过。

**构建与验证：** 外部临时构建（D:\build-onlyspace，规避中文路径，JAVA_HOME 需指到 jdk-17.0.20.1+1 子目录）→ `flutter build apk --release` 成功（55.0MB）→ apksigner 验证签名 **CN=Einz** ✅ → 产物拷回 `app/build/app-release.apk`，jniLibs/pubspec 同步回源仓库。

**真机首次使用流程（待老板执行）：** 装 APK → App 生成密钥 → 公钥加服务器 config.json（devices 数组新增条目）+ 重启 server 容器 → 本地 `seal` 生成副本 → App 粘贴 → 认证进聊天页。

### iOS 开发启动（老板已购置 Mac；2026-08-29）

**背景：** 老板确认有 Mac（macOS + Xcode），iOS 从"明确跳过"转为启动开发（projectPlan Phase 3 状态已更新）。老板选择**暂无 Apple 付费账号，APNs 验证留待**（WS/轮询兜底不受影响）。

**已完成（代码层，Windows 侧）：**

- `app/ios/Runner/Info.plist`：App 显示名 Einz + 4 项权限声明（相机/麦克风/相册读/相册写，对齐 AndroidManifest，plist 解析验证通过）
- **iOS libsodium 集成**：sodium_libs 包内 `ios/Libraries/libsodium.xcframework`（静态库，ios-arm64 + simulator）复制到 `app/ios/Libraries/` → 本地 `libsodium.podspec`（vendored_frameworks + -force_load，仿 sodium_libs 的 iOS 集成）→ `app/ios/Podfile`（**Flutter 3.47 默认 SPM，需 CocoaPods：`flutter config --no-enable-swift-package-manager`**）→ shared `loadDynamicLibrary` iOS 分支改 `DynamicLibrary.process()`（静态链接符号在进程内，dylib open 会失败）。shared analyze + 13 单测过
- **APNs 接入代码**：shared ApiClient 补 `registerPushToken`/`unregisterPushToken`（+ `_delete` 辅助，对齐 PROTOCOL.md §7.3）；`AppDelegate.swift` 注册远程通知 + MethodChannel('onlyspace/apns') 传 device token；`chat_page.dart` 认证后 `_registerPushToken()`（失败静默降级）。shared analyze + 13 单测、app flutter test 6 项全过
- `docs/IOS.md`：Mac 构建指引（clone/构建/真机签名/Ad Hoc/已知点/快速参考）

**遗留/下一步（Mac 侧执行）：** ① 远程仓库已配置并推送成功（老板自建 Gitea：`https://git.tic.cc/fon/only`，main 已推，Mac 直接 clone）；② Mac clone → `flutter config --no-enable-swift-package-manager` → build ios 验证 libsodium 链接；③ 真机签名运行；④ APNs/Ad Hoc 待 Apple 付费账号（Server `sendPushHint` 仍为日志占位）。

### App 启动锁（方案 B：PIN 加密密钥；2026-08-29）

**需求：** 老板要求每次启动 App 输入验证码/口令才允许查看消息。给出三层次方案（A 本地校验 / B PIN 加密密钥 / C 生物识别增强），老板选 **B（推荐）**：Argon2id 派生密钥**加密 Space Key 包**，输错 PIN 即解不出密钥——防偷看 + 防设备取证，且复用 backup.dart 现有基建（encryptBackup/decryptBackup 的 recoveryCode 即 passphrase，XChaCha20 格式一致）。

**实现（app/lib/）：**

- `data/app_lock.dart`：`AppLockService`（setPin 双份加密：PIN 一份 + 12 词恢复码一份存 drift app_state；unlock 解密；错误 5 次 → 锁定 30s 纯本地计时；unlockWithRecovery 兑底；AppLockPayload 含 server/spaceKeyB64/spaceId/deviceId/keyVersion/token）+ AppLockException/AppLockLockedException
- `lock_page.dart`：锁屏页（PIN 输入/锁定倒计时 1s 刷新/展开恢复码入口/解锁成功进 ChatPage）
- `main.dart`：`StartupGate` 启动门（检查 isSetup → LockPage or SetupPage）
- `setup_page.dart`：认证成功后 `_setupLockAndEnter` 弹 `SetPinDialog`（PIN 两次确认 → 展示恢复码要求离线保存 → 进聊天页）；**注意 payload 需含 server 字段**（锁屏后直接进聊天页需要）
- `test/app_lock_test.dart`：4 项单测（设置+正确解锁 / 错误 PIN / 5 次锁定期间正确 PIN 也被拒 / 恢复码兑底+锁定清除）

**验证：** app flutter test **10 项全过**（原 6 + app_lock 4）。widget_test 改为直接渲染 SetupPage（绕过 StartupGate——它依赖真实 drift 库，widget 测试环境用内存库）。

**设计要点（可写 docs/APP_LOCK.md 用）：** PIN 纯本地验证、Server 不见口令；锁定纯本地计时防爆破；恢复码与 PIN 分开保存；冷启动必锁，后台切回锁定留待后续阶段（app lifecycle observer）。

### 后台切回锁定（App 锁增强；2026-08-29）

老板选"1. 后台切回锁定"。实现：

- `app/lib/data/lock_timer.dart`：`LockTimer` 纯逻辑（recordBackgrounded/shouldRelock/clear，阈值 30s 可配）+ `test/lock_timer_test.dart` 5 项单测（未后台/29s/30s/clear 重置/自定义阈值）
- `app/lib/chat_page.dart`：`with WidgetsBindingObserver`——paused/inactive 记时，resumed 超 30s → `Navigator.push(LockPage(asOverlay: true))`；**注意 switch 语句 case 需 break（改用 if/else）**
- `app/lib/lock_page.dart`：加 `asOverlay` 参数——覆盖模式解锁成功 `pop()` 回聊天页（保留消息状态），冷启动模式 `pushReplacement` 进聊天页

**验证：** flutter test **15 项全过**（原 10 + lock_timer 5）。analyze 无问题（顺带清理 chat_page 的 unnecessary_import）。

**行为：** 聊天中切后台 ≤30s 回前台不锁；>30s 回前台弹锁屏，解锁后回到原聊天页（消息不丢）。冷启动锁屏行为不变。

### 界面截图展示（golden 渲染；2026-08-29）

老板暂无手机，想先看界面 → 用 **golden 测试渲染**替代模拟器截图（无 AVD、无手机、app 无桌面平台目录）：

- `app/test/golden_render_test.dart`：加载系统中文字体（C:\Windows\Fonts\simhei.ttf 覆盖 'Roboto' family，否则中文渲染为方块）+ 390×844 手机尺寸，渲染 SetupPage / LockPage / ChatPage（fake api 返回 2 条 libsodium 真实加密消息）→ matchesGoldenFile 输出 PNG
- `app/test/goldens/{setup_page,lock_page,chat_page}.png`：**UI 回归基准图**（后续 flutter test 自动比对界面变化）
- 为此给 LockPage/ChatPage 加了 `db`/`api` 测试注入参数（生产路径默认不变）
- 生成命令：`flutter test --update-goldens test/golden_render_test.dart`（3 项全过）

**入库决定：** 老板确认 golden 截图作为 UI 基准图入库（含 golden 测试 + 注入参数改动）。

### 口令托管密钥实现（KEY_ESCROW.md，2026-08-29）

老板决定放弃 Server 明文管钥，把现有实现升级为口令托管（KEY_ESCROW.md 方案落地，决策点全按推荐：按 space 存一份 / 口令与 App 锁 PIN 区分 / 保留 seal-import 兜底 / 支持重传）。

**分层实现与验证：**

- **Server**：`key_escrow` 表（space_id 主键）+ `src/escrow.ts` 三端点（POST/GET/DELETE，白名单鉴权，包结构仅校验字段类型、**不解析内容**）+ app.ts 路由；smoke.test.ts §11 增 7 项断言（上传/拉取一致/坏字段 400/无 token 401/DB 只存密文包/DELETE 清空）——`npm test` 全过
- **shared**：Api 常量 `keyEscrow` + ApiClient 三方法（uploadKeyEscrow/getKeyEscrow/deleteKeyEscrow）+ `src/crypto/key_escrow.dart`（KeyEscrowService：createPackage/openPackage/upload/fetch/remove，复用 backup.dart 零新密码学）+ EscrowPayload + 3 项单测——dart test 16 项全过
- **CLI**：`escrow --action upload|download` 命令（auth → KeyEscrowService → store 读写，download 参照 import 归档逻辑）；**全链路 e2e 过**（upload → Server 密文 → download → 错误口令 FormatException 拒绝 → 收发解密）
- **App**：AppLockPayload 加 `escrowPassphrase`（被 App 锁 PIN 加密，与 PIN 区分）；SetPinDialog 加"接入口令"可选输入 + 上传托管（阶段2 显示状态）；SetupPage 加"③ 凭口令接入"（认证 → fetch → 口令解密 → 设置 PIN → 进聊天，免 sealed 副本）；LockPage 解锁成功 `_syncEscrow` 重传（rotate 后自动同步）——flutter test 18 项全过（golden setup_page 基准图更新）
- **协议文档**：PROTOCOL.md 增补 §7.4（/key-escrow 三端点、鉴权、口令验证在客户端、接入流程）；KEY_ESCROW.md 状态 [待评审]→[已实现]
- **双端 e2e**（escrow-pair-e2e.mjs）：A 上传 → B 清空 Space Key 凭口令接入 → A↔B 互发互收解密，全过

**排障记录（关键）：** ① bash 内后台 server 不 kill 必超时（工具等待全部子进程）→ 改用 **Node 脚本 spawn 管理 server 生命周期**（finally kill）；② `dart run` 进程被杀后留下编译锁会卡死 → 用 `dart compile exe` 编译 CLI 后直跑 exe；③ shared 测试用 flutter_test 报 URI 不存在（纯 Dart 包用 `package:test`）；④ `package:test` 的 expect 只接受 2 个位置参数；⑤ C 新设备需先加白名单再 escrow download（auth 依赖白名单公钥）；⑥ CLI sync 前需先 auth（store.sessionToken）。

**部署影响：** VPS 现有 server 容器需重新构建（新表 + 新端点）才能使用口令托管；存量数据不受影响（key_escrow 表为空）。

### App 附件消息：语音 / 图像 / 视频（2026-08-29）

老板需求：聊天页添加语音输入 + 图像、视频功能。协议层（kMessageTypes 含 image/video/voice）与 Server 附件链路早已就绪，本次为 App 端完整接入。

**依赖**（pubspec 新增）：`image_picker ^1.2.3`（拍照/拍摄/相册）、`record ^7.1.1`（录音）、`audioplayers ^6.8.1`（语音播放）、`video_player ^2.14.0`（视频播放）。

**MessageRepository**（app/lib/data/message_repository.dart）：
- `sendAttachment({fileBytes, fileName, type, caption})`：encryptAttachment 加密 blob → `api.postAttachment`（/attachments，x-attachment-meta 带 sha256/nonce/size）→ 发 caption 消息（type 标记）→ 本地附件元数据落库；无 token 时消息入 pending（v1 附件 blob 不做离线补传）
- `history()` 扩展：按 message_id 关联 local_attachments，返回附件元数据
- `fetchAttachment({attachmentId, keyVersion, sha256, nonce})`：下载密文 → decryptAttachment（AEAD + sha256 校验）

**chat_page**（语音/图像/视频三类 UI）：
- 语音：输入区 mic 图标**按住说话**（GestureDetector 长按 → record 录音到临时 m4a → 松开 `sendAttachment(type: voice)`）→ 接收渲染播放条（点击 `fetchAttachment` 解密 → 临时文件 → audioplayers 播放，onPlayerComplete 复位）
- 图像：附件 sheet（拍照/相册图片）→ pickImage(maxWidth:1600) → `sendAttachment(type: image)` → 接收缩略图（FutureBuilder 下载解密 → Image.memory，`_imageCache` 防重复下载）→ 点击全屏（InteractiveViewer）
- 视频：sheet（拍摄视频/相册视频，pickVideo maxDuration 1min）→ `sendAttachment(type: video)` → 接收播放按钮（下载解密 → video_player 对话框播放）

**排障记录（关键）：**
- `AudioRecorder()`/`AudioPlayer()` **构造即触发原生平台通道** → widget 测试 MissingPluginException → 改为**懒构造**（仅录音/播放时 `??=` 实例化），渲染路径不触碰平台通道
- golden ChatPage 基准图更新（新增 mic/+ 按钮后界面变化）；flutter test failures 产物不入库（rm 清理）

**验证：** app analyze 无问题 + flutter test **18 项全过**（golden 3 + app_lock 4 + lock_timer 5 + message_repository 6）；shared 16 项全过（未改动）。

**遗留：** ① 附件离线发送 v1 不做（blob 需联网上传）；② 图片压缩/视频转码未做（原样上传，v1 够用）；③ 真机录音/播放/拍照/相册需真机验证（老板有手机后可测）。

### App 附件扩展（音频文件/任意文件）+ 固定服务器地址（2026-08-29）

老板新需求：① 支持上传音频文件（mp3 等）；② 支持任意文件附件；③ 配置界面不再让用户输入服务器地址（域名固定）。

**协议层：** `shared kMessageTypes` 与 `server/src/messages.ts ALLOWED_TYPES` 同步加 `audio`/`file`（Server 有独立白名单校验，漏改会拒绝消息——已同步 + npm run build 过）。

**chat_page：**
- 附件 sheet 扩至 **6 项**（拍照/相册图片/拍摄视频/相册视频/音频文件/任意文件），新增 `_AttachmentKind` 枚举（顶层，Dart 不允许类内 enum）
- **file_picker 12.x API 大改**（排障关键）：`FilePicker` 为 `abstract final class`，**无 `platform` 静态成员**；`pickFiles()` 返回 `List<PlatformFile>`（非 FilePickerResult）；`PlatformFile` **无 `bytes` getter**（`withData` 已废弃），用异步 `readAsBytes()`；`name` 非空（`?? 兜底` 是死代码）
- audio 消息：与 voice 共用播放条（`_playAudioMessage` 泛化，临时文件扩展名按类型：voice→m4a、audio→原扩展名）；file 消息：文件卡片（📄 文件名 + 大小格式化 + 下载保存到应用文档目录 path_provider）
- 附件选择后 caption=文件名（file/audio 消息正文即文件名，渲染直接显示）

**setup_page：** 服务器地址输入框移除，改顶层常量 `kEinzServer = 'https://only.tic.cc'`（删 controller/dispose/4 处使用点）。

**验证：** app analyze 无问题 + flutter test 18 项全过（golden setup_page 更新）+ shared 16 项 + server 冒烟全过。

**遗留：** 文件附件下载保存到应用文档目录（用户可经文件管理器访问）；大文件上传未做进度条/断点（v1 内存读取）。

### 多设备身份判断修复（person_id，2026-08-29）

**背景：** 老板询问"A 设备发的消息，A 的其他设备上线后能否获得"——确认同步机制已支持（sync 按 space 维度 + 锚点只在 sync 推进），但发现**显示语义瑕疵**：sender 判断基于 device_id，同用户另一设备（dev-a2）的消息在 dev-a 上显示为"对方"（气泡方向错）。阅后即焚计划的"自己的消息"语义需要 person 维度。老板决定先单独修复。

**实现：**
- `shared`：`SpaceDevice`/`SpaceResult`（GET /space 返回 device_id→person_id 映射，const 构造）+ ApiClient.getSpace；测试 `get_space_test.dart`（本地 HttpServer 模拟 /space，2 项）
- `app`：MessageRepository 加 `refreshDeviceMap()`（getSpace 缓存）+ `_isSamePerson()`（**person 优先、映射缺失降级 device**）；history() 的 sender 判断改 `_isSamePerson`；chat_page `_refresh` 先拉映射再读历史
- 测试：message_repository_test 加 person 判断用例（FakeApi.getSpace override：dev-a/dev-a2→person-a、dev-b→person-b，dev-a2 的消息显示 me、dev-b 显示 peer）

**排障：** SpaceDevice 构造函数未加 const → 测试 `const SpaceDevice(...)` 编译失败 → types.dart 补 const。

**验证：** shared dart test 18 项全过（+2）、app flutter test 19 项全过（+1）。

**后续关联：** 阅后即焚计划前置已就绪——"自己的消息"在多设备间语义一致。

### 阅后即焚实现（纯本地、每设备独立；2026-08-29）

**最终语义（多轮澄清后）：** 服务器**不记录**阅后即焚状态——每台设备按自己的设置（分钟/小时/天，默认无限）管理**自己本地**副本的删除。设置、计时、删除全部纯本地，**Server 零改动**。

**实现：**
- `data/burn_after_settings.dart`：`kBurnAfterOptions`（无限/1分/5分/30分/1小时/1天/7天）+ `BurnAfterSettings`（app_state 存取，load/save）
- `local_database.dart`：local_messages 加 `burn_after_seconds`（默认 0）+ `expires_at`（可空）；**schemaVersion 1→2** + MigrationStrategy `m.addColumn(localMessages, ...)`（drift 2.34.3 正确 API；TableMigration 需 TableInfo 不行）
- `message_repository.dart`：`_burnState()`（设置快照：burn + expiresAt）；send/sync 落库写新字段（**消息到达本设备时的设置快照**）；`purgeExpired(now)` 删除到期消息 + 关联附件（可注入 now 测试）；history 返回带 expiresAt
- `chat_page.dart`：顶栏 **⏱ 按钮**（tooltip 显示当前档位）→ BottomSheet 档位选择（当前项打勾）→ 保存 + SnackBar 提示；3s ticker `_refresh` 里调 purgeExpired（到期消息自然消失）；气泡顶部"⏱ 阅后即焚"小字标记
- 测试：`burn_after_settings_test.dart`（默认 0/往返/关闭，3 项）+ message_repository_test 加 purgeExpired 用例（+59s 不删、+61s 删）

**排障记录（关键）：**
- **中文路径 build_runner 失败**（AOT 编译写入 .dart_tool 报错）→ 外部目录 `D:\build-onlyspace\onlyspace\app`（无中文路径、依赖已解析）跑 `dart run build_runner` 生成 g.dart 拷回仓库；**PATH 的独立 dart 3.12.2 不满足 pubspec ^3.13.2**，需用 Flutter 自带 dart（3.13.2）跑
- drift 2.34.3 迁移：`TableMigration(LocalMessages())` 类型错误（需 TableInfo）→ 用 `m.addColumn(localMessages, localMessages.xxx)`（生成表 getter，正确 API）

**验证：** flutter test **23 项全过**（+4：设置 3 + purgeExpired 1）；analyze 无问题；golden chat_page 更新（AppBar ⏱ 按钮）。Server/shared 零改动。

**行为：** 设置后新到达的消息带到期时间；到期后本设备无痕删除（消息+附件）；改设置只影响之后的消息（落库时快照）。

### 聊天分页加载优化（UI 懒渲染 + 增量刷新；2026-08-29）

**背景：** 老板问"新设备初次载入历史是否有分页"——确认拉取层有分页（sync 翻页 100/页 + has_more），但 UI 层无分页（history() 全量渲染 + 每次 _refresh 全量 setState）。老板要求立即优化。

**实现：**
- `message_repository.dart`：
  - `typedef HistoryMessage`（env/plaintext/sender/attachment/expiresAt）替代长 record 类型
  - `history()` 重构（提取 `_rowsToHistory` 公共解密方法）
  - 新增分页方法：`historyRecent(limit)`（未同步全部 + 同步最近 N 条 DESC→升序）、`historyBefore(beforeSequence, limit)`（更早 N 条升序）、`historySince(afterSequence)`（更新 + 未同步，NULL 排最后）
- `chat_page.dart`：
  - 首屏 `_loadInitial()`：sync 全量 → purgeExpired → 只渲染 `historyRecent(50)`
  - `ScrollController` 上滑到顶（extentBefore < 200）→ `_loadOlder()` 插入头部（`_hasMoreOlder`/`_loadingOlder` 防重入）
  - 3s ticker `_refresh()` 改**增量**：sync → purgeExpired(now) → `historySince(_lastLoadedSequence)` 追加去重 + 到期消息本地移除（不再全量 setState）

**排障（测试）：** 分页单测首次失败 `Actual: []`——两个根因：① FakeApi.sync 不给 env 赋 serverSequence（本地全 NULL → historyRecent 查不到）→ FakeApi 模拟 Server 分配递增序列；② `repo.sync()` 在 token=null 时直接 return 0 → 分页测试须 `makeRepo(api, token: 'tok')`；③ send 后 token 置 null 才能产生"未同步 pending"（否则 postMessage 成功赋序列）。

**drift API 备忘：** 2.34.3 的 `orderBy` 参数是 `List<OrderClauseGenerator<T>>`（函数形式 `[(t) => OrderingTerm.desc(t.serverSequence)]`，不是 OrderingTerm 列表）；DataClass 名是 `LocalMessage`（单数化）。

**验证：** flutter test **25 项全过**（+2 分页用例）；analyze 无问题（顺手删 golden_render_test 多余 dart:typed_data import）；golden 3 项通过（UI 渲染结构未变，无需更新基准图）。

### 多语言界面（中文/英文，官方 l10n；2026-08-29）

**背景：** 老板问"目前有多语言界面吗？至少需要英文、中文"——现状：全部硬编码中文（chat_page 590 行/setup_page 387/lock_page 160/main 39 行含中文），无任何 i18n 基础设施。老板确认决策：**官方 l10n + 跟随系统/手动覆盖 + 分批（先核心：设置页+聊天页）**。

**基础设施：**
- pubspec 加 `flutter_localizations` + `intl: any` + `generate: true`；`l10n.yaml`（arb-dir: lib/l10n，template: app_en.arb）
- `lib/l10n/app_en.arb` + `app_zh.arb`：各 60+ 键（通用 9 + setupPage.* 18 + setPinDialog.* 12 + chatPage.* 27 + burnOption.* 7），占位符用 `{name}` + `@key.placeholders`
- gen-l10n 生成 `lib/l10n/app_localizations*.dart`（**入库**，generate: true 时 pub get 自动生成）
- `data/locale_settings.dart`：LocaleSettings（app_state locale：system/zh/en）+ `localeNotifier`（ValueNotifier，切换即时生效）
- `main.dart` EinzApp 改 StatefulWidget：MaterialApp 加 `localizationsDelegates/supportedLocales/locale`（null=跟随系统；手动选择 zh/en 覆盖）

**文案抽取（核心工作量）：**
- setup_page.dart：~30 处（build UI + 状态消息 + SetPinDialog 全部）——`AppLocalizations.of(context)!` 替换；**async 方法 await 后取 l10n 会触发 use_build_context_synchronously lint → 在 await 前取局部变量**（_uploadEscrow 排障）
- chat_page.dart：~35 处（SnackBar 错误/附件 sheet 6 项/播放错误/输入区/阅后即焚档位）——**阅后即焚档位标签改 `_burnSeconds`（存秒数）+ `_burnOptionLabel(seconds, l10n)` switch 映射**（原存中文 key 无法国际化）；附件选择弹层、🌐/⏱ 弹层用 l10n
- golden/widget 测试：MaterialApp 补 `localizationsDelegates + locale: Locale('zh')`（页面用 AppLocalizations.of 需要；基准图是中文渲染）；ChatPage golden 0.05% 像素差 → `--update-goldens`

**验证：** gen-l10n 成功；analyze 无问题；flutter test **25 项全过**（含 golden 3 项更新后）；chat_page golden 已更新（界面含 🌐 按钮等变化）。

**遗留：** lock_page 160 行 + main.dart 39 行含中文的文案**未在本批抽取**（后续批次）；l10n 键在 setupPage/chatPage 前缀下组织，后续页沿用。

### 多语言第二批（lock_page 全量抽取；2026-08-29）

**内容：**
- ARB 加 `lockPage.*` 12 键（中英双语，含 int 占位符：`lockPageLockedSeconds(seconds)`/`lockPageTooManyAttempts(seconds)`、String 错误参数）
- lock_page.dart 12 处替换：AppBar title、PIN 提示、锁定倒计时 label（三目：locked ? LockedSeconds : PinLabel）、解锁/恢复码入口按钮、错误消息（TooManyAttempts/UnlockFailed/RecoveryFailed）；**AppLockException 的 e.message 来自 app_lock.dart（业务消息，非本页字面量），保留原样**
- main.dart 确认**无 UI 中文文案**（`title: 'Einz'` 英文，39 行中文均为注释）→ 无需替换

**验证：** gen-l10n 成功（lockPage 键生成）；analyze 无问题；flutter test **25 项全过**；lock_page golden 更新（0.31% 像素差，label 三目等渲染变化）。

**状态：** 四个页面（设置/聊天/锁屏/启动）**全部中英文化完成**；剩余可选项：app_lock 业务错误消息国际化、英文文案润色。

### WS 实时接入 + 轮询兜底（2026-08-29）

**背景：** 老板问"上线后还是每 3 秒轮询吗？换成 WS 就实时了吗？"——回答：Server WS 早已就绪（ws.ts 广播 message.new），CLI 有 listen，但 **App 未接入**（仍 3s 轮询）。老板要求开发。

**实现：**
- `shared/lib/src/protocol/ws_client.dart`（新）：`WsClient` + `WsEvent` 模型（sealed：WsHelloEvent/WsMessageNewEvent/WsKeyRotationEvent/WsDeviceRevokedEvent）；**指数退避重连**（1/2/4/8/16/30s 上限）直到 stop；token URL 编码（PROTOCOL.md §8.1）；状态回调（stopped/connecting/connected/reconnecting）；未知帧忽略（协议向前兼容）
- `app/lib/data/ws_realtime_service.dart`（新）：封装 WsClient → `connected` ValueNotifier + `onMessageNew` 回调（chat_page 收到 message.new 立即增量刷新）
- `chat_page.dart`：initState 启动 WS（`enableWs` 参数——**测试环境关闭，避免真实连接/重连 Timer 挂起**）；`_restartTicker` 动态切换轮询间隔：**WS 在线 → 30s 兜底；断开 → 恢复 3s**（_onWsStatusChanged 监听 connected）；dispose 清理
- 测试：`shared/test/ws_client_test.dart`（本地 HttpServer + WebSocketTransformer 模拟 /ws：hello/connected、message.new 解析、key.rotation、未知帧忽略、断开→reconnecting→重连成功，5 项）；`app/test/ws_realtime_service_test.dart`（message.new → onMessageNew + connected 状态，1 项）

**验证：** shared dart test **23 项全过**（+5）、app flutter test **26 项全过**（+1）；analyze 无问题；golden 不变（渲染结构未动）。

**效果：** App 上线后 WS 在线时消息**毫秒级实时**（Server 广播 → App 立即增量刷新），3s 轮询降为 30s 兜底；WS 断线自动指数退避重连，重连期间恢复 3s 轮询保底（不丢消息）。

**遗留：** ① Server 无 message.deleted 广播（阅后即焚纯本地，无 Server 删除）——WS 只需处理 message.new；② key.rotation/device.revoked 事件 App 暂未处理（device.revoked 后 App 应强制登出，后续可加）；③ 真机验证 WS 连接稳定性。

### device.revoked 撤销处理（2026-08-29）

**背景：** 老板要求做 device.revoked（撤销强制登出）+ 询问 key.rotation。**key.rotation 说明**：Space Key 轮换目前是 CLI 离线流程（rotate → 密封给对方 → import），Server 广播仅通知性；App 密钥管理固定 keyVersion=1、无导入流程 → 收到 key.rotation 暂无实际动作，**本次不处理**。

**实现：**
- `WsRealtimeService`：加 `onDeviceRevoked` 回调（onEvent 分发 WsDeviceRevokedEvent）
- `AppLockService.clear()`：删除锁包 4 个 key（app_lock.package/recovery/attempts/locked_until）——设备撤销后回到未配置状态，防止残留密钥
- `chat_page._onDeviceRevoked()`：停轮询/WS → 清理本地（AppLockService.clear + 清空 localMessages/localAttachments/syncState）→ SnackBar 提示（新增 l10n 键 chatPageDeviceRevoked）→ `pushAndRemoveUntil` 强制回 SetupPage（清空导航栈）；清理失败不阻塞登出（尽力清除）
- 测试：app_lock_test 加 clear 用例（clear 后 isSetup=false + 原 PIN 解锁抛 AppLockException）；ws_realtime_service_test 加 revoked 分发用例（广播 device.revoked → onDeviceRevoked 触发 1 次）

**验证：** app flutter test **28 项全过**（+2）；analyze 无问题；shared 23 项不变。

**安全语义：** Server 广播 device.revoked 后主动断开连接（P2 修复），App 收到即清数据登出——被撤销设备上不留密钥与消息副本。

### Server 备份密钥改名（命名消歧；2026-08-29）

**背景：** 老板指出 `backup key`（实为口令派生机制，非独立实体）与 `EINZ_BACKUP_KEY`（Server env）命名易混淆。老板确认方案：**改 Server env 名 + 文档对照表**；backup.dart 保持原名。

**改动：**
- `EINZ_BACKUP_KEY` → `EINZ_DB_BACKUP_KEY`（全库同步）：
  - `server/src/backup.ts`（注释 + process.env 读取 + 2 错误消息）
  - `server/scripts/backup.ts`（注释）
  - `deployment/docker-compose.yml`（注入行）
  - `docs/DEPLOYMENT.md`（7 处：起服务示例 + 说明）
  - `docs/updateServer.md` §5（备份密钥行 + 新增"旧部署升级"行：2026-08 前部署的 .env 旧变量名需手动改名 + `docker compose up -d --build server`，否则 backup 脚本拒绝执行）
  - `server/dist/`（编译产物，.gitignore 不入库，build 自动更新——已确认 dist/backup.js 含新名）
- `docs/E2EE.md` 末尾加**附录：密钥命名对照**：Space Key（消息 E2EE）/ 口令派生密钥（backup.dart 三处复用：CLI 备份、App 锁、托管）/ DB 备份密钥（Server env）——三层独立互相解不开

**验证：** server `npm run build` 通过；smoke 测试全过；grep 确认 server/src、scripts、deployment、DEPLOYMENT.md 无残留旧名（仅文档升级说明有意提及旧名）。

**⚠️ VPS 运维提醒（交付时同步老板）：** VPS 的 `deployment/.env`（gitignore 不入库）需手动把 `EINZ_BACKUP_KEY` 改名 `EINZ_DB_BACKUP_KEY` 后重启 server，否则 backup 脚本报"变量未设置"拒绝备份。

### 自建空间 + 二维码加入（降小白门槛；2026-08-29）

**背景：** 老板要求 App 支持自生成 Space Key——第一个使用者（老板，技术型）纯 App 完成建空间，第二个使用者（小白）零门槛加入。决策：**A 端一键生成 + 二维码分享 + 白名单保持手动**。

**实现：**
- `shared/lib/src/protocol/join_info.dart`（新）：`JoinInfo`（`onlyspace-join-v1?space=<spaceId>&p=<passphrase>`，口令 URL 编码防特殊字符）+ `decode` null 安全；3 单测（往返/特殊字符中文口令/格式不符）
- `setup_page` A 端：新增**"自建空间（一键生成 Space Key）"**按钮（与③凭口令接入并列）→ `_generateSpaceKeyAndAuth()`：`Random.secure()` 生成 32B Space Key（**shared sodium 无 randombytes 暴露，用 Dart CSPRNG**）→ challenge-response 认证 → SetPinDialog（口令托管复用）→ `_showJoinInfoDialog()`（**QrImageView 二维码** + 口令/空间文本 + 一键复制 joinDialog.* 键）→ 确认进聊天页；未生成密钥/未填口令分别提示
- `setup_page` B 端：口令输入框 📷 suffixIcon → `_scanJoinCode()` → `_JoinScanPage`（**MobileScanner 懒构造**——进入页面才实例化，widget 测试不触碰原生相机通道；扫到 onlyspace-join-v1 自动填 spaceId/口令 → scanJoinFound 提示）
- 依赖：`qr_flutter 4.1.0`（纯 Dart 绘制，测试环境安全）+ `mobile_scanner 7.4.0`（相机权限拍照时已配置，Android CAMERA/iOS NSCameraUsageDescription 复用）
- 测试：widget_test 加"自建空间入口"用例（**ensureVisible 滚动修复**——按钮在 ListView 视口外 tap 命中失败）；flutter test **29 项全过** + setup golden 更新（新增按钮/suffixIcon）

**小白（B）完整流程（零技术）：** 装 App → ①生成设备密钥 → 把公钥转发给 A → A 加 VPS 白名单 → 📷 扫 A 的二维码 → ③凭口令接入 → 完成。A 全程纯 App（不再需要 CLI）。

**遗留：** ① 二维码分享对话框（joinDialog）展示时机在进聊天页前——若 A 想"先建空间后补发邀请"，可后续加聊天页内入口；② mobile_scanner 需真机验证（模拟器相机不可用）；③ 白名单仍需 A 上 VPS 操作（保持手动，安全核心不变）。

### 配置页分步向导重构（交互优化；2026-08-29）

**背景：** 老板审核截图时提出关键交互批评：①"生成设备密钥"点击后无明确结果反馈；②"导入并认证"与"自建空间/凭口令接入"四个功能并列但无前后关系，易混淆；③ 建议**分步向导、每页只收集一个信息**。决策确认：**先选角色再进向导 + sealed 保留折叠入口**。

**重构（setup_page 大改）：**
- **第 0 步角色选择**：我是第一个使用者（创建新空间）/ 我要加入现有空间 / 高级 sealed（ExpansionTile 折叠）
- **创建（create）7 步**：设备名+生成密钥（**本页 Card 明确显示"✅ 密钥已生成"+ 设备 ID/公钥，回应反馈缺失批评**）→ 白名单确认（展示公钥，用户 VPS 添加后继续）→ 接入口令 → PIN（_runPinSetup：生成 Space Key + 认证 + SetPinDialog）→ 二维码分享（QrImageView + 一键复制）→ 完成
- **加入（join）5 步**：设备名 → 扫码/粘贴加入信息（_buildStepJoin：📷 扫码自动填 + 手动输入）→ PIN（_runJoinAccess：认证 → 托管拉取 → 口令解密）→ 完成
- **高级（advanced）5 步**：设备名 → sealed 粘贴（_buildStepSealed）→ PIN（_runSealedImport：解封 → 认证）→ 完成
- 框架：_WizardRole 枚举 + 步骤状态机（_step/_stepCount/_stepTitle/_buildStep）+ 进度圆点 + 底部上一步/下一步/完成 + AnimatedSwitcher；共享状态（_keyPair/_spaceKey/_sessionToken）；_nextStep 按 (role, step) 前置校验（每步一个信息未填即提示）；_authenticate 提取公共认证
- l10n：wizardRole*/wizardStep*/wizard 提示键 + setupPageKeyGenerated（中英，zh/en 键一致性 diff 校验）
- 测试：widget_test 重写 3 用例（首屏角色选择/创建分流+未生成密钥提示/加入分流）；golden setup_page 更新（向导首屏）；flutter test **30 项全过**

**排障：** ① 重构期字段重复定义（旧字段残留）与 _finish 重复（框架空实现 vs 新实现）→ 清理；② `FilledButton.tonal.icon` 不存在（API 无组合）→ tonal + Row；③ widget_test"选择你的情况"在 AppBar 与 body 各一次 → findsWidgets。

**老板反馈落实：** 生成密钥后本页明确展示结果 ✅；每页一个输入 ✅；步骤前后关系清晰（进度圆点 + 步骤标题 + 上一步/下一步）✅；sealed 技术路径保留在折叠入口 ✅。

### macOS 本机恢复 + Flutter 安装（2026-08-30）

**背景：** 老板从 Windows 机器转回 macOS 本机继续。Windows 期间已推进大量工作（口令托管 KEY_ESCROW 落地、App 多语言/WS 实时/自建空间二维码/分步向导、Server 备份密钥改名 EINZ_DB_BACKUP_KEY、更新流程 git push/pull 化等，最新 HEAD e5f09c6）。

**本次 macOS 会话完成：**

- **回答 .env 问题**：docker-compose 变量名已从 `EINZ_BACKUP_KEY` 改名 `EINZ_DB_BACKUP_KEY`（7504791 消歧）；应在 `deployment/.env` 定义（compose 自动读取同目录 .env，gitignore 保护），新增 `deployment/.env.example` 模板；口令托管（KEY_ESCROW）的"接入口令"是客户端口令，与 DB 备份密钥是两回事。
- **文档 macOS/Linux 化**：DEPLOYMENT.md / IOS.md / updateServer.md 中 PowerShell、`D:\`、`C:\`、`.\bin\`、`setx`、反引号续行全部改为 bash / `/Users/Shared/product-产品/only` / `bin/`、`\` 续行；libsodium 提示改为 `/opt/homebrew/lib/libsodium.dylib`。
- **Flutter 安装**：磁盘已腾出（13GiB），中国镜像下载 3.41.0 后因 App 需要 Dart ^3.13.2（Windows 用 Flutter 3.47.2）不匹配，卸载换装 **Flutter 3.47.2**（Dart 3.13.2）到 `~/development/flutter`；Google storage/GitHub 不可达，全程 storage.flutter-io.cn。
- **验证链全绿**：server build + 冒烟（含密钥托管）；shared analyze + 26 单测（修 1 个 unused_import）；cli analyze + e2e 全过；app flutter test **39 项全过**（ASCII 路径副本 /tmp/onlyspace-build 跑的，因仓库路径含中文"产品"触发 analysis_server 崩溃缺陷）。
- **App 侧修复（Windows 产物在 macOS 的适配）**：
  1. `e2e.sh` cygpath 是 Windows 专用 → 加 `command -v cygpath` 判断跨平台；
  2. `app/pubspec.yaml` 加 sqlite3 `hooks: source: system`（否则 flutter test 尝试从 GitHub 下载预编译 sqlite3 原生库，国内网络必失败）；
  3. `golden_render_test.dart` 字体加载硬编码 `C:\Windows\Fonts\simhei.ttf` → 改为跨平台候选（macOS Hiragino/STHeiti / Windows simhei / Linux Noto）；goldens 基准图在 macOS 重新生成（--update-goldens，含新 setup_step_*.png）；
  4. `widget_test.dart` `_wrap` lint 修复（no_leading_underscores_for_local_identifiers）。

**遗留：** app 的 Android SDK / Xcode 工具链未装（flutter doctor 有警告），真机构建验证留待 Phase 3 移动端；goldens 已按 macOS 平台重新生成入库。

### 设置向导页眉改造 + golden 树形编号（2026-08-30）

**老板需求：** 首页选择空间类型后，每一页页眉固定显示所选角色名（创建新空间/加入你的空间/导入 sealed 密钥），本页功能描述移到 body 上方；golden 文件名按页面出现顺序树形编号。

**编号规则（老板确认）：** 页面层级用 `.` 分隔；并列分流同层按数字顺序。映射：`setup_step1_roles.png`（1=首页角色选择）、`setup_step1.1.x_*`（create 分流）、`setup_step1.2.x_*`（join 分流）、`setup_step1.3.x_*`（advanced 分流），分流内按出现顺序（如 1.1.1_device=设备名、1.1.2_whitelist=白名单…）。

**实现：**
- setup_page.dart：新增 `_appBarTitle`（按角色返回 wizardAppBarCreate/Join/Advanced，第 0 步仍显示引导语）；AppBar 改用角色名；步骤标题 `_stepTitle` 移到 body 进度圆点下方（20px w600）
- l10n：新增 `wizardAppBarCreate/Join/Advanced` 三键（zh/en），gen-l10n 重新生成
- golden 文件：10 个 git mv 重命名（含 setup_page.png → setup_step1_roles.png）；golden_render_test.dart 用例名与 matchesGoldenFile 路径全部同步（含 skip 列表 keygen/whitelist 新名）
- widget_test：补 AppBar 角色标题断言（创建新空间/加入你的空间）

**验证：** app flutter analyze 无问题；flutter test **39 项全过**（golden 基准图已按新 UI 重新生成；锁屏/聊天页基准图未动）。

### 项目路径改名 product-产品 → productX + session 找回（2026-08-30）

**背景：** 老板把项目目录从 `/Users/Shared/product-产品/only` 手动重命名为 `/Users/Shared/productX/only`，重启 atom 后找不到原来的 session（session 按工作目录哈希分桶存储，旧桶 202a4f4986bdf4ed 不再被新路径命中）。另核实：`/Users/Shared/only` 并不存在，实际路径以 `/Users/Shared/productX/only` 为准。

**session 找回（atom 侧，~/.atomcode/sessions/）：**
- session 存储机制：`~/.atomcode/sessions/<工作目录hash>/` 分桶，会话 meta 的 `working_dir` 字段决定归属；`~/.atomcode/history-v2/<hash>/entries.jsonl` 存历史提问索引。
- 迁移动作：把旧桶 `202a4f4986bdf4ed`（product-产品/only，3 个会话：623c51f8 架构重构讨论、9b00b45c fork、ce33edfe 空会话）与 `dac869ed60aeec99`（productAll/only，1 个会话 9182817b，上次改名遗留）下的会话文件全部移入新桶 `36c61259c00d9bf2`，并将这些 meta 的 `working_dir` 更新为 `/Users/Shared/productX/only`；history-v2 的 entries.jsonl 一并合并。
- 备份：迁移前已打包 `~/.atomcode/backup-sessions-20260830.tar.gz`（sessions + history-v2）。
- 效果：在 `/Users/Shared/productX/only` 启动 atom 后 `/resume` 即可看到全部历史会话（Einz 架构设计重构讨论等）。

**项目内文档同步（以实际路径为准）：**
- `docs/DEPLOYMENT.md`、`docs/IOS.md`、`docs/updateServer.md`、`docs/HANDOFF.md` 中的 `cd /Users/Shared/product-产品/only` 全部改为 `/Users/Shared/productX/only`。
- `app/android/gradle.properties` 注释同步（现路径 productX 已是 ASCII，保留 overridePathCheck 开关防未来非 ASCII 路径）。
- `aimemo/worklog.md` 旧条目与 `notes/cli-config.md`（Windows 机器历史命令）为历史记录，未改写。

### macOS 本机 iOS 构建环境搭建（2026-08-30）

**背景：** 老板要求在 macOS 本机构建 iOS 版 App。环境初检：Flutter 3.47.2 已装于 `~/development/flutter`（但不在 PATH）；Xcode 26.3 已装但 **`xcode-select` 仍指向 CommandLineTools**（首次启动未完成：许可证未接受 + iOS 平台组件未安装）。

**搭建过程与踩坑：**

1. **CocoaPods 缺失** → `brew install cocoapods`（1.16.2，brew 无需 sudo）；本项目 iOS 侧强制用 CocoaPods（Podfile 引入本地 libsodium pod），已 `flutter config --no-enable-swift-package-manager` 关闭 SPM。
2. **Xcode 未激活** → `xcode-select -s /Applications/Xcode.app` 需 root（sudo），非交互环境无法执行 → 先以 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 环境变量绕过；构建报 `No Xcode build settings have been found` / `iOS 26.2 is not installed`。
3. **磁盘告急**：数据卷 98%（4.2Gi）→ 清理 `~/Library/Caches/` 大项（pip 1.1G、ms-playwright 1.1G、Homebrew、typescript、HBuilder X、hardhat-nodejs、Edge ×2 等约 3.2G）→ 释放到 7.7Gi。**教训：`~/development/flutter`（Flutter SDK 3.9G）绝不能删。**
4. **老板执行 sudo 三步**（我无法代输密码）：`sudo xcodebuild -license accept` → `sudo xcode-select -s /Applications/Xcode.app` → `xcodebuild -downloadPlatform iOS`（下载数 GB，装好后磁盘又从 7.7G 降到 1.7Gi，⚠️ 现在很紧张）。
5. **构建验证**：`flutter build ios --debug --no-codesign` 首次跑超 300s（pod install + Xcode 编译），第二次增量完成 → **`✓ Built build/ios/iphoneos/Runner.app`（arm64）**。

**当前 iOS 环境状态：**
- Flutter 3.47.2（`~/development/flutter`，需 export PATH）；Xcode 26.3 + iOS 26.2 SDK + 模拟器运行时 26.3；CocoaPods 1.16.2（brew）
- Bundle ID 目前 `com.example.onlyspace`，真机签名需改为唯一值（如 `com.tic.onlyspace`），Team 选 Apple ID（免费账号可真机调试；APNs 推送需付费账号 99$/年，当前跳过，`server/src/push.ts` 为日志占位，WS/轮询兜底）
- ⚠️ 磁盘仅剩 ~1.7Gi：后续构建/Archive 失败先清 `~/Library/Developer/Xcode/DerivedData`
- 真机运行：`open ios/Runner.xcworkspace` → Signing & Capabilities → Run ▶；首次手机需信任开发者证书

### CLI 交互式聊天 REPL（方案 B 雏形，2026-08-30）

**背景：** 老板想给 Einz 做一个类似 Claude Code 的终端界面。经分析：项目已有 `cli/`（子命令式测试端，send/sync/attach/backup 全能力）+ `shared/`（纯 Dart 加密与同步协议），缺的是交互层。定方案：A = Dart 原生 TUI（分栏、光标控制），B = 轻量 REPL（stdin 循环 + 彩色输出，能收能发）。**老板选先做 B 验证交互。**

**实现（新文件 `cli/bin/onlyspace_chat.dart`，278 行）：**
- 启动即增量同步历史；直接输入文本即发送；发送后自动 sync（能立即看到对方回复）
- 命令：`/auth [server]`（challenge→sealOpen→verify 认证）、`/sync`、`/history`、`/help`、`/exit`
- ANSI 彩色输出：我=绿、对方=黄、系统=灰、错误=红；`_uuidv7` 与 onlyspace.dart 一致
- 复用 DeviceStore / ApiClient / encryptMessage / decryptMessage，无新增依赖
- 定位说明：与 store.dart 一致，测试端明文落盘，不上生产

**验证：** `dart analyze` 无问题（修 1 个 unused import）；临时 server + 双端设备冒烟**双向收发全过**：A REPL 发 → B REPL 同步解密 ✅；B REPL 回 → A REPL 同步解密 ✅。

**后续（方案 A 升级，待老板定）：** 分栏 TUI（消息区+输入区+状态栏）、后台 WS 实时监听（复用 _cmdListen 逻辑）、附件收发入口。桌面 GUI 版另议（Flutter Desktop 复用 ~95% 现有代码）。

### CLI 交互式聊天 TUI（方案 A 升级完成，2026-08-30）

**背景：** 老板体验方案 B（REPL）后决定升级方案 A：分栏 TUI + WS 实时接收 + 附件收发。调研结论：shared 的 `WsClient`（回调式 onEvent/onStatus + 指数退避重连）已导出可复用；pub 缓存无 TUI 库且国内网络下载不稳 → **手写 ANSI 渲染（零新依赖）**。

**实现：**
- `cli/lib/chat_core.dart`（255 行）：从 onlyspace_chat.dart 提炼业务核心 `ChatSession`（认证/发送/补发/增量同步/历史/解密/UUIDv7 + 消息缓存），新增 `attachFile`（PROTOCOL.md §6.1 附件上传全流程）与 WS 实时监听（message.new → 落盘 + 解密 + 追加缓存）
- `cli/bin/onlyspace_tui.dart`（314 行）：分栏 TUI——顶部状态栏（设备/空间/WS 状态●↻○）、中间消息区（滚动）、底部输入行；`stdin.listen` + utf8.decoder 逐键（raw 模式，Ctrl+C 退出）；命令 `/auth /sync /history /attach <file> /help /exit`；WS 状态变化与新消息即重绘
- `demo/run_a.sh` / `run_b.sh` 切到 TUI；新增 `cli/test/tui_smoke.py` 冒烟脚本

**踩坑与修复（Dart pty 环境已知行为，真实终端无碍）：**
1. `readByteSync` 在 pty 下与 `stdout.write` 冲突（"StreamSink is bound to a stream"）→ 改 `stdin.listen` + utf8.decoder（顺带解决中文逐字节乱码）
2. `stdout.terminalLines/Columns` 在 pty 下抛异常 → try-catch 兜底 24/80
3. 渲染失败会崩进程 → try-catch 兜底（业务逻辑不受影响）
4. demo 冒烟依赖 stdout 文本不可靠 → 改为验证 store 落盘（history 条数与 seq 递增）
5. 残留 server 占 3901 端口导致 auth 失败 → 每次重置环境前先确认端口释放

**验证：** `dart analyze` 无问题；干净环境双端冒烟全过：TUI 状态栏渲染 ✅、A(TUI) 发中文消息 B 解密收到 ✅、B 发消息 A(TUI) WS 实时落盘 ✅（history 1→2 条 seq 1→2）。

**真实终端体验：** `bash cli/demo/run_a.sh` / `run_b.sh` 开两个终端窗口互发；两个窗口都能实时看到对方消息（WS 推送），无需手动 /sync（保留 /sync 作兜底）。

### Android release APK 首次构建（2026-09-01）

**背景：** 新项目环境（Windows 无 Flutter/JDK，Android SDK 在 `D:\Android\Sdk` 已齐备：platforms 33/35/36、build-tools 35/36、ndk 28.2）。老板拍板：debug 签名、包名 `cc.tic.einz`、单文件全架构 APK。

**环境搭建（工具链装在 `D:\devtools`）：**
- Flutter 3.47.2（stable，Dart 3.13.2，满足 pubspec.lock 的 flutter>=3.44/dart>=3.13.2）。**踩坑：** 腾讯 flutter_infra_release 镜像只有版本清单（releases_linux.json 等 200），无 Windows 实体包（全 404）；官方 GCS 实体包正确 URL 是 `https://storage.googleapis.com/flutter_infra_release/releases/<archive>`（archive 路径带 `stable/windows/` 前缀，**不是** `flutter/<version>/windows-x64/`）。清华 flutter 镜像同样 404。
- JDK 21（Adoptium，清华镜像 `OpenJDK21U-jdk_x64_windows_hotspot_21.0.12.1_1.zip`）——AGP 9.1.0 需要 JBR/JDK 17+，21 兼容。
- 构建脚本固化在 `D:\devtools\run_apk_build.sh`（export FLUTTER_ROOT/JAVA_HOME/ANDROID_HOME 后 `flutter build apk --release`），下次重建直接跑它。

**构建问题与修复：**
1. **Kotlin 增量编译跨盘符失败**：pub 缓存在 C 盘、项目在 D 盘，Kotlin daemon 关缓存时报 `this and base files have different roots: C:\Users\...\Pub\Cache\... and D:\Seafile\einz\app\android` → `gradle.properties` 加 `kotlin.incremental=false` + 清 `app/build/android_file_picker/kotlin` 残留缓存后一次通过。
2. **后台构建被杀**：bash 工具里 `nohup … &` 启动的进程在工具调用返回时被回收 → 只能前台跑，单次 300s 超时；首次失败后依赖已下载完，续跑 213s 完成。

**产物验证：** `app/build/app/outputs/flutter-apk/app-release.apk`，70.8MB，`cc.tic.einz`，versionCode 1 / versionName 1.0.0，minSdk 24 / targetSdk 36，apksigner 验证通过（Android Debug 证书，符合本次"debug 签名"约定）。

**改动（2 文件）：** `app/android/app/build.gradle.kts`（applicationId → cc.tic.einz）、`app/android/gradle.properties`（kotlin.incremental=false + 注释）。

**待办（非本次范围）：** release keystore（`app/android/key.properties`）未配，上架/长期升级前必须换正式签名并重建（换签名后用户需卸载重装，越早换越好）。

### 模拟器验证 + 修复启动崩溃（libsqlite3.so 缺失，2026-09-01 续）

**模拟器环境（Windows 本机）：** Hyper-V/WHPX 虚拟化可用（vmcompute 已启用）。补装 `emulator 37.1.11` + `system-images;android-35;google_apis;x86_64`（sdkmanager，Google 官方源经代理可达），AVD `einz_avd`（pixel_6，auto-select x86_64）。**踩坑：** bash 工具会话内的 `nohup … &` / `Start-Process` 子进程会在工具调用返回时被回收 → 改用计划任务 `EinzEmuStart` 跑 `D:\devtools\start_emulator.bat`，模拟器才真正脱离会话常驻。

**发现真 bug（APK 在 Android 上无法启动）：** 首版 APK 装模拟器后黑屏，logcat 显示 `dlopen failed: library "libsqlite3.so" not found`（drift 初始化）。根因：`app/pubspec.yaml` 配了 `hooks: user_defines: sqlite3: source: system`（原意是桌面/测试环境走系统 SQLite 免下载），但 **Android 系统不提供 libsqlite3.so**，应用启动即崩。该配置对 Android 是错误方向。

**修复（pubspec.yaml 一处）：**
- 删除 `source: system` → sqlite3 包按默认捆绑预编译 `.so` 打入 APK（构建时从 GitHub releases 下载，本机代理可达，83s 重建成功；APK 70.8→75.7MB，三 ABI 均有 libsqlite3.so）
- 顺带修复 `uses-material-design: true` 被错误缩进进 `hooks:` 块下的 YAML 结构错误（构建日志 MaterialIcons 字体缺失警告即此因），移回 `flutter:` 块
- `sqlite3_flutter_libs 0.6.0+eol` 是 EOL 空壳包（无原生库），由 drift_flutter 强制引入，保留不动

**验证：** 新 APK 重装模拟器，无崩溃日志，topResumedActivity 稳定在 MainActivity；截图确认渲染出浅色设置页界面（screencap 像素分析非全黑，1080x2400）。截图存 `aimemo/shots/emu_setup_20260901.png`。

**结论：** 首版 debug 签名 APK 不可用（此 bug 真机同样会崩）；修复版 `app-release.apk`（75.7MB, cc.tic.einz, v1.0.0+1）为当前可用版本，模拟器运行正常。

### macOS 本机磁盘清理：npm 缓存（2026-09-01 续）

**背景：** 老板考虑卸载本机（macOS）Xcode 与 iOS 开发资源释放空间。盘点后发现：Xcode 相关合计仅 ~7GB（Xcode.app 5.0G + CommandLineTools 1.8G + 模拟器等 0.25G），而磁盘大头在别处（`~/.npm` 9.5G、`~/.cache` 6.6G、Parallels 4.4G、Homebrew 7.5G、Seafile 21G）。

**老板决策：** 只清 npm 缓存，不卸载 Xcode（保留 iOS 打包能力）。

**执行：** `npm cache clean --force` → `~/.npm` 9.5G → 294MB，释放约 **9.2GB**；磁盘占用 93% → 53%，可用 ~1GB → ~10GB。无代码改动，无需 commit。

**备查：** 若日后仍需腾空间：`~/Library/Developer/CoreSimulator`（192M）、`/Library/Developer/CommandLineTools`（1.8G，brew/git 依赖，建议保留）、`brew cleanup --prune=all`、Parallels 虚拟机镜像（4.4G，不用可删）、`~/.cache`（6.6G，需逐项甄别）。

### macOS 本机环境盘点 + Flutter 配 PATH（2026-09-01 续）

**盘点结论：** 本机 Flutter SDK 其实已安装于 `~/development/flutter`（3.47.2 stable / Dart 3.13.2，与项目 pubspec.lock 要求匹配），但从未配 PATH，终端 `flutter` 一直 command not found。另发现 brew 独立装了一份旧版 dart-sdk 3.11.0（`/opt/homebrew/bin/dart`），**不满足项目 dart>=3.13.2 要求**，且此前因 flutter 不在 PATH 而遮蔽了正确版本。

**操作：** `~/.bashrc` 的 add path 段前置 `export PATH="$HOME/development/flutter/bin:$PATH"`（置于 brew 之前）。默认 shell 为 /bin/bash，`.bash_profile` 已 source `.bashrc`，故无需改 zsh。验证：`which flutter`→SDK、`which dart`→SDK 自带 3.13.2 ✓。

**备注：** brew dart 3.11.0 保留未删（被遮蔽），如需可 `brew uninstall dart`。新终端或 `source ~/.bashrc` 后生效。

### Homebrew 半更新损坏修复（2026-09-01 续）

**背景：** 卸载 brew dart-sdk 时 brew 报 `Unexpected method 'command_wrapper' called on Cask drawio`，`brew update` 报 sorbet-runtime 的 `UnboundMethod#bind_call` 崩溃。根因：此前一次 `brew update` 半途而废，git 代码已被推到 6.0.20-85，但 vendored gems（`vendor/bundle/ruby/4.0.0` 仅 8 个，5.0.7 时代旧版本）未同步重建，新旧不匹配导致崩溃。

**修复：** `brew install-bundler-gems`（官方内部命令，按 `Gemfile.lock` 重建 vendored gems，8 个全部重装）。**验证：** `brew update`、`brew info --cask drawio`（原崩溃点）、`brew doctor`、`brew list --versions` 全部正常。

**经验：** brew 半更新（git 代码已 fetch 但 gems 未重建）是常见损坏态，`install-bundler-gems` 是轻量修复手段，比重装 brew 快。另：brew 已随修复升级至 6.0.20；`brew uninstall <formula>` 遇 cask 加载错误时可用 `--formula` 参数绕过。

### CI 打包方案落地与调整（2026-09-01 续）

**背景：** 老板放弃在本机（macOS）打包后，CI 成为打 Android APK + iOS 的路径。方案：**APK 走 Gitea Actions**（自建 git.tic.cc，runner 机器独立于 Gitea 服务器），**iOS 走 Codemagic** 云构建（免费 500 分钟/月）。

**产出（commit 147cf71 / 966b8ac / ee34be9 / 4ce8bed / 7039488）：**
- `.gitea/workflows/build-apk.yml`：push main / v* 标签 / 手动触发 → debug 签名 APK（无需 keystore）
- `codemagic.yaml`：iOS 构建（`flutter config --no-enable-swift-package-manager` 禁 SPM 走 CocoaPods，bundle id `cc.tic.einz`，产物 IPA）
- `docs/CI.md`：完整指引（注册令牌生成、gitea-runner 安装、Codemagic 配置、镜像说明）

**本机 runner 尝试失败（重要教训）：** 先在 MacBook Air（Apple Silicon）装 gitea-runner v3.3.2（注意：**act_runner 已更名 gitea-runner**，v0.2.x → v3.3.2，二进制名与默认镜像都变了）。构建卡在拉取基础镜像 `docker.gitea.com/runner-images:ubuntu-latest`（1.5–2 GB）：国内网络下小镜像可拉（hello-world 12s、node:20-alpine），**大镜像 300s+ 拉不完**；配置 OrbStack registry-mirrors 与 proxies（`host.orb.internal:17891`）均无效。**结论：国内网络无法跑 Docker 容器化 runner。**

**调整决策：** 放弃本机 runner 并彻底清理（进程 / `~/.local/bin/gitea-runner` / `/Users/luk/Seafile/.runner` 注册文件 / 测试镜像 / `~/.orbstack/config/docker.json` 还原为 `{}`）；Gitea 侧删除旧 runner doomship.local。改用 **Oracle Cloud 免费 ARM 服务器（2 OCPU / 12 GB，海外网络）** 注册 gitea-runner（`linux-arm64` 二进制 + systemd 常驻，见 docs/CI.md §1.3）。Actions 页 `no matching online runner with label: ubuntu-latest` 警告待新 runner 上线后自动消失。

**runner 磁盘占用说明：** 常驻大头是基础镜像 ~2 GB（一次下载）；每个 job 容器临时创建、结束即删；JDK/Flutter/Android SDK（~2–4 GB）在容器内每次重新下载。建议：容器挂载 `~/.gradle`、`~/.pub-cache` 跨构建复用（省时省盘）+ 定期 `docker system prune -a`。

**待办：** Oracle 服务器按 §1.3 部署并跑通首次构建；挂载缓存优化（构建提速）。
