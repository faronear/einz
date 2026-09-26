# Einz — 开发计划（projectPlan）

> **本文件是索引，只放"现在与将来"**：每行一个专项（状态 + 指向细节文档）。
> 约定（2026-09-22 立）：**细节一律住专项文档**，本文件不展开；
> 过程与决策流水住 `aimemo/worklog.md`；Phase 0–4 的历史保留在**文件末尾**备查。
> 状态标记：`[ ]` 待办、`[>]` 进行中、`[⏸]` 被阻塞、`[x]` 已完成。

- **产品：** Einz — 两个人的私密秘境（E2EE 聊天 + 共享空间）
- **部署形态：** Multiverse 多租户（`spaces` 表 + 动态登记；**一条通道可进多个秘境**，
  见 `docs/GLOSSARY.md` 的术语分层）
- **架构依据：** `aimemo/productLens.zhcn.md`（Draft v2.0）
- **最后更新：** 2026-09-22

---

## 进行中

| 专项 | 状态 | 细节文档 |
| --- | --- | --- |
| **多空间**（一条通道进多个秘境） | M0.5 ✅ / M1 ✅ / M2 ✅ / **M3 ✅（2026-09-22 完成）**——剩真机自测 | `aimemo/multiSpaceDesign.zhcn.md` §8（里程碑）、§9（决策） |
| **字段改名**（`device_id`→`entrance_id`、`person_id`→**`member_id`**、`device_uid`→`install_uid`） | `[x]` **2026-09-23 主线完成**（一次性机械替换，无 alias）；身份词 **2026-09-24 续改 `partner`→`member`**（界面文案不动） | `aimemo/renamePlan.zhcn.md` §9 |
| **语音实时通话** | `[⏸]` 待评审（评审通过才拆任务） | `aimemo/voiceCall.zhcn.md` |

## 待办（跨专项；一行一项，细节在各自文档）

- `[x]` **多空间 M3**（2026-09-22）：未读（服务端派生 `GET /messages/unread` + 数字角标）、
  术语（`docs/GLOSSARY.md`）、`projectPlan` 索引化
- `[ ]` 多空间**真机自测**：空间级「销毁本秘境通道」、`install_uid` 回填、未读角标、
  空间列表不再有破坏性入口
- `[ ]` `productLens` 剩余复核：§12 通道管理 / §14 路线图仍是 v1 口径（§2 概念模型已修）
- `[⏸]` **语音通话 Phase A**：`flutter_webrtc` 在 Xcode 26.3 + Codemagic 下的构建与真机打通
- `[x]` 字段改名**执行**（2026-09-23，见 `renamePlan.zhcn.md`）
- `[x]` **中文「设备」→「通道」清扫 + CLI `/device`→`/entrance`**（2026-09-23，见 `renamePlan.zhcn.md` §7）
- `[ ]` **撤销的 App 入口**（通道列表「撤销这条通道」：口令 + 二次确认；`ApiClient.revokeEntrance` 已就绪）
- `[ ]` **macOS 分发签名 + 公证**（2026-09-18 记）：Developer ID Application 证书 →
  `codesign --options runtime --timestamp` → `notarytool submit` + `stapler staple` →
  搬进 GitHub Actions（secrets：证书 p12/密码/App 专用密码/AppleID）
- `[ ]` **TUI/CLI 接入 escrow**（生产化加固候选）：新通道接入改走 `escrow download`
  （凭口令取 Space Key）替代直接传 sealed 文件；配套考察加密 store
- `[ ]` 文档债：`projectPlan` 之外的旧文档复核（`docs/DATABASE.md`/`PROTOCOL.md` 的
  Draft v0.1 头、`aimemo/upgradeToMultiverse.md` 是否仍与实际一致）
- `[ ]` 待定（承接 productLens §16）：消息删除语义 / 已读回执粒度 / 一次性配置形式（归 SETUP.md）
- `[ ]` 环境依赖项：Android 真机验证、iOS 真机构建签名（待 Apple 付费账号）

---

## 历史：Phase 0–4（全部已完成，保留备查）

## Phase 0 — 架构 + 密码学 PoC（估算 2–5 天）

**目标：** 验证"通道密钥 → 一次性配置 → Space Key → 加解密 → 认证"全链路跑通，Server 只见密文。

