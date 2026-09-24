# 多空间支持（一条通道加入多个 Space）— 详细设计与计划

状态：`[已评审·部分定稿]`（2026-09-18 起草；方案 A 已获老板原则同意；**2026-09-22 代码核查后修订**：
修正 6 处与现状不符的断言、补入 4 个漏掉的耦合点，⑤⑥⑦ 三项已定，①②③④ 待老板一句话确认）
关联：`docs/PROTOCOL_MULTIVERSE.md`、`aimemo/appWizardMultiverse.md`、`aimemo/productLens.zhcn.md`

> 2026-09-22 修订依据：逐条对照 `server/src`（db/spaces/auth/guard/push）与 `app/lib`
> （app_lock/server_config/chat_page/local_database/media_cache 等）核实原稿断言。

---

## 1. 背景与目标

当前 app 全链路假设「一条通道 = 一个 Space」：

- 凭证托管只有一份（`AppLockPayload`：spaceId/spaceKey/entranceId/token/通道密钥对）
- 启动流程 StartupGate → 直接进唯一 ChatPage，无空间列表概念
- 部分设置（阅后即焚、附件存储等）存 app_state 无空间维度

目标：一条通道可以创建/加入多个 Space，本地并存，用户可切换；非当前空间保底可用。

**非目标**（本轮不做）：

- 多空间同时在线的多条 WS 长连接（方案 B，二期）
- ~~跨服务器空间~~（**2026-09-22 砍掉**：见 §3.4，一期全局单 server）
- 空间级强隔离沙盒（方案 C，已否决）
- 跨通道空间列表云端同步（列表是本机事实，凭 Space Key 包恢复）

## 2. 核心决策：通道身份按「通道 × 空间」生成

### 2.1 问题（2026-09-22 重写：原依据失效，结论不变）

原稿称「`PROTOCOL_MULTIVERSE.md` §8.2 明确：已绑 Space 的通道再创建/加入一律
`DEVICE_ALREADY_BOUND`」。**核实结果：该依据不成立**——

| 原稿断言 | 实际 |
| --- | --- |
| 协议 §8.2 有此约束 | 该文只有 7 节，这句话在 **§7**；且是"要求"而非已实现描述 |
| server 会返回 `DEVICE_ALREADY_BOUND` | server 代码 **grep 零命中**，无此错误码 |
| `entrances` 表 `entrance_id` 主键、归属单个 `space_id` | `entrances` 表**没有 space_id 列**（`server/src/db.ts:19-27`）；entrance 是全局表，空间归属在 `sessions(session_token, entrance_id, space_id)`（`db.ts:80-86`） |
| （隐含）通道会被 server 拒绝二次加入 | `createSpace`/`joinSpace` **每次都新造一行 entrances**（`spaces.ts:164`、`:324`），从不复用 entranceId |

真正的约束只有一个：`entrances.partner_id` 是单列（`db.ts:21`）——**一行 entrance 只能属于一个
partner**，而 partner_id 是 per-space 生成的（`spaces.ts:302-311`）。

反向证据：server 已经预期「一个通道持多空间会话」——

- `guard.ts:84-85`：成员判定走 `entrances.partner_id → space_members(space_id)`，"同一身份多条通道、
  或将来一个通道持多空间会话都不受影响"；
- `auth.ts:91-96`：续期只删 `WHERE entrance_id = ? AND space_id = ?`，即"同一通道在同一 Space
  只保留一个会话"，多空间并列是其既有语义。

**结论不变**（仍采用 per-space 通道身份），但性质要改写：这不是"绕开 server 限制"，而是
**客户端侧成本最低的选择**。备选方案（共用 entranceId）的真实成本比原稿估计的低——只需
entrance↔(space, partner) 映射（`entrances` 加 `space_id` 列，或新表 `entrance_space_members`），
不需要协议大改。仍留作二期备选，本期理由变为「不该为客户端功能动 server」。

### 2.2 决策

**每个 Space 使用独立的通道身份**（entrance 密钥对 + entranceId 在 join/create 时新生成），
客户端本地维护「物理设备 → 多个空间身份」的映射（即 Vault）。server 视角每个 entranceId
仍只属于一个 Space，协议零改动、server 零改动。

推论与代价：

| 项 | 结果 |
| --- | --- |
| server 改动 | 无（create/join/reauth/challenge 全部按现有语义，因为本来就是每次新造 entrance 行） |
| 「我的空间列表」 | 纯本地（Vault 就是列表），server 无需 `GET /my/spaces` |
| 重装恢复 | 与现状一致：凭 join token 重新加入，或口令 escrow 取回 Space Key；Vault 本身不参与恢复 |
| 「本机信息」弹窗 | 每个空间一套（不同 entranceId、**不同公钥**、各自的名称）。弹窗只显示**名称 + 公钥**（`chat_page.dart`，不显示 entranceId）。`[2026-09-22 修订]` ~~Vault 级统一通道名~~ → **承认 per-space**：见下方注 |
| 通道撤销 | 按空间独立撤销，只摘除该空间的身份（现有语义不变） |
| 推送 | `push_tokens` PK 是 `entrance_id`（`db.ts:57-62`），per-space entranceId 天然可用；但只在 ChatPage initState 注册当前空间 → **非当前空间无推送**（一期接受，二期再做多空间注册） |

