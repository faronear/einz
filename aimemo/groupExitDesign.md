# 群组成员退出（自愿退群）设计方案 —— 2026-10-19 评估定稿

> **老板 2026-10-19 三项拍板**（本设计的基础）：
> 1. **duo 不支持退出**——双人秘境想离开只能走既有「销毁本通道」；退群仅对 group 空间开放。
> 2. **同一身份的多设备一并退出**：手机上退群，同身份的平板等设备全部掉线；
>    **其他设备上线时自动销毁本地数据，"就像被撤回一样"**（复用 `entrance.revoked` /
>    `ENTRANCE_REVOKED` 既有口径）。
> 3. **告知形式走顶部通知 + 名单刷新**（与 `member.joined` 同构），不在聊天流落系统消息。
>
> 范围红线：只做**自愿退群**（自己退出），**不做踢人 / 强行退出别人**（老板明确排除）。

## 一、结论

**可实现。** 工作量估算：服务端 ~1 天、shared ~0.5 天、App ~2-3 天、测试 ~1 天，
合计 **3-5 天**。架构无阻断：member 身份锚点、按 member 的 receipts、通道模型、
本地 `removeSpace` 清理链全部现成；缺的只是 **member 级离场**这一层语义。

## 二、现状核实（代码事实）

| 事实 | 位置 | 对退出的意义 |
| --- | --- | --- |
| `space_members.status` 实际只写 `'active'` | `server/src/db.ts:149-165`、`spaces.ts:84` | 可扩展 `'left'` 墓碑状态，无 FK 级联障碍 |
| `isSpaceMember` 要求 `status='active'` | `server/src/guard.ts:74` | 退出后该身份的其他通道会被各端点 403 → **必须主动通知清理，不能留僵尸设备** |
| `retireEntrance`（本人单通道自助退役） | `server/src/entrances.ts:128` | 批量版的现成样板（清 push/sessions/challenges + 断 WS） |
| `notifyRevoked`（发 `entrance.revoked` 帧 + WS 4403 关闭） | `server/src/ws.ts:392` | "其他设备上线自动销毁"的既有机制，退群直接复用 |
| 离线撤销通道发现路径：403 `ENTRANCE_REVOKED` → 客户端自毁 | 2026-09-16 既定口径（projectPlan Phase 4） | 离线设备无需推送，下次请求自然发现 |
| `broadcastMemberJoined` | `server/src/ws.ts:143` | `member.left` 广播直接照抄 |
| `getSpace` 返回**全部**成员行（无 status 过滤） | `server/src/push.ts:102` | 墓碑方案下，已退出成员的历史消息**名字不丢** |
| `countActiveMembers` / `planNotifications` 已按 `status='active'` 过滤 | `spaces.ts:84`、`notifier.ts:170` | 退出者自动不占名额、不再收通知，**零改动** |
| `removeSpace` 删 Vault 条目（含 Space Key）+ 全部本地数据 | `app/lib/data/app_lock.dart:214` | 退出后的本地清理可直接复用 |
| 确认弹窗范式（输入名字 + PIN、按钮退出） | `app/lib/widgets/reset_entrance.dart:115` | 退出确认弹窗照抄 |
| 撤销自毁客户端处理 `_onEntranceRevoked` | `app/lib/chat_page.dart:1326` | 其他设备被退群时的自毁路径，零新代码 |
| 本地 schema v10，无 members 表 | `app/lib/data/local_database.dart:152` | 墓碑方案**不需要本地迁移** |

## 三、退出语义：身份级离场

一次退群 = 该 member 身份退出空间（不是"退出一台设备"）：

1. 本身份名下**全部** entrances 一并注销（批量退役，见 §4.1）；
2. `space_members` 行转**墓碑**（保名字、让 slot，见 §4.1）；
3. 服务端广播 `member.left`；
4. 发起设备本地清数据 + 导航收尾（见 §6.3）。

## 四、服务端设计（~1 天）

### 4.1 新端点 `POST /spaces/{space_id}/leave`

