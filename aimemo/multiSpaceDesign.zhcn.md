# 多空间支持（一台设备加入多个 Space）— 详细设计与计划

状态：[待评审]（2026-09-18 起草，方案 A 已获老板原则同意，本文档供进一步评审）
关联：`docs/PROTOCOL_MULTIVERSE.md`、`aimemo/appWizardMultiverse.md`、`aimemo/productLens.zhcn.md`

---

## 1. 背景与目标

当前 app 全链路假设「一台设备 = 一个 Space」：

- 凭证托管只有一份（`AppLockPayload`：server/spaceId/spaceKey/deviceId/token/设备密钥对）
- 启动流程 StartupGate → 直接进唯一 ChatPage，无空间列表概念
- 部分设置（阅后即焚、附件存储等）存 app_state 无空间维度

目标：一台设备可以创建/加入多个 Space，本地并存，用户可切换；非当前空间保底可用（轮询同步），实时推送二期再做。

**非目标**（本轮不做）：
- 多空间同时在线的多条 WS 长连接（方案 B，二期）
- 空间级强隔离沙盒（方案 C，已否决）
- 跨设备空间列表云端同步（列表是本机事实，凭 Space Key 包恢复）

## 2. 核心决策：设备身份按「设备 × 空间」生成

### 2.1 问题

`PROTOCOL_MULTIVERSE.md` §8.2 明确：已绑 Space 的设备再创建/加入一律 `DEVICE_ALREADY_BOUND`（server devices 表 device_id 为主键、归属单个 space_id）。

### 2.2 决策

**每个 Space 使用独立的设备身份**（device 密钥对 + deviceId 在 join/create 时新生成），客户端本地维护「物理设备 → 多个空间身份」的映射（即 Vault）。server 视角每个 deviceId 仍只属于一个 Space，协议零改动。

推论与代价：

| 项 | 结果 |
|---|---|
| server 改动 | 无（create/join/reauth/challenge 全部按现有语义） |
| 「我的空间列表」 | 纯本地（Vault 就是列表），server 无需 `GET /my/spaces` |
| 重装恢复 | 与现状一致：凭 join token 重新加入，或口令 escrow 取回 Space Key；Vault 本身不参与恢复 |
| 「我的设备」弹窗 | 每个空间显示各自的设备条目（不同 deviceId、不同公钥）——需要向老板确认可接受 |
| 设备撤销 | 按空间独立撤销，只摘除该空间的身份（现有语义不变） |

备选（不采用）：server 增加「设备→person 跨空间映射」，让一台物理设备共用一个 deviceId。需要协议变更 + 迁移，且「我的设备」列表语义反而变复杂。评审时可再议。

## 3. 数据设计

### 3.1 本地库：新增 `Spaces` 表（schemaVersion 6 → 7）

```
Spaces
  spaceId          TEXT PRIMARY KEY
  server           TEXT NOT NULL          // per-space server，支持跨服务器空间
  name             TEXT NOT NULL DEFAULT ''   // 显示名（对端名 or 自定义）
  peerName         TEXT NOT NULL DEFAULT ''
  personId         TEXT
  deviceId         TEXT NOT NULL
  keyVersion       INTEGER NOT NULL DEFAULT 1
  spaceKeySealed   TEXT NOT NULL          // 见 3.3，落库形态由 Vault 决定
  createdAt        INTEGER NOT NULL
  lastActiveAt     INTEGER NOT NULL DEFAULT 0
  sortOrder        INTEGER NOT NULL DEFAULT 0
```

说明：
- `local_messages / sync_state / drafts / peer_receipts` 已有 spaceId 列，天然多空间，不动。
- 迁移 v6→v7：读取现有 `app_lock.plain` / `app_lock.package` 解出的 payload，写入 Spaces 首行；app_state 里的锁相关键语义变化见 3.2。

### 3.2 凭证层：Vault（单包 → 包集合）