**注（2026-09-22 定）：通道名是「通道名」，归 per-space，不做 Vault 级统一。**

老板一句话点破：「我的通道名其实是**我的通道名**，只不过从前一通道一通道一空间，所以用了
物理设备名做默认值。」——正是这个历史遗留让 `entrance_name` 看起来像"物理设备的名字"：

- **语义** = 本机**在这个秘境里**的称呼（对方通道列表里看到的就是这个名字）；
- **默认值** = 设备型号（`_autoEntranceName()`，`setup_page.dart`）——一设备一通道一秘境时代够用，
  因为一台机器在一个空间只会有一条记录；
- 于是 `entrance_name` 存在 **per-space profile**（`app_lock.profile.<spaceId>`），
  同一台手机在"家人"秘境可以叫「我的手机」、在"工作"秘境叫「工作机」，这是**合理的**；
- 曾写进 §2.2 的 `[已定]` "Vault 级统一通道名"**从未实现**（`VaultPayload.entranceName`
  三个构造点都没传值，恒为空串），2026-09-22 直接删掉该字段，改为承认 per-space。

代价与消歧手段：同一台设备在不同秘境的**公钥必然不同**（per-space 密钥对），只看公钥会
让人以为"换了条通道" → 用**文案限定**（标题「本机信息（本秘境）」、标签「本秘境里的名称 /
公钥」）+ 弹窗内一行说明来消歧，而不是把名字强行统一。

已知遗留：默认名取型号，若双方用同型号机器，TUI `/entrances` 里会出现两行同名条目
（App 侧目前没有通道列表界面，所以影响面只在 TUI）。是否改默认值 / 向导里允许改名，
待老板定。

精度边界：本地资料是按 **space** 存的（`app_lock.profile.<spaceId>`），不是按 `entrance_id`。
所以严格说本地保存的是"本机**在这个秘境里**的通道名"。只有当**同一个 install 在同一个
秘境里存在多行 entrances**（例如同一台手机重复 join 同一空间）时，"per-space" 与
"per-entry" 才会分叉——这种用法罕见，暂不为它增加一层键。

## 3. 数据设计

### 3.1 本地库：新增 `Spaces` 表（schemaVersion 6 → 7）

```
Spaces
  spaceId          TEXT PRIMARY KEY
  name             TEXT NOT NULL DEFAULT ''   // 显示名（对端名 or 自定义）
  peerName         TEXT NOT NULL DEFAULT ''
  partnerId         TEXT
  entranceId         TEXT NOT NULL
  keyVersion       INTEGER NOT NULL DEFAULT 1
  createdAt        INTEGER NOT NULL
  lastActiveAt     INTEGER NOT NULL DEFAULT 0
  sortOrder        INTEGER NOT NULL DEFAULT 0
```

2026-09-22 相对原稿的两处删减：

- **删 `server` 列**：一期不支持跨服务器空间（见 §3.4），避免动数十处 `ApiClient(effectiveServer)`。
- **删 `spaceKeySealed` 列**：`[已定]` Vault 是 Space Key 的唯一真相来源，表里不留第二份（原评审点①）。

说明：

- `local_messages / sync_state / drafts / peer_receipts` 已有 spaceId 列，天然多空间，不动。
- `local_attachments` **没有 spaceId**（`local_database.dart:44-57`）→ 本次补上（见 §3.5）。
- 迁移 v6→v7：读取现有 `app_lock.plain` / `app_lock.package` 解出的 payload，写入 Spaces 首行。
  迁移逻辑写在 `local_database.dart:119-146`（无独立迁移文件），改完需跑 build_runner 重生成
  `local_database.g.dart`。

### 3.2 凭证层：Vault（单包 → 包集合）

`AppLockPayload` 不改（它本来就是"一个空间的完整凭证"），在外面包一层：

```
VaultPayload = { version: 1, spaces: [AppLockPayload, ...], activeSpaceId: string, entranceName: string }
```

（**2026-09-22 修订**：`VaultPayload.entranceName` 已**删除**——通道名归 per-space profile，见 §2.2 的注。）

- **PIN 模式**：PIN 加密整个 `VaultPayload`（一次解锁全部空间可用），仍存 app_state
  `app_lock.package`，序列化格式兼容——旧格式单 payload 解出后包成单元素 Vault（读时归一，无需迁移旧密文）。