- 鉴权：entrance 会话（`requireSpaceMember`）；限流 auth 桶。
- **幂等**：member 已是 `left` → 直接返回 `{ok:true}`。
- 单事务内：
  1. 定位 `member_id`（会话带）；
  2. **批量退役本身份全部 entrances**：`status='revoked'` + `last_seen=0` /
     `offline_since=now` + 删 `push_tokens` / `sessions` / `challenges`
     （`retireEntrance` entrances.ts:128 的批量版，**无口令**——自助语义，session 即所有权）；
  3. `space_members` → **墓碑**：`status='left'`、`left_at=now`；
     **保留** `member_id` / `display_name` / `gender`（历史消息名字解析依赖，见 §4.3）；
     **slot 让位**：`UPDATE slot = max(slot)+1`（事务内唯一），最小空槽分配逻辑
     （spaces.ts:484）自然回收原 slot；
  4. email 解绑（置 NULL + `purgeEmailIfUnused` 模式，notifier.ts:892）；
     receipts 行删除（PK `(space_id, member_id)`，无下游依赖）；
  5. avatars 文件**保留**（历史消息头像按 member_id 取）。
- 事务后：
  - `broadcastMemberLeft(spaceId, memberId, displayName)`（ws.ts，抄 broadcastMemberJoined ws.ts:143）；
  - 对**在线**的其他本身份连接逐个 `notifyRevoked`（ws.ts:392）→ `entrance.revoked`
    帧 + WS 4403 关闭 → 客户端 `_onEntranceRevoked`（chat_page.dart:1326）自毁。
    **这就是老板要的"就像被撤回一样"。**
  - **离线设备无需推送**：下次任何请求吃 403 `ENTRANCE_REVOKED` → 同一自毁路径
    （2026-09-16 既定口径：客户端只对明确撤销自毁）。

### 4.2 `getSpace` 下发 status

push.ts:102 的成员查询带出 `status`，响应加 `member_status` map。客户端据此三分：

| 用途 | 口径 |
| --- | --- |
| 成员弹层名单（`_showMembersSheet`） | 只列 active |
| 计数 / 邀请判定（`_memberCount` / `_canInvite` / 在线人数） | 只数 active |
| 名字解析（`_senderNameOf`，chat_page.dart:546） | 用**全量**（含墓碑） |

### 4.3 墓碑行为什么必要

消息不带发送者名字，客户端靠 `/space` 成员表解析（chat_page.dart:546
`_senderNameOf`，查不到回落「未命名」）。若退出即删行，**剩余成员看历史消息会显示
「未命名」**。墓碑行 + `getSpace` 全量下发解决，且零本地迁移（本地无 members 表）。

### 4.4 零改动自动正确的既有逻辑

- `countActiveMembers`（spaces.ts:84）→ 退出者不占名额，group 可补人；
- `planNotifications`（notifier.ts:170）→ 退出者不再收邮件通知；
- `isSpaceMember`（guard.ts:74）→ 退出者通道各端点 403（与 §4.1 第 5 条自毁发现路径配套）。

## 五、shared 设计（~0.5 天）

- `ApiClient.leaveSpace(spaceId)` → `POST /spaces/{id}/leave`；
- WS 帧常量 `kWsTypeMemberLeft` + `WsMemberLeftEvent`（member_id, display_name）；
- **PROTOCOL_VERSION 建议不升**（维持 3）：纯增量（新端点 + 新帧），老客户端无退出
  按钮、收到未知帧忽略（上线前确认 `ws_client` 未知帧容错——现有单测已覆盖
  "未知帧不崩"）。若团队政策要求任何 wire 变化都升，则 3→4 与服务端同批上线
  （一次性升级流程见 groupChatDesign.md §升级步骤）。

## 六、App 设计（~2-3 天）

### 6.1 入口（仅 group）

- `_showMembersSheet`（chat_page.dart:3352）底部加「退出群组」destructive 红字项
  （替换原 L3348「无退出入口」注释的位置）；
- duo 弹层 `_showDuoPeerSheet`（chat_page.dart:3536）**不加**（决策 1，见 §八）。

### 6.2 确认弹窗

复用 `confirmLeaveSpace` 范式（reset_entrance.dart:115：输入空间名 + 已设 PIN 验 PIN +
`barrierDismissible:false` + PopScope）。文案三明示：

- 退出后**本机删除该空间全部数据**；
- 历史消息仍留在其他成员的设备上；
- 日后回来需剩余成员重新发邀请（以新身份）。

### 6.3 退出执行链

`leaveSpace` API 成功 → `removeSpace`（app_lock.dart:214，删 Vault 条目含 Space Key +
全部本地数据）→ `SpaceSessions.forget` → 导航收尾（复用 chat_page.dart:4424-4441：
有其他空间则切换、没有则回向导）。**失败不清本地**（顶部报错，留在群里）。

