# Einz 架构 / 接口 / 安全审查报告

> 审查日期：2026-09-15 · 模型：qwen3.8-27b · 范围：全仓（docs 13 份 + server + shared + app + cli + deployment），只读评估，**未做任何改动**
> 审查方式：文档全读 + 代码交叉核对（server 路由/schema、shared 加密核心、app/cli 密钥存储、git 敏感文件扫描）

---

## 0. 总体评价

架构分层健康：`shared/`（Dart 加密核心）被 app 和 cli **真实共用**（无分叉实现），server 确实只做密文透传（messages/附件均 sha256 校验后原样落盘），密码学选型（libsodium、XChaCha20-Poly1305 + AAD 绑定、Argon2id、路径遍历双重防御、SQL 全占位符）经核查无硬伤。

**核心问题集中在：Multiverse v2 重构后，v1 时代文档大面积过期，且 v2 引入了一批匿名公开端点，与"静态白名单哑转发器"的自我定位背离。**

---

## 1. 安全问题（按严重级别）

### 高

| # | 问题 | 证据 | 建议方向 |
|---|------|------|---------|
| S1 | **Multiverse 端点整体免鉴权**：`POST /spaces` 匿名可建空间，且带 `publicKey` 时直接注册 active 设备 + 签发 24h session；`POST /spaces/{id}/join-tokens` 匿名可对**任意** spaceId 造邀请 token；`POST /spaces/{id}/key-escrow`（取包）只校验 space 存在；`GET /spaces/lookup` 匿名。`maxSpaces=0` 时无上限——公网部署下"双人私密服务"实际是匿名多租户开放服务 | `server/src/app.ts:128-181`、`spaces.ts:156-171`、`escrow.ts:207-214` | 成员端点补 session 校验；`maxSpaces` 默认收紧为 1 |
| S2 | **请求体无大小上限**：`readJson`/附件/头像全部读完 buffer 才处理，持合法 session 可单请求打爆内存 | `server/src/app.ts:481-491`、`attachments.ts:59` | 累计字节超限 413；附件先校验 content-length |
| S3 | **附件上传重试不幂等**：响应丢失→重试→`wx` 标志 EEXIST 或 PK 冲突→500，blob 在盘但**无 attachments 行**，对端永远拿不到元数据，人工重发也救不回；shared 里"重试幂等安全"的注释与事实相反 | `server/src/attachments.ts:70`、`shared/lib/src/protocol/api_client.dart:296-332` | server 端同 id+sha256 幂等返回原记录 |
| S4 | **备份功能在当前部署下实际是坏的**：`backup.ts:81` 无条件 `readFileSync(config.json)`，但当前"动态白名单"模型**没有 config.json**（ONBOARDING 明确"无需配置文件"）→ 容器内 `npm run backup` 直接 ENOENT 崩溃。而 DEPLOYMENT.md 把每日备份列为核心运维动作 | `server/src/backup.ts:32,81`、compose 注入 `EINZ_CONFIG=/config/config.json` | config 缺失时跳过该 entry 或标记 optional |
| S5 | **restore 无路径校验**：备份文件内 `entry.path` 可被 `../../…` 利用在容器内（root）任意写文件（纵深防御缺口，密钥持有者本已全权） | `server/src/backup.ts:126-142` | 拒绝含 `..`/绝对路径的 entry |

### 中

