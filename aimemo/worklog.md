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

| 决策点   | 结论                                                                                                                                |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 恢复模型 | V1 纯本地备份+恢复码（模型 A），架构预留服务器托管（模型 B）                                                                        |
| 多设备   | Person≠Device 分开建模，V1 一人一机，预留扩展                                                                                       |
| 技术栈   | **放弃 UniApp**，改用 **Flutter**（dart:ffi 绑原生 libsodium，无 WebView 中间层；flutter_secure_storage / drift / camera 生态成熟） |
| 文档     | 确认按新结构大幅重写，统一命名 Einz                                                                                                 |

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

| 决策点     | 结论                                            |
| ---------- | ----------------------------------------------- |
| 配对方案   | **一次性人工配置**（静态白名单，删除配对流程）  |
| 多设备预留 | **保留**（Person≠Device 建模不变，V1 一人一机） |
| 文档更新   | 先 commit 当前状态，再更新文档                  |

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

| 决策点     | 结论                                                    |
| ---------- | ------------------------------------------------------- |
| Web 客户端 | **不做**（破坏 E2EE 信任模型，明确写入非目标）          |
| 电脑端     | 暂缓（V2 再评估：CLI 加 TUI 升级，或 Flutter 桌面端）   |
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

| 发现                                       | 修复                                                                                                                                     |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 撤销后不关闭被撤销设备的 WS                | `notifyRevoked` 发帧后 `close(4403)` + 移出 conns（否则 revoked 设备继续收新消息解密）                                                   |
| app `_uuidv7` 时间戳伪随机 + 格式非法      | 改 `Random.secure()` CSPRNG + 正确 8-4-4-4-12 UUIDv7                                                                                     |
| `MessageRepository.history()` 固定密钥解密 | 注入 `archivedKeys`（key_version→密钥），按 `env.keyVersion` 选密钥（对齐 CLI `spaceKeyForVersion`）；缺密钥时抛明确 StateError          |
| 发送推进锚点跳过未同步历史                 | **锚点只在 /sync 响应推进**：`_markSent`/CLI `_flushPending` 不再推进（PROTOCOL.md §5.2），避免新设备未同步先发消息 → 对方历史被永久跳过 |
| `x-attachment-meta` 缺失/坏 JSON → 500     | 显式校验 → 400 INVALID_REQUEST（协议 §9）                                                                                                |

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

### 多设备凭证判断修复（person_id，2026-08-29）

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

**背景：** 老板问"新设备初次载入历史是否有分页"——确认拉取层有分页（sync 翻页 100/页 + has_more），但 UI 层无分页（history() 全量渲染 + 每次 \_refresh 全量 setState）。老板要求立即优化。

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
- `lib/l10n/app_en.arb` + `app_zh.arb`：各 60+ 键（通用 9 + setupPage._ 18 + setPinDialog._ 12 + chatPage._ 27 + burnOption._ 7），占位符用 `{name}` + `@key.placeholders`
- gen-l10n 生成 `lib/l10n/app_localizations*.dart`（**入库**，generate: true 时 pub get 自动生成）
- `data/locale_settings.dart`：LocaleSettings（app_state locale：system/zh/en）+ `localeNotifier`（ValueNotifier，切换即时生效）
- `main.dart` EinzApp 改 StatefulWidget：MaterialApp 加 `localizationsDelegates/supportedLocales/locale`（null=跟随系统；手动选择 zh/en 覆盖）

**文案抽取（核心工作量）：**

- setup_page.dart：~30 处（build UI + 状态消息 + SetPinDialog 全部）——`AppLocalizations.of(context)!` 替换；**async 方法 await 后取 l10n 会触发 use_build_context_synchronously lint → 在 await 前取局部变量**（\_uploadEscrow 排障）
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
- `chat_page.dart`：initState 启动 WS（`enableWs` 参数——**测试环境关闭，避免真实连接/重连 Timer 挂起**）；`_restartTicker` 动态切换轮询间隔：**WS 在线 → 30s 兜底；断开 → 恢复 3s**（\_onWsStatusChanged 监听 connected）；dispose 清理
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
- `setup_page` A 端：新增**"自建空间（一键生成 Space Key）"**按钮（与③凭口令接入并列）→ `_generateSpaceKeyAndAuth()`：`Random.secure()` 生成 32B Space Key（**shared sodium 无 randombytes 暴露，用 Dart CSPRNG**）→ challenge-response 认证 → SetPinDialog（口令托管复用）→ `_showJoinInfoDialog()`（**QrImageView 二维码** + 口令/空间文本 + 一键复制 joinDialog.\* 键）→ 确认进聊天页；未生成密钥/未填口令分别提示
- `setup_page` B 端：口令输入框 📷 suffixIcon → `_scanJoinCode()` → `_JoinScanPage`（**MobileScanner 懒构造**——进入页面才实例化，widget 测试不触碰原生相机通道；扫到 onlyspace-join-v1 自动填 spaceId/口令 → scanJoinFound 提示）
- 依赖：`qr_flutter 4.1.0`（纯 Dart 绘制，测试环境安全）+ `mobile_scanner 7.4.0`（相机权限拍照时已配置，Android CAMERA/iOS NSCameraUsageDescription 复用）
- 测试：widget_test 加"自建空间入口"用例（**ensureVisible 滚动修复**——按钮在 ListView 视口外 tap 命中失败）；flutter test **29 项全过** + setup golden 更新（新增按钮/suffixIcon）

**小白（B）完整流程（零技术）：** 装 App → ①生成设备密钥 → 把公钥转发给 A → A 加 VPS 白名单 → 📷 扫 A 的二维码 → ③凭口令接入 → 完成。A 全程纯 App（不再需要 CLI）。

**遗留：** ① 二维码分享对话框（joinDialog）展示时机在进聊天页前——若 A 想"先建空间后补发邀请"，可后续加聊天页内入口；② mobile_scanner 需真机验证（模拟器相机不可用）；③ 白名单仍需 A 上 VPS 操作（保持手动，安全核心不变）。

### 配置页分步向导重构（交互优化；2026-08-29）

**背景：** 老板审核截图时提出关键交互批评：①"生成设备密钥"点击后无明确结果反馈；②"导入并认证"与"自建空间/凭口令接入"四个功能并列但无前后关系，易混淆；③ 建议**分步向导、每页只收集一个信息**。决策确认：**先选角色再进向导 + sealed 保留折叠入口**。

**重构（setup_page 大改）：**

- **第 0 步角色选择**：我是第一个使用者（创建新空间）/ 我要加入现有空间 / 高级 sealed（ExpansionTile 折叠）
- **创建（create）7 步**：设备名+生成密钥（**本页 Card 明确显示"✅ 密钥已生成"+ 设备 ID/公钥，回应反馈缺失批评**）→ 白名单确认（展示公钥，用户 VPS 添加后继续）→ 接入口令 → PIN（\_runPinSetup：生成 Space Key + 认证 + SetPinDialog）→ 二维码分享（QrImageView + 一键复制）→ 完成
- **加入（join）5 步**：设备名 → 扫码/粘贴加入信息（\_buildStepJoin：📷 扫码自动填 + 手动输入）→ PIN（\_runJoinAccess：认证 → 托管拉取 → 口令解密）→ 完成
- **高级（advanced）5 步**：设备名 → sealed 粘贴（\_buildStepSealed）→ PIN（\_runSealedImport：解封 → 认证）→ 完成
- 框架：\_WizardRole 枚举 + 步骤状态机（\_step/\_stepCount/\_stepTitle/\_buildStep）+ 进度圆点 + 底部上一步/下一步/完成 + AnimatedSwitcher；共享状态（\_keyPair/\_spaceKey/\_sessionToken）；\_nextStep 按 (role, step) 前置校验（每步一个信息未填即提示）；\_authenticate 提取公共认证
- l10n：wizardRole*/wizardStep*/wizard 提示键 + setupPageKeyGenerated（中英，zh/en 键一致性 diff 校验）
- 测试：widget_test 重写 3 用例（首屏角色选择/创建分流+未生成密钥提示/加入分流）；golden setup_page 更新（向导首屏）；flutter test **30 项全过**

**排障：** ① 重构期字段重复定义（旧字段残留）与 \_finish 重复（框架空实现 vs 新实现）→ 清理；② `FilledButton.tonal.icon` 不存在（API 无组合）→ tonal + Row；③ widget_test"选择你的情况"在 AppBar 与 body 各一次 → findsWidgets。

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
  3. `golden_render_test.dart` 字体加载硬编码 `C:\Windows\Fonts\simhei.ttf` → 改为跨平台候选（macOS Hiragino/STHeiti / Windows simhei / Linux Noto）；goldens 基准图在 macOS 重新生成（--update-goldens，含新 setup*step*\*.png）；
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

**后续（方案 A 升级，待老板定）：** 分栏 TUI（消息区+输入区+状态栏）、后台 WS 实时监听（复用 \_cmdListen 逻辑）、附件收发入口。桌面 GUI 版另议（Flutter Desktop 复用 ~95% 现有代码）。

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

- `.gitea/workflows/build-apk.yml`：push main / v\* 标签 / 手动触发 → debug 签名 APK（无需 keystore）
- `codemagic.yaml`：iOS 构建（`flutter config --no-enable-swift-package-manager` 禁 SPM 走 CocoaPods，bundle id `cc.tic.einz`，产物 IPA）
- `docs/CI.md`：完整指引（注册令牌生成、gitea-runner 安装、Codemagic 配置、镜像说明）

**本机 runner 尝试失败（重要教训）：** 先在 MacBook Air（Apple Silicon）装 gitea-runner v3.3.2（注意：**act_runner 已更名 gitea-runner**，v0.2.x → v3.3.2，二进制名与默认镜像都变了）。构建卡在拉取基础镜像 `docker.gitea.com/runner-images:ubuntu-latest`（1.5–2 GB）：国内网络下小镜像可拉（hello-world 12s、node:20-alpine），**大镜像 300s+ 拉不完**；配置 OrbStack registry-mirrors 与 proxies（`host.orb.internal:17891`）均无效。**结论：国内网络无法跑 Docker 容器化 runner。**

**调整决策：** 放弃本机 runner 并彻底清理（进程 / `~/.local/bin/gitea-runner` / `/Users/luk/Seafile/.runner` 注册文件 / 测试镜像 / `~/.orbstack/config/docker.json` 还原为 `{}`）；Gitea 侧删除旧 runner doomship.local。改用 **Oracle Cloud 免费 ARM 服务器（2 OCPU / 12 GB，海外网络）** 注册 gitea-runner（`linux-arm64` 二进制 + systemd 常驻，见 docs/CI.md §1.3）。Actions 页 `no matching online runner with label: ubuntu-latest` 警告待新 runner 上线后自动消失。

**runner 磁盘占用说明：** 常驻大头是基础镜像 ~2 GB（一次下载）；每个 job 容器临时创建、结束即删；JDK/Flutter/Android SDK（~2–4 GB）在容器内每次重新下载。建议：容器挂载 `~/.gradle`、`~/.pub-cache` 跨构建复用（省时省盘）+ 定期 `docker system prune -a`。

**待办：** Oracle 服务器按 §1.3 部署并跑通首次构建；挂载缓存优化（构建提速）。

### TUI 状态栏美化与附件上传修复（2026-09-02）

**产出（commit 7cd948f / ed12b3a / 601397b / a3784f2 / 待提交）：**

- 状态栏各片段改用灰色竖线 `|` 分隔，去掉 `WS:` 前缀，身份片段 `person@device` → `person #device`，最终样式：`Einz TUI | ● 在线 | Alice #macbook | 临时通知`；同步更新 docs/ONBOARDING.md。
- `/help` 与裸 `/` 的命令列表改为 system 消息进消息流（随消息区滚动），不再占用顶部状态栏通知。
- **附件上传修复：** `/attach <file>` 报 `HandshakeException: Connection terminated during handshake`——根因是 `ApiClient.postAttachment`/`getAttachment` 未套 `_withRetry`（其余请求都有），大 blob 上传耗时长、网络抖动/握手中断时直接失败且不重试。修复：shared `api_client.dart` 两方法套 `_withRetry`（3 次退避重试，与设计注释"翻墙/网络抖动下的间歇性握手失败不致命"一致；server 端只在收到完整 body 且 size/sha256 校验通过后落盘，重试幂等安全）。

**遗留问题（老板决策后修复）：** 老板选择**先传 blob 再发消息**方案（杜绝幽灵消息）。实现（commit 待提交）：server `attachments.message_id` 去掉外键（旧库自动重建迁移）+ `storeAttachment` 不再要求 message 先存在 + 新增 `cleanupOrphanAttachments`（孤儿窗口 10 分钟，随每小时清理任务）；cli `attachFile`/`_cmdAttach` 改为先上传 blob 再发消息；PROTOCOL.md §6.1 更新两阶段协议。验证：`dart analyze` 无问题、`tsc` 构建通过、`server/test/verify_two_phase.mjs`（新写验证脚本）四步全过——blob 先于 message 上传 200、再发消息关联成功、sync 返回 attachments_meta、孤儿清理删文件+记录且正常附件保留。

**发现存量问题（与本任务无关）：** `npm test`（smoke.test.ts）基线即失败——config.ts 早已改为"自主模式"（白名单只认 devices 表动态登记，不再读 config.json），而 smoke.test.ts 仍用旧 config.json 白名单方式（dev-a1 未登记 → challenge 403）。修复需把测试改为先 POST /devices/enroll 再认证，待老板安排。

### smoke 测试修复 + TUI 交互增强（2026-09-02）

**老板安排（上一节遗留问题）顺手修掉 + 三个 TUI 需求（commit 待提交）：**