`AppLockPayload` 不改（它本来就是"一个空间的完整凭证"），在外面包一层：

```
VaultPayload = { version: 1, spaces: [AppLockPayload, ...], activeSpaceId: string }
```

- **PIN 模式**：PIN 加密整个 `VaultPayload`（一次解锁全部空间可用），仍存 app_state `app_lock.package`，序列化格式兼容——旧格式单 payload 解出后包成单元素 Vault（读时归一，无需迁移旧密文）。
- **跳过 PIN 模式**：明文 `VaultPayload` 存 SecureStore，条目名不变（`app_lock.plain`），读时兼容旧单 payload 格式。
- 新增 API（`AppLockService`）：
  - `loadVault() / saveVault(VaultPayload)`
  - `addSpace(AppLockPayload)`（向导完成新空间后追加并设为 active）
  - `removeSpace(spaceId)`（含清理该空间的 SecureStore/锁包内条目 + Spaces 表行；**不**清其他空间）
  - `setActiveSpace(spaceId)`
  - `clear()` 语义保留 = 全量清除（仅「卸载即重置」/整库清理场景用）
- `AppLockService.clearPackage()/setPin()` 改为操作 Vault 整体；`saveProfile/loadProfile` 改为 per-space（key 前缀 `app_lock.profile.<spaceId>`，迁移旧 key 到首个空间）。

### 3.3 敏感数据存放边界（保持现状原则）

- Space Key 明文：仅存在于解锁后的内存 + SecureStore（跳 PIN 模式）+ PIN 密文包内。Spaces 表**不存** Space Key 明文（`spaceKeySealed` 冗余列可去掉，Vault 是唯一密钥来源——避免两处真相）。评审点①。
- 因此 Spaces 表定位为「**元数据 + 会话外状态**」（名字、排序、最近活跃），密钥仍只在 Vault。

### 3.4 per-space 设置迁移

app_state 中无空间维度的键改为 `space.<spaceId>.<key>` 前缀：

- `BurnAfterSettings`、`AttachmentStorageSettings`、聊天页内保存的 UI 状态等逐个盘点（实现时列出完整清单）
- v7 迁移：现有值归入当时唯一的空间（即迁移后的首个空间）

`ServerSettings` 保留全局默认值语义（新空间向导的预填地址），Spaces.server 为每空间实际地址。

## 4. 会话与实时

### 4.1 ChatPage

构造参数已全靠入参，无需结构改动。变化点：

- 构造来源：StartupGate 从「唯一 payload」变为「Vault.activeSpace 对应 payload」
- 菜单新增「切换空间」入口（多空间时显示）：退出当前会话 → 空间列表
- 补设 PIN / 改口令 / 邀请 / 设备管理：均为 per-space 操作，落当前空间 payload（现逻辑不变）

### 4.2 切换流程（一期）

```
离开空间 A：断开 WsRealtimeService → 保存草稿/同步锚点（已有）→ 返回列表
进入空间 B：读 B 的 payload → WsRealtimeService 重连（新 token）→
            启动增量同步（sync_state per-space 已隔离）→ 刷新未读
```

- 同步逻辑以 spaceId 为键已隔离，切换后靠 `lastServer_sequence` 增量拉齐，无额外协议工作。
- 未读数：本地可算（`messages where spaceId=? and status delivered/received and deletedAt is null`），一期在列表页显示；实时刷新仅当前空间，其他空间在切回时更新。评审点②：一期非当前空间要不要后台周期轮询（省电 vs 及时）？默认**不轮询**。

### 4.3 WS（二期预留）

`WsRealtimeService` 一期保持单实例、随切换重建；二期改为 per-space 实例池或多路复用，接口上让 ChatPage 不感知（本期不实现，仅确保不反向锁死）。

## 5. UI 设计

### 5.1 启动流程（StartupGate）

