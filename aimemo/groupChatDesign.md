# 多人群聊（一期）设计方案 —— 2026-10-03 评估

老板已拍板的方向性决策：

| 决策点           | 结论                                                      |
| ---------------- | --------------------------------------------------------- |
| 群规模上限       | 3-4 人小群（服务端可设上限常量，UI 不做通用人海列表）     |
| 新成员历史可见性 | 可见全部历史（与现有 Space Key 模型一致，产品上明示即可） |
| 群语音通话       | 一期禁用，call.\* 信令仅限两人私聊空间                    |
| 成员管理权限     | 全员平等：所有人可邀请；**不做踢人**                      |
| 二人私密空间(duo) | duo 空间默认**禁止加入第三人**（自动升格前），情侣私密体验（2026-10-03 拍板） |
| mode 确定方式     | 创建时**不选类型**；伴侣入网后点「邀请新成员」自动升格 group，单向不可逆（2026-10-03 拍板，方案 C） |
| 创建/加入流程    | duo/group **共享同一套创建与加入流程**（mode 仅服务端生效 + 少量 UI 文案/入口差异）；创建时不预置对方，partner 加入时自己填名 |
| 加通道 token     | 邀请链接分两种（invite/channel），channel 绑定发起人身份，杜绝冒充（方案 B） |
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
  → 现存情侣空间天然是严格二人空间，零迁移成本）：duo = 二人私密空间（上限 2、
  通话可用），group = 多人群空间（上限 maxMembersPerSpace、通话禁用）
- **创建时不选类型**（创建流程保持现状零打扰：只填创建者名字，不预置伴侣；
  create 删 peer_name/peer_gender，partner 在新成员加入流里自己填名），新空间一律
  'duo'；**mode 自动升格**：duo 空间伴侣入网后签发 invite token 即升格 group
  （幂等 `UPDATE spaces SET mode='group'`，token 签发 + join 双闸门——防止 token
  签发于升格前、使用于升格后的窗口；单向不可逆；仅当 maxMembersPerSpace > 2
  时允许升格，否则入口隐藏）
- slot 0/1 → 开放为小整数槽位（保留 UNIQUE(space_id, slot)）；join 的 slot 参数改为
  显式语义（无老客户端兼容）：**不带 slot = 新身份**（分配最小空 slot、生成新
  member_id），**带 slot = 已有成员加通道**（slot 必须已有人，否则报错）
- join_tokens 加 `purpose` 字段（`invite` | `channel`，**发起人生成时选定**）：
  invite = 邀请新成员（新身份）；channel = 绑定发起人自己的 slot（由
  created_by_entrance → member → slot 查出），仅该成员可在新设备加通道——
  彻底消除"任何成员任选他人身份加通道"的冒充面（现状身份选择页允许选任意人）
- join 校验：purpose=invite → 必须不带 slot（新身份，分配最小空槽）；purpose=channel
  → 必须带 slot 且 == 发起人 slot（不符 403）；原"任选已有身份"路径删除
- 人数上限单一 chokepoint：mode=group 超 `maxMembersPerSpace`（serverConfig.json
  新增，建议默认 4，与 maxSpaces / maxEntrancesPerSpace 同一模式，不写死代码常量）
  → 409（SPACE_FULL）；mode=duo 且 active 成员 ≥2 收到 invite join → 不拒绝，
  自动升格 group（见上）——DUO_FULL 仅作为升格后仍超限的防御性错误码保留
- preflight 返回 purpose + 受邀人（token 签发者）名字 + 成员数：invite token →
  客户端走"新成员加入"流（填自己名字，无身份选择页）；channel token → 客户端走
  "在其他设备加入我的账号"流（身份由链接绑定，无选择）；token 逐人一次性
  （现状一次性 / 24h 机制不变，不新增吊销端点）
- **duo 与 group 共享同一套创建/加入流程与代码路径**（不出现按 mode 分叉的流程
  分支）：mode 只在服务端生效（人数上限、call.\* 判定）+ 少量 UI 文案/入口差异
  （duo「邀请伴侣」、满员隐藏邀请入口、隐藏通话入口）；客户端不按 mode 画两套向导
- WS 加 `member.joined` 广播（新成员加入时在线成员刷新成员名单）；**无 member.left**
  （一期无退出）