- **smoke.test.ts 修复（存量问题）：** 改为自主模式流程——TestDevice 新增 `enroll()`（POST /devices/enroll，首设备免邀请码自举、B 凭 A 生成的邀请码登记），登记后回写服务端分配的规范 id（dev1/dev2），移除 config.json 白名单方式；AAD 的 space_id 改用 enroll 响应值。`npm test` 全绿。
- **TUI 方向键（输入体验）：** 之前按方向键会打出 `[D[C[A[B`（ESC 序列的 `[` 与字母被当普通字符插入）。新增转义序列解析（ESC [ A/B/C/D、ESC O 变体、Home/End、Delete），跨 chunk 拼合；↑↓ 浏览输入历史（首次进入暂存草稿、↓ 越过最新恢复草稿，口令/邀请码等机密输入不进历史），←→ 移动光标、Home/End 跳首尾、Backspace 删光标前、Delete 删光标处；输入区渲染改为光标跟随（ANSI 定位到文本内偏移），并顺带修复 hiddenInput（口令）在局部重绘时泄露原文的问题。
- **状态栏 person 名加粗：** `_personLabel` 返回 `**person** #device`，person 与 device 视觉区分。
- **对方消息右对齐（气泡风格）：** 对方消息整块右对齐到终端右缘，正文在右、末尾附 `[who seq v]` 元数据（如 `          今天来玩 [sisi seq=31 v1]`）；自己消息与系统提示保持左对齐。

**验证：** `dart analyze`（cli/shared）无问题、`npm test` 全绿、`tsc` 构建通过。

**光标定位修复（同日跟进）：** 方向键功能上真机后老板反馈"输入文字紧贴 you>，但光标在固定隔开一段距离处"。根因有二：① `_displayWidth` 不剥除 ANSI 转义字节，`you>` prompt（含色码）被算成 14 列（实际 5 列）→ 光标定位到固定偏移处（同时使折行宽度、右对齐填充都偏窄，一并修复）；② `_cursorPos` 列公式差一列（光标应在已渲染文本之后）。修复：`_displayWidth` 跳过 `\x1B[...m` 序列；光标列 = lead + offset + 1。`dart analyze` 无问题。

**全角光标修复（同日跟进）：** 中文输入时光标落在字符一半处——`_cursorPos` 用 UTF-16 代码单元数当列偏移，全角字符占 2 列。改为行内列 = 行首偏移 + `_displayWidth(光标前文本)` + 1，折行边界光标落到下一行行首。`dart analyze` 无问题。

### 自动补拉：断线后/周期同步兜底（2026-09-02）

**背景：** 老板反馈 A 发消息给 B 时若 B 临时断线，过后 B 收不到，必须手动 /sync。根因：WS 重连只重连、不回放断线期间的消息（hello 帧无 replay，消息只推送给已连接设备），chat_core 的 `onStatus` 只记录断线时间不触发补拉。

**实现（commit 待提交）：** `ChatSession.startWs` 新增可选 `onAutoSync` 回调 + 两种补拉：

- **重连快路径**：`onStatus` 里记录 wasDown，WS 从断线转 connected 时立即后台 `sync()` 补拉缺口；
- **周期兜底**：`autoSyncInterval = 30s` 定时器增量拉取（WS 推送丢帧/断线不回放都兜住，顺带补发离线发送队列），`stopWs` 取消。
  并发保护 `_autoSyncing`；网络异常静默等下轮。TUI 4 处 `startWs` 调用点接 `onAutoSync: (_) => _render()`（静默重绘，不占状态栏）。

**验证：** `dart analyze` 无问题；双端断线场景（probe 常驻 A + kill server 8s + B 发消息 + A 重连）probe 日志确认 `reconnecting×5 → connected → AUTOSYNC added=1 → FOUND-VIA-AUTOSYNC`（无需 /sync）。测试脚本 `cli/test/auto_sync_probe.dart` + `auto_sync_check.sh`（编排脚本在本工具非交互环境有进程回收挂起问题，真实终端可用）。

**测试环境踩坑（demo 是自主模式前遗留）：** store-b.space_id 被旧 import 写死 space-demo 与登记的真实 space_id 不一致 → AAD 解密失败，需对齐双端 space_id；setup.sh 重跑会用 import 重置 space_id 故不能复用；server.pid 缺失时 stop.sh 空转，需 pkill。

### 重启后消息时间显示 1970 修复（2026-09-02）

**背景：** 老板反馈重启 TUI 后近一半消息时间显示 `19700101-080000`，且发送时显示正常时间的消息重启后也变 1970。

**根因（实证）：** 客户端落盘 created_at 选错值——`chat_core.sync()` 用 `createdAt: seq`（server_sequence 序号）落盘，覆盖了服务端响应携带的真实时间戳（store-a 历史里 seq=1,2,3 / 13,14,15 的 created_at 正是 1,2,3 / 13,14,15）；WS 路径兜底 `env.createdAt ?? 0`（缺省落 0，即精确的 19700101-080000）。重启后 `loadHistory` 用落盘的坏值 → 显示 1970。发送路径（flushPending）落盘真实时间、且发送不推进锚点，下次 sync 会把自己刚发的消息重新拉回并以 seq 覆盖 → "发送时正常、重启后变 1970"。（einz.dart 的 `_syncIncremental` 一直用 `env.createdAt!`，无此问题。）

**修复（chat_core.dart）：**

- `sync()` 增量落盘改 `createdAt: env.createdAt ?? seq`（服务端始终携带真实 created_at）；
- WS 兜底改 `env.createdAt ?? event.serverSequence`（不再落 0）；
- 新增 `_backfillTimestamps()` 存量自愈：检测到坏时间戳（<1e11，1973 年前）时全量拉取服务端消息、按 message_id 幂等覆盖为真实 created_at，随后 `loadHistory()` 重建展示缓存让当前会话立即正确；失败静默下次再试。

**验证：** `dart analyze` 无问题；`cli/test/timestamp_check.dart`（自包含：脚本内拉起 server 子进程，不依赖后台进程）——store-a 原有坏数据（ca=1,2,3,13,14,15）已被 sync 治愈；再故意改坏一条（ca=7）后重跑，回填为真实值 1788325059952 ✅。

### App 端启动流程自动化（去掉 config.json 白名单，2026-09-02）

**背景：** 服务端早已全自动登记（devices 表 enroll：首设备免邀请码自举、之后凭邀请码；challenge 校验 devices 表），但 App 启动向导还停留在旧时代——从不调用 enrollDevice，仍要求用户把公钥手动加进服务器 config.json 白名单并重启，再粘贴 sealed 副本。

**调研结论：** shared 的 ApiClient 已具备 enrollDevice/challenge/verify/createInvite/KeyEscrowService 全部能力，无需改 shared 协议与 server；enrollDevice 对已 active 设备幂等 → 存量设备无迁移负担。App 流程唯一缺口 = 认证前缺少 enroll 步骤、deviceId/spaceId 用了本地临时值而非登记返回值。

**设计（老板拍板）：** Android + iOS 一起改（纯 Flutter 层同构）；对方加入的邀请码打包进分享二维码（一键加入）。

**实现（纯 Flutter/App + shared 一处）：**

- shared JoinInfo 扩展可选 inviteCode（`&i=` 参数，旧格式无码仍可解码，兼容）；新增 3 个编解码单测。
- setup_page.dart 向导改造：
  - create：白名单步骤 → **登记设备（自动自举）**；失败（服务器已有空间）提示改用"加入"向导；分享步骤先"生成邀请码（personB）"再展示含邀请码+口令的二维码，可重新生成；
  - join：加入页新增邀请码字段，扫码自动填入（含新码）；PIN 步先凭邀请码 enroll 再认证再拉托管；
  - advanced（sealed 导入）：同样先凭邀请码 enroll；
  - 认证（challenge）一律用登记返回的真实 deviceId；escrow/分享用登记返回的真实 spaceId（弃 space-demo 默认值）；\_finish 进聊天页用登记值。
  - 新增 SetupPage 测试注入 enrollOverride/createInviteOverride（与既有 probeServer/db 同模式）。
- l10n zh/en ARB 同步（删白名单文案、新增登记/邀请码文案），flutter gen-l10n 重新生成。
- golden 测试：白名单步骤用例 → 登记步骤；1.1.3–1.1.6 改走"登记→口令→PIN→分享（生成邀请码）→完成"新流程（注入 fake enroll/invite）；1.3.2 sealed 新增邀请码输入框 → 全部重刷图片。

**验证：** flutter analyze 仅剩预存 info（ws_realtime_service）；`flutter test` 39/39 全绿 ✅（golden 12 项先 --update-goldens 重刷再全量比对通过）。

**测试踩坑：** create 流程 step2 登记是网络步，旧 golden 纯"下一步"走法断链——必须注入 enroll 才能走到口令/PIN/分享/完成步骤；widget 测试无真实 sodium/DB 限制同前（LocalDatabase.forTesting + probeServer 注入）。

### TUI 引导阶段 '/' 后输入崩溃修复（2026-09-02）

**现象（老板）：** 新设备引导（消息流问答）中输 '/' 回车（提示"引导中仅支持 /exit 退出（输入未提交）"）后再输入任意字符 → `RangeError (end): Only valid value is 0: 1` 崩溃，且回到 shell 后输入不回显。

**根因（代码定位）：** 引导问答的 '/' 分支与"必填留空"分支只 `input.clear()` **未复位 cursor**（回车前 cursor=1，清空后 input 长度 0）→ 下一字符进 `_insertAtCursor` 执行 `str.substring(0, cursor)` = `substring(0,1)` 于空串 → RangeError。崩溃走 unhandled async exception，`_restoreTerminal()` 未执行 → 终端残留 raw 模式（无回显）。

**修复（einz_tui.dart）：**

- 两处引导分支 `input.clear()` 后补 `_state.cursor = 0`；
- `_insertAtCursor` 加防御钳制（cursor 超界时 clamp 回 [0, len]），杜绝同类不一致再崩；
- 输入回调整体包 try/catch：未捕获异常 → `_inputLoopCrash()`（先 `_restoreTerminal()` 恢复 echo，再报错退出），不再残留不回显终端。

**验证：** dart analyze 无问题；新增 `cli/test/guide_crash_check.py`（pty 驱动：全新 store → 引导问答发 '/' 回车 → 发 'x'）——修复后进程存活、无 RangeError、/exit 正常退出 ✅。

### 引导中 /exit 未立即中断（2026-09-03）

**现象（老板）：** 新设备引导"请输入设备名称"问答输 /exit，仍继续输出"系统将为您自动设置本设备名称"→"设备与空间绑定中"后才退出。

**根因：** /exit（及 Ctrl+C）路径只 `_abortPendingGuide()`（以空串 complete 当前 \_prompt）并置 running=false，但 \_runGuide 把空串当"用户跳过"继续执行后续线性步骤（自动名提示、store.save、enroll 绑定、口令托管等）；仅部分循环处有 `!running` 守卫，靠 2 秒延迟 exit(0) 兜底。

**修复（einz_tui.dart \_runGuide）：** 在人物名、设备名两处 prompt 后立即 `if (!_state!.running) return;`；绑定成功后、发起者口令托管流程前再加守卫；catch 的"绑定失败"else 分支同样守卫（中断时不输出噪音）。

**验证：** dart analyze 无问题；新增 cli/test/guide_exit_check.py（pty 复现老板步骤）——/exit 后进程立即退出、无后续引导提示 ✅。

### 换机到 iMac 2019 + Docker 目录枚举问题（2026-09-04）

**背景：** 老板从 MacBook Air（性能不足）切换到 **iMac 2019（Intel x86_64，64GB）** 作为主力开发机，新机需重装开发环境（Node / Dart / libsodium / Flutter，见 docs/ONBOARDING.md「新机环境准备」，原 HANDOFF.md 精华已迁入后删除）。已记录至 aimemo/userProfile.md 设备信息。

**Docker 挂载外部卷无法枚举目录（本次核心坑）：** `./cli/dart-docker.sh tui` 报 `PathAccessException: Directory listing failed, path = '/app/cli/bin/' (OS Error: Operation not permitted, errno = 1)`。

- 根因：仓库位于外部 APFS 卷 `/Volumes/repodisk`（挂载标志 `noowners`），Docker Desktop（gRPC-FUSE/virtiofs）对此类卷**只能按路径打开单个文件、无法枚举目录**（`ls 具体文件` 可以，`ls 目录` 一律 EPERM）。已验证：容器里枚举 `~/` 下目录正常，枚举 `/Volumes/repodisk` 下任何目录（含新建测试目录）都失败——与仓库内容无关，是卷的问题。
- 符号链接**不解决**（已实测）：`ln -s /Volumes/repodisk ~/.dtest_link` 后容器内 `ls /app/.dtest_link/...` 仍失败——FUSE 在宿主侧解析链接后还是要枚举 noowners 卷目录。
- **解决方案：仓库必须物理位于 Docker 可枚举的卷上**（如 `~/`）。本次：提交并推送 `7cc4437` 到远程 `origin`（git.tic.cc/fon/einz，仓库已有远程，HANDOFF §1 的 bundle 搬运方式已过时）→ 老板 `git clone ... ~/einz` 后在该路径开发。换机后 clone 需补：`cli/config.json`（服务器地址，非白名单，见下）、`deployment/.env`（备份密钥）等本机专属文件。

**配置文件角色澄清（防混淆）：** 两个 config.json 含义不同——① `server/config/config.json` 白名单**已废弃**（2026-09-02 起自主模式：server 首启自动生成 space_id 存 db meta，白名单 = devices 表动态登记，首设备免邀请码自举、之后凭邀请码；ONBOARDING.md §0）；② `cli/config.json` = `{"server": "https://einz.tic.cc"}` 是 **TUI 默认服务器地址**（可本地改，优先级低于 `--server` 参数与 store 持久化值），不是公钥白名单。

**验证：** 宿主 `~/` 下目录容器枚举正常。老板实测：`git clone` 到 `~/einz` 后 `./cli/dart-docker.sh tui` **运行成功**（noowners 卷解决方案确认有效）；测试完成即删除 `~/einz`——**日常开发仍留在原路径 `/Volumes/repodisk/productX/einz`**，除非再遇 Docker 枚举类问题才考虑迁移到 `~/`。

### iOS 模拟器构建与启动验证（2026-09-04，iMac）

**背景：** 老板在 iMac 上首次尝试 iOS 本地构建（`flutter create . --platforms=ios,android` 在 app/ 内，仓库根无污染）。初始 `flutter run` 报 "No supported devices connected"，排查链：iPhone 已 USB 识别但 **unpaired（code -29）** 或 **未开开发者模式（code -27）**——设备侧问题，真机验证后置；先走模拟器验证构建。

**环境修复：**

- **CocoaPods 未装** → `brew install cocoapods`（1.16.2_2），并 `flutter config --no-enable-swift-package-manager`（项目 Podfile 含本地 libsodium pod，禁 SPM，见 docs/IOS.md §1）。
- **Xcode 16.1 无 iOS 18.1 平台**（只有 iOS 17.4 运行时）→ `flutter build` 预检 `-destination generic/platform=iOS` 失败 "Unable to find a destination"（iOS 18.1 is not installed）。`xcodebuild -downloadPlatform iOS` 下载 8.59G（Apple CDN 中国直连 ~6-10MB/s，无需翻墙），安装后模拟器构建即通。
- **sqlite3 native assets 从 GitHub 下载预编译库超时**（`SocketException: Operation timed out, github.com`）——重试时 GitHub 可达后通过；若再遇可考虑翻墙或 sqlite3 hook 备选方案（pub.dev hook-topic）。

**验证结果：** `flutter build ios --simulator --debug` ✅ 编译通过（含 libsodium pod 链接，`✓ Built build/ios/iphonesimulator/Runner.app`）；iPhone 16（iOS 18.1）模拟器 `flutter run` 启动成功（Dart VM Service 就绪、进程存活），截图确认首屏渲染。

**遗留：**

1. `flutter run` 启动早期出现 `SqliteException(5): database is locked` 未处理异常一次，未阻塞启动，待观察是否复现。
2. 真机验证（任务 #7）后置：iPhone 配对（Xcode Devices 窗口 Pair + 手机确认）、XR 需开「设置→隐私与安全性→开发者模式」、Xcode Accounts 登录 Apple ID 选 Personal Team（当前 `0 valid identities`）。
3. iOS 17.4 模拟器运行时已删除（释放 ~6.7G，仅留 18.1）；iPhone 15 等 17.4 模拟器设备随运行时移除而不可用。

**环境现状（iMac）：** Xcode 16.1 + iOS 18.1 运行时、CocoaPods 1.16.2、Flutter 3.47.2（禁 SPM）、Dart 3.13.2、Node 23.5.0、libsodium 1.0.22（brew）；Android SDK 缺 cmdline-tools（Android 侧待办，见 flutter doctor）。

## 2026-09-08 会话：启动门误进向导根因 + l10n 一致性修复

**bug 调查：重启 App 再次进入新设备向导（疑与输错 PIN 有关）**

- 结论：输错 PIN **不会**删除本地 store——`AppLockService.unlock` 失败只计尝试次数/锁定 30s；chat/setup 的「退出秘境」确认只调 `exit(0)` 不清数据；全 app 唯一清数据路径是 `_onDeviceRevoked`（仅服务端 device.revoked 广播触发，即 /revoke 或 /recover 全丢恢复）
- 真凶：`StartupGate._check()` 在本地库查询异常（SQLite 锁竞争/热重启残留连接）时 catch 降级为「未配置」→ 直接进新设备向导（数据未丢只是误导向，且重走向导会重复登记设备）
- 修复（41b98b3）：启动门瞬态失败自动重试 4 次（1s 间隔）→ 仍失败显示「启动初始化失败，配置未丢失，请重试」错误页（含重试按钮），不再自动进向导

**l10n 一致性修复（79f2e8f）**

- 244ab3d 文案 commit 造成 ARB/生成文件/测试三方不一致（AppBar 标题冒号版 vs 无冒号、身份 vs 身份名字、PIN vs 锁屏码、我的设备 vs 设备名称），widget/join/envelope 测试红
- 老板决策：以 ARB 为准（文案不动）→ `flutter gen-l10n` 重新生成 + 修正 6 个测试文件 35 处断言匹配实际渲染；非 golden 测试 25 项全过
- golden：10 个 PNG 因文案渲染变化失配（0.44%~2.70%），老板决策**暂不重刷**（golden 测试保持红，作为文案变更标记，待批准后随时重刷）
- 待确认：ARB `wizardSwitchToPassphrase` = 「该用线上密保口令」疑似「改用」笔误

## 2026-09-08 会话：邀请码降级 B（二维码不再含明文口令）

**背景：** 老板指出 App 邀请码二维码（JoinInfo `einz-join-v1?space=&p=&i=`）含**明文口令**不安全，决定降级到 B 方案——与 TUI 完全一致：邀请码分享不再携带口令，口令由加入方另行输入。

**设计（老板拍板 2026-09-08）：**

- 二维码保留，内容改为**纯邀请码**（扫码=输入邀请码；无口令无风险）；彻底去掉含口令字段的 JoinInfo 分享格式
- 口令被重设的通知机制保留并完善：WS 广播 passphrase.rotated（在线 App SnackBar / TUI 系统消息）+ 上线/重连补查（对比 getKeyEscrow updated_at，已改则发一次通知）

**实现：**

- `app/lib/chat_page.dart` `_showInviteDialog`：删除生成前的口令过时校验（getKeyEscrow 对比 + 重验证弹窗）与口令编入；二维码 = 纯邀请码；提示文案改「对方扫码或输入此邀请码加入，加入时需另行输入口令」
- 删除死代码：`_showReverifyPassphraseDialog` + `_ReverifyPassphraseDialog` 类 + `_escrowPassphrase` 缓存 state（邀请码编入口令的唯一用途）；保留 widget.escrowPassphrase（补设锁/改口令用）与 `_escrowUpdatedAt`（上线补查对比用）
- `shared`：删除 `JoinInfo` 类/export/单测（生产代码已无解析者；join 向导只接收邀请码文本）
- `cli/bin/einz_tui.dart`：WS onStatus 变为 connected 时再次 `_checkEscrowRotated`（对齐 App 的重连补查）；补查/广播通知后更新 `store.escrowUpdatedAt` 并 save（防消息流重复刷屏）；通知文案更新（接入/space 或修改 /passphrase 时使用新口令）
- `docs/KEY_ESCROW.md` §12.2/12.3：三通道改为两通道，记录降级 B 决策

**验证：** shared dart analyze 0 issue + dart test 24 全过；app flutter analyze 仅 1 既有 info lint（ws_realtime_service.dart，非本次引入）；chat_page_menu/widget/setup_join_passphrase/setup_envelope 20 项全过。golden 失配为既有已知问题（2026-09-08 早前文案 commit 造成，老板已决策暂不重刷），本次改动不在 golden 覆盖路径内。

**遗留：** join 端扫码功能（scanJoin 文案）仍未实现——二维码现在只装邀请码，未来若做扫码只需解析纯邀请码文本。

## 2026-09-08 会话：新 Logo（粉蓝图标）替换品牌 + 应用粉蓝主色调

**背景：** 老板提供 AI 生成新 Logo（`/Users/luk/Downloads/已生成图像 1 (5).png`，1254×1254 RGB 无透明），要求 ① 作为 app 的 Logo ② 取图标里的粉蓝配色作 app 主色调。

**图标配色提取**（sips 转 BMP + 纯 Python 聚类；本环境无 PIL 且 pip 被 PEP 668 限制）：

- 粉系：浅粉底 #FDD6ED/#FDC1E5（占比 ~70%），粉强调 #FB89CD
- 蓝系：天蓝 #3BAFFD、浅蓝 #7BCDFC、深蓝 #2271F7
- 空间结构：整幅以浅粉渐变为主，中部偏下为蓝色图形（约 20×20 网格 6-14 行中列），四角近白

**实现：**

- 全平台图标以 1024 母版（`assets/logo.png`，品牌源文件）经 `sips -z` 生成替换：Android 5 个 mipmap（48/72/96/144/192）、iOS AppIcon 15 张（20~1024 全档，含 83.5@2x=167）；macOS/web（favicon 16 + icons 192/512/maskable）本地同样替换但**不入 git**（项目约定只跟踪 ios/android，见 app/.gitignore）
- `app/lib/main.dart` 粉蓝主题：seed 天蓝 #3BAFFD（派生 primary 保持深蓝对比达标）；`copyWith` 注入粉系（secondary #D6529C、secondaryContainer #FDD6ED 浅粉底、tertiary #2271F7 深蓝）+ 浅粉表面族（surface #FFF8FB / container 粉白渐变）；scaffold/appbar 背景 #F4FAFF 浅蓝白 → #FFF5FA 浅粉白；输入框描边 #D9E6F5→#E9D5E0、聚焦边 #4FC3F7→#3BAFFD
- `web/manifest.json` theme_color/background_color #0175C2 → #3BAFFD/#FFF5FA（本地生效，gitignored）
- 旧 `assets/logo.svg` 未删除（git 历史/潜在回退参考）

**验证：** app flutter analyze 0 issue（仅 1 既有 info lint，非本次引入）。golden 政策不变：主题色改动使 golden 失配 → 保持红不重刷（老板既定决策 2026-09-08）。启动图标为原生资源改动，需完整重建/重装才能在桌面看到新图标（热重启不刷新 launcher icon）。

**备注：** 应用内 UI 原本无 Logo 展示位（logo.svg 仅设计源，未被任何页面引用）；如需在锁屏/设置/聊天页头展示新 Logo，可作为后续 UI 任务单独排期。

## 2026-09-08 会话：应用内展示新 Logo（对话页/向导页标题左侧 + PIN 解锁页）

**背景：** 老板要求把新粉蓝 Logo 放进 UI：对话页、向导页的顶部标题左侧，PIN 解锁页找合适位置。

**实现：**

- `pubspec.yaml` 注册 `assets/logo.png`；新增共用组件 `app/lib/brand_logo.dart`（`BrandLogo`：ClipRRect 圆角 + Image.asset，按展示尺寸 cacheWidth 降采样解码，避免顶栏小图解码 1024 大图）
- 对话页 `chat_page.dart`、向导页 `setup_page.dart`：AppBar 标题改为 `Row[BrandLogo(28) + 10px + Flexible(Text, ellipsis)]`（无 leading，Logo 贴标题左侧；长标题自动省略防溢出）
- PIN 解锁页 `lock_page.dart`：解锁表单顶部原 56px `Icons.lock_outline` 占位图换成居中 `BrandLogo(72, r16)`；「未设置 PIN」的 noLock 提示分支保留 lock_open 图标（有语义：说明为何不显示解锁表单）

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；widget/chat_page_menu/lock_page/wizard_envelope_entry 4 个文件 17 项非 golden 测试全过。golden 失配保持红不重刷（既有决策；本次新增图片渲染亦在 golden 覆盖内，预期失配）。

## 2026-09-08 会话：对话页菜单标签淡化 + 与老板并发文案改名的协调收尾

**菜单样式（本次任务）：**

- 对话页右上角菜单行内左侧标签（我的名字/我的设备/语言/阅后即焚/锁屏码等 6 行）改用 `colorScheme.onSurfaceVariant` 稍淡色，与右侧当前值文字（默认 onSurface 深色）区分；纯动作项（邀请码/导出等无右值）保持原样

**并发协调记录：**

- 老板同一工作区同步改文案（「PIN 锁屏码」→「锁屏码」，含 ARB/生成文件/app_lock 异常串/lock+setup+menu 测试断言），其 WIP 中间态曾致 4 个 PIN 测试瞬红——A/B（stash 我的改动）证实与我的菜单样式无关，根因是 ARB 改名后测试断言未同步 + 未提交的生成文件中间态
- chat_page_menu_test 退出弹窗断言同步 523d25a 新文案（「将彻底关闭应用。」→「将在本设备上退出 Einz 秘境。」）
- 老板选择「我代为分两个 commit 收尾」：① b579172 文案批次（含 test 文件锁屏码断言与退出断言）② 本次样式（chat_page.dart + 本条注记）
- `server_settings.dart` 的 `kEinzServer = http://localhost:3000` 为老板本地测试配置（源码注释「不要 commit」），始终不入库

## 2026-09-08 会话：锁屏码文案空格清理 + 对话页菜单第二组重排

**背景：** 老板指出「PIN 锁屏码」机械删除后残留空格文案（如「设置 锁屏码」），要求修复；并要求把菜单第二组顺序调整为：界面语言/阅后即焚/锁屏码/邀请码/密保口令/导出完整备份。

**实现：**

- `app_zh.arb` 5 处空格清理：wizardRecoverDone（请设置锁屏码）、setupPageSkipPinTitle（不设置锁屏码？）、setupPageSkipPinMessage（不设锁屏码则…）、chatPageSetLockTitle（设置锁屏码）、lockPageNoPinSet（尚未设置锁屏码（为空时不启用）），`flutter gen-l10n` 重新生成；chat_page_menu_test 6 处断言同步去空格
- 菜单第二组 PopupMenuItem 重排为 locale→burn→pin→invite→passphrase→export（锁屏码移到邀请码前、密保口令在导出前）
- 菜单标签 `chatPageMenuChangePassphrase`：修改口令 → 密保口令（与 627e76c 口令密保箱、确认弹窗「修改密保口令？」命名方向一致）；chat_page_menu_test 菜单项断言/点击同步

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；chat_page_menu/lock_page/setup_envelope_verify/setup_join_passphrase 4 文件 18 项全过。

**遗留提示：** 改口令弹窗（chatPageChangePassphraseTitle 等）标题与按钮仍为「修改口令」，与菜单「密保口令」不一致；确认弹窗已是「修改密保口令？」。如需全套统一为「密保口令」措辞，另行排期。

## 2026-09-08 会话：邀请码弹窗修复（弹窗不显示 + 二维码从未可见）

**老板真机报告：** app 使用一段时间后点菜单生成邀请码，经常整个屏幕变暗但弹窗不出现；flutter run 报 RenderIntrinsicWidth / RenderBox was not laid out 连锁异常（异常原文开头被截断）。另补充：弹窗里从未见过二维码。

**根因（双重，已用 widget 测试复现确认，e07c9d6）：**

1. 弹窗内容用 `QrImageView`（qr_flutter 4.1.0）——其内部**无条件包 LayoutBuilder**（qr_image_view.dart build），而 AlertDialog 内部用 **IntrinsicWidth** 包裹内容做固有尺寸测量 → 弹窗首帧 performLayout 抛 `LayoutBuilder does not support returning intrinsic dimensions`（Flutter issue #46063 同款签名），整个弹窗子树未布局 → 遮罩变暗、弹窗不出现。时序相关性：IntrinsicWidth 仅在松约束相位触发测量，真机 vsync 下偶发命中 → "使用一段时间后经常"。
2. `_QrContentView` 的绘制面 CustomPaint **无显式尺寸**且被内部 Padding 松约束包裹 → 实际 0x0，`QrPainter.paint` 直接 return（"[QR] WARN: width or height is zero"）→ 即使弹窗正常也看不到二维码。

**修复：** chat_page.dart 新增私有 `_InviteQrCode`（`QrCode.fromData` + `QrPainter.withQr` 自绘，SizedBox 160x160 显式定尺寸），无 LayoutBuilder、必定可见；不用 `package:qr` 直引（qr_flutter 已 re-export，避免 unnecessary_import lint）。新增真实路径回归测试 `app/test/invite_dialog_layout_test.dart`：开菜单→邀请码→断言首帧无异常、弹窗内容齐全、二维码 160x160 可见。

**验证：** flutter analyze 仅剩 1 条既有 info lint（ws_realtime_service.dart prefer_initializing_formals，存量不动）；回归测试通过。`server_settings.dart` 本地 localhost 配置照旧不入库。

**经验教训（跨项目可复用）：** 任何放在 AlertDialog/SimpleDialog（内部 IntrinsicWidth）里的内容，都不能含 LayoutBuilder / ListView / PageView / SingleChildScrollView / 自定义不支持固有尺寸的 RenderBox——首帧必然抛固有尺寸异常。QrImageView 的 LayoutBuilder 是 qr_flutter 4.x 的已知坑。

## 2026-09-08 会话：锁屏页顶栏 ⋯ 菜单（语言/退出）+ 身份卡片显示优化 + 文案统一提交

**任务：** ① 重启后输入 PIN 解锁的 LockPage 也要有右上角展开菜单（对齐新设备向导），含「界面语言 + 退出」；② 菜单样式对齐对话页：标签靠左、当前值靠右（如「界面语言 中文」），标签用 onSurfaceVariant 淡灰；③ 老板在暂停期间自改的文案（wizardRoleTitle→wizardStartTitle「寻找秘境...」、密保口令措辞统一、领地创建者/共有者→秘境创建者/共有者、cli 同步等）一并提交；④ setup_page 身份卡片：有名字显示名字，无名字才显示身份标签本身。

**实现：**

- `lock_page.dart`：新增 `_buildMenu`（PopupMenuButton：语言行「界面语言 中文」= Row 标签淡灰 + Spacer + 当前值；退出行；中间 PopupMenuDivider）、`_showLocalePicker`（复用 LocaleSettings 底部弹层，即时生效）、`_showExitAppDialog`（确认后 exit(0)）；两个 Scaffold（正常解锁表单 + \_noLock 兜底页）AppBar 均挂 ⋯ 菜单；onSelected 沿用 300ms 延迟防 MenuRoute/DialogRoute 交叉卸载断言
- `setup_page.dart` 身份卡片：`title: Text(aName.isEmpty ? wizardIdentityCreator : aName)`（bName 同）；不再拼接「名字 (身份)」
- 测试同步：widget_test/setup_probe_retry_test 的「Einz 秘境：创建中：名字」→「创建中：我」（老板文案 名字→我）；4 个测试文件 5 处 `find.textContaining('秘境创建者')` → `find.text('Lukas')`（身份卡有名字只显名字）；golden_render_test 退出弹窗断言「将彻底关闭应用。」→「将在本设备上退出 Einz 秘境。」（HEAD 已过期，顺手修）

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；全部功能测试通过（含 lock_page/menu/join/envelope/probe_retry/widget/invite_dialog）；11 个 golden 像素失配保持红不重刷（政策：禁止 --update-goldens；本轮文案 + 身份卡 + 锁屏 ⋯ 图标均影响渲染，需老板定夺是否后续统一重刷）。

**不入库：** `server_settings.dart` 的 `kEinzServer = http://localhost:3000`（老板本地测试配置，注释「不要 commit」，照旧跳过）。

## 2026-09-08 会话：口令"重设"误报修复（对方只是重启输 PIN 却收到"已重设密保口令"）

**背景：** 老板报告：对方没有改口令，只是 APP 重启输入 PIN 解锁，TUI 却收到系统消息
「⚠️ 对方已重设密保口令——接入或修改口令时请使用新口令」。

**根因：** `KeyEscrowService.hashPassphrase` 用 libsodium `crypto_pwhash_str`（**自含随机盐**），
同一口令每次生成的哈希串都不同。服务端 `uploadKeyEscrow` 原凭
`prevRow.passphrase_hash !== hashVal` 判定"口令被重设"——只要有旧行必误判。而 App 每次
重启解锁都会 `lock_page._syncEscrow` 重传密保箱 → 实时广播 + `updated_at` 推进 → 对方
TUI/App 双路误报（离线补查 `serverAt > knownAt` 也误触发）。

**实现（显式 rotated 标记，服务端不再比对哈希）：**

- `server/src/escrow.ts`：`rotated: true`（仅"修改口令"流程发送）才推进 `updated_at` +
  广播 `passphrase.rotated`；普通重传（首次设口令/解锁同步）保留原 `updated_at`、不广播
- shared：`ApiClient.uploadKeyEscrow` / `KeyEscrowService.upload` 增加 `rotated` 透传
- App 改口令弹窗传 `rotated: true`，成功后回传服务端 `updated_at` 记录本端已知时间
  （防下次补查误报"自己刚改的口令"）；`_checkEscrowRotated` 命中后记录已知时间防刷屏
- App `lock_page._syncEscrow`：服务器包已不旧于本端（`openPackage` 解出 keyVersion 比对，
  同/更高则跳过）→ 重启解锁不再无谓重传
- TUI `/passphrase` 传 `rotated: true`；docs（KEY_ESCROW.md §12 / PROTOCOL.md §7.4）同步

**验证：** server `npm run build` + `npm test` 全过（**需 Node ≥20.11：`import.meta.dirname`，
本机默认 v18.12.1 跑不了，`nvm use 22` 即可**）；shared `dart test` 24 项全过；app 相关
flutter test（lock_page/setup_join_passphrase/chat_page_menu/ws_realtime）18 项全过；
cli `dart analyze` 0 issue。

**不入库：** `server_settings.dart` 的 `kEinzServer = http://localhost:3000`（老板本地测试配置，照旧跳过）。

## 2026-09-08 会话：App 通知从底部 SnackBar 改为顶部通知条

**背景：** 老板要求：底部 SnackBar 会遮挡输入框等底部功能按钮，改为屏幕顶部显示。

**实现：** 新增 `app/lib/widgets/top_notice.dart`：`showTopNotice(context, 文案)` 用根
Overlay 贴顶显示（SafeArea + 下滑入场/上滑退场动画 + 4s 自动消失 + 点击提前关闭 +
重复调用替换旧条）；异步间隙/路由 pop 后显示用 `showTopNoticeOn(overlay, 文案)`
（await 前同步捕获 `Overlay.of(context, rootOverlay: true)`，绕开
use_build_context_synchronously）。替换 chat_page（26 处，含 SetPin 弹窗两处 messenger
捕获改 overlay）、lock_page（1 处语言切换）、setup_page（2 处：语言切换 + enroll 绑定通知）。
测试只断言文案文本出现、无 byType(SnackBar) 断言，不受影响；等通知消失的 pump(5s) 依旧兼容。

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；chat_page_menu/lock_page/
setup_join_passphrase/setup_envelope_verify/ws_realtime/widget_test 23 项全过
（golden 按政策跳过）。

**不入库：** `server_settings.dart` 的 `kEinzServer = http://localhost:3000`（老板本地测试配置，照旧跳过）。

## 2026-09-08 会话：顶部通知品牌化（粉蓝渐变 + Logo 徽章）

**任务：** 老板要求顶部通知更有特色：用 Einz 粉蓝主题色、通知前放 Logo，自行设计。

**设计（top_notice.dart 重构 \_TopNoticeBanner.build）：**

- 卡片主体：**天蓝 #3BAFFD → 粉 #D6529C 对角渐变**（左上→右下，品牌双色）
- 左侧**白色圆角徽章 + BrandLogo(22)（assets/logo.png 粉蓝图标，复用 brand_logo.dart）**
- 白字加粗 + 轻微文字阴影（粉端对比度兜底），最多 3 行省略号
- 半透明白细边（浅粉白背景上描边）+ **粉调柔投影**（#D6529C 35% alpha）
- 圆角 14；动画/4s 自动消失/点击关闭/替换旧条逻辑不变
- 色值用具 alpha 的 const（0x59D6529C / 0x8CFFFFFF），不依赖 withValues/withOpacity

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；chat_page_menu/lock_page/
setup_join_passphrase/setup_envelope_verify 18 项全过（golden 按政策跳过）。

**不入库：** `server_settings.dart` 的 `kEinzServer = http://localhost:3000`（照旧跳过）。

## 2026-09-08 会话：App 彻底取消备份/恢复，/recover 仅限 TUI

**背景（老板决策）：** 从 App 彻底取消「备份和恢复」功能——设备丢失用"添加新设备"解决；
双方设备全丢 = 放弃空间，无需恢复。全丢恢复（仅凭口令召回所有设备、重置整个空间）对
App 用户太危险，**仅限 TUI**。密保信封导入（join 口令页「改用线下密保信封」离线接入）
经老板拍板**保留**（属于"添加新设备"的离线路径）。

**已移除（App）：**

- chat_page：菜单「导出完整备份」+ \_ExportBackupDialog 整类 + \_showExportBackupDialog +
  ChatPage.initialHistory / importArchiveHistory 归档历史管线（死代码）
- setup_page：⋯ 菜单「从备份恢复」入口 + \_RecoverDialog 整类（escrow 口令重置 + 折叠区
  归档恢复）+ \_showRecoverDialog / \_applyRecovered / \_applyArchiveRestored / \_importedHistory
- l10n：app_zh/en.arb 删除 23 个键（wizardRecover* + chatPageExport* + chatPageMenuExport）
  → flutter gen-l10n 重新生成（0 残留）
- 测试：chat_page_menu_test 去掉「导出完整备份」断言

**保留：** TUI/CLI `/recover`、backup/restore 与 Server /recover 端点不变；App 新设备接入
= 邀请码 / 口令 / 密保信封。docs：KEY_ESCROW.md 新增 §13 决策记录、PROTOCOL.md §7.4 注明
/recover 仅 TUI。

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；13 个测试文件 53 项全过
（golden 按政策跳过）。

**不入库：** `server_settings.dart` 的 `kEinzServer = http://localhost:3000`（照旧跳过）。

## 2026-09-08 会话：新设备向导 ⋯ 菜单与对话页一致化

**任务（老板要求）：** 新设备向导（setup_page）右上角可展开菜单应与对话页菜单一致：
标签靠左、内容靠右（如「界面语言 中文」）、标签用淡灰（onSurfaceVariant）。

**实现（对齐 chat_page/lock_page 菜单样式）：**

- setup_page ⋯ 菜单 locale 项：`Text(wizardMenuLocale(...))` 改为
  `Row[Text(chatPageMenuLocaleLabel, labelStyle) + Spacer + Text(kLocaleLabels[...])]`
- exit 项补 labelStyle（此前无淡色）；locale 与 exit 之间加 PopupMenuDivider（与
  lock_page/chat_page 分隔一致）；itemBuilder 内定义 labelStyle
- `wizardMenuLocale` ARB 键（"语言: {value}"）改后无引用 → zh/en 删除 + gen-l10n 重生成
- golden_render_test 过时注释「语言 / 恢复 / 退出」→「语言 / 退出」（恢复已移除）

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；widget/setup_join_passphrase/
setup_envelope_verify/wizard_envelope_entry/setup_probe_retry/chat_page_menu/lock_page
25 项全过（golden 按政策跳过）。

**不入库：** `server_settings.dart` 的 `kEinzServer = http://localhost:3000`（照旧跳过）。

## 2026-09-08 会话：join 身份卡片左右并排（左蓝右粉）+ 顶部通知文字去阴影

**任务（老板要求）：** ① 后续设备加入时的用户身份选择，两张卡片**左右并排**（原来上下
排列），左侧蓝色背景、右侧粉色背景；② 顶部通知文字下方的"两条彩色下划线"（实为白字
阴影在粉蓝渐变上形成的细线观感）移除。

**实现：**

- setup_page `_buildStepIdentity`：Card+ListTile 上下排列 → `Row[Expanded(左卡),
SizedBox(12), Expanded(右卡)]`；新增 `_buildIdentityCard`：品牌色背景（左天蓝
  #3BAFFD / 右粉 #D6529C，与 Logo/顶部通知同色系）+ 白字图标标签 + 选中白色粗边框
  - 对勾（未选中 circle_outlined 占位保持等高）
- **溢出修复（模拟器黄色条纹 "Bottom overflowed by 8.0 pixels"）**：根因 = Row
  `crossAxisAlignment: stretch` 在垂直 SingleChildScrollView（高度无界 h=Infinity）
  下给子项传无限高度 → 非法约束崩溃/溢出；移除 stretch + 压缩卡片高度（padding
  18→12、图标 32→28、对勾 18→16）
- top_notice：TextStyle 删 `shadows`（黑 20% 偏移 1px 阴影在渐变上像下划线，
  多行消息即"两条"）；文字阴影本为粉端对比兜底，删后白字仍可读

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；widget_test/
setup_join_passphrase/setup_envelope_verify/wizard_envelope_entry 13 项全过
（溢出修复前 10 项红）、chat_page_menu_test 10 项全过（通知改动）（golden 按政策跳过）。

**不入库：** `server_settings.dart` 的 `kEinzServer = http://localhost:3000`（照旧跳过）。

## 2026-09-08 会话：TUI 被撤销设备启动直接提示退出（不再进入 TUI）

**任务（老板要求）：** 当前设备已被 revoked 时，启动 einz_tui.dart 不再进入 TUI 界面，
直接在终端提示"本设备已被撤销。"后退出。

**实现（cli/bin/einz_tui.dart）：**

- 启动自检 `_probeRevoked` 返回 1（getSpace 403）→ 直接提示"本设备已被撤销。"后
  exit(0)（此刻仍在 cooked 模式，无需恢复终端）
- 引导认证挑战 403（设备已撤销；/recover、/revoke 会删会话 → 先走 probe==2 清
  token → 挑战 403 兜底识别）→ `_restoreTerminal()` 后清屏提示并 exit(0)
- 提示写 stderr：pty 下退出瞬间 stdout flush 未决时 write 抛 "StreamSink is
  bound to a stream"（与 \_printFarewell 同款场景，stderr 是独立 sink 必达）
- 移除 `_revoked`/"仅可退出"模式全部死代码（\_runGuide 守卫、main 历史守卫、
  状态栏、输入循环/命令拦截、\_revokedBanner）

**回归测试：** cli/test/revoked_check.py 重写（原测试文案已过时）：首设备入网
（适配现行问答：输入我的名字/伴侣名字/设置密保口令/设置锁屏码）→ /recover →
重启断言"本设备已被撤销。"并自动退出。

**验证：** dart analyze 0 issue；`python3 test/revoked_check.py` 全过。

**备注：** 撤销最快也在引导认证 403 时检出（probe==2 先行），TUI 会有极短闪烁
（网络往返 <1s）后清屏退出。

## 2026-09-08 会话：在线 TUI 收到撤销广播立即提示退出（承接上一条撤销退出改动）

**任务（老板要求）：** 被撤销后，在线的 TUI 收到 ws 广播应当立刻返回命令行界面，
输出"本设备已被撤销。"并退出。

**实现：**

- `cli/lib/chat_core.dart`：`startWs` 增加 `onRevoked` 回调，透传
  `WsDeviceRevokedEvent`（共享包 ws_client.dart 已解析该帧）
- `cli/bin/einz_tui.dart`：新增 `_exitRevoked()`（恢复终端 + stderr 提示 + exit，
  与引导 403 路径共用）；新增 `_onWsRevoked` 接线全部 4 处 startWs（引导启动、
  /server 切换、/auth 激活、邀请码登记）
- `server/src/escrow.ts`：`recoverSpace` 撤销全部设备后，向在线旧设备逐个广播
  `device.revoked`（原只有 DELETE /devices/:id 单撤路径有广播；/recover 时在线
  TUI 的 WS 会保持连接收不到通知）
- 测试：revoked_check.py 改为「首设备保持在线 → /recover → 断言在线 TUI 提示并
  自动退出」+ 重启退出场景。踩坑：pty 缓冲一次吐出相邻多次渲染，分两次
  wait_text 会让第一次吞掉绿点渲染 → 单次 wait 同时校验「🎉 一切就绪」+ 绿点

**验证：** dart analyze 0 issue；server tsc 构建通过；revoked_check.py 全过。

## 2026-09-08 会话：App 认证 403（设备被撤销）→ 走 \_onDeviceRevoked

**任务（老板要求）：** 补一个：认证 403 时也走 \_onDeviceRevoked（此前只覆盖 WS
广播 device.revoked；后台错过广播时 WS 会因 token 失效反复重连，认证 403 无
撤销处理）。

**实现（app/lib/chat_page.dart）：**

- 新增 `_reauthWithRevokedFallback()`：包装 `widget.reauth`，捕获
  `ApiException code == 'FORBIDDEN'`（challenge-response 被服务端拒绝 = 设备已
  撤销）→ `await _onDeviceRevoked()`（清理锁包/消息库 → 顶部通知 → 回设置页）；
  其他异常原样抛出
- 两处 reauth 接线点改用包装（widget.reauth 为空时保持透传 null）：
  MessageRepository（请求 401 自动续期）与 WsRealtimeService（WS 4401 续期）
- 403 覆盖路径：WS 4401 → reauth → 挑战 403；请求 401 → reauth → 挑战 403

**验证：** flutter analyze 0 issue（仅 1 既有 info lint）；ws_realtime_service/
chat_page_menu/message_repository 测试全过；widget_test 有 1 个既有失败
（「Einz 秘境：认领中：身份」期望文本在现行代码/l10n 已不存在——老板并行 WIP
的 UI 改造遗留，与本次改动无关，未处理）。

## 2026-09-08 检测页重设计为品牌启动屏（commit 284c1ca）

老板要求：首页（检测服务器状态）作为启动屏幕页，突出粉蓝配色，页面上方放
LOGO，检测期间正中显示旋转图标，取消服务器地址输入框，顶部无菜单。

**设计（app/lib/setup_page.dart）：**

- `build()` 顶层分流：`_role == null`（角色未判定）→ 新增 `_buildSplashScreen()`
  全屏品牌启动屏：粉蓝渐变（天蓝 #3BAFFD → 粉 #D6529C，同顶部通知渐变）+
  上方白色圆角徽章大 LOGO（BrandLogo 96）+ 正中白色旋转图标 + 状态文案；
  无 AppBar/菜单/服务器输入框
- 失败态不展示输入框：探测失败文案改为「暂时无法连接服务器，正在自动重试…」，
  由既有 4 秒自动重试兜底（就绪即自动进入向导），spinner 持续旋转
- 删除死代码：`_serverController`、`_saveServer()`、失败输入框 Card

**其他：**

- main.dart StartupGate 加载页同步品牌化（渐变 + LOGO 72 + 旋转图标），
  需 import brand_logo.dart
- l10n：wizardDetectFailed 更新 zh/en（5 个文件：2 arb + 3 dart）
- setup_probe_retry_test 适配：失败态 spinner 常转 → 有限 pump 替代
  pumpAndSettle（否则无限动画超时）
- golden 政策：检测页/向导 golden 全部失配保持红，不重刷（向导步骤失配
  叠加老板并行文案改动影响）

**验证：** flutter analyze 0 error（仅 1 既有 info）；setup_probe_retry_test
通过；golden 失配保持红（政策）。

## 2026-09-08 启动屏渐变铺满全屏修复（commit aafad56）

老板反馈：断线时启动屏只显示左侧一大半渐变，右侧全白（页面停留久才暴露）。

**根因（查 Flutter SDK 源码确认）：**

- Scaffold body 约束是宽松的（`_BodyBoxConstraints` 只传 maxWidth/maxHeight，
  minWidth/minHeight 默认 0）
- 现代 Flutter `RenderProxyBoxMixin._computeSize`：尺寸 = child 尺寸
  （`constraints.constrain(childSize)`），不是撑满 biggest
- 启动屏渐变 Container 无 alignment → 缩到 Column 宽度 = 最宽文案
  （断线失败文案「暂时无法连接服务器，正在自动重试…」≈260px = 屏幕 2/3）

**修复：** 渐变 Container 加 `alignment: Alignment.topCenter`——内部 Align
撑满全屏 → 渐变 DecoratedBox 铺满整页，内容布局不变。

**验证：** analyze 0 error；setup_probe_retry_test 通过；重渲染截图像素
分析——右上角由白 (254,247,255) 变为渐变过渡色 (87,158,235)，四角均为
渐变；golden 保持红不重刷。

## 2026-09-08 启动屏「LOGO + 加载图标」二合一——嵌套圆环旋转动画（commit 467224c）

老板提议：把 logo 的两个嵌套圆环直接做成旋转动画，首屏不再需要单独 LOGO
徽章 + 旋转图标，二合一。

**logo 结构分析（python 解码 PNG + 旋转对称性检测）：** 蓝环（有粗细变化/
缺口）与粉环嵌套交错，90° 旋转差异均值 78、180° 88.5（满值 255）——明显
非旋转对称，旋转动画清晰可见。

**实现（app/lib/brand_logo.dart）：**

- 新增 `SpinningBrandLogo`：`RotationTransition` + `AnimationController`
  `..repeat()` 无限顺时针旋转 `BrandLogo`（size/radius/duration 可配）
- 启动屏（检测页）：去掉「白色徽章大 LOGO + spinner」，改为单个旋转 logo
  居中（SpinningBrandLogo size 96）+ 状态文案
- StartupGate 加载页同步二合一（size 72）

**验证：** analyze 0 error；setup_probe_retry_test 通过；重渲染截图像素
确认渐变铺满、文案布局正常。注：golden 测试 pump 一帧后 Image.asset 异步
未加载（截图中央无 logo 图像），属 flutter_test 环境行为，真机正常；临时
调试测试验证旋转时 runAsync/toImage 在 fake clock 下死锁超时，已删除。

## 2026-09-08 向导页沿用粉蓝渐变 + 进度圆点减一

老板要求：新设备向导页也保留首屏的粉蓝渐变背景；服务器检测集成在首屏完成、
不属于向导，进度圆点应减少一个。

**向导页渐变（app/lib/setup_page.dart build）：**

- AppBar 加 `flexibleSpace` 渐变（AppBar 区域含状态栏同款渐变）
- body 改为渐变 `Container` + `SafeArea`（与首屏同款 LinearGradient）
- 步骤内容包白色圆角内容卡（白底圆角 20 + 柔和投影）——表单可读性 + 品牌层次
- 底部「上一步」TextButton 改白色（渐变上可读）；进度圆点改白色系
- 步骤页内红字错误提示、身份卡片（左蓝右粉）在白卡内不受影响

**圆点减一（\_buildProgressDots）：** 原 `total = _stepCount` 且 `i <= _step`
点亮导致 i=0 恒亮（被感知为首屏圆点）。改为 `total = _stepCount - 1`、
点亮条件 `i + 1 <= _step`——create/join 5→4 个、offline 3→2 个，圆点只
代表向导内部步骤；`_stepCount` 本身不动（导航/完成判定仍用它）。

**验证：** analyze 0 error；setup_probe_retry_test 通过；重渲染 create 步骤
1 截图像素分析——四角与 AppBar 区域均为渐变、白色内容卡存在、圆点 4 个
（x=173/187/201/215，第 1 个纯白=已完成、后 3 个半透明白=未到）；
golden 保持红不重刷。

## 2026-09-08 修复向导页抬头栏/正文渐变突变

老板反馈：向导页顶部抬头栏（有 logo）与下方有明显背景突变。

**根因：** 之前 AppBar 用 `flexibleSpace` 渐变——渐变矩形是 AppBar 自己的
小区域（0..56px 高），与 body 的渐变矩形（AppBar 下方全屏）坐标系不同；
AppBar 底边已到粉色、body 顶部还是天蓝，衔接处颜色跳变。

**修复（app/lib/setup_page.dart）：**

- `extendBodyBehindAppBar: true` + AppBar `backgroundColor: transparent`——
  body 渐变容器延伸到屏幕顶部（含 AppBar 与状态栏区域），整屏共用同一个
  渐变矩形，无缝衔接
- Column 顶部加 `SizedBox(height: kToolbarHeight)`：AppBar 浮动于渐变上，
  内容从工具栏高度下方开始（避免与抬头 logo/标题重叠）；顺带修正了真机上
  SafeArea 多余顶部 padding 的问题（extend 场景 SafeArea 才是正确用法）

**验证：** analyze 0 error；setup_probe_retry_test 通过；重渲染 create 步骤
1 截图像素分析——衔接处（y=54 与 y=58 同 x）平均色差 1.4（<20 无突变），
四角渐变正常；golden 保持红不重刷。

## 2026-09-08 向导完成页去掉浅绿色块

老板要求：完成页那块浅绿色背景去掉——现在已有更好看的粉蓝渐变背景。

**修改（app/lib/setup_page.dart）：**

- `_buildStepDone` 不再渲染 60% 高的浅绿纯色块（原"完成语义"背景），
  返回 `SizedBox.shrink()`——欢迎对话框盖住全页
- 白色内容卡在完成页（`_step >= _stepCount`）跳过：done 页不包白卡，
  直接呈现粉蓝渐变背景（与首屏/向导品牌一致）

**验证：** analyze 0 error；setup_probe_retry_test 通过；done 步骤 golden
渲染正常（无崩溃）、失配保持红不重刷。

## 2026-09-09 语音录音波形遮罩

**需求：** 按住麦克风按钮录音时，页面中央显示正在录音的波形图。

**实现（commit 0fe560d）：**

- 新增 `app/lib/widgets/recording_overlay.dart`：真实振幅驱动（record 插件
  `onAmplitudeChanged(70ms)`，dBFS -50~0 归一化 + 一阶平滑），波形条 + 录音时长 + 提示文案。
- `chat_page.dart`：开始录音时取振幅流存 `_amplitudeStream`，停止时置空；
  body 包 Stack，`_recording` 时中央挂遮罩（IgnorePointer 不挡操作）。

**要点/坑：**

- `dart format` 会把 chat_page.dart 整体重排（594 行噪音）——该文件并非 format-clean，
  已恢复 HEAD 重做最小 diff；本项目大文件慎跑 dart format。
- 测试环境无原生录音，遮罩仅在 `_recording` 时挂载，渲染路径不触碰 AudioRecorder，测试安全。
- widget_test 2 个探测类失败为环境既有问题（stash 验证与 HEAD 一致）。

## 2026-09-09 修复：重启后旧消息错位 + 附件消息缺头像（commit 6120230）

**症状：** app 首设备入网发消息（语音+文字）→ 退出重开 → 全部旧消息变成对方（左对齐）；
新发的消息又正常。另：语音消息不带头像。

**根因1（错位）：** create 流程 `_runPinSetup` 把 AppLockPayload 三处（escrow 上传/
savePlain/setPin）存了占位 deviceId `kp.deviceId`（'dev-mobile'），而首次进聊天 `_finish`
用的是登记真实 id（dev1）→ 重启后 main/LockPage 用占位 id 自识别 → `_isSamePerson` 设备映射
查不到自己 → 降级 device 维度比较 → 旧消息 senderDeviceId(dev1) != 当前(dev-mobile) 全判 peer。
修：三处改用 `_enroll!.deviceId`（与 join/offline 一致）。

**根因2（无头像）：** `sendAttachment` 构造信封漏传 `senderPersonId`（send() 文字有传）。
修：补传 + 渲染侧兜底 `personIdOfDevice()`（旧消息也能恢复头像）。

**教训：** 设备身份必须统一用服务端登记返回值，本地占位 id 只能用于生成密钥对时
的临时 key 参数；持久化（AppLockPayload）不得存占位 id。

**验证：** analyze 通过；message_repository/app_lock/chat_page_menu 测试全过；
setup 相关 7 个失败经 stash 基线确认系既有环境问题，与本次无关。

## 2026-09-09 界面风格切换（素雅纯色 / 渐变粉蓝）

**需求：** 保留现有视觉效果；新增一种风格——把首屏/向导的粉蓝渐变背景用到对话页；
菜单「界面语言」下新增「界面风格」，弹窗内每风格 = 一张预览图 + 一句描述，
点选即立刻生效且不关窗（用户不离开弹窗即可预览大致效果）。

**实现（commit eed4f2d）：**

- 新增 `app/lib/data/ui_style_settings.dart`：`kUiStyleOptions`（plain/gradient）、
  双语标签/描述、品牌渐变常量 `kBrandGradient`（与首屏/向导同款
  [3BAFFD→D6529C topLeft→bottomRight]）、`uiStyleNotifier`（即时生效通知）、
  `UiStyleSettings`（app_state key='ui_style'，默认 plain）。
- 新增 `app/lib/widgets/ui_style_picker.dart`：`UiStylePickerSheet` 弹层——
  每风格一张程序化绘制的迷你聊天页预览图（纯色/渐变 + 左右两枚迷你气泡）+
  名称 + 一句描述；点选即保存并通知（弹窗保持打开，选中态/聊天页背景同步刷新），
  右上角 ✕ 或下滑关闭（与语言弹窗"点选即关"不同——风格需要边看边试）。
- `chat_page.dart`：菜单「界面语言」下新增「界面风格」（显示当前值）；
  `_uiStyle` 状态 + notifier 监听（initState 同步取值防首帧 LateInit，异步加载
  持久化值校正）；body 背景按风格渲染——gradient 铺品牌渐变（Key
  chatPageGradientBackground 供测试定位），顶部在线状态条/输入区改半透明白
  （渐变透出且文字可读）；plain 保持原样（像素级不变，golden 不受影响）。
- l10n：ARB 加 `chatPageMenuStyleLabel`（界面风格/Interface style）+
  `chatPageStyleSheetClose`（关闭/Close），gen-l10n 重新生成。

**验证：** analyze 通过（仅 1 条存量 info）；新增 `test/ui_style_switch_test.dart`
2 用例（点选即生效且不关窗 + 持久化恢复）+ chat_page_menu 12 用例全过；
golden 未触碰（plain 默认像素级不变）。

## 2026-09-09 对话页渐变背景全屏化（对齐向导）

**老板反馈：** 对话页渐变效果不如向导好看——标题栏（logo/Einz 秘境/菜单）没被渐变
覆盖；渐变被底下输入栏截断；要求输入栏在该风格下不顶左右两头。

**实现（commit b03e1de）：**

- `chat_page.dart` gradient 风格对齐向导做法：`extendBodyBehindAppBar: true` +
  AppBar 透明——渐变延伸到状态栏/标题栏（全屏自然过渡）；内容从工具栏高度下方
  开始（`MediaQuery.paddingOf.top + kToolbarHeight` 顶部留白，同向导
  `SizedBox(kToolbarHeight)`，避免与浮动 AppBar 重叠、列表也不会滚到 AppBar 后）。
- 输入栏改悬浮圆角条：不顶左右两头（横向 12 边距 + 圆角 24），半透明白 85% +
  柔和投影（同向导白卡在渐变上的层次）；plain 风格保持原样（全宽透明，像素级不变）。

**验证：** analyze 通过（仅 1 条存量 info）；`ui_style_switch_test` 扩断言
（gradient 下 Scaffold 延伸到 AppBar 后 / AppBar 透明 / 输入栏圆角条，切回纯色全部
恢复）+ chat_page_menu 12 用例全过。

## 2026-09-09 修复：渐变风格下输入栏上方消息被截断（SafeArea 顶部 inset 空隙）

**老板实测：** 切到渐变背景后，输入框上方约 2 个输入框高度的区域只有渐变背景过渡，
消息到不了那里（被截断）。

**根因（widget 测试复现定位，空隙实测 115px）：** 输入栏包在 `SafeArea` 里（默认
四边都应用 MediaQuery padding）。`extendBodyBehindAppBar` 下 Scaffold 给 body 的
`MediaQuery.padding.top` = 状态栏 + kToolbarHeight（真机约 115px，测试注入 59+56），
SafeArea 把它全垫在输入栏上方 → 消息列表底部停在输入栏上方 115px 处（plain 风格
同样存在较小的同类空隙，只是背景无渐变不易察觉）。

**修复（commit 0c105f2）：** 输入栏 SafeArea 加 `top: false`（底部 inset 保留防 Home 条
遮挡）；两风格统一——消息列表直达输入栏，plain 原有的小空隙一并消除（像素变化极小）。

**验证：** 新增回归用例（模拟真机 insets 59/34：断言消息列表底部 == 输入栏顶部，
修复前失败/修复后通过）；analyze 通过；ui_style_switch_test 3 用例 + chat_page_menu
12 用例全过。

## 2026-09-09 状态条悬浮圆角 + 气泡深色白字（渐变风格）

**老板要求（2026-09-09）：**

1. 顶部两人在线状态条目前左右顶到头、截断背景——改成与输入条一样：不顶左右两头、
   四角有弧度、悬浮在背景上。
2. 渐变背景下消息气泡浅 tint 与背景区分不足——气泡底色改深粉（女）/深蓝（男），
   字体改白色，更醒目。

**实现（commit 8d3e528）：**

- 状态条 gradient 改悬浮圆角条：横向 12 边距 + 圆角 24 + 半透明白 85% + 柔和投影
  （与输入条同款样式，Key `chatPageStatusBar`）；plain 保持全宽浅灰条（像素不变）。
- 气泡底色 `_bubbleColor` gradient 分支：男 → 品牌深蓝 `#2271F7`、女 → 深粉
  `#B83D80`（品牌粉加深，白字对比度约 5:1）、性别未登记本人深蓝/对方石板灰
  `#64748B`；plain 分支不变（浅 tint）。
- 气泡内容包 `DefaultTextStyle.merge` + `IconTheme.merge`：gradient 下文字/图标白色，
  plain 下不合并（保持深色）；次要灰字（阅后即焚徽标/文件大小）gradient 下改
  `white70`。

**要点/坑：** 本机 Flutter 的 `DefaultTextStyle.merge`/`IconTheme.merge` 是
`style:`/`data:` + `child:` 命名参数（无 `context:`），初次误加 `context:` 触发
analyze 报错；`IconThemeData(color: null)` 合并时保留祖先色（plain 安全）。

**验证：** analyze 通过；ui_style_switch_test 4 用例（新增状态条圆角断言 + 气泡
深色/白字断言，FakeApi 扩展支持编排加密消息 + getSpace）+ chat_page_menu 12 +
chat_bubble_gender_test 1 全过。

## 2026-09-09 修复：进入对话页首屏未滚到最新消息

**老板实测：** 刚打开 app 进对话页，列表停在最早消息处（顶部）；等几秒到一分钟
（ticker 自动刷新）才滚到最新消息。应在刚进入时就同步并显示最新。

**根因：** `_loadInitial`（首次载入：sync → purgeExpired → historyRecent 最近一页
50 条 → setState）**没有滚动到底**；`_scrollToLatest()` 只在 `_refresh()`（3s/30s
ticker 轮询/WS message.new）里调用——所以首屏停在顶部，等第一个 ticker 触发才
滚到底，正好是老板看到的现象。

**修复（commit 68e9c6d）：** `_loadInitial` setState 后调用
`_scrollToLatest(animate: false)`——首次载入直接跳转到底部（进入即见最新，不播
从顶部飞过的动画）；`_scrollToLatest` 加 `{bool animate = true}` 参数（新消息到达
仍走 250ms 平滑滚动，行为不变）。

**验证：** 新增 `test/chat_initial_scroll_test.dart` 回归用例（60 条消息，断言首屏
滚动位置 == 列表底部 + 最新消息可见；修复前失败/修复后通过）；analyze 通过；
chat_initial_scroll + chat_page_menu 12 + ui_style_switch 4 + chat_bubble_gender 1 +
invite_dialog_layout + widget_test 全过。

## 2026-09-09 素雅纯色风格的双人状态条也改悬浮圆角

**老板要求（2026-09-09）：** 渐变风格里双人状态条的悬浮效果改造得很好——素雅纯色
风格的状态条也这样改造：左右不要顶边、做成悬浮圆角。

**实现（commit 7a32973）：** 状态条样式从"按风格条件化"改为**两风格统一**——
去掉全部 `_uiStyle == 'gradient'` 条件分支：横向 12 边距 + 圆角 24 + 半透明白
85% + 柔和投影（与渐变风格一致）；plain 下不再使用全宽浅灰条 + 底边框。

**验证：** analyze 通过；ui_style_switch_test 断言更新（默认素雅纯色/切回纯色
状态下状态条均为圆角 24）+ chat_page_menu 12 + chat_initial_scroll +
chat_bubble_gender 全过（共 18 项）。

## 2026-09-09 消息时间标注 + 图片黑底全屏（chat_page 两处 UI 改进）

**老板要求（2026-09-09）：** 1) 点击消息流里图片全屏时，要和点击头像一样用纯黑
背景遮罩（不要半透明），看图片才好看；2) 每条消息上部标注发送时间——当天
HH:MM、当年 mm-dd HH:MM、跨年 yyyy-mm-dd HH:MM；阅后即焚消息再附加时钟图标 +
焚毁时长（1m/5m/30m/1h/1d/7d 紧凑格式），去掉原来的「⏱ 阅后即焚」字样徽标。

