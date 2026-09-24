# 字段/标识符改名计划：`device_*` → `entrance_*`/`install_*`、`person_*` → `partner_*`

状态：**`[执行中]`**（2026-09-23 重新拍板并开工；原 2026-09-22 三期 alias 计划**作废**）
关联：`docs/GLOSSARY.md`（术语分层的唯一权威）、`aimemo/multiSpaceDesign.zhcn.md` §3.7

---

## 0. 为什么推翻旧计划

| | 旧计划（2026-09-22） | 新计划（2026-09-23） |
| --- | --- | --- |
| 前提 | 有存量用户、有老客户端、有老本地数据 | **全新上线**：无老客户端、无历史数据、上线前整机清空 |
| 目标名 | `entry_id`（早于术语改「通道」） | **`entrance_id`**（与已落地的 `entrance` 一致） |
| 机制 | 三期 alias：遥测列 + 版本双接受 + 双名映射文件 + 跨端发布 + 读旧回退 | **一次性机械替换**，一次提交 |
| 风险 | 🔴 锁包旧密文、drift 旧列、TUI store 旧键回退 | 归零（直接按新语义写新格式，本地库/商店重建） |
| 待删资产 | `last_proto_version`、`protocolAliases.ts`、`assertProtocolVersion` 双接受 | 全部不需要 |

**关键更正**：旧计划的 `entry_id` 已过期——2026-09-23 界面术语定为「通道 / **entrance**」，
代码里 `entrance` 已成既成事实（`maxEntrancesPerSpace`、`advancedDestroyEntrance`、
`entrance_limit.test.ts`）。改叫 `entry_id` 反而会造出第三个词。

## 1. 命名口径（2026-09-23 老板拍板）

| # | 决定 |
| --- | --- |
| D1 | `person_id` → **`partner_id`**（partner = 秘境内的一位身份，两个 slot 都是 partner）；`person` 一词**腾给真人**（将来若做全局 person 身份） |
| D2 | `partner_slot` → **`slot`**（它本就是泛型槽位列，存 0/1，两个槽位都用；旧名会让人误以为专指 slot1） |
| D3 | device 家族**全量改**，**连 HTTP 路径也改**（`/devices/*` → `/entrances/*`、成员改名 → `/partners/name`） |
| D4 | `device_uid` → **`install_uid`**（GLOSSARY 的「安装」层；改后代码里 device 一词只剩 UI 的「本机 / device」） |
| D5 | 创建时四个字段：**`creator_*`（创建者/slot0）+ `peer_*`（第二人/slot1）**；成员改名接口 body 用泛称 `partner_name`。选 `peer` 而非 `follower`/`joiner`：加入方不一定是 slot1（`setup_page.dart:1448`「加入者可能是第二人，也可能是第一人的其他通道」），且 `peer` 是仓库既有词 |
| D6 | 审计 kind **一起改**：`device.{rename,revoke,retire,revoked}` → `entrance.*`，`person.rename` → `partner.rename` |

## 2. 命名分层总表

一句话：**一台机器 = 一个 `install`；一个安装 × 一个秘境 = 一个 `entrance` = 一条通道；
秘境里的一位 = 一个 `partner`。**

| 概念 | 旧 | 新 |
| --- | --- | --- |
| 登记项 id（表行） | `device_id` / `deviceId` | `entrance_id` / `entranceId` |
| 登记项显示名 | `device_name` / `deviceName` | `entrance_name` / `entranceName` |
| 安装 id | `device_uid` / `deviceUid` | `install_uid` / `installUid` |
| 表 | `devices` | `entrances` |
| 审计表 | `device_activity` | `entrance_activity` |
| 身份 id | `person_id` / `personId` | `partner_id` / `partnerId` |
| 身份显示名（泛称） | `person_name` / `personName` | `partner_name` / `partnerName` |
| 创建者的名字/性别 | `person_name` / `gender` | `creator_name` / `creator_gender` |
| 第二人的名字/性别 | `partner_name` / `partner_gender` | `peer_name` / `peer_gender` |
| 槽位（0/1） | `partner_slot` / `partnerSlot` | `slot` |
| 消息发送者 | `sender_device_id` / `sender_person_id` | `sender_entrance_id` / `sender_partner_id` |
| 身份名单 map | `person_names` / `person_genders` / `person_slots` | `partner_names` / `partner_genders` / `partner_slots` |
| 名字策略 | `person_name_policy` / `PersonNameViolation` | `partner_name_policy` / `PartnerNameViolation` |
| 通道名策略 | `device_name_policy` / `DeviceNameViolation` | `entrance_name_policy` / `EntranceNameViolation` |

