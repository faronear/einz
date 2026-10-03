# 多人群聊（一期）设计方案 —— 2026-10-03 评估

老板已拍板的方向性决策：

| 决策点           | 结论                                                      |
| ---------------- | --------------------------------------------------------- |
| 群规模上限       | 3-4 人小群（服务端可设上限常量，UI 不做通用人海列表）     |
| 新成员历史可见性 | 可见全部历史（与现有 Space Key 模型一致，产品上明示即可） |
| 群语音通话       | 一期禁用，call.\* 信令仅限两人私聊空间                    |
| 成员管理权限     | 全员平等：所有人可邀请；**不做踢人**                      |
| 二人私密空间(duo) | duo 空间**禁止加入第三人**，情侣私密体验（2026-10-03 拍板）  |
| 邀请 token 策略  | 维持**一次性**（现状）：每个新成员单独生成一条邀请链接    |
| 成员退出         | **一期不考虑退出**——入群即永不退群（2026-10-03 拍板）     |
| 老客户端兼容     | **不做**——现仅少量测试用户，一次性全员升级，协议无双接受（2026-10-03 拍板） |

## 现状结论（已核实代码）

服务端消息层天然接近多人模型，改动集中在上层：

- `space_members` 按 (space_id, slot) 组织，member_id 是身份锚点，一人多 entrance 共享
- messages 按 (space_id, server_sequence) 编号；WS 广播带 member_id 供客户端二次过滤
- receipts 按 (space, member) 记水位，天然支持 N 人
- E2EE 为单一对称 Space Key，N 人共享即用，**密码层一期零改动**

真正锁死"两人"的三层：slot 0/1 二槽语义（服务端）、`peerName/peerGender` 二元创建协议（shared）、`chat_page.dart` 的"一个对方"假设（app）。

## 改动清单

### 服务端（~2-3 天）

- spaces 表加 `mode` 字段（`duo` | `group`，NOT NULL 默认 'duo'；存量空间回填 'duo'
  → 现存情侣空间天然是严格二人空间，零迁移成本）：duo = 二人私密空间（create 保留
  伴侣名字/性别录入，情侣 UX 原样保留），group = 多人群空间（create 只填创建者名，
  不预置伴侣）
- slot 0/1 → 开放为小整数槽位（保留 UNIQUE(space_id, slot)）；join 的 slot 参数改为
  显式语义（无老客户端兼容）：**不带 slot = 新身份**（分配最小空 slot、生成新
  member_id），**带 slot = 已有成员加通道**（slot 必须已有人，否则报错）
- 人数上限单一 chokepoint：mode=duo 且 active 成员 ≥2 → join 409（DUO_FULL）；
  mode=group 超 `maxMembersPerSpace`（serverConfig.json 新增，建议默认 4，与
  maxSpaces / maxEntrancesPerSpace 同一模式，不写死代码常量）→ 409（SPACE_FULL）；
  duo 模式的 token 只供"已有成员加通道"（带 slot 绑定），新身份 token 拒绝
- preflight 响应的 slots 列表加"新成员"选项（仅 group 模式且成员数 < 上限），duo
  空间不提供；客户端据此走"新成员加入"流（不展示身份选择页），token 逐人一次性
  （现状 join_tokens 不变，不新增多用户/吊销端点）
- WS 加 `member.joined` 广播（新成员加入时在线成员刷新成员名单）；**无 member.left**
  （一期无退出）
- notifier.ts（948 行）核对：未读口径已是 member 维度（`!= 自己身份`），基本不用动；
  ① 重提封顶是**按收件人邮箱**计的，与"对方"无关——核对后不动；② `sendPushHint`
  排除的是 entrance 维度（push.ts），同身份其他通道也会收到推送 → 改为按 member 排除；
  ③ 邮件「对方」回退文案改群口径
- call.\* 信令改按 **mode** 判定：duo 空间可用（二人私聊通话），group 空间直接拒绝
  （服务端兜底 + 客户端隐藏入口；group 即使当前仅 2 人也不通话——空间性质创建时定）
- key_escrow 口令归属：一期维持"创建者口令"不变，新成员用同一口令取钥，文档注明

### shared 协议层（~1 天）

- api_client.dart create：duo 保留 creatorName + peerName/peerGender（二人私密），
  group 仅 creatorName（不预置伴侣）
- join 请求：不带 slot = 新身份，带 slot = 已有成员加通道（现状 join 必须选
  slot ∈ {0,1}；身份选择页改作"加通道选已有成员"入口，新成员流不经过它）；
  preflight 响应 slots 加"新成员"选项（group 模式）
- `PROTOCOL_VERSION` "2" → "3"（create 参数变化 / join slot 语义变化 = wire 契约
  变化，protocolVersion.ts 单一来源）