**实现：**

- HistoryMessage typedef 新增 createdAt（落盘发送时间戳，未同步消息为本地发送
  时间）+ burnAfterSeconds（焚毁时长快照）；`_rowsToHistory` 填充，归档恢复缺
  快照时按 到期-创建 反推（dart:math max 保底 1s）。
- chat_page：气泡顶部统一渲染时间行（`_messageTimeLabel`：同天 HH:MM / 同年
  mm-dd HH:MM / 跨年 yyyy-mm-dd HH:MM）；阅后即焚消息追加 Icons.schedule +
  `_burnDurationLabel`（按 60/3600/86400 整除推导 m/h/d）；原内联 record 签名
  的 8 处函数改收 HistoryMessage（typedef 加字段后类型不同，必须同步）。
- `_showFullImage` 改黑底全屏（Dialog backgroundColor: Colors.black +
  insetPadding zero + 右上角关闭按钮，与 \_MessageAvatar 全屏一致；保留
  InteractiveViewer 双指缩放）。视频全屏弹窗未动（老板只要求图片）。
- l10n 清理 chatPageBurnBadge 死代码（app_zh/en.arb + app_localizations 三个
  dart 文件共 5 处）。

**验证：** `dart analyze` 通过，仅剩 1 条既有 info（ws_realtime_service 的
prefer_initializing_formals，与本次无关）。老板侧热重启（ios-reload / USR2）后
可看效果。

