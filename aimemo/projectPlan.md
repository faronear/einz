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
| Phase 1 | 消息 MVP | [x] 已完成（CLI 测试端：离线队列/自动同步/WS 实时） |
| Phase 2 | 媒体 | [x] 已完成（CLI 测试端：附件加密上传/下载/解密闭环） |
| Phase 3 | 移动端集成 | [x] 代码层完成（drift 本地库/签名 APK），真机验证待环境 |
| Phase 4 | 加固 | [x] 已完成（撤销/轮换/备份恢复/安全韧性测试，phase4_e2e.sh 全过） |

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

- [x] 图片 / 视频 / 语音：加密上传、下载、本地缓存（CLI `attach`/`fetch`，phase2_e2e.sh 全过）
- [x] 附件元数据管理（`/sync` attachments_meta 随消息下发，客户端落盘供解密）

## Phase 3 — 移动端集成（估算 3–7 天）

- [x] 推送决策：**WS 兜底 + Server 占位**（FCM 大陆不可达、厂商推送需各家开发者账号，已决策不接；APNs 留待 iOS 上线，大陆可用）
- [x] 相机 / 麦克风 / 权限（AndroidManifest 已声明 CAMERA/RECORD_AUDIO/INTERNET，真机权限流待验证）
- [x] Android 签名 APK 构建流程（JDK 17 + SDK 36 + keystore + key.properties 签名配置，`flutter build apk --release` 产出 50MB 签名 APK 并 apksigner 验证通过）
- [x] 客户端本地库：drift SQLite（local_messages/sync_state/local_attachments，DATABASE.md §3）——补 Phase 1 遗留
- [x] app 接入 shared 核心包：ApiClient 上移 shared（App/CLI 共用）、MessageRepository（发送/同步/历史/补发），6 项单测全过
- [x] **iOS 启动开发**（老板已购置 Mac）：Info.plist 权限声明 + libsodium 静态库集成（Podfile 本地 pod + DynamicLibrary.process）+ APNs 注册代码（ApiClient registerPushToken + AppDelegate）；构建/真机验证见 docs/IOS.md，待 Mac 执行
- [x] **App 启动锁（方案 B：PIN 加密密钥）**：AppLockService（Argon2id 派生密钥加密 Space Key 包存 drift app_state，错误 5 次锁定 30s，12 词恢复码兑底）+ 锁屏页 + 启动门 + 认证后设置 PIN；4 项单测，flutter test 10 项全过
- [x] **后台切回锁定**：ChatPage 生命周期监听（WidgetsBindingObserver：切后台记时、回前台超 30s 覆盖锁屏保留聊天状态）；LockPage 覆盖模式（asOverlay pop）；LockTimer 纯逻辑 + 5 项单测，flutter test 15 项全过
- [x] **口令托管密钥（KEY_ESCROW.md，已实现）**：Server /key-escrow 三端点（表+冒烟用例）；shared KeyEscrowService（复用 backup.dart Argon2id+XChaCha20）+ 3 项单测；CLI escrow upload/download（全链路 e2e + 双端口令接入 e2e 过）；App 接入口令（SetPinDialog 可选上传）+ 新设备凭口令接入（③按钮）+ rotate 后解锁自动重传（_syncEscrow）；flutter test 18 项全过
- [x] **App 附件消息（语音/图像/视频）**：MessageRepository.sendAttachment（encryptAttachment 加密 blob → /attachments 上传 + caption 消息 + 本地附件元数据落库）+ history 关联附件 + fetchAttachment 下载解密；chat_page：语音（按住说话录音 record → 播放条 audioplayers）、图像（拍照/相册 image_picker → 缩略展示/点击全屏）、视频（拍摄/相册 → 下载解密 video_player 播放）；插件懒构造避免测试环境 MissingPluginException；flutter test 18 项全过 + golden 更新
- [x] **App 附件扩展（音频文件/任意文件）+ 固定服务器地址**：协议 kMessageTypes/Server ALLOWED_TYPES 加 audio/file；chat_page 附件 sheet 扩至 6 项（file_picker 12.x：FilePicker 静态方法 + readAsBytes）；audio 播放条（与 voice 共用 _playAudioMessage）、file 文件卡片（下载保存 path_provider）；setup_page 服务器地址改固定常量 kOnlySpaceServer（移除输入框）；全量验证过（server 冒烟/shared 16/app 18）
- [x] **多设备身份判断（person_id）**：shared ApiClient 加 getSpace + SpaceResult/SpaceDevice（含 person_id 映射，const 构造）；MessageRepository 加 refreshDeviceMap 缓存 + _isSamePerson（person 优先、device 降级），history sender 按 person 判断——同用户不同设备的消息显示为 me；chat_page _refresh 拉取映射；单测（shared getSpace 2 项 + app person 判断 1 项），shared 18/app 19 全过
- [ ] 真机验证（需 Android 真机/模拟器 + FCM 之外的推送场景）——待环境就绪
- [ ] iOS 真机构建/签名/Ad Hoc（docs/IOS.md §3–§4）——待 Mac + Apple 付费账号（APNs 暂无账号，WS/轮询兜底）

## Phase 4 — 加固（估算 3–7 天）

- [ ] 设备撤销 + Space Key 轮换
- [ ] 备份与恢复（模型 A：本地加密备份 + 恢复码）
- [x] 设备撤销 + Space Key 轮换（撤销生效于认证/同步路径 + key.rotation WS 通知 + 归档密钥解旧消息）
- [x] 备份与恢复（模型 A：本地加密备份 + 恢复码，shared backup.dart + CLI backup/restore）
- [x] 安全测试 / 离线 / 网络故障 / 服务重启测试（phase4_e2e.sh 段 C/D/E/F 全过）
- [x] Server 备份脚本（SQLite Backup API）与恢复演练（npm run backup/restore，演练通过）

---

## 待定事项（承接 productLens §16 Open Questions）

- [ ] 一次性配置的具体操作形式（命令行 / 配置界面 / 二维码）→ 归入 SETUP.md
- [ ] 消息删除语义
- [ ] 已读回执粒度