| # | 问题 | 证据 |
|---|------|------|
| S6 | 协议文档承诺的**限流基本未实现**（PROTOCOL.md §10 的 /auth 10次/分 等），全服务唯一限流是 escrow 取包；`/auth/challenge` 可无限造 DB 行 | `server/src/escrow.ts:161` 为唯一 rate limit |
| S7 | **X-Protocol-Version 硬校验双侧均未实现**（REST 无任何检查，client 从不设头），`kProtocolVersion` 是死常量 | `PROTOCOL.md:12,383` vs `server/src/app.ts` 全文无该检查 |
| S8 | WS 无 `maxPayload`（默认 100MiB/帧）、ping 无限速、建连无限速 | `server/src/ws.ts:115-167` |
| S9 | 无条件信任 `x-forwarded-for/proto`：若端口直曝公网，攻击者可自定 Host 让**邀请链接指向攻击者域名**（token 钓鱼）并伪造审计 IP | `server/src/app.ts:26-30`、`audit.ts:45-48` |
| S10 | `GET /space`、`GET /devices` 返回**全局** devices 表（无 space 过滤）：多租户下可枚举其他空间的设备/在线状态（元数据泄漏） | `server/src/push.ts:75-77`、`devices.ts:45-48` |
| S11 | **口令策略偏弱**：≥10 位字母数字 ≈ 13bit 熵，而 escrow 取包免设备认证、离线爆破只靠熵 | `shared/lib/src/crypto/passphrase_policy.dart` |
| S12 | Multiverse 字段契约三方对不上：client 发的 `gender` server 不读（创建者性别丢失）；draft 文档的 `spaceAddress/spacePublicKey` 与 client 实际字段又不同 | `spaces.ts:65-114` vs `api_client.dart:153-170` vs `PROTOCOL_MULTIVERSE.md:123-127` |
| S13 | escrow 限速状态在**进程内存**，重启清零、多实例不共享 | `server/src/escrow.ts:165` |
| S14 | v1 首设备免邀请码自举为创建者——公网部署下第一个匿名请求者可抢占创建者身份（影响有限但属白名单绕过路径） | `server/src/devices.ts:131-172` |
| S15 | app 用 Dart `Random.secure()` 生成 Space Key，偏离 E2EE.md"随机数=randombytes_buf"（安全上仍是 CSPRNG，可接受，但违反文档"唯一库 libsodium"口径） | `app/lib/setup_page.dart:1555,1863` |

### 低（摘选）

- `/auth/verify` 第二个分支**永远不可达**（死代码）：`app.ts:212-217`
- `/sync?after=abc` → NaN → 500（无 400 校验）：`app.ts:246-248`
- `createSpace` 接受任意非空 space_id，无格式/长度上限：`spaces.ts:88-90`
- enroll/join 不校验公钥 base64 格式 → 之后 `/auth/challenge` 抛未分类 500：`auth.ts:31`
- escrow 取包 404（无包）与 401（口令错）可区分 → 可探测某 space 是否设了箱：`escrow.ts:226,236`
- 无 helmet/安全响应头；`/health` 泄漏全局 `messages_count`/`ws_clients`（轻微）
- 头像恒按 `image/png` 下发、无 content-type 校验
- 无 SQL 注入 ✅（全占位符）、附件路径遍历防御到位 ✅、token 回显有字符集白名单 ✅

---

## 2. 接口问题

1. **PROTOCOL.md §4 API 一览严重不全**：缺 `spaces/*`、`/spaces/join*`、`/devices/enroll`、`/devices/name`、`/devices/person-name`、`/invites`、`/avatar` 等 9+ 个实际端点；自称"唯一权威"的文档已名不副实。
2. **`POST /spaces/{id}/key-escrow` 的语义反直觉**：实际是"**取包+验证口令**"端点（不是上传），而 draft 文档写的是 `/key-escrow/verify` 路径——路径和语义都不符。
3. **两套邀请机制并存**：v1 邀请码（`/invites`，20 字符 32 字母表，24h）与 v2 join token（`e1_…`）同时存在；worklog 已标 v1 废弃，但 server 与 CLI 都还挂着，app 测试还在注入。建议收敛后删 v1。
4. **DATABASE.md 与 PROTOCOL.md 互相矛盾**：前者"附件必须先有 message（外键约束）"，后者"两阶段上传：blob 先传、message 可尚不存在"。实际 schema **没有外键**，以 PROTOCOL.md 为准，DATABASE.md 该改。
5. `/spaces/join/preflight` 已实现（app.ts:150）但 draft 文档里只是"可选方案"——文档状态需更新。

---

## 3. 过期文档清单（建议删除/修改）