## 2026-09-09 长按消息菜单：删除 / 引用 + 附件消息阅后即焚修复

**老板要求（2026-09-09）：** 1) 长按消息弹菜单：删除、转发——2 人世界没有转发，改为
「引用」；2) 删除 = 只在本机删除，重启也不显示（经确认：要确认弹窗）；3) 老板实测
图片/录音/视频/文件消息对阅后即焚免疫，要求同样受控。

**删除实现：** repo 新增 `deleteMessage(messageId)`——与 purgeExpired 同款彻底删行
（local_attachments + local_messages 一起删，非标记不可见）。重启不显示：同步锚点
只向前推进，已删序号不在增量拉取范围，WS 只推新消息，均不会重拉。长按气泡 →
showModalBottomSheet（引用/删除）→ 删除弹确认框（文案说明仅本机消失、对方不受
影响、不可恢复）→ 删行 + setState 移除。

**引用实现（关键协议决策）：** 调研确认 server 的 validateEnvelope 是白名单重建
信封（未知字段被丢弃）→ 引用快照不能放信封字段，改放**加密载荷内**：载荷从裸文本
变为 `{"plaintext":…, "quote":{messageId, preview}}` JSON（仅引用消息才包装；
AEAD 密文对 Server 完全不透明，无 server/shared 改动）。repo `send()` 加可选
quote 参数；`_rowsToHistory` 解密后解析包装（裸文本向后兼容）。UI：长按→引用→
输入栏上方引用条（预览 60 字截断 + 关闭按钮）→ 发送携带 → 气泡内渲染引用块
（左侧天蓝竖条 + 预览，最多 2 行）；被引消息删除/焚毁后引用块仍可显示（快照）。