- **跳过 PIN 模式**：明文 `VaultPayload` 存 SecureStore，条目名不变（`app_lock.plain`），读时兼容旧单 payload 格式。
- 新增 API（`AppLockService`）：
  - `loadVault() / saveVault(VaultPayload)`
  - `addSpace(AppLockPayload)`（向导完成新空间后追加并设为 active）
  - `removeSpace(spaceId)`（含清理该空间的 SecureStore/锁包内条目 + Spaces 表行 + 该空间的
    消息/附件/媒体缓存/同步锚点；**不**清其他空间）
  - `setActiveSpace(spaceId)`
  - ~~`clear()` 语义保留 = 全量清除~~ → **2026-09-22 已删除**：M1 把撤销自毁改成
    `removeSpace` 后它没有任何生产调用点，且它是"按已知键清单删"的实现（新增
    app_state 键容易漏）。清除范围从此只有两家：**逐空间** `removeSpace(spaceId)`、
    **全通道** `resetLocalData()`（`data/local_reset.dart`，删 app_state 整表，不会漏键）。
- `AppLockService.clearPackage()/setPin()` 改为操作 Vault 整体；`saveProfile/loadProfile` 改为
  per-space（key 前缀 `app_lock.profile.<spaceId>`，迁移旧 key 到首个空间）。
- attempts/lockout（`app_lock.dart:181`）天然是**整包粒度**，改为 Vault 后 = 一次 PIN 守护全部空间。

### 3.3 敏感数据存放边界 `[已定]`

Space Key 明文仅存在于：解锁后的内存 + SecureStore（跳 PIN 模式）+ PIN 密文包内。
**Spaces 表不存 Space Key**（故不建 `spaceKeySealed` 列）——Vault 是唯一密钥来源，避免两处真相。
Spaces 表定位为「元数据 + 会话外状态」（名字、排序、最近活跃）。

### 3.4 服务器地址：一期全局单 server（2026-09-22 更正）

- `AppLockPayload` **本来就没有 server 字段**：`app_lock.dart:247-249` 注释明写"不含服务器地址"，
  理由是地址每次启动算一次，存进锁包会出现"锁屏页显示的和解锁后实际连的不一致"。
- `ServerSettings` **已不存在**（原稿 §3.4 该条失效）：现为全局只读 `effectiveServer`
  （`server_config.dart:59`），由 `--server` > 编译期覆盖 > 出厂候选域名算出。
- 因此 Spaces 表**不建 `server` 列**，`ApiClient(effectiveServer)` 的数十处调用点**不动**。
  跨服务器空间列为二期（届时再评估 `effectiveServer` 改注入的代价）。

### 3.5 附件与媒体缓存隔离 `[已定 ⑥]`

现状风险：

- `local_attachments` 无 spaceId → 删除空间时无清理边界；
- `AttachmentStore` / `MediaCache` 目录**不按 space 分**（`attachment_store.dart:31`、
  `media_cache.dart:130`），文件名只含 messageId；
- `chat_page.dart:1641` 的 `MediaCache.prune(_repo.allMessageIds())` 只保留**当前空间**的 id
  → 多空间下会**删掉其他空间的媒体缓存**。

**实现注记（M1，2026-09-22）**：`spaceId` 列**加了**，但**没有**把存储/缓存目录按 space
分——改目录要动 `MediaCache.cacheFileName` 的全部调用点，收益不抵成本。隔离改用
「按 messageId 集合定点删除」（`MediaCache.deleteFor` / `AttachmentStore.deleteFor`，
删除空间前先取出该空间的 messageId 集合），效果等价且改动面小得多。

另修掉一个会**误删**的既有 bug：`chat_page.dart` 的媒体缓存孤儿清理原先只传当前空间的
messageId 集合（`_repo.allMessageIds()`），多空间下会把其他空间的缓存判成孤儿删掉 →
改为新增的 `MessageRepository.allMessageIdsAcrossSpaces()`。

### 3.6 per-space 设置迁移

app_state 中无空间维度的键改为 `space.<spaceId>.<key>` 前缀。现有清单（2026-09-22 核实）：

| 键 | 位置 | 是否 per-space |
| --- | --- | --- |
| `burn_after_seconds` | `burn_after_settings.dart:20` | 是 |
| `attachment_storage` | `attachment_storage_settings.dart:27` | 是 |
| `ui_style` | `ui_style_settings.dart:25` | 否（全局外观） |
| `locale` | `locale_settings.dart:24` | 否（全局） |
| `identity.entrance_partner_map` | `message_repository.dart:129` | 全局单表，需补"删除空间时清理该空间条目" |
| `app_lock.*` | `app_lock.dart:46-55` | Vault 化（§3.2） |

v7 迁移：现有值归入当时唯一的空间（迁移后的首个空间）；读取函数改带 spaceId 参数，
默认回退旧 key 一次以防迁移遗漏。

