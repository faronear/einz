# OnlySpace — 工作日志（worklog）

> 事件视角：按时间线记录工作过程与重要变化。持续追加，不覆写历史。

---

## 2026-08-28

### 架构评审与 productLens 重构（v1.0 → v2.0）

**背景：** 老板要求评估 `aimemo/productLens.zhcn.md`（原 2164 行 Draft v1.0），继续讨论 OnlySpace 架构，允许大幅删改。

**评审发现：**

- 方向正确（E2EE 从 V1 开始、Server 只存密文、设备密码学身份、Local-First、两人约束服务端强制），骨架保留。
- 形式问题：大量重复（E2EE 流程图出现 3+ 次）、Markdown 标题/表格损坏（§2.2 起大量小节标题丢失 `##`）、文件末尾残留多余代码块、命名不一致（Only Space / OnlySpace / private-space）。
- 架构空白：① 密钥层级与恢复模型未定义（丢机/换机如何恢复）；② 设备撤销后未定义 Space Key 轮换；③ 配对握手顺序未定死；④ 消息 schema 缺 nonce/key_version；⑤ server_sequence 作用域未明确（应为 per-space）。

**老板决策（2026-08-28）：**

| 决策点 | 结论 |
| --- | --- |
| 恢复模型 | V1 纯本地备份+恢复码（模型 A），架构预留服务器托管（模型 B） |
| 多设备 | Person≠Device 分开建模，V1 一人一机，预留扩展 |
| 技术栈 | **放弃 UniApp**，改用 **Flutter**（dart:ffi 绑原生 libsodium，无 WebView 中间层；flutter_secure_storage / drift / camera 生态成熟） |
| 文档 | 确认按新结构大幅重写，统一命名 OnlySpace |

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