**附件阅后即焚修复：** `sendAttachment` 落库漏带 `_burnState()`（文本消息 send()
一直带着）→ 本端附件副本永久保留。修复：落库时补 burnAfterSeconds/expiresAt，
发送端附件消息与文本消息同样受控（接收端 sync 路径本来就有）。

**验证：** flutter analyze 仅剩 1 条既有 info（ws_realtime_service 无关）；
message_repository_test 新增 2 用例（引用载荷往返还原、deleteMessage 彻底删除）
共 11 个全过。golden 政策不变：chat_page golden 若失配保持红不重刷。

## 2026-09-09 首屏旋转加载换成 3D 双环渲染图（老板提供新素材）

**老板要求（2026-09-09）：** 用新图（logo/logo-bgBlack.png，1254×1254 黑底
粉蓝 3D 双环渲染）作为打开应用首屏上的旋转等待按钮，取代原来我自己抠图的
（圆角方框版 logo.png 旋转）。

**实现：**

- 抠图：无 PIL/ImageMagick，用 node + pngjs 写 chroma-key 脚本（/tmp/einz_imgtool/
  chroma.js）：按亮度软阈值（22/40）+ 饱和度保护把黑底变为透明（保留光晕），
  输出 app/assets/spinnerLogo.png（1254×1254 RGBA，已注册 pubspec）。
- SpinningBrandLogo 改用 spinnerLogo.png + RotationTransition 无限旋转，去掉
  ClipRRect 圆角（透明底不再需要）；移除 radius 参数，同步 main.dart 启动屏
  （size 72）与 setup_page 检测页（size 96）两处调用点。
- 静态小 Logo（BrandLogo/assets/logo.png）不动——顶栏、锁屏、通知条照旧。

**验证：** dart analyze 0 新问题（仅 1 条既有 info）；检测页行为测试
setup_probe_retry_test 通过。golden 政策不变：setup_step1_detect（100%，
换图所致）、chat_page（11.77%，上轮时间标注所致）、lock_page（1.12%）与
向导各步骤（98%+，风格改版遗留）保持红不重刷。

## 2026-09-09 修复：引用消息重启后显示原始 JSON（{plaintext:…} 泄漏）

**老板报告（2026-09-09）：** 引用另一条消息发出去后，退出并重新打开 app，
看到被引用的消息以纯文本 `{plaintext:'…',quote:{…}}` 展示。

**排查（实证优先）：**

- 先怀疑 repo 解析链路，写了复现测试「send → 服务端回拉（\_markSent 不推进
  锚点，重启 sync 会把消息再拉回）→ 重新读取历史」——**12/12 全过**：app 侧
  `_rowsToHistory` 对引用包装的解析是确定性的，密文落盘稳定，重启前后不可能
  一个解析成功一个失败。
- 结论：能显示原始 JSON 的，一定是**没有解析引用包装的客户端**。确认 CLI 的
  `_decrypt()` 直接返回 `decryptMessage` 原文——TUI 把引用消息整段 JSON 当
  明文展示；同理旧版本 app 构建（无解析代码）也会这样。

**修复（cli/lib/chat_core.dart）：** `_decrypt` 加与 app 侧同款的包装解析
（`raw.startsWith('{')` → jsonDecode → 取 `plaintext` 字段；裸文本以 { 开头时
按原文展示），TUI 只展示正文不渲染引用块。app 侧当前构建无需改（已证正确）。

**验证：** app analyze 仅 1 条既有 info；cli analyze 0 issue；message_repository_test
12 个全过（含新增「重启后引用消息不显示原始 JSON」回归用例）。

**待老板确认：** 若看到 JSON 的端是 app，多半是**旧构建**（需重装/重建）或 CLI
（本次已修）；两种都不是的话提供截图，我再继续查。

## 2026-09-09 修复：首屏旋转 logo 出现 "Einz" 文字 + 四角残留（换透明底素材）

**老板报告（2026-09-09）：** 换用透明背景 logo（Image #2）后，首屏旋转 logo
有两个问题：1) 里面为何有 "Einz" 文字？给的 logo 是透明背景两个嵌套圆环；2) 旋转的正方形四周露出 4 个角（像正方形抠掉圆后剩的角）。

**根因（像素级分析，node+pngjs inspect）：**

- 上一版 `spinnerLogo.png` 是我从 `logo-bgBlack.png`（1254×1254 黑底）chroma-key
  抠出来的：**黑底源图本身就含 "Einz" 文字**（顶部 0-12% / 底部 68-94% 高度带
  有内容像素）且四角非纯黑（暗角 alpha ~57，抠图阈值没切掉）→ 文字和 4 个角
  被一起保留。
- 老板的透明版 `logo-bgTransparent.png`（1536×1024）：四角 alpha = 0、内容居中
  （包围盒 1220×820）、无文字条带——干净。

**修复：** `spinnerLogo.png` 直接原样替换为透明版（不做抠图/裁剪）：

- 试过居中裁方 1024×1024，发现会**切掉左右环边缘**（横版双环 1220px 宽 > 1024），
  弃用；
- 用 1536×1024 原图 + 控件侧 `BoxFit.contain`（方形画布内留白居中）→ 旋转零
  裁剪、无角残留、无文字，环绕正方形中心转无摆动（内容偏离画布中心仅 ~1.5%）。

**验证：** 像素检查四角 alpha=0、内容居中；dart analyze 仅 1 条既有 info；
检测页行为测试通过。golden 政策不变（检测页 golden 已红，不重刷）。

## 2026-09-09 修复：发了几条引用消息后，重启 app 不再自动跳到底部

**老板报告（2026-09-09）：** 引用消息重启显示正常了（上一轮已修），但发了
几条带引用的消息后重启 app，又不能自动跳到最新消息了（此前 68e9c6d 修过：
首次载入 `_scrollToLatest(animate: false)` 直接跳底部）。

**根因（复现实证）：** `_loadInitial` 首帧 `jumpTo(position.maxScrollExtent)`
——**懒构建列表首帧的 maxScrollExtent 是估算值**（未构建条目按平均高度估算）。
末尾几条是引用消息（引用块使气泡明显更高）时，估算偏低 → 一次 jumpTo 停在
半路（真实底部在下）；WS 在线时 ticker 不轮询、也没有新消息追加，无人纠正。
普通消息场景高度均匀，估算≈真实，所以一直没暴露。新增复现用例（55 普通 +
末尾 5 条引用载荷消息）修复前失败、修复后通过。

**修复（chat_page）：** 首次跳转改走 `_jumpToBottom()`——jumpTo 会触发目标
附近条目补建、extent 变准，post-frame 检查 extent 仍在增长（>target+1）就
再跳一次，逐帧校正直到贴底（depth≤5 防极端死循环）；新消息到达的平滑滚动
（animate: true）路径不变。

**验证：** chat_initial_scroll_test 两个用例全过（原 60 条普通 + 新增引用
场景）；dart analyze 仅 1 条既有 info（ws_realtime_service）。

## 2026-09-09 首屏视觉统一：无小→大跳变、Logo 移上半部、去掉服务器文字

**老板要求（2026-09-09）：** 1) 刚打开时先显示小 logo、再跳变成更大的旋转 logo
——不要跳，开屏就定格（否则宁愿不显示小的）；2) logo 位置在屏幕偏下方不对，
应在屏幕上半部分；3) 不需要显示「服务器找不到」类文字，保持简洁优美。

**定位：** 启动链三段都有问题——iOS 原生启动屏显示小 LaunchImage（168×185
居中，白底）；StartupGate 显示 72px 居中 spinner；setup 检测页（\_buildSplashScreen）
Spacer(3):Spacer(2) 把 96px spinner 压到约 60% 高度 + 下方「正在检测服务器
状态…/暂时无法连接服务器，正在自动重试…」文字。

**实现：**

- iOS LaunchScreen.storyboard：移除 LaunchImage 小图（原生启动屏空白，宁缺毋滥）；
- main.dart StartupGate：改与检测页同款布局（96px + 上半部 Spacer 2:3），
  原生屏→StartupGate→检测页全程同尺寸同位置，无跳变；
- setup `_buildSplashScreen`：Spacer 改 2:3（约 40% 高度，上半部），删除状态
  文字（wizardDetectTitle/Failed），探测失败仍由 4 秒自动重试兜底；
- setup_probe_retry_test 同步更新：断言启动屏保持旋转 Logo 且无失败文字、
  进入向导后启动屏消失（不再依赖旧失败文案）。

**验证：** dart analyze 仅 1 条既有 info；setup_probe_retry + chat_initial_scroll
（2 个滚动用例）全过。golden 政策不变（setup_step1_detect 失配保持红不重刷）。

## 2026-09-09 引用块移到消息正文下方（气泡内顺序调整）

**老板要求（2026-09-09）：** 被引用的消息（引用块）现在显示在消息正文上面，
应放在正文**下面**。

**实现（chat_page 气泡 Column）：** 子项顺序由「时间行 → 引用块 → 正文」改为
「时间行 → 正文 → 引用块」，引用块外边距 bottom:4 改 top:4（与正文分隔）。
对接收方显示同步生效（同一渲染路径）。

**验证：** dart analyze 仅 1 条既有 info（ws_realtime_service，与本次无关）。

## 2026-09-09 删除/阅后即焚改本地墓碑：内容隐藏、记录保留（不打破历史流水）

**老板决策（2026-09-09）：** 想清楚了——阅后即焚和手动删除都改**本地标记**，
不再彻底删行。被删/被焚的消息在界面上显示为：内容为空，但时间+时钟+时长
的记录还在（不打破消息历史流水，只隐藏内容）。

**实现：**

- 数据层：local_messages 加 `deleted_at` 可空列（v3 迁移，build_runner 重生成
  g.dart）；NULL=正常，非空=本机已删除/已焚毁。
- repo：`HistoryMessage` 加 `deleted` 字段（\_rowsToHistory 按 deletedAt 填充）；
  `deleteMessage`→`tombstoneMessage`、`purgeExpired`→`tombstoneExpired`
  （都改为只置 deletedAt，行与附件保留；已墓碑不重复标记）；
  `_flushPending`/`pendingCount` 跳过墓碑行（已删的未发送消息不再补发）。
- chat_page：删除确认后调 tombstoneMessage + 列表就地标记 `_asDeleted` 副本
  （不再 removeWhere）；`_refresh`/`_loadInitial` 到期消息就地标记为已焚毁
  （不再移出列表）；气泡渲染 `if (!m.deleted)` 才显示正文+引用块——墓碑消息
  只剩时间行（含时钟+时长），内容为空。
- 测试：tombstoneExpired（到期打标记、未到期不动、不重复标记）、tombstoneMessage
  （记录保留、deleted 标记、模拟重启后仍隐藏）替代原彻底删除断言。

**验证：** dart analyze 仅 1 条既有 info；message_repository_test 12/12 全过；
chat_initial_scroll + setup_probe_retry + chat_page_menu 15/15 全过。golden
政策不变（chat_page golden 失配保持红不重刷）。

## 2026-09-09 自动 sync 无新消息时不拉到底 + 引用块去掉蓝边

**老板要求（2026-09-09）：** 1) 自动 sync 没发现新消息时，不要把消息流拉到最
下面（用户可能在往上翻历史）——除非刚启动、sync 发现新消息、或收到发来的
新消息，才拉到底；2) 引用块灰框左侧那条带弧度的蓝边没必要，删掉蓝边（阴影
可以有）。

**实现：**

- `_refresh`：先算出实际新增消息 `added`（historySince 结果去重），仅当
  `added.isNotEmpty` 才 `_scrollToLatest()`——ticker 轮询/WS 断线重连等无新
  消息的自动 sync 不再打扰用户的滚动位置；发送消息、收到新消息仍会拉到底；
  启动路径 `_loadInitial` 保持无条件跳底。
- 顺带修复新用例暴露的问题：`_scrollToLatest` 动画路径（animateTo）落点可能
  因懒加载 extent 估算偏短，动画结束后 `.then((_) => _jumpToBottom())` 校正
  贴底（估算准确时是无操作）。
- 引用块（气泡内）去掉左侧蓝色竖条（border: left BorderSide #3BAFFD），保留
  灰底+圆角。

**验证：** chat_initial_scroll_test 3/3 全过（新增用例：固定序号 fake 模拟真实
Server——无新消息时不拉回底部、新消息到达后拉到底）；dart analyze 仅 1 条
既有 info。

## 2026-09-09 输入栏引用条去掉「引用：」前缀（双引号图标已足够）

**老板要求（2026-09-09）：** 选择引用后，输入框上方的引用框里，双引号图标后
有「引用：」标签——删除，双引号图标足够表达这是引用内容。

**实现：** `_buildQuoteBanner` 文本直接显示 `_quotePreview(quote.plaintext)`，
不再套 `chatPageQuoteBanner`（原「引用：{preview}」）；清理该 l10n 死代码
（abstract/zh/en/两 arb 共 5 处）。引用框蓝色左边框保留（老板未要求删）。

**验证：** 残留引用检查干净；dart analyze 仅 1 条既有 info。

## 2026-09-09 CLI/TUI 对方消息按性别配色

**老板要求：** 对方为男性时使用蓝色消息背景；女性保持现有粉红消息背景。

**实现：** `SpaceResult` 解析服务端 `person_genders`，TUI 刷新空间信息时缓存
性别，并按消息 `senderPersonId` 选择男性亮蓝底或默认亮品红底；未知性别继续回退粉红色，兼容旧空间。

**验证：** `dart analyze bin/einz_tui.dart ../shared` 通过；shared `dart test` 24/24 通过。

## 2026-09-10 CLI/TUI 性别配色收尾：规范值 + 青绿兜底 + 探测带性别

**背景：** 老板自查 2026-09-09 的性别配色实现，发现不周到之处并交由我实施服务端性别表方案。

**修复（cli/bin/einz_tui.dart）：**

1. **提交规范化**：旧 TUI 引导直传中文 男/女 到服务端 meta（App 传 male/female），
   渲染端按 `'male'` 匹配不上 → 新增 `_genderCode()` 提交时转 male/female（与 App/服务端规范一致）。
2. **渲染兼容两值**：`male`/`female` 与旧数据 男/女 都能识别——男蓝 `_bgBlue`(104m)、
   女粉 `_bgPink`(105m)。