- notifier.ts（948 行）核对：未读口径已是 member 维度（`!= 自己身份`），基本不用动；
  ① 重提封顶是**按收件人邮箱**计的，与"对方"无关——核对后不动；② `sendPushHint`
  排除的是 entrance 维度（push.ts），同身份其他通道也会收到推送 → 改为按 member 排除；
  ③ 邮件「对方」回退文案改群口径
- call.\* 信令改按 **mode** 判定：duo 空间可用（二人私聊通话），group 空间直接拒绝
  （服务端兜底 + 客户端隐藏入口；group 即使当前仅 2 人也不通话——**升格 group 的
  代价即失去通话能力**，升级确认文案必须明示）
- key_escrow 口令归属：一期维持"创建者口令"不变，新成员用同一口令取钥，文档注明

### shared 协议层（~1 天）

- api_client.dart create：删 peerName/peerGender（统一只填创建者，v3）
- createJoinToken：加 purpose 参数（invite/channel）
- join 请求：purpose 由 token 自带；channel token 带 slot（绑定发起人身份），
  invite token 不带 slot；preflight 响应加 purpose / 受邀人名字（替代身份选择页
  的 slots 选择逻辑）
- `PROTOCOL_VERSION` "2" → "3"（create 参数变化 / join slot 语义变化 = wire 契约
  变化，protocolVersion.ts 单一来源）
- 载荷 meta 加键为安全渐进升级，几乎不动

### App 客户端（大头，~1-2 周）

- chat_page.dart（7837 行）157 处 peer/对方假设 → 按"发送者 member"维度渲染：
  气泡左右侧（自己 vs 他人）、N 人头像与名字、颜色分配泛化
  （按 **member_id 稳定哈希**分配色板，不按 slot 序号轮换——槽位复用/空槽会让颜色漂移）
- 成员管理页（新）：成员列表（头像/名字/通道数）；邀请链接生成/复制按状态变化：
  伴侣入网前 = 「邀请伴侣」（直接生成，不升格）；伴侣入网后 = 「邀请新成员」
  （点击弹升格确认：**升级后本空间禁用语音通话、最多 N 人、不可逆** → 确认后
  生成链接，服务端自动升格）；group 满员后隐藏邀请入口；「在其他设备加入我的账号」
  入口放在我的菜单（channel 链接绑定自己身份，文案明示"XX 的设备接入"）；**无退出入口**
- 加入向导改造：删身份选择页（setup_page 步骤 2）——新成员流 = 粘贴链接 →
  填自己名字（+性别，新步骤）→ 密保口令；加通道流 = 粘贴链接 → 密保口令
  （身份由链接绑定）；join 确认页显示「受邀人名字 + N 人」（preflight 提供，
  替代原 slots 卡片的"对方是谁"展示）
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
  （space_members / join_tokens / receipts 的群语义、spaces.mode 与升格规则）、
  GLOSSARY.md、ONBOARDING.md（新成员可见全部历史的明示文案）

### 一次性升级步骤（无老客户端兼容，服务端先行）

1. `PROTOCOL_VERSION` 2 → 3，与服务端改动同批上线
2. **服务端先上**：老 app 连新服务端 = 明确拒收（pv 校验 REST 400 / WS 4400，
   加入向导已有"app 太旧"专门文案）→ 安全侧；新 app 连老服务端则可能意外可用但
   group 创建必挂 → 不允许，故服务端先
3. 手动通知 2-3 名测试者统一升级 app（APK / TestFlight 直推）
4. 存量数据零迁移：现有两人空间 slot 0/1 原样可用；存量"建了空间但伴侣未加入"的
   pending 行（slot 1, member_id NULL）由"最小空槽"逻辑自然复用——pending 行
   语义变为"未预置名字的空槽"，伴侣拿 invite 链接照常加入
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

- **一期（2-3 周）**：上述全部；duo / group 双模式（创建不选类型，duo 满员后自动
  升格 group、单向不可逆；group 禁通话）；创建流程不预置对方，新成员自己填名；
  邀请链接双 purpose（invite/channel，channel 绑定发起人身份）；新成员可见全部历史
  （加入页明示文案）；token 逐人一次性；成员无退出；一次性升级（v3，服务端先行）
- **二期候选**：成员退出（含状态机/重入/广播，依赖下条）、密钥按成员封装（退群作废）、
  踢人+密钥轮换、群通话（Mesh ≤4 人）、CLI 深度适配（含创建/加入群空间入口）、
  "启动时强制升级"（/health 加 min_app_version + 启动阻断提示 + 下载链接）
