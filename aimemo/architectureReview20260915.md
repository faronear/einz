# Einz 架构 / 接口 / 安全评估报告（只读审查）

- 日期：2026-09-15
- 审查方式：未作任何改动；server 端逐文件审读 + shared/app 审读 + 仓库卫生检查
- 基线 commit：70f32cf（菜单排序：附件存储移到阅后即焚之后）
- 结论速览：架构分层清晰、注释留痕好、密码学用法总体正确，**服务器"只见密文"定位核实成立**；但服务端存在 2 个严重鉴权/隔离漏洞，另有 v1/v2 双轨并存带来的一批死代码与文档过期。

---

## 一、安全问题（按严重程度）

### 🔴 严重

| # | 问题 | 位置 |
|---|---|---|
| C1 | **两个端点完全无鉴权**：`POST /spaces/{id}/join-tokens`（生成邀请凭证）和 `POST /spaces/{id}/key-escrow` 上传分支（可覆盖任意空间的口令托管包与 passphrase_hash）。任何人拿到 spaceId 即可把自己登记进空间（`partnerSlot` 可自选，可冒充创建者）、或替换口令顶掉真实用户 | `server/src/app.ts` L169-181、`spaces.ts` L280/339-347、`escrow.ts` |
| C2 | **跨空间隔离失效**：`GET /space`、`GET /devices` 直出全局 devices 表（无 space 过滤）；`GET /attachments/:id` 与附件写侧均不校验空间归属，A 空间设备可读写 B 空间附件（密文，但违反隔离模型、可做元数据关联） | `push.ts` L75-77、`devices.ts`、`attachments.ts` L87-103 |

### 🟠 高

| # | 问题 | 位置 |
|---|---|---|
| H1 | 请求体无大小上限，`readJson`/附件上传全量缓冲进内存 → 单请求可打爆内存；messages.ciphertext 也无长度上限 | `app.ts` L481-491、L304-306 |
| H2 | 除 escrow 口令外几乎无速率限制；`maxSpaces=0`（当前生产配置）+ `POST /spaces` 免认证 = 公网开放注册，与"双人私密"定位矛盾 | `app.ts`、`einz_server_config.json` |
| H3 | 首设备自举可抢注：`activeCount===0` 时免邀请码、免认证自举为 personA/creator | `devices.ts` L124-173 |
| H4 | WS session token 走 URL query（进反代 access log/浏览器历史）；且 session_token 在 DB 明文存储（join token 只存 sha256 hash——同一库两种标准） | `ws.ts` L119 |

### 🟡 中

- `GET /avatar/:personId` 免认证公开可读；`/health` 泄露消息总量、ws 在线数（`app.ts`）
- `restoreBackup` 的 `entry.path` 直接 join 落盘，`../` 可逃逸 dataDir（缓解：备份包有 AES-256-GCM 认证，属纵深防御缺口）（`backup.ts` L126-142）
- `sendPushHint` 定义了但从未被调用——**推送功能实际断裂**（`push.ts` L43，app.ts 未 import）
- 无服务端主动吊销单条 session 的手段（只有 revoke device 全删）；`/auth/verify` 成功后不清旧 session
- shared 恢复码取词 `(16bit) % wordList.length` 潜在模偏差（仅当词表长为 65536 因子才均匀）（`shared/lib/src/crypto/backup.dart:285`）
- AAD 无分隔符拼接（理论二义性，线上格式变更需按版本演进）（`message_crypto.dart:64`）
- `decryptWithPassphrase` 用 `sodium()` 而加密路径用 `_sumo()`（一致性瑕疵）；`hashPassphrase` 每次重新 dlopen SodiumSumo 未缓存（`passphrase_crypto.dart:124`、`key_escrow.dart:66-73`）

### ✅ 已确认做对的

- SQL 全参数化；服务端路径遍历有 `SAFE_ID_RE` + `assertInsideFilesRoot` 双保险；avatars `SAFE_PERSON_RE`
- 服务器只见密文：messages/attachments/key_escrow 全程密文；`crypto.ts` 仅 challenge seal 与 argon2id 校验，无解密路径；审计日志纪律好（push token 只记前 8 位）
- WS 鉴权链完整（resolveSession + isActiveDevice + 撤销实时踢线 4403、重复连接 4408、30s 心跳）
- challenge 32B CSPRNG、一次性、5min TTL、常量时间比较；session 32B 熵、24h TTL
- `/join` 页 XSS 白名单；回执 HWM 原子只前进；客户端 `_uuidv7` 用 `Random.secure()`

---

## 二、架构问题