| 文档 | 状态 | 具体过期点 | 建议 |
|------|------|-----------|------|
| **SETUP.md** | 🔴 整体过期 | 描述 v1 旧模型（config.json 种子、seal 信封为主路径）；§5"撤销设备与密钥轮换"（`key_rotation_required: true` + 重密封分发）**与 2026-09-14"不做轮换"决策直接矛盾**；DEPLOYMENT.md §4 已自认"替代 SETUP.md" | **删除**，或瘦身为指向 ONBOARDING.md 的一页指针 |
| **PROTOCOL_MULTIVERSE.md** | 🟡 状态过期 + 与实现不符 | 头部仍标"[待评审] 草案，尚未实现"，但端点/表**已全部实现**；§4"除 lookup 外均需认证"与实际（全部匿名）矛盾；§5④ `/key-escrow/verify` 路径不存在；字段名与实现不符 | 改状态为"已实现（含与草案的偏差清单）"并修订 |
| **PROTOCOL.md** | 🟡 多处过期 | §1/§11 X-Protocol-Version 硬校验未实现；§7.4"口令验证发生在客户端、Server 无法限速"被 KEY_ESCROW.md 2026-09-14 明确订正（现为服务端 argon2id 校验 + 限速）；§10 限流数字未实现；§4 端点表不全（见上） | 修订 §1/§4/§7.4/§10/§11 |
| **DATABASE.md** | 🟡 多处过期 | §1"Server 端无 spaces/space_members 表"**直接错**（db.ts 有 5 张 v2 新表）；缺 `key_escrow`/`invites`/`meta`/`join_tokens`/`spaces`/`space_members` 表定义；`messages.server_sequence`"全局 UNIQUE"实为 `UNIQUE(space_id, server_sequence)`；缺 `sender_person_id` 列；§6 备份含 config.json（该文件现在不存在且导致备份崩溃，见 S4） | 补 v2 schema，修订 §1/§6 |
| **E2EE.md** | 🟡 部分过期 | §7.3"服务器静态白名单 config.json"过期（白名单=devices 表动态登记）；§10 恢复码备份写成"用户设置页导出"——**App 该入口 2026-09-08 已删**（现仅 CLI 保留）；附录"密钥命名对照"仍提"App 锁 PIN 包"含 Space Key 的表述需与 secure_store 迁移后口径对齐 | 修订 §7.3/§10 |
| **DEPLOYMENT.md** | 🟡 大段过期 | §2.2 整段"生成 config.json 白名单"流程过期（server 不再需要）；§7 故障排查"config.json 缺失 Server 拒绝启动"——**现在缺失照常启动**，该行直接错；§5.2 客户端恢复码"App 导出"入口已删；§9.2 路径 `/Users/Shared/productX/only` 已改为 `/Volumes/repodisk/productX/einz`、VPS 路径按记忆为 `/opt/onlyspace` | 修订 §2/§5.2/§7/§9.2，部署主线改引 ONBOARDING.md |
| **ONBOARDING.md** | 🟢 基本现行，3 处错 | 术语表"space_id 由 server 首启自动生成（db meta）"过期——v2 无全局 space_id，`/health` 也不再返回它（阶段 0 的示例输出过期）；"撤销…触发密钥轮换"过期（不做轮换）；常见坑"邀请码只能由首设备自举的 person 生成"与本文 §3 注释及代码矛盾（**任一 active 设备均可**） | 修订 3 处 |
| **updateServer.md** | 🟡 仓库名过期 | 全文 `git.tic.cc/fon/only`、`cd only`——实际 remote 是 **`git.tic.cc/fon/einz`** | 全局替换 only→einz |
| **KEY_ESCROW.md** | 🟢 基本现行 | §3"现有出处"表指向 `backup.dart derivePassphraseKey()`（已迁到 `passphrase_crypto.dart:37`）；§11"待老板审核的决策点"5 条大多已拍板落地，可改为决策记录；§4.1 端点表未反映 v2 的 POST 取包设计 | 小修 |
| **SECURITY.md** | 🟢 现行 | §2 表"整机备份：CLI backup/restore、**App「导出完整备份」**"——App 入口已删（已 grep 确认 app/lib 无此功能） | 删 App 半句 |
| **README.md** | 🟡 | "静态白名单哑转发器"措辞过期；文档表**漏列** ONBOARDING/CI/SECURITY/PROTOCOL_MULTIVERSE 4 份；KEY_ESCROW 仍标`[待评审]`（文档自身已标`[已实现]`） | 更新文档表 |
| **app/README.md** | 🔴 纯模板 | `flutter create` 默认文案（"A new Flutter project"），零项目信息 | 删除或重写 |
| IOS.md / CI.md / REMOTE.md | 🟢 现行 | IOS.md v3.0 与代码一致（APNs 未接入等描述准确）；CI.md 与 codemagic.yaml/.gitea 工作流一致（小瑕疵：build-apk.yml 头注释还写 act_runner，正文已改 gitea-runner）；REMOTE.md 内容有效但含个人信息（Apple ID/LAN IP/主机名），私有仓库可接受 | 无需动 |