```
解锁（PIN 或跳过）→ loadVault()
  spaces.length == 1 → 直接进 ChatPage（现状不变，无列表闪现）
  spaces.length  > 1 → SpaceListPage（选中即进）
  spaces.length == 0 → SetupPage（向导，现状）
```

### 5.2 SpaceListPage（新增）

- 列表项：空间名/对端名、未读数、最近活跃时间
- 操作：点击进入；长按或侧滑 → 删除该空间（本地移除身份，二次确认，提示「不影响服务器与其他设备」）
- 「新建/加入空间」按钮 → SetupPage（复用现有向导，完成后 `addSpace` + 直接进入）

### 5.3 ChatPage 增量

- 菜单加「切换空间」（仅多空间时）
- 顶栏/标题不变（当前空间语义）
- 「我的设备」弹窗文案标注这是当前空间的设备身份（若评审点③确认需要）

### 5.4 l10n

新增 key（en/zh）：空间列表标题、切换空间、删除空间确认、未读数、新建/加入空间入口等。老板会自行润色，先给直译占位。

## 6. 兼容与迁移清单

| 项 | 处理 |
|---|---|
| 旧锁包（单 payload） | 读时归一为单元素 Vault，不重写密文（下次 setPin/改口令自然升级） |
| SecureStore 旧明文包 | 同上，`loadPlain` 读时归一 |
| `_kProfile` 旧 key | v7 迁移到 `app_lock.profile.<首个空间>` |
| per-space 设置键 | v7 迁移 + `BurnAfterSettings` 等读取函数改带 spaceId 参数（默认回退旧 key 一次以防迁移遗漏） |
| golden 测试 | 单空间用户路径 UI 不变，golden 应保持绿；SpaceListPage 不加 golden（政策：不重刷） |
| CLI（einz_cli） | 不在本期范围，仅保证协议无变更不会破坏它 |

## 7. 测试计划

单元/组件：
1. Vault 序列化：单→多→删除→activeSpace 切换；旧单 payload 归一
2. PIN 加密 Vault：错误 PIN、 attempts/locked 行为不变（整体包粒度）
3. v6→v7 迁移：构造 v6 库 + 旧锁包/旧 profile/旧设置键 → 断言迁移结果
4. removeSpace：Spaces 行、Vault 条目、per-space 设置键、同步锚点一并清除；其他空间完好
5. 未读数计算：混合 delivered/read/deleted 状态

页面测试：
6. StartupGate 三分支（0/1/N 空间）
7. SpaceListPage 渲染与交互（fake vault）
8. ChatPage「切换空间」入口存在性（单空间不显示）

不做 golden 重刷（既定政策）。

## 8. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M1 数据与凭证 | Spaces 表 + Vault + 迁移 + per-space 设置键 | 单测 1–5 绿；旧数据升级后单空间行为不变 |
| M2 会话切换 | StartupGate 分支 + SpaceListPage + ChatPage 切换入口 + WS 随切换重建 | 手动：双空间创建/加入/切换/删除全流程；单测 6–8 绿 |
| M3 收尾 | 未读数、l10n、`productLens/projectPlan` 更新、（若需）「我的设备」文案调整 | 全量 `flutter test`（已知 4 个既有失败除外）；单空间路径 golden 保持绿 |

二期（另行评审）：多空间并行 WS、后台轮询未读、跨 server 空间的健康探测 UI。

## 9. 待老板评审确认的点

1. ** Spaces 表不存 Space Key**（Vault 唯一密钥来源）——同意？
2. **一期非当前空间不轮询**，切回才同步——未读及时性可接受？
3. **每空间独立设备身份**导致「我的设备」弹窗在不同空间显示不同 deviceId/公钥——可接受？还是希望显示统一的"物理设备名"（本地把 deviceId 映射到设备名展示，server 不变）？
4. 空间删除的本地语义：仅本地移除身份（server 端该设备仍在 devices 表）——是否需要顺带调撤销设备接口（需口令）？默认**仅本地移除，不做 server 撤销**。