### 6.4 `_onMemberLeft`（别人退出时）

- `_refreshProfileFromServer()`（与 `_onMemberJoined` chat_page.dart:1114 同构）；
- 顶部通知「X 退出了群组」（新 l10n 键，zh/en）；
- 计数口径改按 active 过滤（`_memberSlots` 全量保留供名字解析）。

## 七、多设备处置（决策 2 详述）

授权口径说明：2026-09-16 定过"远程触发擦除的授权信号只有口令干得动（撤销路径），
retire 不打开这条旁路"（entrances.ts:113-114 注释）。本次**为自愿退群场景打开该
旁路**：授权依据 = 发起设备上**同身份会话**（session 即所有权，与 retireEntrance
同档，不需要共享口令）。

安全增量评估：设备 A 被入侵者持会话 → 可擦除同身份设备 B。但入侵者已完全控制 A
（可读全部消息），擦除 B 是拒绝服务而非信息泄露；且用户主动退群本就要这个效果。
此口径变化记入 `docs/SECURITY.md`。

## 八、duo 不开放退出（决策 1）

- duo 空间**没有退群入口**；想"离开"只有既有「销毁本通道」（reset_entrance 全链）
  ——身份仍在册，对方仍可 re-invite（attach token）帮你在新设备回来；
- 产品后果明示：duo 是二人契约，身份一旦入群永不退群（与一期拍板一致）；
  关系结束的产品出路是双方各自销毁通道 / 另建空间；
- `groupChatDesign.md` 的 duo 语义不变（恒 2 人、禁通话）。

## 九、重入（rejoin）

- 退出后回来 = 剩余成员发新 invite token（现成一次性流程）→ 新 member_id、
  拿最小空槽（很可能就是自己让出的那个 slot）；
- 历史可见（一期既定：新成员可见全部历史，加入页明示）；
- 无特殊状态机、无"原身份复活"概念。

## 十、风险与边界

| 风险 | 等级 | 对策 |
| --- | --- | --- |
| **退出 ≠ 作废解密能力**：提前保存 Space Key / 密文者仍可解密历史 | 高（接受） | 二期密钥按成员封装（sender-keys）联动（groupChatDesign.md 早已绑定）；本期产品文案 / FAQ 明示；退出设备本地 Space Key 随 Vault 条目一并删除（app_lock.dart:214） |
| 最后一人退出 → 空间冻结（无人可发邀请） | 中（接受） | 数据留服务端；FAQ 注明；duo 无此问题（不开放退出） |
| 老客户端无退出按钮 + 未知帧 `member.left` | 低 | 上线前确认未知帧容错；必要时升 pv 3→4 |
| slot 让位与并发 join 竞争 | 低 | 事务内 `max(slot)+1`，与最小空槽分配同事务 |
| 墓碑行累积 | 低 | 每行约百字节；churn 场景可接受 |

## 十一、实施任务清单

1. **server**：`leaveSpace`（spaces.ts）+ 路由（app.ts）+ `broadcastMemberLeft`
   （ws.ts）+ `getSpace` status 下发（push.ts）+ 单测（幂等 / 批量退役 / slot 回收 /
   广播 / 最后一人 / 邮件解绑 / 离线设备 403 自毁发现）。
2. **shared**：`leaveSpace` + `kWsTypeMemberLeft` + `WsMemberLeftEvent`。
3. **app**：入口 + 确认弹窗 + 执行链（chat_page.dart / reset_entrance.dart）+
   `_onMemberLeft` + 计数口径 active 化 + l10n（zh/en）+ `_FakeApi` stub。
4. **文档**：`docs/PROTOCOL_MULTIVERSE.md`（端点 + 帧）、`docs/DATABASE.md`
   （status='left' / slot 让位）、`docs/SECURITY.md`（授权口径变化 + 退出密码学
   边界）、FAQ（退出文案）、`aimemo/groupChatDesign.md`（二期候选第 1 条划掉）。
5. **真机自测**：三人群两人退出、退出后补位、退出后重入、多设备（手机退群 →
   平板上线自毁）、最后一人退出、duo 无入口。

## 十二、关联文档

- `aimemo/groupChatDesign.md`（一期设计；"二期候选"第 1 条即本功能）
- `docs/SECURITY.md` §3（无密钥轮换）、§7.2（撤销语义）