- 载荷 meta 加键为安全渐进升级，几乎不动

### App 客户端（大头，~1-2 周）

- chat_page.dart（7837 行）157 处 peer/对方假设 → 按"发送者 member"维度渲染：
  气泡左右侧（自己 vs 他人）、N 人头像与名字、颜色分配泛化
  （按 **member_id 稳定哈希**分配色板，不按 slot 序号轮换——槽位复用/空槽会让颜色漂移）
- 成员管理页（新）：成员列表（头像/名字/通道数）、邀请链接生成/复制（duo 空间仅
  "已有成员加通道"，无邀请新成员）；**无退出入口**
- 顶部条：单名字 → 名字列表/「N 人」摘要
- 已读状态：从"对方读到 seq"到"每位成员水位"展示（可简化为"全员已读"）；
  **本地 peer_receipts 表现为单"对方"水位行 → 升级为 per-member 多行（schema 迁移 v10）**
- per-space 资料落库泛化：本地 spaces 表 peerName 列（"对端名"）升级为成员名单，
  供切换空间卡片/顶部条离线显示
- 引用回复、通知文案同步泛化；烧完即焚在群内维持现状（本地 per-member 各自删除）
- 通话入口在 group 空间隐藏（duo 空间保留通话）；call 状态消息（kMetaCallState）
  group 内按系统消息展示
- 成员管理页可设成员邮箱（notify_emails 按 space_members.email；未验证不发是现状机制）

### CLI/TUI（~1-2 天）

- chat_core.dart（919 行）单对方假设，改动小；群消息显示 "name: text" 前缀
- 范围注：CLI 现无创建/加入空间入口（仅复用 shared api）——一期 CLI 群适配只做
  "已在群内的消息收发/显示"，创建/加入群空间列二期

### 文档同步

- PROTOCOL_MULTIVERSE.md（§4 创建/join、§5 escrow、§8.4 通话）、DATABASE.md
  （space_members / join_tokens / receipts 的群语义、spaces.mode）、GLOSSARY.md、
  ONBOARDING.md（新成员可见全部历史的明示文案）

### 一次性升级步骤（无老客户端兼容，服务端先行）

1. `PROTOCOL_VERSION` 2 → 3，与服务端改动同批上线
2. **服务端先上**：老 app 连新服务端 = 明确拒收（pv 校验 REST 400 / WS 4400，
   加入向导已有"app 太旧"专门文案）→ 安全侧；新 app 连老服务端则可能意外可用但
   group 创建必挂 → 不允许，故服务端先
3. 手动通知 2-3 名测试者统一升级 app（APK / TestFlight 直推）
4. 存量数据零迁移：现有两人空间 slot 0/1 原样可用；存量"建了空间但伴侣未加入"的
   pending 行由新 join 的"最小空槽"自然复用
5. CLI 无空间创建/加入流程（已核实：不在代码库内），无需升级；群支持列二期

## 风险

| 风险                                             | 等级       | 一期对策                                                       |
| ------------------------------------------------ | ---------- | -------------------------------------------------------------- |
| 成员（未来若开退出）永久持有 Space Key，无法作废解密能力 | 高（接受） | 一期无退出，风险不实际发生；二期做退出必须搭配密钥封装（sender-keys / 按成员密钥封装），两者绑定 |
| chat_page 回归面大，golden 政策保持红不重刷      | 中         | 改动拆小步；气泡渲染层抽独立 widget 再动；手测为主             |
| 无老客户端兼容 → 升级窗口期旧版无法使用         | 低         | 服务端 pv 校验拒收 `PROTOCOL_VERSION_MISMATCH`（REST 400 / WS 4400），不崩即可；窗口仅数天，手动通知全部测试者升级（见升级步骤） |
| 全员平等无踢人 → 成员只能自己退出                | 低         | 拍板接受（一期更进一步：**无退出**）；将来要踢人需配合密钥轮换再做   |
| notifier 多人多通道重复提醒                       | 低         | 核对封顶逻辑按 member 维度（未读口径已是 member 维度，见服务端清单） |

## 分期

- **一期（2-3 周）**：上述全部；duo / group 双模式（duo 禁加第三人、group 禁通话）；
  新成员可见全部历史（加入页明示文案）；邀请 token 逐人一次性；成员无退出；
  一次性升级（v3，服务端先行）
- **二期候选**：成员退出（含状态机/重入/广播，依赖下条）、密钥按成员封装（退群作废）、
  踢人+密钥轮换、群通话（Mesh ≤4 人）、CLI 深度适配（含创建/加入群空间入口）、
  duo → group 空间迁移、"启动时强制升级"（/health 加 min_app_version + 启动阻断
  提示 + 下载链接）