**实现注记（M0.5，2026-09-22）**：`saveProfile/loadProfile` 的 spaceId **必须由调用点
显式传入**，不传就走旧全局键——不要在内部去读 Vault 猜 active 空间。原因：资料读写发生在
ChatPage/向导这些没有 Vault 上下文的地方，读 Vault = 读安全存储，测试环境/平台未支持会抛，
会让"取个名字"连带把整个页面异步链打断（实测 7 个 widget 测试挂死 10 分钟超时）。
M2 改向导/聊天页时把 `widget.payload.spaceId` 传进去即可。

### 3.7 服务端侧通道认知：`install_uid`（2026-09-22 定，M3 落地）

> 术语以 **`docs/GLOSSARY.md`** 为准：物理设备 / **安装**（`install_uid`）/ **登记项**
> （`entrances` 表一行，`entrance_id`）三层。UI 用词服从用户习惯（保留「通道」并加限定词），
> 代码与文档用层名（`install` / `entrance` / `partner`）。曾经的 wire 改名（`device_id` →
> `entrance_id`、`person_id` → `partner_id`）**已于 2026-09-23 全量落地**，见
> **`aimemo/renamePlan.zhcn.md`**。

多空间让一台物理设备在每个空间各有一套**故意互不关联**的身份（entrance_id / 公私钥 /
partner_id / entrance_name）。这在协议上是干净的，但服务端因此**无法知道"这几行其实是
同一台机器"**——运维、审计、将来"整机退役"都需要这个认知。补一个显式标识：

```
entrances.install_uid  TEXT NULL   -- 索引 idx_entrances_uid
```

| 项 | 约定 |
| --- | --- |
| 谁生成 | **客户端**（32 位 hex），随 `POST /spaces`、`POST /spaces/join` 上报 |
| 存量通道 | 不重走入网流程 → 客户端进聊天页时 `POST /entrances/install-uid` 幂等补登（只写本会话那一行） |
| 粒度 | **安装级**：同一台设备的所有空间共用一份；卸载重装 / 「整机清空」清掉即轮换 |
| 存哪（App） | `app_state` 的 `app_lock.install_uid`（`AppLockService.installUid()` 惰性生成）。**不放 SecureStore**：与密钥无关，而在这里读安全存储会让"取个 id"依赖平台支持（同 §3.6 的教训） |
| 存哪（TUI） | `EntranceStore.installUid`（TUI 的粒度是"一个 store = 一条通道"，见 `_deleteLocalData`） |
| **不外泄** | `/space`、`/entrances`、WS 广播**都不带**该字段（两者都是显式列投影）——成员之间互不可见 |
| 权限 | **不参与**任何授权、认证或破坏性操作的范围判断。定位就是"服务端内部认知" |

与之相对，**服务端本来就能靠旁证关联**（IP/时间/push token/同名 entrance_name），那些是
概率性的、会误伤也会漏；显式标识把它变成确定性事实，代价只是一个自报字段。

**反向约定**：需要"整条通道退网"这种客户端能力时，**不要**用 install_uid 当依据——客户端
Vault 里有每个空间的 token，逐个调退役即可（见 §5.5）。

## 4. 会话与实时

### 4.1 ChatPage

构造参数为全入参（`chat_page.dart:66-130`），无需结构改动。变化点：

- 构造来源：StartupGate 从「唯一 payload」变为「Vault.activeSpace 对应 payload」
- 菜单新增「切换空间」入口（多空间时显示）：退出当前会话 → 空间列表
- 补设 PIN / 改口令 / 生成令牌 / 通道管理：均为 per-space 操作，落当前空间 payload（现逻辑不变）
- 内部仍依赖若干全局件，切换时必须显式处理：`WsRealtimeService`（`initState` 内 new，非单例）、
  3s/30s 同步 ticker、30s 对端在线 ticker（`dispose` 已 stop，需确认全部 cancel）、
  `uiStyleNotifier / attachmentStorageNotifier / localeNotifier`（全局，保持全局语义）、
  静态头像缓存（键为 partnerId，天然 per-space）。

### 4.2 切换流程与未读数（2026-09-22 更正）

```
离开空间 A：断开 WsRealtimeService → 停 ticker → 保存同步锚点 → 返回列表
进入空间 B：读 B 的 payload → WsRealtimeService 重连（新 token）→
            启动增量同步（sync_state per-space 已隔离）→ 刷新未读
```

更正两点：

- **未读数不是"本地可算"**：全库 grep `unread`/`未读` 零命中，消息 `status` 只有
  pending/sent/delivered/read/failed，`delivered` 是"已送达"不是"未读"。未读语义要从零建：
  建议在 `sync_state`（主键已是 spaceId）加 `lastReadSequence`，未读数按
  「`server_sequence > lastReadSequence` 且非本人发送」统计（具体列名实现时按
  `local_messages` 现有列敲定）。
- **"保存草稿"无实现**：`drafts` 表从未被使用（仅 `local_reset.dart` 清表），输入框内容未持久化。
  一期不把草稿写进切换流程。