---

## 4. 过期/死代码清单

| 位置 | 内容 | 建议 |
|------|------|------|
| `server/src/app.ts:212-217` | 不可达的重复 `/auth/verify` 路由 | 删除 |
| `server/src/push.ts:43-63` | `sendPushHint` 全仓零调用（Phase 3 占位，IOS.md 有记载） | 保留但加注释，或待接 APNs 时一并清理 |
| `server/src/ws.ts:253`、`backup.ts:172` | `export { randomUUID }` / `export { copyFileSync }` 无意义再导出 | 删除 |
| `server/src/*.ts` 多处 | `_cfg` 占位参数（旧 config 白名单设计残留） | 清理签名 |
| `shared/lib/src/sync/sync_state.dart:11-46` | `SyncState`/`PendingMessage` 类**全仓零调用**（App 用 drift 表、CLI 用 store.dart 各自实现），文件约 2/3 是遗留 | 删除，仅留 `generateSpaceKey`/`buildConfigPayload` |
| `shared/lib/src/crypto/attachment_crypto.dart:67-70` | `generateAttachmentNonce()` 零调用 | 删除 |
| `shared/lib/src/protocol/types.dart:5,8,27` | `kProtocolVersion`/`kMessageTypes`/`Api.spaceLookup` 死常量 | 删除或补实现 |
| `shared/lib/src/protocol/api_client.dart:197-214` + `types.dart:215-227` | `createInvite`/`InviteResult`（v1 邀请路径，被 join token 替代；仅 CLI 与 app 测试还在用） | 加 `@Deprecated`，随 v1 邀请码退役一并删 |
| `app/README.md` | flutter 模板文案 | 删/重写 |
| 根 `package.json` | `"name": "only"`（应为 einz） | 改名 |
| `cli/demo/` 工作区 | 66 个未跟踪文件，含 20+ 个 `(SFConflict …)` 垃圾文件与 sqlite 数据 | git 无危害（已 ignore），本地可清理 |

**app/cli 正面确认**：无 TODO/FIXME 残留；密钥存储已按 2026-09-14 决策迁到 `flutter_secure_storage`（`first_unlock_this_device`，卸载即重置逻辑齐全），SQLite 中无明文 Space Key；app/cli 均真实 import `einz_shared`，无加密实现分叉。

---

## 5. 密钥泄漏检查（✅ 基本干净）

- **git 中无任何真实密钥**：`android.keystore.jks`、`key.properties`、`local_config.{android,ios}.json`、`deployment/.env`、`server/einz_server_config.json`、cli demo 数据全部 gitignore 且未跟踪（`git ls-files` 逐一确认）。
- `deployment/.env.sh`（已入库）只是**密钥生成器脚本**，不含真实密钥——设计正确。
- 已入库的 `cli/config.json` 仅含服务器 URL（`https://einz.tic.cc`），无秘密。
- 两个小提醒：① `REMOTE.md` 含个人信息（Apple ID、局域网 IP、iMac 主机名），私有仓库可接受；② 根 package.json 的 `build-and-install-ios-adhoc-stepbystep` 里硬编码了设备 UDID（非敏感）。
- 注意：工作区（未跟踪）的 `server/data/*.db` 含生产数据副本（SFConflict 残留），注意别误提交/误拷贝。

---

## 6. 建议的处理优先级（若后续动手）

1. **S4 备份崩溃**（一行级修复，影响运维可用性）→ **S1 v2 端点鉴权**（影响安全模型）→ **S3 附件幂等**（影响数据完整性）
2. 文档批处理：删 SETUP.md、app/README.md；修 PROTOCOL.md §7.4/§10、DATABASE.md v2 表、updateServer.md 仓库名、README.md 文档表
3. 死代码批清理（§4 清单，全低风险）
