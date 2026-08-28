# OnlySpace — 开发计划（projectPlan）

> 项目视角：阶段计划、任务列表、进度跟踪。与 `aimemo/productLens.zhcn.md` 保持同步。
> 状态标记：`[ ]` 待办、`[>]` 进行中、`[⏸]` 被阻塞、`[x]` 已完成。

- **产品：** OnlySpace — 两个人的私密聊天与共享私人空间
- **部署形态：** 固定两人一空间、不分发（静态白名单，无动态配对）
- **架构依据：** `aimemo/productLens.zhcn.md`（Draft v2.1）
- **最后更新：** 2026-08-28

---

## 当前阶段概览

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| Phase 0 | 架构 + 密码学 PoC | [x] 已完成（#16 app 骨架于跨机器续接后完成） |
| Phase 1 | 消息 MVP | [>] 下一步 |
| Phase 2 | 媒体 | [ ] 未开始 |
| Phase 3 | 移动端集成 | [ ] 未开始 |
| Phase 4 | 加固 | [ ] 未开始 |

---

## Phase 0 — 架构 + 密码学 PoC（估算 2–5 天）

**目标：** 验证"设备密钥 → 一次性配置 → Space Key → 加解密 → 认证"全链路跑通，Server 只见密文。

- [x] 产出 `docs/E2EE.md`（密钥层级、派生、一次性配置的密钥分发、轮换、恢复细节）
- [x] 产出 `docs/SETUP.md`（一次性配置手册：两台设备 + 服务器白名单操作步骤）
- [x] 产出 `docs/PROTOCOL.md`（REST + WebSocket 消息格式、版本化）
- [x] 产出 `docs/DATABASE.md`（双端 schema 与迁移）
- [x] 搭建 monorepo 骨架：`app/`（Flutter）、`cli/`（Dart CLI 测试端）、`server/`（Node+TS）、`shared/`（纯 Dart 核心包）、`deployment/`、`docs/`
- [x] `shared/` 核心包：crypto（libsodium 封装）、protocol（类型与契约）、sync（状态机）——纯 Dart，App 与 CLI 共用
- [x] CLI 测试端：`dart run` 无 UI，作为"第二台设备"跑完整流程
- [x] Client：Flutter + sodium_libs，生成 Device Key，Keychain/Keystore 存取 —— **骨架完成**（app/ 已生成并接入 shared；安全存储与消息界面归 Phase 1/3）
- [x] Server：加载静态白名单（config.json）+ challenge-response 认证
- [x] 一次性配置工具：生成 Space Key、分别密封、写入两端、登记白名单（CLI `config`/`import` 命令）
- [x] 消息：客户端加密上传，Server 只存密文，对方解密
- [x] 验收：A（CLI）加密 → Server 只见密文 → B（CLI）解密（`cli/test/e2e.sh` 全过）

## Phase 1 — 消息 MVP（估算 5–10 天）

- [x] 文字消息全链路（REST + WebSocket），先用 CLI 双端收发验证
- [ ] Client/Server SQLite（drift / better-sqlite3，shared 层同步逻辑）—— **CLI 端已用 JSON 落盘实现（pending/history/锚点）**，drift 入库待移动端集成（Phase 3）
- [x] 离线发送队列 + 自动同步（per-space server_sequence）
- [x] 消息历史加载
- [x] CLI 自动化测试脚本：离线发送 → 恢复网络 → 自动补发 → 无重复无乱序（`cli/test/phase1_e2e.sh` 全过）

## Phase 2 — 媒体（估算 3–7 天）

- [ ] 图片 / 视频 / 语音：加密上传、下载、本地缓存
- [ ] 附件元数据管理

## Phase 3 — 移动端集成（估算 3–7 天）

- [ ] APNs / FCM 推送（不含正文）
- [ ] 相机 / 麦克风 / 权限
- [ ] iOS Ad Hoc / Android 签名 APK 构建流程

## Phase 4 — 加固（估算 3–7 天）

- [ ] 设备撤销 + Space Key 轮换
- [ ] 备份与恢复（模型 A：本地加密备份 + 恢复码）
- [ ] 安全测试 / 离线 / 网络故障 / 服务重启测试
- [ ] Server 备份脚本（SQLite Backup API）与恢复演练

---

## 待定事项（承接 productLens §16 Open Questions）

- [ ] 一次性配置的具体操作形式（命令行 / 配置界面 / 二维码）→ 归入 SETUP.md
- [ ] 消息删除语义
- [ ] 已读回执粒度