**非当前空间的及时性** `[已定 ②的方向]`：不做周期轮询。

**未读数最终方案（2026-09-22 实现，M3）——否决了本节原先的"本地方案"**：

原先设想是"`sync_state` 加 `lastReadSequence` + 冷启动/切回对每个空间轻量 sync + 本地计数"。
实现时发现两个问题，改走**服务端派生**：

1. **"轻量 sync"并不轻**：`MessageRepository.sync()` 是循环拉到 `hasMore=false`，冷启动等于把
   每个空间**积压的全部消息**拉下来落库（久未打开的空间尤其重）；
2. **读取水位本来就在服务器上**：`receipts(space_id, partner_id) → read_upto_seq`，由客户端在
   "用户真看到最新消息"时才上报（前台 + 页面最上层 + 列表贴底，`chat_page._scheduleReadReport`）。

于是新增 `GET /messages/unread`（会话绑定空间）：服务端数
「`server_sequence > 我的 read_upto_seq` 且发送者不是我」的消息条数——
判定"不是我"**走 partner 维度**（同一身份可能有多台登记项，只比 entrance_id 会把自己的另一台
通道发来的消息算成未读）；没有 receipts 行 = 从没读过 = 全都算未读。

客户端在空间列表页对**每个空间各调一次**（用各空间自己的 token，空间数个位数），显示**数字角标**
（>99 显示 `99+`）。取舍：**离线时列表没有角标**（可接受——列表本来也不可靠）；好处是省掉一次
本地 schema 迁移，且不会为看一个数字而下载别处的全部历史。

**"保存草稿"无实现**：`drafts` 表从未被使用（仅 `local_reset.dart` 清表），输入框内容未持久化。
一期不把草稿写进切换流程。

### 4.3 WS（二期预留）

`WsRealtimeService` 一期保持单实例、随切换重建；二期改为 per-space 实例池或多路复用，
接口上让 ChatPage 不感知（本期不实现，仅确保不反向锁死）。

### 4.4 通道撤销自毁必须逐空间化 🔴（2026-09-22 新增，最高优先级）

**改前** `chat_page.dart:705-710`：通道被撤销 → `AppLockService.clear()`（该 API 已于
2026-09-22 删除，见 §3.2）+ 删全表（attachments / messages / sync_state）+ `MediaCache.deleteAll`
+ `AttachmentStore.clear` + 跳 SetupPage。

**已改（M1，2026-09-22）**：`_onEntranceRevoked` 改为 `removeSpace(widget.spaceId)`，只清该
空间的凭证 + 消息/附件/同步锚点/回执/草稿/Spaces 行/per-space 设置键 + 这些消息的媒体缓存
与留存明文；**其余空间的会话与数据原样保留**。

PIN 模式下的额外处理：重写密文包需要 pin，而撤销发生在聊天页（那里没有 pin，也不该把 pin
留在页面里）→ 先清数据并把该空间记为 pending，下次 `unlockVault(pin)` 时补摘凭证条目。
M2 补：Vault 里还有其他空间时应回 SpaceListPage 而不是 SetupPage（代码里留了 TODO）。

同一类问题：`local_reset.dart`（用户主动"整机清空"）语义保持全清，但 UI 上需与"删除单个空间"明确区分。

## 5. UI 设计

### 5.1 启动流程（StartupGate）

```
解锁（PIN 或跳过）→ loadVault()
  spaces.length == 1 → 直接进 ChatPage（现状不变，无列表闪现）
  spaces.length  > 1 → SpaceListPage（选中即进）
  spaces.length == 0 → SetupPage（向导，现状）
```

### 5.2 空间选择：聊天页内的「选择秘境」弹层（原 SpaceListPage 独立页面已删除）

- 列表项：空间名/对端名、**未读数字角标**（服务端派生，见 §4.2；>99 显示 99+）、最近活跃时间（`Spaces.lastActiveAt`，尚未展示）
- 操作：**只有"点击进入"**。底部按钮「新建/加入空间」→ 第一屏（向导，完成后 `addSpace`
  + 直接进入）
- **本页没有任何破坏性操作**（2026-09-22 定，见 §5.5）：没有长按移除、没有溢出菜单清空。
  为什么"切换空间"必须是一个**独立页面**而不是真正的第一屏：PIN 模式下读 Vault（列空间）
  与写 Vault（切 active）都要 pin，而聊天页刻意不持有 pin → 只能由"手里有 pin 的上下文"
  新构造一个页面（启动门 / 锁屏页 / 本页自己）

**入口追加（2026-09-24，commit `63a190f` / `4942315`）**：除菜单项外，**状态条**
（`chatPageStatusBar`）里对方名字旁加一个实心下拉三角（`Icons.arrow_drop_down`），
整块做成「可按芯片」（底色比胶囊深一档 + 右圆角）→ 一步打开本弹层。动机 = 老板嫌
「☰ → 眼扫菜单 → 点『切换我的秘境』」三步啰嗦（微信是「返回 → 选人」两步）。
复用 `chat_page._openSpacePicker`，零路由/零冷启动/零 PIN 改动；菜单项保留。