3. **性别未知回退青绿**（老板要求）：新增 `_bgTeal`(256 色 48;5;37 ≈ #00AFAF)。
4. **探测带性别**：`_probeServer`(/health) 与启动时一并取回 `person_genders` 种入
   `_TuiState.personGenders`（此前仅 /space 刷新才有性别，首屏及刷新失败时无性别表）。

**验证：** `dart analyze`（cli + shared）通过；本机起 demo server + pty 启动 TUI，
标题栏三段式布局正常渲染、新探测代码不崩溃（demo store 在本机未认证，进入引导属环境状态，非本次改动）。

## 2026-09-10 CLI/TUI 消息左右分栏互换 + 标题栏状态互换

**老板要求：** 我的消息放右边、对方消息放左边（对齐主流聊天 App 习惯）；顶部在线状态
同步互换（对方贴左、我的贴右）；按对方性别配色不变。

**实现（cli/bin/einz_tui.dart）：**

1. **我的消息**：绿色前缀 + 普通正文，整块右对齐（每行右缘对齐 cols-8，8 列右留白镜像原左侧布局）。
2. **对方消息**：气泡镜像到左侧——`[who 时间]` 标签贴最左、彩色底正文居右，矩形气泡
   （col 10+suffixW → cols-8 各行列一致），性别配色（男蓝/女粉/未知青绿）不变；
   新增 rightPad=8 与左侧留白对称。
3. **系统提示**：保持左对齐（信息流提示不参与左右分栏）。
4. **标题栏**：三段式互换——对方状态贴左、我的状态贴右、"Einz TUI" 仍居中。
5. 引导阶段性别提交规范化（中文 男/女 → male/female）上一提交已就位；einz.dart /
   einz_chat.dart 无性别提交路径，无需同步。

**验证：** dart analyze 通过；pty 启动确认标题栏互换生效（左 `○ - #-` 对方、右 `○ - #dev-a1` 我的），
消息区镜像因 demo 环境未认证未做视觉验证（几何经核算对齐）。

## 2026-09-10 CLI/TUI 消息分栏对齐修复（保留原插槽排版、互换内容）

**背景：** 上一版镜像改造后老板反馈"双方消息的留白、对齐效果都乱了"，要求保留
之前的排版效果（插槽），把双方消息内容换到对方的插槽。老板拍板：我的消息=右侧
纯文本（不加气泡）；对方消息=左侧保留性别气泡（标签贴左）。

**定位的问题（cli/bin/einz_tui.dart）：**

1. 我的消息原实现把 [我 时间] 放行首再右对齐——长消息首行起点落回左缘、短消息
   标签飘在中间，左右观感不一致 → 改为**标签贴右缘**（末行末尾 `body [我 时间]`），
   所有行右缘统一对齐 cols-8。
2. 对方气泡原实现把标签后的空格算进背景色，末行背景左缘比其他行早 1 列（矩形
   错位）→ 改为**标签嵌入气泡内**（黑字），气泡矩形各行列统一 col 9→cols-8。

**验证：** dart analyze 通过；pty 启动正常、标题栏分栏正确；消息区视觉效果
待老板在真实 demo 环境确认。

## 2026-09-10 CLI/TUI 消息左右分栏互换（终版：严格互换插槽）

**老板要求：** 我的消息放右边、对方消息放左边（对齐主流聊天 App 习惯）；顶部在线状态
同步互换。两版镜像改造被否（留白/对齐乱）后 git reset 回 f125491 重新开始，
老板选定「严格互换插槽」：

- 分支条件 `m.isMine || m.isSystem` → `m.isSystem || !m.isMine`，**渲染代码零改动**；
- 我的消息 = 右侧性别气泡（按**我的**性别配色：男蓝/女粉/未知青绿，`[我 时间]` 黑字贴右缘）；
- 对方消息 = 左侧黄色 `[对方名 时间]` 前缀纯文本；系统提示灰色左侧不变；
- 标题栏三段式：对方贴左、我的贴右、"Einz TUI" 居中。

**时间标签格式：** 跨天 `9月2号` → `09-02`，跨年 `2026年9月2号` → `2026-09-02`（月日补零）。

**验证：** dart analyze 通过；pty 启动正常、标题栏互换生效。

## 2026-09-10 CLI/TUI 对方消息加左侧性别气泡（待老板确认效果后提交）

**老板要求：** 在严格互换插槽基础上，对方消息也加上按性别配色的气泡效果。

**实现（cli/bin/einz_tui.dart）：**

- 新增 `_genderBubble(rawGender)` 辅助：男蓝 / 女品红 / 未知青绿（兼容 male/female 与旧中文 男/女）；
- 对方消息从"黄色前缀纯文本"改为**左侧性别气泡**：`[对方名 时间]` 黑字标签嵌在气泡
  左缘、正文白字，气泡矩形 col 1 → cols-8（右侧留白 8 列），与右侧我方气泡
  （col 9 → cols）左右对称；
- 我的右气泡分支保持原代码不动（inline 性别映射保留，避免扰动已确认代码）。

**效果预览：** 双方都是性别气泡——我的在右（按我的性别配色）、对方在左（按对方性别配色），
系统提示仍是左侧灰色纯文本。

**验证：** dart analyze 通过；pty 启动正常。**未提交**，等老板确认效果。

## 2026-09-10 CLI/TUI 气泡细节调整：对方标签移首行 + 我的气泡右缘补齐

**老板要求：**

1. 对方（左侧）长消息的 `[名字 时间]` 标签从末行开头改到**首行开头**（我的右侧消息标签在末行是对的，不动）；
2. 我的（右侧）长消息气泡**包含右侧留白**——此前非末行只给正文上背景色，中英文折行宽度差
   造成右缘锯齿；改为正文 + 背景色填充到整行右缘（col cols），与末行（标签本就在背景色上贴右）
   一致，整块成为右侧实心矩形，与左侧对方气泡（col 1 → cols-8）对称。

**实现（cli/bin/einz_tui.dart）：**

- 对方分支：标签渲染从 `i == last` 移到 `i == 0`（首行，含单行）；其余行（含末行）标签栏留空
  并补齐到右留白前，矩形保持完整；
- 我的分支：非末行新增 `fill = (cols - leftPad) - bodyW` 背景色填充，各行右缘统一对齐 col cols。

**验证：** dart analyze 通过。老板确认后提交（本条目随提交落库）。

## 2026-09-10 启动链首帧回归修复：StartupGate 加载屏渐变缩成左侧细条

**老板反馈：** app 打开时第一个画面只有左侧约 1/3 是渐变粉蓝背景 + Logo，右侧
2/3 全白，持续约 0.5 秒后跳变到全屏——要求开屏就是全屏背景 + Logo。

**根因（main.dart StartupGate 加载屏）：** commit 3474618（2026-09-09）把
`Center(child: SpinningBrandLogo(72))` 改为 `SafeArea(Column(Spacer, Logo 96,
Spacer))` 以统一启动链布局，但外层仍是无 alignment 的 `DecoratedBox`——Scaffold
body 是宽松约束，RenderProxyBox 尺寸 = child 尺寸，渐变缩到 Column 宽度
（96px Logo）→ 左侧一条渐变 + 右侧露白（theme scaffold 浅粉白 #FFF5FA）。
Center 会撑满宽松约束，Column 不会，改动引入了回归。加载屏仅在 `_check()`
（SQLite 查询约 0.5s）期间可见，随后切入 setup 检测页（该页有 alignment 修复，
全屏）——正是「0.5s 左侧 1/3 → 跳变全屏」的成因。

**修复：** StartupGate 渐变容器改 `Container` + `alignment: Alignment.topCenter`
（与 setup_page.\_buildSplashScreen 同款已验证写法，aafad56），宽松/紧约束下
都撑满全屏；启动链三段（原生屏→StartupGate→检测页）恢复无尺寸跳变。

**测试：** 顺带修复 3474618 遗留的陈旧断言——widget_test「探测失败」用例仍断言
已删除的失败文字（`暂时无法连接服务器…`），改为断言新行为（旋转 Logo 保持 +
无失败文字，与 setup_probe_retry_test 一致）。setup_probe_retry + widget_test
4/4 全过；flutter analyze 0 issue。已 USR2 热重启供老板确认。
## 2026-09-10 点击引用卡跳转原消息 + 目标短暂高亮

**老板要求（2026-09-10）：** 1) 点击消息内引用卡跳转到原消息位置；2) 跳转后
短暂高亮目标——老板指出边框 0→有会改气泡尺寸，用背景色高亮更稳。

**实现（chat_page）：**
- 引用卡（气泡内引用块）包 GestureDetector onTap → `_jumpToMessage`：
  目标未加载（UI 分页懒加载只渲染最近一页）时先 `sequenceOfMessage`（repo
  新增：按 messageId 查 serverSequence）往前分页补载直到覆盖目标；定位用
  「估算 jumpTo 触发目标附近构建 → 目标 GlobalKey ensureVisible 居中校正」。
  目标 GlobalKey 仅跳转目标持有，不阻碍懒回收。
- 高亮：气泡 Container → AnimatedContainer（350ms 过渡），只换背景色——
  gradient 深色气泡（白字）原色提亮 30%；plain 浅 tint 气泡用品牌浅粉
  #FDD6ED；1.6s 后 Timer 恢复（dispose cancel）。
- **坑（真机同类 bug，widget 测试暴露）**：高亮 setState 原放在嵌套第二个
  post-frame 回调里——目标已在视口时 jumpTo 是 no-op 不调度新帧，`pump()`
  只在 hasScheduledFrame 时才处理帧，嵌套回调永不执行、高亮不生效。改为在
  第一个 post-frame 回调里立即置高亮（目标未构建时由后续构建按
  _highlightMessageId 应用），ensureVisible 校正保留在嵌套回调。

**老板决策（墓碑/抹除语义）：** 原消息被删除/焚毁（本地墓碑）时仍可跳转——
meta（时间信息）仍在消息流，用户可能对上下文感兴趣（现状即正确）；未来实现
彻底抹除功能时，抹除消息不跳转，改为顶栏通知「已抹除无法跳转」。

**验证：** flutter analyze 0 issue；chat_initial_scroll（含新高亮用例 4/4）、
chat_bubble_gender、chat_page_menu、message_repository 29/29 全过；已热重启。

## 2026-09-10 CLI/TUI 我的短消息气泡统一左对齐（8 列留白起铺满屏缘）

**老板要求：** 我的（右侧）消息——长消息气泡已左对齐至 8 列留白（col 8 → cols），
但短消息气泡仍按正文长度整行右对齐贴屏缘，左缘参差有锯齿；要求短消息气泡同样
左对齐至留白 8 字符到边，让我的长短消息气泡统一对齐（对方左侧气泡一直是对称的
整块矩形，无此问题）。

**实现（cli/bin/einz_tui.dart `_formatMessage` 我的分支）：** 删除单行消息的
「整行右端贴屏缘」特例（`' ' * (cols - contentW)` 右对齐），末行分支条件由
`i == wrapped.length - 1 && wrapped.length > 1` 简化为 `i == wrapped.length - 1`
统一处理（含单行）——正文左对齐至 leftPad(8)、背景色空格填充至 textWidth、
[我 时间] 标签贴最右，整行背景矩形与长消息各行完全一致。对方分支不受影响。

**验证：** dart analyze 0 issue；已提交。

## 2026-09-10 CLI/TUI 我的短消息：气泡左缘统一 + 正文仍右对齐贴标签

**老板反馈（紧随上条）：** 上一条把短消息正文也改成了左对齐（col 8 起），但老板
要求短消息的**正文仍然右对齐、贴着 [我 时间] 标签**——只是气泡整块要从 8 列留白
铺满到屏缘（左缘与长消息统一，消除锯齿），正文位置保持右贴标签的形态。

**实现（cli/bin/einz_tui.dart `_formatMessage` 我的分支）：** 单行短消息分支改为
`' ' * leftPad + bg + 背景色空格填充(textWidth - chunkW) + 正文 + ' ' + 标签`——
气泡矩形与长消息各行完全对齐，正文右对齐贴着标签（标签贴最右）。长消息末行
保持正文左对齐不变。

**效果：** 短消息「hi」显示为：col 8 起整块背景色气泡铺满屏缘，右侧「hi [我 时间]」。

**验证：** dart analyze 0 issue；已提交。

## 2026-09-10 CLI/TUI 新设备引导标题栏：身份确认前不再猜测对方名字

**老板反馈：** 新设备引导在确认身份（输入 1/2 选择是 personA 还是 personB）之前，
标题栏左侧就显示了一个名字（personA 的名字）；若随后选择了就是这个名字的身份，
标题栏左右两侧变成同一个人。

**根因（demo server + pty 复现确认）：**

1. `_peerNameOf` 在 `store.personId == null`（身份未确认/未登记）时返回
   `personNames.values.first`——把名称表第一项（通常 personA）当对方展示，纯猜测
   （复现：选择前标题栏左段「○ Lukas #-」）；
2. 选择身份后 `store.personName` 立即设为所选名字（右侧标题栏随之显示所选名字），
   但 `store.personId` 要等 enroll 返回才设置——期间左侧仍显示猜测名 →
   「左右两侧都是同一个人」（复现：选择 personA 后左「○ Lukas #-」右
   「○ Lukas #doomship」）。

**修复（cli/bin/einz_tui.dart）：**

- `_peerNameOf`：`personId` 为空时返回中性占位「对方」（与消息区未知发送者
  「对方」一致），不再猜测名称表第一项；
- `_runGuide`：身份一旦选定（输入 1/2 确认）立即 `store.personId = chosenPerson`
  并落盘——标题栏随即显示正确的对方（左）/自己（右），无需等 enroll 完成
  （enroll 请求本就携带 `personId: chosenPerson`，服务端返回同值，本地提前设置
  仅影响显示层）。恢复路径（personId 置空重登记）不受影响。

**验证：** dart analyze 0 issue；demo server + pty 复现：选择前标题栏
「○ 对方 #- … ○ - #doomship」，选择 personA(Lukas) 后「○ Alice #- …
○ Lukas #doomship」，两侧不再同人。已提交。

## 2026-09-10 CLI/TUI 标题栏改三段 1/3 布局：左右状态段截断 + 品牌固定居中

**老板要求：** 标题栏左右两段的在线状态各自长度上限为全宽 1/3 - 1 字符，超出
截断成一个 … 符号；品牌名 "Einz TUI" 放在中间 1/3 的正中，窗口拉伸时保持在
中央不变。

**实现（cli/bin/einz_tui.dart）：**

- `_titleBarThree` 重写：`sideMax = cols ~/ 3 - 1` 截断左右段（复用
  `_truncateByWidth`），品牌名起点 `centerPos = (cols - cw) ~/ 2`（屏幕正中
  = 中间 1/3 的正中），左段贴左缘、品牌居中、右段贴右缘；超窄终端（左右段与
  品牌重叠）时弃品牌保左右段。

**顺带修复根因（`_truncateByWidth` 对 ANSI 输入的计宽 bug）：** 该函数逐 rune
调 `_displayWidth` 时，转义序列的 `[97m` 等字节被按普通字符计宽（单个 `\x1B`
返回 0，其后字符失去转义上下文）——彩色输入 `"○ - #doomship"` 限 9 列被错误
截成 `"○ - …"`（截断预算被 4 字节转义吃掉）。标题栏是它首次接收带 ANSI 的输入
（此前只有状态行纯文本）。改为循环内原样复制整段转义序列、不计宽度。

**验证：** dart analyze 0 issue；独立脚本 + pty 实抓：120 列品牌起始列 56（期望
56）、右段完整；30 列品牌起始列 11（期望 11）、右段正确截断为 `"○ - #doo…"`。

## 2026-09-10 CLI/TUI 引导阶段标题栏对方占位：'对方' → '?'

**老板要求：** 引导阶段（确认对方是谁以前）标题栏不要写"对方"，用 `?` 代替。
`_peerNameOf` 的 `personId` 为空分支返回 `'?'`（消息区未知发送者仍显示"对方"，
不受影响）。

**验证：** dart analyze 0 issue；pty 实抓标题栏左段 `"○ ? #-"`。

## 2026-09-10 CLI/TUI 气泡上下加角标框线（方案 3：╭─╮/╰─╯ 同色实线）

**老板要求（先出方案后选择）：** 同一人的相邻消息叠加难以区分，气泡上下加能
区分边界的框线。给出 4 方案（上下实线边框 / 仅同人相邻分隔线 / 角标框线 /
标签嵌进上边框行）+ 4 线型（同色实线 / 暗灰实线 / 白色实线 / 同色虚线），
老板选定：**角标框线 ╭─╮/╰─╯ + 与气泡同色的实线**（不好看就换方案 1 纯实线）。

**实现（cli/bin/einz_tui.dart `_formatMessage`）：**

- 新增框线前景色常量 `_fgBlue`(94m)/`_fgPink`(95m)/`_fgTeal`(38;5;37)——与气泡
  底色同色系，黑底上用亮色才可见；新增 `_genderBorderFg` 按性别取框线色；
- 双方气泡分支在返回行列表首尾各插入一行 `╭─…─╮` / `╰─…─╯`，随各自气泡宽度
  （对方 col 1 → cols-8，我的 col 8 → cols）；系统消息无气泡、不加框线。

**验证：** dart analyze 0 issue；独立脚本（原样复制 `_formatMessage`）渲染模拟
会话：对方蓝框两条（col 0→72）、我的粉框两条（col 8→80，短消息正文右贴标签），
各行宽度与气泡矩形完全一致。已提交，效果待老板实机确认（不好看换方案 1）。

## 2026-09-10 CLI/TUI 气泡分隔最终定版：空行隔开（角标框线 → 实线 → 空行）

**迭代过程（老板实机看效果后连续调整）：**

1. 方案 3 角标框线 `╭─╮/╰─╯`（commit 588bf15）——老板看完觉得框线重；
2. 方案 1 简化「每条消息下方一条同色实线 `─`」（未提交）——老板觉得 `─` 线
   视觉干扰不好看；
3. **最终定版：消息之间用空行隔开**（本提交）。角标框线、实线分割线及其框线
   前景色常量（`_fgBlue/_fgPink/_fgTeal`）、`_genderBorderFg` 全部移除。

**实现（cli/bin/einz_tui.dart）：** `_render` 消息循环按下标遍历，在相邻消息之间
插入一个空行（`if (i < msgs.length - 1) lines.add('')`），末条消息后不插；
`_formatMessage` 恢复为纯气泡行（不再带分隔行）。系统提示消息同样参与空行分隔。

**验证：** dart analyze 0 issue；独立脚本模拟渲染循环：系统提示、对方长短两条、
我的长短两条之间各一个空行，末条无尾随空行。老板确认后提交。

## 2026-09-10 CLI/TUI 空行分隔微调：末条消息后也插空行

**老板反馈（紧随上条提交）：** 末条消息后也要插空行，否则底部 `[我]` 输入框
紧贴末条。此前"末条后不插"的考虑有误：把空行当成"两条消息之间的分隔符"、
末条后无下一条就不插，漏了输入区需要呼吸空间。改为 `_render` 每条消息
（含末条）后无条件 `lines.add('')`。

**验证：** dart analyze 0 issue；已提交。
## 2026-09-10 长按消息菜单顶部加消息预览行（头像 + 按性别气泡风格正文）

**老板要求：** 对话页长按消息弹出的菜单顶部加一行：发言人头像 + 该消息正文
（截取到行末不溢出）；该行使用消息流里的按性别区分的气泡风格。