1. **`app.ts` 500 行手写路由**：`resolveSession + isActiveDevice + touchLastSeen` 三连重复约 20 次——抽成 auth 中间件，可一次性解决 C1 那类"漏挂鉴权"。
2. **v1/v2 双轨身份体系并存**：`personA/personB`+meta 与 `space_members` UUID 并行；`getSpace` 混用两张表；`config.ts isActiveDevice(_cfg,...)` 仍携带已失效的 cfg 参数。历史上已引发 escrow 的 space_id 错位 bug。
3. **`chat_page.dart` 4826 行 God class**：状态字段约 40 个，回归面大。建议至少拆出 `_VoiceRecorderController`、`_AttachmentViewer`（三套 `_imageCache/_videoCache/_videoThumbCache` 合一）、回执/在线逻辑。
4. **wire 格式两套命名混用**：v1 snake_case、Multiverse camelCase——在 PROTOCOL.md 明示冻结，或新端点统一 snake_case。
5. `HttpClient` 每请求新建并 `close(force:true)`，无 keep-alive；3s 轮询 + 附件场景 TLS 握手开销可观（`api_client.dart:31-35`）。
6. POST 重试依赖"服务端按 message_id 幂等"的隐式契约，未在 PROTOCOL.md 固化。
7. WS `_onClosed` 未校验 `ws == _ws`，旧连接 onDone 迟到会多触发一次重连（`ws_client.dart:185-200`）。

---

## 三、可删除/修改的代码（已过期）

| 项 | 位置 | 建议 |
|---|---|---|
| `tmp_probe4_test.dart` | `app/test/`（未入 git） | 一次性调试探针（无断言，只 debugPrint），直接删除 |
| 第二个 `POST /auth/verify` | `app.ts` L212-217 | 永不可达（L185 已匹配），删除 |
| `generateAttachmentNonce` | `shared/lib/src/crypto/attachment_crypto.dart:67` | 死代码，删除 |
| `PendingMessage` / `SyncState` / `buildConfigPayload` | `shared/lib/src/sync/sync_state.dart` | 与 app drift 实现（pending 队列 + `_advanceAnchor`）重复，疑似遗留；确认 CLI 是否仍用后移除 |
| `Api.devices` | `shared/lib/src/protocol/types.dart:17` | 从未使用，删除 |
| `fetchAttachment` 的 `sha256` 参数 | `app/lib/data/message_repository.dart:744-764` | **注释与实现不符**（声称校验 sha256 但从未比较）；要么实现校验（下载中断/存储损坏的深度防御），要么删参数改注释 |
| `statusText` | `app/lib/data/server_settings.dart:63` | 调试遗留，删除 |
| `export { randomUUID }` / `export { copyFileSync }` | `server/src/ws.ts:253`、`server/src/backup.ts:172` | 无消费者 |
| `history()` 重复 doc 注释 | `app/lib/data/message_repository.dart:533-536` | 清理 |

---

## 四、过期/失实的说明信息

1. **README.md:54 npm scripts 名不对**：`npm run build-ios`、`build-apk`、`ios-run`、`ios-run-new` 均不存在；实际为 `build-prod-ios`、`build-ios-adhoc`、`upload-ios-appstore`、`ios-run-dev`、`ios-run-dev-new` 等（以根 package.json 为准）。
2. **README.md 文档表缺 4 个**：`docs/` 实际还有 `CI.md`、`ONBOARDING.md`、`SECURITY.md`、`PROTOCOL_MULTIVERSE.md` 未列入。
3. **README 本地配置说明**：只提 `local_config.json`，实际已有 `local_config.ios.json` / `local_config.android.json` 分平台文件。
4. **PROTOCOL_MULTIVERSE.md 示例链接硬编码** `https://einz.tic.cc/join/<token>`，与文中"host 由服务端动态生成（2026-09-11）"自相矛盾——示例宜改占位符。
5. **KEY_ESCROW.md / SETUP.md** 仍描述 v1 白名单模型，与 Multiverse 加入闭环部分脱节，宜标注适用版本。

---

## 五、仓库卫生

- **约 64 个 Syncthing `SFConflict` 冲突副本**（cli/demo 53、server/data 9、.dart_tool 2），均未入 git。建议确认后删除，并把 `server/data/`、`cli/demo/`、`.dart_tool/` 加入 Syncthing 忽略（否则继续繁殖）。
- **`cli/demo/.gitignore` 漏保护 `store-*.json`（设备私钥 store 文件）**——当前未入 git 仅因尚未被 add，`git add .` 即泄露。卫生项里最优先补这条。
- Android 签名口令 `app/android/key.properties` 明文在工作区且随 Syncthing 多机流转（未入 git）：建议轮换口令 + 构建脚本改环境变量注入。keystore.jks 同理（未入 git）。
- `cli/demo/.gitignore` 的 `app.db*` 宜改为 `*.db*`，与根规则对齐。
- `cli/test/cliMultiverseE2E.py` 中 `einzpass2026` 若与真实口令同值，建议更换。

---

## 六、修复优先级路线

1. **C1**：给 space 级端点挂 session/成员校验（顺手抽 auth 中间件）
2. **C2**：补齐 space 过滤（/space、/devices、attachments 读写）
3. **H1/H2**：body 大小上限 + 全局限速；生产 `maxSpaces` 置为实际预期值
4. **H4**：WS token 移出 URL（header 或首帧）；session_token 改存 hash
5. 补 `cli/demo/.gitignore` 的 `store-*.json`（一行改动，立即可做）
6. 文档修正（README scripts 名、文档表）+ 死代码清理（第三节清单）
7. 架构项按需推进（chat_page 拆分、双轨身份收敛）