**但仅当有 ≥2 个空间时**（`4942315`）：**只有 1 个空间时状态条不给任何切换暗示**
（纯「圆点 + 名字」，无箭头、无底色、不可点）。理由（老板）：单空间往往就是"只想和
某一个人用"，不该暗示这里能切换；真要加空间去汉堡菜单里找。判断依据 = 已加入的空间数
（读内存里已解锁的 `VaultSession`，不触安全存储、不需要 PIN；取不到按单空间处理，最保守）。

**卡片布局（2026-09-24，`571120c`）**：头像半径 18→24、名字 13→15，卡片**正方形**
且边长**按弹层可用宽度反算**（`(宽 − 2×间距)/3` 向下取整）→ 一行**正好 3 张**、
不满 3 张靠左；勾在**左上角**、未读角标在**右上角**（各占一角，都不压名字）。
详见 `worklog.md` 2026-09-24。

**已评估并否掉（2026-09-24）**：把弹层改成**独立页面 + 冷启动多空间先落列表**（让对话页
左上角返回箭头回列表）。否掉的理由：(a) 这是 09-22「冷启动直接进上次的空间」的翻转；
(b)「返回箭头」只有"列表在栈底"时才成立，而对话页一直是 `pushReplacement` 出来的栈底；
(c) 多空间先落列表会**留下后台重锁空窗**——重锁挂在 `ChatPage.didChangeAppLifecycleState`，
列表为栈底时没有 ChatPage 活着，切后台回来不会锁。结论：对 1:1 私密通讯，
"打开即进上次那个人"比"先选空间"值钱。

### 5.5 破坏性入口的两档语义（2026-09-22 定，M3 落地）

多空间把"通道"拆成了"每空间一台虚拟通道"，于是原来那个唯一的「重置本机」（整机级）在不同位置
含义不清：站在某个空间里点它，用户想的是"结束这个空间"，实际却抹掉本机所有空间。定为两档：

| 档 | 语义 | 影响范围 | 入口 | 服务端 |
| --- | --- | --- | --- | --- |
| **空间级** | 销毁本机在这个秘境里的**通道**（并清除本机该空间的聊天记录与密钥） | 只这一个空间；**秘境本身与服务器数据保留，凭新令牌可重新加入** | **唯一呈现给用户的破坏性入口**：聊天页 → 高级 →「销毁本秘境通道」 | 退役这个空间那一行（best-effort；失败时顶部提示，不静默） |
| ~~通道级~~ | ~~清除本通道全部数据~~ | — | **已从 UI 移除**（老板 2026-09-22：太危险，不呈现给用户） | — |

**为什么通道级那档被砍掉**：老板的判断是"移除某个空间其实就是聊天页菜单里的「退出并清除
这个空间」，而清除本机所有数据太危险、不该呈现给用户"。于是：

- 空间列表页的长按「移除」删掉——与聊天页那格是同一件事，留两处只会让人以为是两种操作；
- 通道级「清除本通道全部数据」连同它的弹窗文案一起删掉（`confirmResetDevice` 已删除）；
- 用户的等价路径：**逐个空间退出**（N 个空间就退 N 次，比一键抹掉安全），
  或**卸载重装**（`ensureFreshInstall` 会清掉残留密钥）。
- `data/local_reset.dart` 的 `resetLocalData()` 作为"整机清空"**原语保留**（当前无 UI 调用点，
  将来若做桌面 `--reset` 逃生口会用到）。

**空间级退出失败要说话**：退役（`POST /entrances/retire`）是 best-effort，但失败**不再静默**
——顶部提示「服务端退役未完成，对方通道列表里可能仍留有这条通道」，避免留下 active 幽灵
而用户不知道。

闸门两档共用同一个弹窗，两档都只用**本机独占**的因子：本机通道名 + 本机锁屏码
（刻意不用空间口令——那是共享给伴侣的凭据，不该有权销毁我这条通道，且校验它必须联网，
会让"身份属于一台已经连不上的服务器"这个最常见场景自锁）。

空间级退出后：`removeSpace(spaceId)`（PIN 模式下没有 pin → 挂 pending，下次解锁补摘凭证）
+ 退役该空间那一行；导航上：还有别的空间 → **直接切到下一个**（`VaultPayload.remove` 已把
active 让给剩下的第一个），一个都不剩 → 回向导。

**为什么不靠 install_uid 来"一次退役整条通道"**：通道级那档本来就需要逐空间各一次会话，
而客户端 Vault 里存着每个空间的 token，逐个调即可；install_uid 只是**服务端内部认知**
（见 §3.7），不参与任何破坏性操作的范围或授权判断。

**入口可达性** `[已定 ⑦]` + **实现注记（M2）**：SpaceListPage **不是只在多空间时才存在**——

