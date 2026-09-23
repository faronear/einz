# 字段/标识符改名计划：`device_*` → `entrance_*`/`install_*`、`person_*` → `partner_*`

状态：**`[执行中]`**（2026-09-23 重新拍板并开工；原 2026-09-22 三期 alias 计划**作废**）
关联：`docs/GLOSSARY.md`（术语分层的唯一权威）、`aimemo/multiSpaceDesign.zhcn.md` §3.7

---

## 0. 为什么推翻旧计划

| | 旧计划（2026-09-22） | 新计划（2026-09-23） |
| --- | --- | --- |
| 前提 | 有存量用户、有老客户端、有老本地数据 | **全新上线**：无老客户端、无历史数据、上线前重置设备 |
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
| D5 | 创建时四个字段：**`creator_*`（创建者/slot0）+ `peer_*`（第二人/slot1）**；成员改名接口 body 用泛称 `partner_name`。选 `peer` 而非 `follower`/`joiner`：加入方不一定是 slot1（`setup_page.dart:1448`「加入者可能是第二人，也可能是第一人的其他设备」），且 `peer` 是仓库既有词 |
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
     其余（确认词 / 本机 PIN / 服务端残留）→ `resetInstall*`。
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
| `app/lib/widgets/reset_device.dart` | `reset_install.dart` |
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
  不做回退读（按"全新上线"口径，老板会重置设备）。

## 7. 本次**没做**、留给下一批的（避免把这批 diff 冲淡）

1. **中文「设备」→「通道」注释/文档清扫**（代码 ~780 处、docs 若干）。**不能全局替换**：
   同一段里「设备」可能指**通道**（登记项）也可能指**本机/物理设备**（UI 保留词），
   必须逐处判断。规则：能换成「通道」且读得通 → 改；指本机/型号/硬件 → 保留。
2. **CLI 命令 `/device`（改名通道）**：是 UI 面，与 App 菜单项「通道名称」不一致。
   要不要改成 `/entrance`（或加别名）由老板定（UI 用词归老板）。
3. **历史快照不动**：`aimemo/architectureReview*.md`、`upgradeToMultiverse.md`、
   `appWizardMultiverse.md`、`escrowArchivedKeys.md`、`voiceCall.zhcn.md`、`worklog.md`
   是**带日期的记录**，里面的旧名保持原样（改了就是篡改历史）；`db.ts` 清理 v1 meta 的
   字面量 `'creator_person_id'` / `'person_name:%'` / `'person_gender:%'` 同理保留。