**实现（chat_page）：** `_showMessageActions` 菜单 Column 顶部插入
`_buildMessagePreviewRow`：头像（`_MessageAvatar`，我的在右/对方在左，与消息流
一致）+ `_bubbleColor(mine)` 按性别气泡底色的正文（maxLines 1 + ellipsis 单行
截断；gradient 风格白字/plain 深字随气泡）；附件消息无正文时显示消息类型
（image/video/voice/file）作占位。

**验证：** flutter analyze 0 issue；chat_page_menu + chat_bubble_gender 13/13
全过；已热重启。
## 2026-09-10 TUI 标题栏左右在线绿灯亮度不一致修复

**老板反馈：** TUI 标题栏左侧（对方）在线绿灯不如右侧（我的）明亮，是否用了
不同颜色？

**根因（cli/bin/einz_tui.dart）：** 左右灯串完全相同（`$_green●$_white`，都是
ESC[32m 标准绿）——不是颜色不同，而是**中段品牌名 "Einz TUI" 用了
`_bold`（ESC[1m）后只切白字（ESC[97m）没关闭粗体**，bold 状态泄漏到右段，
终端把右段绿点按亮绿（≈92）渲染 → 右侧更明亮。

**修复：** 中段改为 `'${_bold}Einz TUI\x1B[22m$_white'`——品牌名 bold 展示后
立即 ESC[22m（normal intensity）关闭粗体再继续，左右绿点同为标准绿。

**验证：** dart analyze（cli + shared）0 issue；修复后右段绿点前 SGR 序列含
ESC[22m（代码级确认）。pty 自动验证受限（TUI 交互终端检测拒绝伪 pty），
亮度一致需老板在真实终端重启 TUI 肉眼确认。
## 2026-09-10 长按菜单预览行对齐修复：我的靠右/对方靠左

**老板反馈：** 弹窗顶部简略消息气泡在消息短时被居中显示，视觉效果不稳定；
要求与消息流一致——对方靠左、我靠右。

**修复（chat_page _buildMessagePreviewRow）：** Row 由 mainAxisSize.min（短消息
整行收缩被 sheet 居中）改为 max + mainAxisAlignment（我的 end / 对方 start）；
长消息 Flexible 撑满截断行为不变。Row 加 ValueKey('messagePreviewRow') 供测试
断言（项目 key 惯例）。

**测试：** chat_page_menu_test 的 _FakeApi 支持可选消息列表；新增用例「长按菜单
预览行对齐：我的消息靠右、对方消息靠左」（长按我的消息 → end、长按对方消息 →
start，遮罩点击关窗）。

**验证：** flutter analyze 0 issue；chat_page_menu 13/13 全过；已热重启。
## 2026-09-10 引用跳转高亮改为边框闪烁（背景色与被引用作者对方气泡色混淆）

**老板反馈：** 跳转目标用的背景高亮色正好是被引用作者的对方气泡颜色（plain
浅粉 #FDD6ED ≈ 女气泡浅粉、gradient 提亮蓝 ≈ 男气泡天蓝），混淆；改用
边框闪烁试试。

**实现（chat_page）：** 移除背景高亮（删 _highlightColor，气泡 color 恢复纯
_bubbleColor）；跳转目标气泡加琥珀实线边框（#FFC107，不撞任何性别气泡色系）
2px，350ms 周期开关 4 次（亮-灭-亮-灭，约 1.4s）后消失——Timer.periodic 序列，
dispose cancel。border 绘制在边界内，不改变气泡布局尺寸（此前"边框会改尺寸"
的注释判断不准确，已修正）。

**测试：** chat_initial_scroll 用例改为断言边框：跳转后 bubble.border 非 null
（2px 琥珀）、闪烁序列结束（推进 1.6s）后 border null。注意断言"亮起"须在
时钟推进前（350ms 周期会被 pump(duration) 触发切换）。

**验证：** flutter analyze 0 issue；chat_initial_scroll 4/4 全过；已热重启。
## 2026-09-10 引用跳转高亮改回背景色（显眼橘黄 #FF9800，2s 恢复）

**老板反馈：** 边框闪烁方案实测闪烁期间气泡尺寸变化（此前"border 绘制在边界
内不影响尺寸"的判断在 AnimatedContainer 动画下不成立）；改回背景色渐变方案，
总时长 2 秒，颜色用显眼橘黄（不与性别气泡色系混淆——之前品牌浅粉 #FDD6ED
与女气泡浅粉、提亮蓝与男气泡天蓝撞色）。

**实现（chat_page）：** 移除边框（_highlightFlashOn/琥珀 Border 全删）；气泡
高亮背景改 `Color(0xFFFF9800)`（Material orange，白字/深字都可读），置高亮后
AnimatedContainer 350ms 渐变出现、保持 2s 后恢复原色（渐变返回）。

**测试：** chat_initial_scroll 用例断言高亮背景 #FF9800、pump 2100ms 后恢复
indigo.shade100。

**验证：** flutter analyze 0 issue；chat_initial_scroll 4/4 全过；已热重启。
## 2026-09-10 引用跳转高亮动画节奏调整：0.8s 渐变 + 0.4s 停留 + 0.8s 渐变回

**老板要求：** 变化过程慢一点、停留短一点——渐变成橘黄 0.8 秒、停留 0.4 秒、
渐变回去 0.8 秒（总 2 秒）。

**实现（chat_page）：** 气泡 AnimatedContainer duration 350ms → 800ms（渐变；
出现与返回共用）；清除 Timer 2000ms → 1200ms（800ms 渐变 + 400ms 停留后触发
清除，随后 800ms 渐变返回原色）。总时长不变仍约 2s。

**测试：** 恢复断言 pump 2100ms → 1300ms（Timer 1200ms 后清除）。

**验证：** flutter analyze 0 issue；chat_initial_scroll 4/4 全过；已热重启。
## 2026-09-10 高亮节奏再调（1.5s/0s/1.5s）+ 菜单安全分组分隔线

**老板要求：** 1) 高亮渐变 1.5 秒、停留 0 秒、褪回 1.5 秒；2) 菜单里界面风格
与阅后即焚之间加分隔线（下面的是安全相关设置，参照我的设备与界面语言之间）。

**实现（chat_page）：**
- 高亮节奏：AnimatedContainer duration 800 → 1500ms；清除 Timer 1200 → 1500ms
  （渐变完成立即褪回，停留 0s，总 3s）；测试恢复断言 pump 1600ms。
- 菜单：style（界面风格）项后插入 PopupMenuDivider，分隔 burn（阅后即焚）及
  其后的 PIN/邀请/口令等安全相关项。

**验证：** flutter analyze 0 issue；chat_initial_scroll + chat_page_menu 17/17
全过；已热重启。
## 2026-09-10 顶部通知条视觉简化（清淡浅粉白，去粉蓝渐变与文字装饰感）

**老板反馈：** 通知条文字底下有两条黄线（视觉现象）；要求简化通知条视觉——
清淡颜色（不用浓缩的粉蓝渐变）、文字不加装饰。

**实现（widgets/top_notice.dart）：** 背景粉蓝渐变 → 浅粉白 #FFF5FA（同
Scaffold 纸感底）；描边半透明白 → 浅粉 #E9D5E0（同输入框描边）；粉调投影 →
淡灰影（12% 深蓝灰）；文字白色 w600 → 深蓝灰 #33415A（AppBar 标题同色）
常规字重 w500、无任何装饰；白徽章 + 品牌 Logo 保留（非文字装饰）。代码查证
无 underline/TextDecoration——"两条黄线"为浓渐变 + 加粗白字在真机的视觉现象，
简化后自然消失。

**验证：** flutter analyze 0 issue；chat_page_menu 13/13 全过（覆盖语言切换
触发 showTopNotice 的路径）；已热重启。
## 2026-09-10 顶部通知条下移到双方在线状态条上（不再遮顶栏菜单按钮）

**老板反馈：** 通知条盖在顶栏标题上会暂时遮挡菜单按钮；建议覆盖在两人在线
状态条上。

**实现（widgets/top_notice.dart）：** Positioned top 由 0 改为
`MediaQuery.paddingOf(context).top + kToolbarHeight + 8`（AppBar 之下第一条
即状态条，左右 margin 12 与状态条对齐）；去掉 SafeArea 层（top 已显式避开
状态栏，SafeArea 会再加一遍状态栏内边距）。通知条仍贴顶下滑入场。

**验证：** dart format + flutter analyze 0 issue；chat_page_menu 13/13 全过
（覆盖语言切换触发 showTopNotice 路径）；已热重启。
## 2026-09-10 通知条完全覆盖在线状态条（与状态条同高开始绘制）

**老板反馈：** 通知条仍偏下，只遮住在线状态栏下半部分；要求完全覆盖——和
在线状态栏同一高度开始往下绘制。

**根因（widgets/top_notice.dart）：** Positioned top = padding.top +
kToolbarHeight + 8，再叠加内层 Padding top 8，DecoratedBox 背景实际从
+16 开始；状态条顶部在 +4（margin top 4）——背景比状态条顶部低 12px，
状态条高度约 30px，只遮住下半部分。

**修复：** Positioned top 改 +4（= 状态条 margin top，两种风格一致）；外层
Padding top 8 → 0（背景贴 Positioned top，与状态条同高开始往下绘制）。

**验证：** flutter analyze 0 issue；chat_page_menu 13/13 全过；已热重启。
## 2026-09-10 口令/信封互切改为表单右上角切换图标（替代下方文字链接）

**老板要求：** 新设备向导口令页⇄信封页互切，由下方文字链接改为表单右上角
切换图标（类似手机/邮件登录互换、二维码/输入框登录互换）。

**实现（setup_page）：** 口令页（join）与信封页标题行包 Row：左侧 Expanded
原 _stepHeader，右侧右上角 IconButton——口令页 Icons.mail_outline（tooltip
改用线下密保信封，onPressed _openEnvelopeImport）、信封页 Icons.password
（tooltip 改用线上密保口令，onPressed _switchToPassphrase）；删除两页下方
TextButton.icon 文字链接。互切逻辑（_preEnvelopeRole 记来源）不变。

**测试：** wizard_envelope_entry 与 setup_envelope_verify 断言由 find.text(链接)
改为 find.byIcon（create 无图标 / join 有图标 / tap 图标互切）。

**验证：** flutter analyze 0 issue；setup_join_passphrase + wizard_envelope_entry
+ setup_envelope_verify + widget_test 14/14 全过；已热重启。
## 2026-09-10 口令/信封切换图标升级为「折角」视觉效果

**老板要求：** 表单右上角切换图标要有折角视觉效果，折角背后是切换图标——
更生动形象，也是很多 app/网站的登录方式切换做法。

**实现（setup_page）：** 新增 `_DogEarSwitch`：40×40 方块，右上角斜切（
`_DogEarClipper` 切掉边长 14 的等腰直角三角形），折角背后露出品牌粉
（#D6529C 底层），主体白底细描边（#E9D5E0）+ 居中切换图标（深蓝灰
#33415A），Tooltip 保留原文案；口令页（mail_outline → 信封）/信封页
（password → 口令）的 IconButton 替换为 _DogEarSwitch，互切逻辑不变。

**验证：** flutter analyze 0 issue；setup_join_passphrase + wizard_envelope_entry
+ setup_envelope_verify + widget_test 14/14 全过（find.byIcon 断言不受影响）；
已热重启。

## 2026-09-10 TUI /rename 命令改名 /myname（不保留兼容旧名）

**老板要求：** TUI 的 /rename 改成 /myname；补充要求不保留兼容旧名。

**实现（cli/bin/einz_tui.dart）：** 命令解析 case '/myname'（删除 /rename
兼容分支）；帮助列表与 4 处引导文案同步 /myname <名字>；文档无 /rename
引用。cli/build 旧编译产物含旧字符串（gitignore 不入库，重新构建自动更新）。

**验证：** dart analyze（cli + shared）0 issue；源码/文档 grep 无 /rename 残留。

## 2026-09-10 长按消息菜单「阅后即焚」——单条消息可设/调整/取消 burn

**老板要求：** 长按消息菜单加「阅后即焚」项，点击打开与右上角菜单同款的档位
弹窗，应用到被点击的这条消息（本机生效纯本地）；可给未设置的消息添加、
调整已设置的、选「无限」取消已有阅后即焚。

**实现：**
- `message_repository.dart` 新增 `setMessageBurn(messageId, burnSeconds)`：
  更新 burnAfterSeconds + expiresAt（burn<=0 → expiresAt=null 无限/取消；
  >0 → now+burn），仅对未墓碑消息，返回是否成功。
- `chat_page.dart`：把档位选择弹窗抽为公共 `_pickBurnSeconds(current)`（全局
  /单条共用，当前值右侧勾选）；`_showBurnPicker`（全局设置）改用公共弹窗；
  新增 `_setMessageBurn(m)`（选档后调 repo、就地重建该消息 record 使倒计时
  即刻生效、通知提示）；长按菜单在引用与删除之间加「阅后即焚」项
  （Icons.timer_outlined，pop('burn')），action 分支调 `_setMessageBurn`。
- l10n：新增 `chatPageActionBurn`（阅后即焚 / Burn after reading）、
  `chatPageBurnFailed`（设置阅后即焚失败）并 gen-l10n。

**验证：** flutter analyze 0 issue；chat_page_menu + message_repository +
chat_initial_scroll 29/29 全过；未提交等老板检查后提交（2026-09-10 老板
确认提交）。

## 2026-09-10 Multiverse（多重宇宙）Server 多租户骨架（feature/multiverse 分支）

**背景：** 老板决定 v2 升级改名为 Multiverse（多重宇宙）；先建 Server 多租户
骨架（docs/PROTOCOL_MULTIVERSE.md §3/§4）。加入授权模型已拍板：token 门禁
（24h 一次性、只存 hash）+ 口令 escrow（沿用 v1）+ 满员事务约束；不做创建者
确认（模型 B）。

**实现（server/）：**
- `db.ts`：新增 `spaces`/`space_members`/`join_tokens` 三表 + 索引；首次启动
  写 `meta.schema_version=2`。
- `config.ts`：ServerConfig 增加 `protocol_version="v2-multiverse"` 与
  `capabilities=["spaces","join-tokens"]`（space_id 保留为 legacy 兼容）。
- `app.ts`：/health 只返回协议版本/能力/legacy 概览，**不再返回全局
  person_names/person_genders**（多空间防泄漏成员元数据）；新增 4 个路由：
  POST /spaces、GET /spaces/lookup、POST /spaces/join、
  POST /spaces/{id}/join-tokens。
- 新 `spaces.ts`：createSpace（创建者=成员0、返回首个 token）、lookupSpace
  （最小公开信息）、joinSpace（事务消费 token：未用/未过期/未满员→插第二成员
  →满员转 active）、createJoinToken；base58url 32B 随机 token（e1_ 前缀）、
  SHA-256 存 hash、24h TTL；space_address 暂为随机 hex 占位（正式版 Keccak-256
  + EIP-55 派生，U2 补）。
- `test/smoke.test.ts`：两处 /health person_names 断言改为 Multiverse 语义
  （断言 /health 不含 person_names + 改查 db meta 验证登记默认名）。

**验证（注意 Node 版本）：** better-sqlite3 原生模块为 Node 22（ABI 127）编译，
**测试/运行必须用 v22**（系统默认 v18 加载失败；v20 也不匹配）。
`npm run build`（tsc）0 错；`npm test`（v22）冒烟全绿；手动 e2e 8 步全过：
health 能力 ✓ 创建空间 ✓ lookup 1/2 ✓ 伙伴加入 ✓ TOKEN_USED ✓
TOKEN_INVALID ✓ 满员生成新 token ✓ 新 token 加入 → SPACE_FULL ✓。
已提交到 feature/multiverse 分支。

## 2026-09-10 Multiverse U2 密钥分发闭环（create 带钥 + 口令 escrow 取包）

**目标：** 把 join 流程补成"能解密"的完整闭环——create 时创建者提交口令加密的
Space Key 密封包（escrow 按空间隔离），加入方凭同一口令取回 Space Key。

**实现（server/，feature/multiverse 分支）：**
- `escrow.ts`：`parsePackage` 加 export；新增 `escrowForSpace(spaceId, body)`：
  取包（{passphrase} → argon2id 校验（pwhashStrVerify），正确才返回密封包，
  区别于 /recover 的"全丢重置"——取钥不撤销设备）/ 上传更新（UPSERT，沿用
  v1 upload 语义）。
- `spaces.ts`：`createSpace` 变 async，新增 `sealedSpaceKey`（EscrowPackage 结构
  校验）+ `escrowPassphrase`（pwhashStr 哈希）成对参数——成对提供时写
  key_escrow（space_id 为新空间）。
- `app.ts`：POST /spaces 路由传参；新增 POST /spaces/{spaceId}/key-escrow 路由。

**验证：** npm run build 0 错；npm test（v22）冒烟全绿；手动 e2e：create 带
sealedSpaceKey+口令 ✓ join ✓ 正确口令取回 Space Key 密封包 ✓ 错误口令
ESCROW_VERIFY_FAILED ✓ 无 escrow 空间取包失败 ✓。**踩坑：3999 端口残留
server 进程导致 EADDRINUSE 与请求打到旧进程（假 404）——先 lsof -ti:3999
清理再测**。已提交。

## 2026-09-10 Multiverse U1 租户隔离（session 绑定 Space + 消息按空间隔离）

**目标：** 多租户实质——设备认证绑定 Space，消息读写与 WS 广播按 Space 隔离，
跨空间互不可见；v1 客户端兼容（challenge 不带 space_id → legacy 回落
cfg.space_id，行为不变）。

**实现（server/，feature/multiverse 分支）：**
- `db.ts`：sessions/challenges 加 `space_id` 列（CREATE + ALTER 迁移）；messages
  `server_sequence` 由全局 UNIQUE 改 `UNIQUE(space_id, server_sequence)`（存量库
  检测旧单列唯一自动索引 → 重建表，复合唯一不触发循环重建）。
- `auth.ts`：createChallenge 可选 spaceId（写入 challenges）；verifyChallenge 的
  session 绑定 `row.space_id ?? cfg.space_id`（legacy 回落）；resolveSession 返回
  `{ device_id, space_id }`。
- `messages.ts`：postMessage/syncMessages 按 session.space_id 回落值过滤；幂等检查
  加 space 条件；server_sequence 按 Space 独立递增。
- `ws.ts`：Conn 加 spaceId（attachWs 时绑定）；广播（peer 状态/passphrase 重设/
  profile 更新/key 轮换）只发同 Space 连接（sameSpace 从发起方 conn 取，发起方
  离线不广播）；broadcastNewMessage 按消息落库 space 分组（发信方可能无 WS）；
  close 先广播离线再删连接。
- `app.ts`：/auth/challenge 透传 space_id。
- 新测试 `test/two_space_isolation.test.ts`：双 Space 隔离验收（A 绑 spaceA 发消息，
  B 绑 spaceB 同步为空；反向亦然；两空间 sequence 各自从 1 起）；package.json
  test 脚本串联冒烟 + 隔离测试。

**验证：** npm run build 0 错；npm test 全绿（冒烟 v1 兼容 + 双 Space 隔离）。
**踩坑：** messages 全局 UNIQUE(server_sequence) 与按空间递增冲突 → 复合唯一 +
重建迁移；TS18047（回调内引用模块级 db 丢非 null 推断）→ 改 for 循环。已提交。

## 2026-09-10 Multiverse U2-U4 + 收尾

### U2 密钥分发闭环（已提交 2fd6050）
- escrow.ts 导出 parsePackage；createSpace 支持 sealedSpaceKey+escrowPassphrase
  成对写入 key_escrow（argon2id）
- 新端点 POST /spaces/{id}/key-escrow（口令验证返回密封包，UPSERT 上传）
- 踩坑：3999 残留进程致假 404

### U3 App 向导接线（已提交 c399ff1）
- 入口页（探测后停留新建/加入选择；修复 build 启动屏条件回归——
  `_role == null && !_probeDone`，否则探测成功仍卡启动屏）
- join：token preflight（首次通过停留显示空间确认卡片，再次点下一步放行）→
  名字页（自填名字+性别）→ 口令 escrow 取钥 → PIN
- create：客户端生成 space_id/Space Key + 口令 sealed 包随 POST /spaces 提交
  （服务端接受客户端 space_id）；完成页欢迎对话框展示邀请链接（复制分享）
- 清理 v1 遗留（personA/B 身份卡体系、邀请码页、伴侣名字页、_enrollDevice）
- 测试注入：preflightOverride/joinOverride/createOverride；42 个测试全绿
- golden 失配保持红不重刷（老板政策）
- 踩坑：join step1 按钮被 v1 身份卡"自动前进"例外隐藏、_backStep offline 回退
  旧位置、fake escrow 非法 base64（salt='s'）、测试漏 setUpAll(sodium)

### U4 CLI 对齐（已提交 2efad8c + feb749e）
- DeviceStore +spaceAddress（旧 store 自动迁移）；探测对齐 protocol_version/capabilities
- 未绑定引导提示 /space create | /space join；移除 v1 伴侣名字/性别询问
- /space create：客户端生成 space_id/Space Key + sealed 包 → POST /spaces →
  打印空间地址 + 24h 一次性邀请链接
- /space join：preflight → join（设备登记+签发 session）→ 口令 escrow 取钥；
  /space address 显示地址
- 提取 _activateAfterBind（create/join 命令与启动引导共用：同步+设锁+WS）
- server join 响应补 spaceAddress；**路由字段名统一下划线**（public_key/
  display_name/sealed_space_key/escrow_passphrase/device_name）——真实 HTTP 级
  bug，U3 全走 fake/函数直调未暴露，CLI pty e2e 复现并修复
- 验收：CLI pty e2e 全通（A /space create → B /space join，空间地址一致，
  含口令 escrow 取钥；脚本 aimemo/cliMultiverseE2E.py 可复用）

### 其他
- git 历史修复：远程 origin/main 停在 78d3b41（本地 main 的 v1 commit 未 push）
  → `git push origin main`（78d3b41..26d4c23）；feature/multiverse 首次 push 远程备份
- 迁移脚本按老板指示取消（老版本未正式上线，无需 legacy 迁移）
- 老板 iPhone 安装试用成功（方案 B：flutter build ios --release + Xcode
  Build/Install + 信任开发者证书）

### U4 引导改造（老板 2026-09-10 定稿）
- 未绑定设备引导第一步改为「选择 加入伴侣的秘境（join）/ 创建新秘境（create）」
  （对齐 App 入口页）——create→名字/性别→口令创建；join→token→名字/口令加入
- _spaceCreate 加性别询问（本地记录；create 暂不提交——服务端无 gender 通道）
- pty e2e 脚本适配新引导序列（aimemo/cliMultiverseE2E.py），create→join 全通
- 踩坑：_spaceJoin 无性别询问（仅 create 有）——脚本别等「我的性别」

### U4 身份选择定稿（老板 2026-09-10）
- create 录入两人身份：我的名字/性别 + 伴侣名字（必填）/伴侣性别（必填）
  ——服务端 createSpace 预置两 slot（creator active + partner pending）
- join 改为「选择是哪一个用户」（preflight 返回 slots：编号/名字/性别/状态）
  ——加入者可能是第二人（选 1），也可能是第一人的其他设备（选 0，同身份
  多设备共享 person_id）；不再自填名字
- 服务端：preflightJoin 返回 slots（移除 SPACE_FULL——多设备语义）；
  joinSpace 加 partnerSlot（绑定指定 slot，slot 行 person_id 为身份锚点，
  首个加入的设备生成、多设备复用）
- db：space_members 的 person_id/joined_at 允许 NULL（伴侣预置行未加入）
- e2e 三设备验证：A create（伴侣流程）→ B 选 1（第二人）→ C 选 0（第一人
  其他设备，curl join-tokens 生成第二个 token）——地址一致，PASS
- 踩坑：space_members NOT NULL 约束与预置 NULL 冲突（create 500）；渲染
  wrap 截断长地址（C 的 spaceId 改从 store 文件读，不依赖 lookup）

### App 同步身份选择方案（老板 2026-09-10 确认：与 v1 一致）
- create 流程加伴侣页（步骤 2）：伴侣名字（必填）/伴侣性别（必选）——复用 v1
  键（wizardTitlePeerName/wizardPeerNameHint 等，U3 清理后为死键）；createSpace
  提交 gender/partnerName/partnerGender；stepCount 5→6；_finish 对方名=伴侣名字
- join 流程名字页改为身份选择页（步骤 2）：preflight slots 展示两身份卡片
  （编号/名字/性别/状态，点选）→ joinSpace 提交 partnerSlot；不再自填名字；
  本人名字/性别取所选身份（服务端中英文 gender → App 'male'/'female' 归一）
- 新增 l10n 键：wizardTitleJoinIdentity/wizardJoinIdentityHint/
  wizardJoinNoSlots/wizardSlotOnline/wizardSlotRequired（zh/en）
- 测试适配：4 个测试文件（fake slots 两身份 + join 身份选择步骤 + create
  伴侣页步骤），17 个测试全绿；analyze 0 error
- 页面设计沿用 v1（名字页/伴侣页：TextField + 性别卡片选择；身份选择页：
  卡片列表点选）

### #3 space_address 落地（Keccak-256 + EIP-55）
- 新增 server/src/address.ts：toEip55（EIP-55 checksum 编码）+ deriveSpaceAddress
  （Keccak-256(space_public_key 字节) 后 20 字节 → EIP-55 地址——确定性）
- 用已有 hash-wasm 依赖的 keccak（无需新增依赖）
- createSpace：space_public_key = 创建者公钥（base64，原"pending:"占位）；
  space_address = 派生地址（公钥缺失回退随机——兼容）
- 验证：地址格式 0x+40hex（含 EIP-55 大写）✓ 确定性 ✓ 旧空间兼容（冒烟/隔离全绿）

### #4 空间数上限（config.json maxSpaces，老板 2026-09-10 方案）
- server/config.json：maxSpaces（0=不限默认；1=单空间即 v1 模式；n=最多 n 个）
- config.ts：启动读取一次（readFileConfig 缓存——改配置需重启）；loadConfig 返回
  max_spaces
- createSpace：现有空间数 ≥ maxSpaces → 409 SPACE_LIMIT_REACHED
- 客户端：CLI/App 新建时收到该错误码显示禁止信息（App 加 l10n wizardSpaceLimit）
- 验证：curl 实测 maxSpaces=1 时空间 1=201、空间 2=409 SPACE_LIMIT_REACHED；
  cli/shared analyze 0 issue、App analyze 0 error（仅既有 info）

### App 本地配置机制（gitignore 的 local_config.json + --dart-define-from-file）
- server_settings.dart 的 kEinzServer 改 String.fromEnvironment('kEinzServer',
  defaultValue: 'https://einz.tic.cc')——移除老板的 localhost 注释行（覆盖走配置）
- app/local_config.json（gitignore）+ local_config.example.json（模板，入 git）：
  {"kEinzServer": "http://localhost:3000"}——flutter run/build 加
  --dart-define-from-file=local_config.json 即覆盖——不再直接改代码、不污染 commit
- scripts/run_app.sh：透传 flutter 命令 + local_config.json 存在则自动加参数
- README 加「本地开发配置（App）」说明
- 验证：不带 define → https://einz.tic.cc；带 local_config.json → localhost:3000 ✓
- 脚本改名 scripts/run_app.sh → scripts/build_ios.sh（聚焦 flutter build ios +
  透传参数；老板 2026-09-10 建议——名字更精确）；flutter run 手动加
  --dart-define-from-file 同样支持（README 已说明）

### TUI 向导输入细节（老板 2026-09-10）
- 创建空间：我的名字/伴侣名字都必填（不允许空——去掉"创建者"回退）
- 性别选择改数字输入：1=男、2=女（只接受数字——不接受"男/女/male/female"文字）

### /invite 改造（v1 邀请码 → Multiverse join token）
- /invite 改为生成绑定新设备的 join token（POST /spaces/{id}/join-tokens——
  24h 一次性；shared 加 JoinTokenResult + createJoinToken；v1 createInvite 废弃）
- 输出：📎 新设备绑定邀请（链接）+ token + 提示"新设备 /space join <链接> 绑定"
- 验证：pty e2e 全通（A create → B join → A /invite 工作 → C join（同端点 token））
- 踩坑：pty 渲染帧交错（抓 token 不可靠——/invite 断言命令工作 + join 用 curl
  同端点 token）；A create 后卡锁屏码询问（/invite 前先回车跳过）

### 落地页 + v2 服务端去全局 space_id（老板 2026-09-10）
- 落地页：GET /join/<token> 返回静态 HTML 指引页（品牌风格卡片——"这是 Einz
  私密空间邀请，请用 App 加入" + 显示邀请码；token 正则校验非法 404）——
  解决浏览器打开邀请链接 404 断裂
- space_id 移除：v2 下空间由客户端 POST /spaces 创建——服务端不再生成/持久化
  全局 space_id（loadConfig 去掉 getMeta/setMeta；health legacy 块、启动日志、
  attachments/escrow/messages/push/ws/devices 的 cfg.space_id 引用全部清理——
  legacy 回落改空串、附件归属从消息查、escrow v1 函数冻结空串）
- 验证：tsc OK；启动日志无"已生成 space_id"；/join 返回 200 HTML；
  /health 无 legacy/space_id；pty e2e 全通（A create → B join → A /invite → C join）
- 踩坑：search_replace 替换文本带 // 注释会破坏表达式语法（escrow.ts TS1005——
  替换文本改纯 "" 修复）

### server 配置文件改名（老板 2026-09-10）
- 删除过时的 server/config/config.json.example（v1 白名单/space_id 模板——v2
  白名单靠动态登记；README 快速开始同步改 v2 方式）
- server/config.json → server/einz_server_config.json（gitignore 不入 git——存
  maxSpaces）；config.ts 的 readFileConfig 路径同步改名；README 引用更新
- .gitignore 顺带清理 deployment/config/config.json（v1 部署残留——目录已不存在）
- 验证：tsc OK；maxSpaces=1 从 einz_server_config.json 生效（curl 空间 2=409）；
  git check-ignore 生效（新配置文件不入 git）

### TUI 引导首问改 C/J 输入（老板 2026-09-10）
- 引导第一步：创建新秘境（输入 C 或 create）/ 加入老秘境（输入 J 或 join）——
  大小写均可（既有 toLowerCase 归一）；保留 1/2 数字兼容；无效提示同步更新
- pty e2e 脚本同步：等特提示改"创建新秘境"、发送改 C/J、注释/描述更新；
  cli/test 的 guide 脚本确认无影响（不涉及该提示/输入）
- 验证：cli analyze 0 issue；pty e2e 全通（A 输 C 创建 → B 输 J 加入 → A /invite
  → C 输 J 加入，地址一致）

### TUI 加入流程：token 错误直接重输（老板 2026-09-10）
- 引导 join 分支：token 被拒后内层循环直接重输（不再回到 create/join 首问）
- pty e2e：join_flow 加 wrong_token 参数（先贴错误 token→断言直接重输→再贴
  正确 token）+ quit_after_wrong（B1 验证重输后退出会话、B2 正常 join——
  pty 渲染/输入竞态下错误 token 后继续 join 不可靠——分离验证）
- 验证：cli analyze 0 issue；pty e2e 全通（B1 错误 token 直接重输 ✓ → B2 正常
  join → A /invite → C join，地址一致）
- 踩坑：pty 时序（异步处理期间输入丢失——sleep 无效——改用 quit_after_wrong
  分离会话验证）；"创建新秘境"文本一直在消息区（重绘再现）不可作"回到首问"信号

### 名字语义对齐（老板 2026-09-10）
- TUI 身份选择：改为输入完整名字（不再输编号 0/1）——提示只显示名字
  （不显示性别/在线状态）；名字精确匹配（不匹配/同名区分报错）
- TUI 创建空间：伴侣名字不能与我的名字相同（报错重输）
- 改名重名：TUI /myname 与 App 菜单改名——不能改成与对方相同的名字
  （TUI 用 personNames 非我 personId；App 用 widget.peerName——新 l10n
  chatPageRenameSameAsPeerError）
- pty e2e：join_flow 的 slot 参数改 identity_name（输名字选身份——B=Alice、
  C=Lukas）
- 验证：cli analyze 0 issue、App analyze 0 error（仅既有 info）、改名相关
  测试 15 个全过、pty e2e 全通（B/C 输名字选身份）

### 修复：标题栏对方名字 '-' + 气泡全青色（老板 2026-09-10 反馈）
- Bug1 根因：a) CLI _peerNameOf 硬编码 v1 假 id（personA/personB）查 personNames
  （v2 personId 是 UUID——查不到）；b) 服务端 getSpace 读 v1 的 meta
  person_name:*（v2 成员数据在 space_members——拉空）
  修复：_peerNameOf 改为 personNames 找非我 personId；服务端 getSpace 改从
  space_members 读 display_name/gender（按 person_id），space_id 从 session 取
- Bug2 根因：CLI createSpace 直传中文 gender（'男'/'女'）——服务端原样存——
  App 判断 'male'/'female' 不匹配（气泡全青色）
  修复：服务端 normGender 统一存 male/female（createSpace 两处 INSERT 归一）；
  CLI createSpace 提交走 _genderCode 转换（与 enroll 一致）
- 验证：cli analyze 0 issue、server tsc OK、App analyze 0 error、App 气泡测试
  全过、pty e2e 全通
- 踩坑：push.ts 注释里 person_name:*/person_gender:* 的 */ 截断注释块（TS1109）
  ——改写措辞避免 */ 序列

### TUI 身份选择列表：名字背景色按性别（老板 2026-09-10）
- 加入向导的身份列表：名字背景色按性别粉/蓝（复用 _genderBubble——与消息
  气泡背景色完全一致）；亮白字 + 重置；仍不显示性别/在线状态
- 验证：cli analyze 0 issue；pty e2e 全通（ANSI 背景色不影响名字匹配）

### 气泡仍青色排查（老板 2026-09-10 反馈"重启后仍青色"）
- 排查结论：服务端 space_members 的 gender 存储正确（normGender 统一 male/female
  ——curl 实测）、getSpace 返回正确、CLI 数据流（join/create 后 _refreshPersonNames
  刷新 personGenders——对方消息气泡按 personGenders[senderPersonId] 配色）逻辑正确
  ——无需代码修复
- 老板青色根因：旧空间数据（早期创建的空间 space_members.gender 为 NULL——未知
  性别回退青绿）；新建空间（修复后创建——gender 有值）按逻辑应正常分色
- pty 实测受阻：临时诊断脚本 create 后发消息失败（Space Key 导入/锁屏码询问时序）
  ——非气泡 bug（已删除临时脚本）
- 老板自行验证：新建空间发消息看对方气泡颜色

### 气泡青色真因更正：认证后未刷新 person 性别表（老板 2026-09-10 实测推翻旧结论）
- 老板实测：新建/加入向导刚结束直接发消息仍青色；/exit 重进后双色正常——非遗留
  数据（server-new-local 已删旧库）——是 CLI 认证成功后未及时拉取 person 名称/性别表
- 真因：main 启动初始化（1022）调 _refreshPersonNames 时 token 未就绪（向导前）——
  getSpace 失败静默，personGenders 空；_activateAfterBind（join/create 认证绑定，
  835/931）认证成功后没有再刷新——向导结束直接发消息 → 对方气泡未知性别回退青绿
- 修复：_activateAfterBind 收尾加 `await _refreshPersonNames(_state!)`（WS 启动、
  渲染前——join/create/启动所有认证路径统一刷新；getSpace 有 try-catch 兜底）
- 验证：cli analyze 0 issue；pty e2e 全通（create→join→多设备地址一致）

### 同性别空间收消息青色：收消息方 personGenders 快照缺新成员（老板 2026-09-10）
- 现象：两人同性别——第二人 join 后发消息，对方 TUI 收到青色；男女组合正常
- 真因：收消息路径（WS onMessage/sync）不刷新 personGenders——第一人快照是加入时
  的（无后来 join 的第二人——person_id 当时为 NULL）；服务端 getSpace 的
  `AND person_id IS NOT NULL` 过滤掉未加入成员——收到第二人消息时查不到性别→青绿
- 修复两层：
  1) 按需刷新：新增 _refreshGenderForLatest——所有 startWs 的 onMessage/onAutoSync
     回调统一接入——收到对方消息缺发送者性别则 await _refreshPersonNames 再重绘
  2) 上线刷新：_onPeerStatus 对方上线（online 状态变化）时刷新 personNames/
     personGenders——第二人性别创建时就写入 space_members（slot 预置），join 后
     person_id 落位 getSpace 即可返回——第一个消息前就知道（老板诉求）