- 启动路径：**不再有独立的落点页面**——老板 2026-09-22 定，冷启动**直接进上次用的空间**
  （`AppLockService.resolveActivePayload`）；
- 聊天页菜单：**一条「切换空间」**（单空间也在）→ 就地弹「选择秘境」**弹层**：小卡片
  瀑布流（每张卡片 = 一个已加入的空间，写对方名字 + 未读角标 + 当前打勾）+ 底部
  「＋ 新建/加入空间」（先过一次锁屏码，再进第一屏向导）。**不再跳页**。
  **2026-09-22 合并**：原先两条「切换空间 / 空间管理」指向的是**同一个页面**，差别只在
  导航动作——从列表进来的（栈里有列表）用 `pop` 退回，单空间直达的（栈里没有列表）用
  `push` 新推、而 push 需要 pin，所以必须由"手里有 pin 的入口"注入。实现差异泄漏到了
  界面上变成两条，产品上就是一件事 → 合并成一条，内部按"有列表可退就 pop，否则 push"。
  入口需要 Vault/pin 上下文，故由入口（StartupGate / LockPage / SpaceListPage）注入回调，
  ChatPage 自己不读 Vault。

向导收尾改动：`setup_page.dart:1252` 现在完成即 `pushReplacement(ChatPage)` 且**无回调**，
需改为把 payload 回传（或返回上层），由调用方决定 `addSpace` 后是进新空间还是回列表。
默认：新建完成后**直接进入新空间**，该空间 ChatPage 的「切换空间」入口可回列表。

### 5.3 ChatPage 增量

- 菜单加「切换空间」（**合并后单空间也在**；回调由入口注入，见 §5.5 的注）
- 顶栏/标题不变（当前空间语义）
- 「本机信息」弹窗（菜单项「本机名称」）：标题/标签带「本秘境」限定 + 一行说明；
  该名称与公钥只属于当前秘境（§2.2 注）

### 5.4 l10n

新增 key（en/zh）：空间列表标题、切换空间、未读、添加空间等。（2026-09-22 已删：
`spaceListManage`「空间管理」随菜单合并删除；`spaceListDeleteTitle/Message`、
`spaceListResetDevice`、`resetDeviceTitle/Message/Confirm` 随破坏性入口收敛删除。）
改 `lib/l10n/app_en.arb` + `app_zh.arb` 后 `flutter gen-l10n`（生成物已入库）。老板会自行润色，
先给直译占位。

## 6. 兼容与迁移清单

| 项 | 处理 |
| --- | --- |
| 旧锁包（单 payload） | 读时归一为单元素 Vault，不重写密文（下次 setPin/改口令自然升级） |
| SecureStore 旧明文包 | 同上，`loadPlain` 读时归一 |
| `_kProfile` 旧 key | v7 迁移到 `app_lock.profile.<首个空间>` |
| per-space 设置键 | v7 迁移 + `BurnAfterSettings` 等读取函数改带 spaceId 参数（默认回退旧 key 一次） |
| `local_attachments` | v7 加 spaceId 列并按 messageId 回填；目录按 space 分（§3.5） |
| `identity.entrance_partner_map` | 删除空间时清理该空间条目（§3.6） |
| 撤销自毁路径 | 改逐空间 scope（§4.4） |
| 通道名 | Vault 级统一；旧单包无此字段 → 取现有空间已登记的名字，缺省空 |
| golden 测试 | 单空间用户路径 UI 不变，golden 应保持绿；SpaceListPage 不加 golden（政策：不重刷） |
| CLI（einz_cli） | 不在本期范围，仅保证协议无变更不会破坏它 |
| 测试基线 | 原稿"已知 4 个既有失败"**已过期**：2026-09-22 实跑 `flutter test`：main = **138 过 0 失败**；M0.5 分支（+13 条 Vault 用例）= **151 过 0 失败** |

## 7. 测试计划

单元/组件：

1. Vault 序列化：单→多→删除→activeSpace 切换；旧单 payload 归一
2. PIN 加密 Vault：错误 PIN、attempts/locked 行为不变（整体包粒度）
3. v6→v7 迁移：构造 v6 库 + 旧锁包/旧 profile/旧设置键 → 断言迁移结果
4. `removeSpace`：Spaces 行、Vault 条目、per-space 设置键、同步锚点、附件与媒体缓存一并清除；
   **其他空间完好**
5. **撤销自毁逐空间化**：空间 A 被撤销后，空间 B 的消息/附件/缓存/凭证全部存活（§4.4）
6. **附件隔离**：两个空间同 messageId 不串；`MediaCache.prune` 不再删其他空间缓存（§3.5）

页面测试：

7. StartupGate 三分支（0/1/N 空间）
8. SpaceListPage 渲染与交互（fake vault），含设置页入口在单空间时可达（⑦）
9. ChatPage「切换空间」入口存在性（单空间不显示）

