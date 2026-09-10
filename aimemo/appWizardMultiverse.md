# App 向导改造清单（Multiverse 多租户加入/创建流程）

> 状态：`[待评审] 改造计划，尚未实现`
>
> 配套：`docs/PROTOCOL_MULTIVERSE.md`（Multiverse 加入授权协议草案）、
> `aimemo/upgradeToMultiverse.md`（总体升级计划 Phase U3）。
>
> 本文是 App（Flutter `setup_page.dart`）改造的具体清单，与协议草案一一对应。

## 1. 目标流程

### 1.1 入口（老板 2026-09-10 确认：路径完整的第一步）

```text
启动
  ↓
① 空间入口页（第一页）
   ├── 新建私密空间（create 路径）
   └── 输入邀请链接 / token 进入现有空间（join 路径）
```

取代现状"连接 Server → /health → 名称为空=create、否则=join → 直接进向导"：
`/health` 只做服务可用性/协议版本/能力探测，不再返回全局 person 名称表、
不再据其推断 create/join。

### 1.2 join 路径（五步，顺序已与老板确认）

```text
① token/邀请链接输入（粘贴或扫码）   ← 新"验证邀请"页改造：链接与纯 token 都认
② 空间确认（显示名称 + 1/2 状态）     ← 新（可合并进 ① 的结果反馈）
③ 身份（名字/性别）                  ← 复用现有身份步骤
④ 口令（escrow 解 Space Key）        ← 复用现有口令验证步骤
⑤ 设置 PIN                          ← 复用现有 PIN 步骤
→ ChatPage
```

### 1.3 create 路径（不变）

```text
① 空间入口 → 新建私密空间
② 身份（名字/性别）
③ 设置口令（escrow 托管，可跳过？——现状：口令非必填但建议）
④ 设置 PIN
→ ChatPage（空间创建完成即进入，可稍后再邀请）
```

## 2. setup_page.dart 改动点清单

| # | 位置/方法 | 改动 |
| - | --------- | ---- |
| 1 | 启动探测 `_probe` / 向导状态机 `_role`/`_step` | 从"探测推断 create/join"改为"入口页显式选择"；`/health` 只验服务可用与协议版本（Multiverse 能力：不支持 `spaces` 的旧 Server 给升级提示） |
| 2 | 新增入口页（`_step == 0`） | 「新建私密空间」→ `_role = create`；「输入邀请链接/token」→ 进入 token 输入页（join 前置，角色此时未定） |
| 3 | `_buildStepInvite`（现"验证邀请码"页）改造 | 输入框语义从"邀请码"改"邀请链接或 token"：粘贴完整链接自动解析出 token；保留扫码图标（复用 `_InviteScannerPage`）；fail-fast 校验（`TOKEN_INVALID/EXPIRED/USED/SPACE_FULL` 在此拦截） |
| 4 | 新增空间确认反馈 | token 校验通过后显示：空间名 + `1/2 等待第二位成员`，让用户确认进对了地方 |
| 5 | `_verifyInviteCode` 改造 | 调 `POST /spaces/join`（分两次：先 preflight 验 token、后提交身份）；错误码 → 中文提示映射 |
| 6 | 身份/口令/PIN 步骤 | 复用现状，不改结构；口令 escrow 按空间隔离语义不变 |
| 7 | create 路径 | 复用现状步骤；创建成功后显示空间链接/二维码（生成首个 join token）供分享，不强制立即邀请 |
| 8 | l10n | 新增：入口页两项（新建空间/输入链接加入）、"粘贴邀请链接或邀请码"、"空间已满/链接已过期/链接已使用/链接无效"、创建后的"分享空间链接"等文案 |

## 3. Server 依赖（第一版）

依赖 `docs/PROTOCOL_MULTIVERSE.md` §4 的端点，App 侧需要的调用序列：

- 入口页：`GET /health`（能力探测，仅版本/能力）
- join ①：`POST /spaces/join` preflight 或 lookup 语义（验 token、不消费）
- join ③：`POST /spaces/join`（事务提交：token 消费 + 身份登记 + 返回 sessionToken）
- join ④：`POST /spaces/{spaceId}/key-escrow` 验证口令取 Space Key 密封包
- create：`POST /spaces`（创建 + 返回首个 join token）+ 分享链接/二维码
- 错误码映射：`TOKEN_INVALID/EXPIRED/USED` → 对应中文提示；`SPACE_FULL` → "空间已满"；`DEVICE_ALREADY_BOUND` → "本设备已绑定其他空间"

## 4. 测试计划

- 向导测试更新：现有 join 用例（先身份后邀请码）改为（token 先行）；create 用例基本不变
- 新增：token 输入页用例（粘贴链接解析、粘贴纯 token、扫码、无效/过期/已用/已满的 fail-fast 提示）
- 新增：入口页用例（选择新建 vs 加入的两条路径）
- Server 端点未实现前：`_FakeApi`/probe 桩先按 Multiverse 语义扩展，保证向导测试先行

## 5. 待定/依赖项

- Server Multiverse 端点实现（Phase U1/U2）是本清单的前置依赖；App 侧可与 CLI e2e 并行开发（协议先定，两端按同一草案实现）
- token TTL = 24h、第一版不做创建者确认（模型 B）——已定（2026-09-10 老板拍板），见 PROTOCOL_MULTIVERSE.md §7
- 深链（universal link）上架后增强，MVP 不做