- [x] 产出 `docs/E2EE.md`（密钥层级、派生、一次性配置的密钥分发、轮换、恢复细节）
- [x] 产出 `docs/SETUP.md`（一次性配置手册：两台设备 + 服务器白名单操作步骤）
- [x] 产出 `docs/PROTOCOL.md`（REST + WebSocket 消息格式、版本化）
- [x] 产出 `docs/DATABASE.md`（双端 schema 与迁移）
- [x] 搭建 monorepo 骨架：`app/`（Flutter）、`cli/`（Dart CLI 测试端）、`server/`（Node+TS）、`shared/`（纯 Dart 核心包）、`deployment/`、`docs/`
- [x] `shared/` 核心包：crypto（libsodium 封装）、protocol（类型与契约）、sync（状态机）——纯 Dart，App 与 CLI 共用
- [x] CLI 测试端：`dart run` 无 UI，作为"第二条通道"跑完整流程
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
- [x] **口令托管密钥（KEY_ESCROW.md，已实现）**：Server /key-escrow 三端点（表+冒烟用例）；shared KeyEscrowService（复用 backup.dart Argon2id+XChaCha20）+ 3 项单测；CLI escrow upload/download（全链路 e2e + 双端口令接入 e2e 过）；App 接入口令 + 新通道凭口令接入（③按钮）；flutter test 全过
      - 2026-09-14 变更：原"rotate 后解锁自动重传（`_syncEscrow`）"**已随轮换撤除一并删除**（客户端不再本地缓存共享口令）；服务器无密保箱时改为走"修改口令"跳过旧口令校验直接重建，或 `cli escrow upload`（见 `docs/SECURITY.md` §4.7）