**HTTP 路径**（D3）：

| 旧 | 新 |
| --- | --- |
| `POST /devices` 系列（uid/name/list/revoke/retire） | `POST /entrances/*`（uid → **`/entrances/install-uid`**） |
| `POST /devices/person-name` | **`POST /partners/name`**（它改的是"我"这位成员的名字，与通道无关） |
| `POST /spaces`、`/spaces/join` 等 | 不变 |

**不动的**：`space_id`、`space_members`、`key_escrow`、`join_tokens`、`receipts`、
`messages` 表名；`/spaces/*`、`/auth/*`、`/messages/*` 路径；UI 文案（界面词已单独定过）。

## 3. 必须小心的边界（自动化替换的红线）

1. **平台同名 API，绝不能改**：`device_info_plus`、`DeviceInfoPlugin`、`.deviceInfo`、
   `DeviceFileSource`（video_player）、`MediaQuery.devicePixelRatioOf`、
   `KeychainAccessibility.first_unlock_this_device`（Apple 常量）、
   `width=device-width`（HTML viewport）。
2. **语义分裂，不能全局替换**：
   - `person_name` / `personName` 有两个去向：**创建者**（`POST /spaces` / 向导里的"我的名字"）
     → `creator_*`；**泛称成员名**（`/partners/name`、ws、store、profile）→ `partner_*`。
   - `partner_name` / `partnerName` / `partner_gender` / `partnerGender` 是**第二人** → `peer_*`。
     顺序上必须先做这步，再做 `person_name` → `partner_name`，否则会互相踩。
   - `resetDevice*`：三个 `resetDeviceName*`（比对的其实是**通道名**）→ `resetEntranceName*`；
     其余（确认词 / 本机 PIN / 服务端残留）→ `resetEntrance*`（二次更正：动作是**按通道**的，不是安装级）。
3. **历史字面量保留**：`db.ts` 清理 v1 meta 的字面量 `'creator_person_id'`、`'person_name:%'`、
   `'person_gender:%'`（引用的是老数据里的键名，改了就没意义）；`cli/bin/einz_tui.dart`
   注释里的 v1 `/health person_names` 同理。
4. **UI 文案不变**：`app_*.arb` 的 **value** 一律不动，只改 **key**（`chatPageDevice*`
   → `chatPageEntrance*` 等）。

## 4. 文件/目录改名

| 旧 | 新 |
| --- | --- |
| `server/src/devices.ts` | `entrances.ts` |
| `server/src/deviceName.ts` | `entranceName.ts` |
| `server/src/deviceUid.ts` | `installUid.ts` |
| `server/src/personName.ts` | `partnerName.ts` |
| `shared/lib/src/policy/person_name_policy.dart` | `partner_name_policy.dart` |
| `app/lib/widgets/reset_device.dart` | `reset_entrance.dart`（2026-09-23 二次更正：该文件当前只有**空间级**「销毁本秘境通道」流程，不是安装级）|
| `server/test/device_name.test.ts` | `entrance_name.test.ts` |
| `server/test/device_retire.test.ts` | `entrance_retire.test.ts` |
| `server/test/device_uid.test.ts` | `install_uid.test.ts` |
| `server/test/person_name.test.ts` | `partner_name.test.ts` |

## 5. 执行步骤