不做 golden 重刷（既定政策）。

## 8. 里程碑

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| M0.5 数据底座 ✅ **已完成**（2026-09-22，分支 `feature/multiSpace`） | Spaces 表（v7） + Vault 读写 + 迁移（**未做任何 UI**） | 单测 1–3 绿；旧数据升级后单空间行为不变；全量 `flutter test` 无回归 |
| M1 数据与隔离 ✅ **已完成**（2026-09-22） | per-space 设置键 + 附件 spaceId + 媒体缓存跨空间保留 + **撤销自毁逐空间化** + removeSpace 数据清理 | 单测 4–6 绿；单空间路径无回归（全量 156 过 0 失败） |
| M2 会话切换 ✅ **已完成**（2026-09-22） | StartupGate 分支 + SpaceListPage + 常驻入口 + ChatPage 切换入口 + 向导回调 + WS 随切换重建 | 手动：双空间创建/加入/切换/删除全流程（**老板真机自测**）；页面测试 7–9 绿 |
| M3 收尾 ✅ **已完成**（2026-09-22） | ✅ `install_uid` 服务端认知（§3.7）✅ 破坏性入口两档化（§5.5）✅ 真机自测 3 条 bug（菜单顺序 / 对方名串空间 / 同性别气泡同色）✅ 删除孤儿 `clear()` ✅ 术语（`docs/GLOSSARY.md` + 文案限定）✅ **未读（服务端派生 `GET /messages/unread` + 数字角标，§4.2）** ✅ `projectPlan` 改为索引；⏳ 真机自测未读角标 | 全量 `flutter test` 167→**168 通过 0 失败**；服务端全套 `npm test` 无回归（含新增 unread 3 条） |

二期（另行评审）：多空间并行 WS、非当前空间后台轮询、跨 server 空间、共用 entranceId
（真实成本比原估低，见 §2.1）。

## 9. 决策记录

**已定（2026-09-22）**

| # | 决策 |
| --- | --- |
| ⑤ | PIN 是 **Vault 级**：解锁一次全部空间可用；后台重锁一次锁全部。不做逐空间二次验证（成本高性能差） |
| ⑥ | `local_attachments` **加 spaceId** + 附件/媒体缓存目录按 space 分（v7 迁移） |
| ⑦ | **单空间用户也有"添加空间"入口**（2026-09-22 重述）：入口 = 聊天页菜单「切换空间」弹层底部的「＋ 新建/加入空间」；原来的独立列表页与"只在多空间时启动"都已取消 |
| ① | Spaces 表**不存 Space Key**，Vault 是唯一来源（不建 `spaceKeySealed` 列） |
| — | 一期**不支持跨服务器空间**（Spaces 表无 `server` 列，不动 `ApiClient(effectiveServer)`） |
| — | 通道撤销自毁**必须逐空间化**（§4.4，最高优先级） |
| — | 非当前空间**不周期轮询**，但冷启动/切回时对所有空间做一次轻量 sync |
| — | **破坏性入口分两档**（§5.5）：聊天页只做空间级「销毁本秘境通道」；整机清理只在空间列表页 |
| — | **`install_uid` 只做服务端内部认知**（§3.7），不参与授权/范围判断、绝不进响应体 |
| — | 旧 `AppLockService.clear()` **删除**（无生产调用点 + 清单式删除易漏键）：清除只有 `removeSpace(spaceId)` 与 `resetLocalData()` 两家 |
| — | **破坏性入口只保留空间级**（§5.5）：空间列表页不做任何破坏性操作；整机清空不呈现给用户（等价路径＝逐个退出 / 卸载重装） |
| — | **未读走服务端派生**（§4.2）：新增 `GET /messages/unread`，客户端列表按空间各调一次显示数字角标；**不做**本地 `lastReadSequence` + 逐空间拉历史（离线无角标，可接受） |

**待老板一句话确认（未按建议回绝即按建议执行）**

| # | 问题 | 建议 |
| --- | --- | --- |
| ② | 非当前空间的未读及时性：轻量 sync + 红点够不够？还是要精确计数 + 后台轮询？ | 先红点，精确计数随 `lastReadSequence` 一起上 |
| ③ | 每空间独立通道身份 → 「本机信息」在不同空间是不同条目（只显示名称+公钥，不显示 entranceId） | 接受。~~用 Vault 级统一通道名抹平视觉差异~~ → **2026-09-22 修订为 per-space**（见 §2.2 注）：名字本质是**通道名**，同一台设备在不同秘境叫不同名字是合理的；改用文案限定 + 一行说明来消歧 |
| ④ | ~~删除空间的本地语义：仅本地移除（server 端该通道行残留）~~ **2026-09-22 修订为：本地移除 + 服务端退役该空间那一行**（原方案会留下 active 幽灵通道；有了逐空间退役能力后没理由不顺手清干净） | 已按修订落地 |