- [x] **App 附件消息（语音/图像/视频）**：MessageRepository.sendAttachment（encryptAttachment 加密 blob → /attachments 上传 + caption 消息 + 本地附件元数据落库）+ history 关联附件 + fetchAttachment 下载解密；chat_page：语音（按住说话录音 record → 播放条 audioplayers）、图像（拍照/相册 image_picker → 缩略展示/点击全屏）、视频（拍摄/相册 → 下载解密 video_player 播放）；插件懒构造避免测试环境 MissingPluginException；flutter test 18 项全过 + golden 更新
- [x] **App 附件扩展（音频文件/任意文件）+ 固定服务器地址**：协议 kMessageTypes/Server ALLOWED_TYPES 加 audio/file；chat_page 附件 sheet 扩至 6 项（file_picker 12.x：FilePicker 静态方法 + readAsBytes）；audio 播放条（与 voice 共用 \_playAudioMessage）、file 文件卡片（下载保存 path_provider）；setup_page 服务器地址改固定常量 kEinzServer（移除输入框）；全量验证过（server 冒烟/shared 16/app 18）
- [x] **多通道凭证判断（person_id）**：shared ApiClient 加 getSpace + SpaceResult/SpaceDevice（含 person_id 映射，const 构造）；MessageRepository 加 refreshDeviceMap 缓存 + \_isSamePerson（person 优先、device 降级），history sender 按 person 判断——同用户不同通道的消息显示为 me；chat_page \_refresh 拉取映射；单测（shared getSpace 2 项 + app person 判断 1 项），shared 18/app 19 全过
- [x] **阅后即焚（纯本地，每通道独立）**：Server 零改动——BurnAfterSettings（app_state 存档位：无限/1分/5分/30分/1小时/1天/7天）；local_messages 加 burn_after_seconds/expires_at 列（schemaVersion 2 + addColumn 迁移）；send/sync 落库按本通道设置算 expiresAt；purgeExpired 到期删除（3s ticker 联动）；chat_page 顶栏 ⏱ 选择器 + 消息 ⏱ 标记；单测（设置 3 项 + purgeExpired 1 项），flutter test 23 项全过
- [x] **聊天分页加载优化（UI 懒渲染 + 增量刷新）**：MessageRepository 分页方法 historyRecent（最近 N 条升序）/historyBefore（更早）/historySince（新增含未同步），typedef HistoryMessage；chat_page 首屏只渲染最近 50 条 + ScrollController 上滑到顶加载更早（插入头部）+ 3s ticker 只增量追加新增（去重）+ 到期消息本地移除；单测 2 项（FakeApi 模拟 Server 分配 server_sequence），flutter test 25 项全过 + golden 确认通过
- [x] **多语言界面（中/英，官方 l10n）**：flutter_localizations + gen-l10n（l10n.yaml + app_en.arb/app_zh.arb 各 60+ 键）；LocaleSettings（app_state locale 偏好 system/zh/en + localeNotifier 即时生效）；main.dart MaterialApp 接入（跟随系统 + 手动覆盖）；**setup_page + chat_page 全部文案中英文化**（~65 处替换：按钮/标签/提示/错误/占位符键）；聊天页顶栏 🌐 切换（跟随系统/中文/English）；阅后即焚档位标签改 \_burnSeconds + l10n 映射；golden/widget 测试指定中文 locale + delegates；flutter test 25 项全过 + golden 更新
- [x] **多语言界面第二批（lock_page 全量抽取）**：ARB 加 lockPage.\* 12 键（含 int 占位符秒数/错误参数）；lock_page 12 处硬编码中文 → AppLocalizations（AppBar/PIN 提示/锁定倒计时/解锁/恢复码入口）；main.dart 确认无 UI 中文文案（注释除外，无需替换）；flutter test 25 项全过 + lock_page golden 更新；**至此四个页面（设置/聊天/锁屏/启动）全部中英文化完成**
- [x] **WS 实时接入 + 轮询兜底**：shared 新增 WsClient（ws_client.dart：WsEvent 模型 hello/message.new/key.rotation/device.revoked + 连接/指数退避重连/状态回调，导出）；app 新增 WsRealtimeService（connected ValueNotifier + onMessageNew）；chat_page 接入（收到 message.new → 立即增量刷新；**WS 在线轮询降频 30s 兜底、断开恢复 3s**；enableWs 测试开关）；单测（shared ws_client 5 项：连接/解析/未知帧/断开重连；app ws_realtime 1 项：message.new 触发 + connected 状态），shared 23/app 26 全过；Server 侧 WS 早已就绪（ws.ts 广播 message.new）
- [x] **device.revoked 撤销处理**：WsRealtimeService 加 onDeviceRevoked 分发；AppLockService 加 clear()（删除锁包 4 key：package/recovery/attempts/locked_until）；chat_page 收到 revoked → 停轮询/WS → 清理本地（锁包+消息库+附件+syncState）→ SnackBar 提示（chatPageDeviceRevoked 键）→ pushAndRemoveUntil 强制回设置页；单测（AppLockService.clear 1 项 + WsRealtimeService revoked 分发 1 项），app flutter test 28 项全过；**key.rotation 暂不处理**（App 无密钥轮换导入流程，仅 CLI rotate 离线流程，事件为通知性）
- [x] **Server 备份密钥改名（命名消歧）**：`EINZ_BACKUP_KEY` → `EINZ_DB_BACKUP_KEY`（backup.ts/scripts/docker-compose/DEPLOYMENT.md/updateServer.md 全部同步；dist 编译产物随 build 更新）；updateServer.md §5 加"旧部署升级"说明（VPS .env 手动改名 + 重启）；E2EE.md 末尾加**密钥命名对照表**（Space Key / 口令派生密钥 / DB 备份密钥三层，防混淆）；server build + smoke 全过；**VPS 需手动改 deployment/.env 变量名并重启**
- [x] **自建空间 + 二维码加入（降小白门槛）**：shared 加 einz-join-v1?space=&p= 格式，URL 编码口令，decode null 安全）+ 3 单测；setup_page A 端新增"自建空间（一键生成 Space Key）"（Random.secure 生成 32B → 认证 → SetPinDialog/口令托管 → 二维码对话框 QrImageView + 一键复制 joinDialog.\*）；B 端口令输入框 📷 扫码入口（mobile_scanner 7.4.0 懒构造 \_JoinScanPage，扫到 einz-join-v1 自动填 spaceId/口令）；依赖 qr_flutter 4.1.0 + mobile_scanner（相机权限拍照时已配置，复用）；Server 零改动；widget 测试加"自建空间入口"用例（ensureVisible 滚动）；flutter test 29 项全过 + setup golden 更新；**白名单保持手动（B 公钥 → A 加 VPS config.json）**
- [x] **配置页分步向导重构（交互优化）**：SetupPage 重构为向导——第 0 步角色选择（创建新空间/加入现有空间/高级 sealed 折叠）；创建 7 步（通道名+生成密钥**本页明确反馈结果** → 白名单确认 → 接入口令 → PIN → 二维码分享 → 完成）、加入 5 步（通道名 → 扫码/口令加入 → PIN → 完成）、高级 5 步（通道名 → sealed 导入 → PIN → 完成）；每步只收集一个信息 + 底部上一步/下一步/完成 + 进度圆点 + 步骤标题（wizardStep\* 键）；\_nextStep 按步骤前置校验；\_authenticate/\_setupLockAndEnter/\_runPinSetup/\_runJoinAccess/\_runSealedImport 复用原认证/托管/sealed 逻辑；widget_test 向导 3 用例 + golden 更新 + flutter test 30 项全过
- [x] **邀请码降级 B（二维码不再含明文口令）**：老板拍板（2026-09-08）——App 邀请码二维码由 JoinInfo（spaceId+口令+邀请码 一键加入）降级为与 TUI 一致：二维码只含纯邀请码，口令由加入方另行输入；shared 删除 JoinInfo 类/export/单测；删除 App 生成邀请码时的口令过时校验与重验证弹窗（死代码）；口令重设通知保留并完善：App 每次 WS online 补查（原有）+ TUI 新增 WS 重连补查（onStatus connected，对齐 App）+ 补查/广播通知后更新 escrowUpdatedAt 防刷屏；docs/KEY_ESCROW.md §12 同步；验证 shared 24 + app 20 全过（golden 保持红：既有文案失配，老板决策暂不考虑 golden）
- [x] **界面风格切换（素雅纯色 / 渐变粉蓝）**：菜单「界面语言」下新增「界面风格」，弹窗内每风格一张预览图+一句描述，点选即生效且不关窗（不离开弹窗预览效果）；UiStyleSettings（app_state key='ui_style'，默认 plain 保留原视觉效果）+ uiStyleNotifier 即时生效；chat_page 背景按风格渲染——gradient 对齐向导全屏渐变（extendBodyBehindAppBar + 透明 AppBar + 顶部留白 + 输入栏/状态条均改不顶左右两头的悬浮圆角条：半透明白+圆角24+投影），气泡改深色白字（男深蓝 #2271F7 / 女深粉 #B83D80，DefaultTextStyle/IconTheme.merge 白字白图标，次要灰字 white70）；ARB 加 2 键；ui_style_switch_test 4 用例（全屏布局/悬浮圆角/气泡深色白字断言）+ chat_page_menu 12 + chat_bubble_gender_test 全过
- [ ] 真机验证（需 Android 真机/模拟器 + FCM 之外的推送场景）——待环境就绪
- [ ] iOS 真机构建/签名/Ad Hoc（docs/IOS.md §3–§4）——待 Mac + Apple 付费账号（APNs 暂无账号，WS/轮询兜底）