- [x] 定 D1–D6（2026-09-23）
- [x] 改写 `docs/GLOSSARY.md`（`entry`→`entrance`、字段对照、wire 改名段改为"已改"）
- [x] server：库表/列名 + 源码标识符 + 路由 + 审计 kind + 测试
- [x] shared：协议类型 / api_client / ws_client / policy
- [x] app：字段 + l10n key（values 不动）+ drift 列（v8 `renameColumn`）+ store/profile 键
- [x] cli：store / TUI / demo JSON / 探针
- [x] docs（PROTOCOL/DATABASE/E2EE/SECURITY/KEY_ESCROW/DEPLOYMENT/ONBOARDING/IOS/updateServer）
- [x] 验证：`server npm run build + test`（28 项全过）、三包 `flutter analyze` 无 issue、残留 grep
- [x] 提交

## 6. 验证口径

- 残留扫描：三个家族只剩 §3 的保留项与 UI value（`device`=本机、wordlist、Apple/平台 API、
  `device-width`、goldens 文件名）。
- `server`：`npm run build` + `npm test` 全绿。
- `app`：`flutter analyze` / `flutter gen-l10n` 无 issue（goldens 不跑、UI 由老板自测）。
- 本地库：drift 升到 **v8**，用 `ALTER TABLE RENAME COLUMN` 保数据；锁包/store 的 JSON 键
  不做回退读（按"全新上线"口径，老板会整机清空）。

## 7. 中文「设备」→「通道」清扫（2026-09-23 **第二批**，已完成）

老板 2026-09-23 拍板：① 单独一批做、逐处核对；② CLI `/device` → `/entrance`；③ 历史快照保持原样。

**规则**（逐处判断，**不**全局替换）：
- 指**登记项** → 「通道」（量词用「条」：一条通道，不是一台通道）；
- 指**本机 / 物理机器 / 型号** → 保留「设备」（GLOSSARY 许可 UI 这么说）；
- 指**安装** → 「本机」（如「本机锁屏码」「两台设备需要连同一台服务器」）；
  注意：**按通道的重置动作叫「重置本通道」**，不要写「重置本机」——它只清一个通道/空间；
  「整机清空」是另一个（当前无 UI 入口）的原语。
- 平台实现语境 → 「平台通道」保留。

**范围**：server/src + server/test、shared/lib + shared/test、app/lib + app/test、
cli/bin + cli/lib + cli/test、`docs/*.md`（技术文档全量）、`README.md`、
`aimemo/{multiSpaceDesign,productLens,renamePlan,projectPlan}`。
**UI 文案只动了 1 条**：`chatPageEntranceScopeHint` zh「通道是**本机**连接到秘境的安全线路…」
（原为"设备"，与同句后面的「本机」不一致；en 同步为 `this device`）。
CLI 命令 `/device` → `/entrance`（help、usage、`case`、policy 注释同步）。

**注意**（这批的坑）：cli 探针里的**期望字符串**（`设备列表`/`输入要撤销的设备序号`/
`本设备已被撤销`/`目标设备毫发无损`）必须跟着 TUI 一起改，否则探针静默失效；
app 测试里那条 UI 断言也同步改了。**探针未实跑**（需真 server + pty），只是把期望串对齐。

## 8. 历史快照不动（老板 2026-09-23 同意）

`aimemo/architectureReview*.md`、`upgradeToMultiverse.md`、`appWizardMultiverse.md`、
`escrowArchivedKeys.md`、`voiceCall.zhcn.md`、`worklog.md` 是**带日期的记录**，旧名保持原样
（改了就是篡改历史）；`db.ts` 清理 v1 meta 的字面量 `'creator_person_id'` /
`'person_name:%'` / `'person_gender:%'` 同理保留；goldens 文件名 `..._device.png` 也不动。

## 9. 续改：`partner` → `member`（2026-09-24，已执行）

老板拍板：新版本尚未上线（计划 2026-09-25 上线），为将来"一个秘境可能不止两人"留弹性，
把指代「秘境内一个身份」的 **`partner` 全线改为中性的 `member`**。**界面文案不改**——
中文仍「伴侣」、英文 UI 仍 `partner`（凸显情侣私密空间气质），代码层与界面词中英不同名，
同「通道 / entrance」先例。