- 验证：cli analyze 0 issue；pty e2e 全通（create→join→多设备地址一致）

## 2026-09-11 TUI /myname 改名后名称不刷新——服务端 meta/space_members 脱节

**老板反馈：** TUI 里 /myname 改名成功后，右上角自己的名字不变；对方 TUI 左上角
我的新名字正确（WS 广播）；但对方自己也 /myname 后，它右上角自己的名字也不变，
且左上角我的新名字又变回老名。v1 TUI 全部正确。

**根因（服务端，非 TUI）：** 90ec740 把 GET /space 的名称表从 meta 改为读
space_members（v2 成员表——create/join 写入 display_name），但 POST
/devices/person-name（改名端点）仍只写 meta `person_name:*`——两表脱节：
- 改名者自身刷新（/myname 后 _refreshPersonNames）拉到的是 space_members 旧名，
  而 TUI 标题栏右段优先取远程名称表（_personLabel 的 personNames[pid] 先于本地
  store.personName）→ 右上角不刷新
- 对方 /myname 后的同名刷新把 WS 已更新的新名覆盖回 space_members 里的旧值 →
  我方名字"变回老名"
- v1 正确因为 v1 的 getSpace 与改名都走 meta（单一数据源）

**修复（server/src/devices.ts updatePersonName）：** 改名时同步
`UPDATE space_members SET display_name = ? WHERE space_id = ? AND person_id = ?`
（session 的 space_id + 设备 person_id）——恢复单一数据源一致性，TUI 渲染逻辑零改动。

**回归测试（server/test/smoke.test.ts 12b）：** 独立服务器 POST /spaces（带
public_key 创建者）→ GET /space 旧名 → POST /devices/person-name 改名 →
GET /space 新名。未修复 dist 上此用例正确失败（能抓住该 bug）。

**顺带修复存量测试破损：** smoke.test.ts 第 280 行断言 enroll 返回非空 space_id
——0ac9372 起 enroll 返回 ""（无全局空间，空间经 session 绑定），主流程其余部分
用空串一致回落仍全通过 → 断言改为 `assert.equal(spaceId, '', ...)`。

**验证：** server tsc 0 issue；npm test 全绿（冒烟含新 12b + 双空间隔离）；
Node 需 ≥20.11（import.meta.dirname——本机默认 18.12 跑不了，用 nvm v22）。