## Phase 4 — 加固（估算 3–7 天）

- [x] 通道撤销（白名单 + 上线自毁）——**Space Key 轮换不做**（2026-09-14 决策，见 SECURITY.md §3）
- [ ] 备份与恢复（模型 A：本地加密备份 + 恢复码）
- [x] 通道撤销（撤销生效于认证/同步路径 403 + 被撤销通道上线自毁）＋ 轮换相关代码撤除（SpaceKeyRing / einz rotate / key.rotation 广播，2026-09-14）
- [x] 撤销语义收窄（2026-09-16）：服务端区分 `DEVICE_REVOKED`（明确撤销）与 `FORBIDDEN`（未登记，含库被清空/重置）；客户端**只对明确撤销**自毁（App 清锁包+消息+附件，TUI 清 store+附件缓存后退出），库被重置/连不上只发常驻警告并允许继续读本地消息；撤销自毁覆盖 TUI 所有已开通的通道（`revoked_check.py` 四场景）
- [ ] 后台被重置后的"重新入网"入口（TUI `/space reset` 解绑 + App 菜单项）——当前 `spaceKey != null` 时 create/join 会被拒，库被清空后只能离线看历史（2026-09-16 定：本轮不做）
- [x] 撤销授权收口（2026-09-16）：`POST /devices/:id/revoke` —— **同 space 内可互撤 + 每次校验共享口令**（argon2id，复用取包的校验与失败限速；缺口令哈希 409 `PASSPHRASE_NOT_SET` 拒绝放行）；旧的免口令 `DELETE /devices/:id` 移除；`ApiClient.revokeDevice` 已就绪
- [x] 撤销的客户端入口（TUI，2026-09-16）：`/devices` 列同空间全部通道（带序号、标注在线/已撤销）＋ `/revoke <序号|通道名>`（三重确认：选通道 → **抄一遍目标通道名**（2026-09-26 由输入 `yes` 改）→ 隐藏输入共享口令；按 `ESCROW_*` 失败码分别提示且均注明"未做任何改动"）；探针 `cli/test/revoke_command_check.py` 全过
- [ ] 撤销的 **App** 入口（通道列表里的"撤销这条通道"）：同样要口令 + 二次确认（`ApiClient.revokeDevice` 已就绪）
- [x] 备份与恢复（模型 A：本地加密备份 + 恢复码，shared backup.dart + CLI backup/restore）
- [x] 安全测试 / 离线 / 网络故障 / 服务重启测试（phase4_e2e.sh 段 C/D/E/F 全过）
- [x] Server 备份脚本（SQLite Backup API）与恢复演练（npm run backup/restore，演练通过）