**决策**：方案 A（只改代码层）；不碰 `peer`（第二人）/`creator`（创建者）/`entrance` /
`install` / `slot` / `space_members` 表名。

### 9.1 映射（现名）

| 概念 | 09-23 名 | 09-24 现名 |
| --- | --- | --- |
| 身份 id | `partner_id` / `partnerId` | **`member_id` / `memberId`** |
| 身份显示名 | `partner_name` / `partnerName` | **`member_name` / `memberName`** |
| 消息发送者身份 | `sender_partner_id` | **`sender_member_id`** |
| 身份名单/性别/槽位 map | `partner_names` / `partner_genders` / `partner_slots` | **`member_names` / `member_genders` / `member_slots`** |
| 创建响应 | `creatorPartnerId` | **`creatorMemberId`** |
| 本机通道→身份映射键 | `identity.entrance_partner_map` | **`identity.entrance_member_map`** |
| 成员改名路由 | `POST /partners/name`（body `partner_name`） | **`POST /members/name`**（body `member_name`） |
| 审计 kind | `partner.rename` | **`member.rename`** |
| 名字策略 | `partner_name_policy` / `PartnerNameViolation` / `checkPartnerNamePolicy` | **`member_name_policy` / `MemberNameViolation` / `checkMemberNamePolicy`** |
| 服务端文件 | `server/src/partnerName.ts`、`test/partner_name.test.ts` | **`memberName.ts`、`test/member_name.test.ts`** |

### 9.2 复用 09-23 的处置结论（因同一"未上线、无数据"前提）

- **wire**：合入**同一个尚未发布的 v2 窗口**（`PROTOCOL_VERSION` 仍为 `2`，不另起 v3）。
- **服务端 DB**：无生产库 → 只改建表语句，**零迁移**。
- **客户端本地库**：drift `schemaVersion` **8→9**，`from==8` 时 `renameColumn`
  `partner_id`→`member_id`；`from<8` 的旧库在 v8 分支直接落到最终列名（不两跳）。
- **TUI store / App profile JSON**：键名随改；按"全新上线、整机清空"口径**不做旧键回退读**。
- **历史快照**：`aimemo/architectureReview*`、`upgradeToMultiverse`、`renameReview20260923`、
  `worklog` 既有条目**一字不动**；`db.ts` 的 v1 meta 字面量同理保留。

### 9.3 验证

- 服务端 `npm run build` + 全套 `npm test` 全绿（0 fail）；
- `app` / `shared` / `cli` 三包 `flutter analyze` 无 issue；`shared`(52) / `cli`(21) dart 测试全过；
  app 抽测与本次契约直接相关的 4 个测试文件（message_repository / app_lock / vault /
  multi_space_pages）61 例全过（goldens 按惯例不跑）。
- 残留 grep：code/test/demo/docs 内 `partner` 归零；仅剩 **l10n UI 文案值**（有意保留）与
  历史快照。
- **删除死探针**：`cli/test/partner_preset_check.py`（改名后 `member_preset_check.py`）
  已彻底失效——① `ROOT` 硬编码 `/Users/Shared/productX/einz`（本机真实路径不是它）；
  ② 期望的 TUI 串（`请输入您的名字`/`第二用户的名字`/`请设置内容安全口令`/`● 在线`）在当前
  TUI 里 0 命中（现为 `❓ 我的名字`/`❓ 伴侣的名字`/`❓ 设置共享口令`）；③ 读
  `/health['member_names']`，而 `/health` 早已按"免鉴权端点不吐业务量"原则只返回
  status/协议版本/能力/uptime；④ 依赖的 `/entrances/enroll` 端点早已删除。且它唯一的
  独有断言（"预置名 pre-join 可观测"）**已无法经公开 API 观察**（`/space` 的名称表按
  `member_id IS NOT NULL` 过滤，预置行加入前无 member_id）——保留只会误导，故删除。
  其覆盖（create 流程问「伴侣的名字」、预置名落 `space_members` slot=1）已分别由
  `presence_check.py` 等探针与 `server/test/smoke.test.ts` 覆盖。

