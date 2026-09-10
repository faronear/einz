# Einz 从单一空间升级为「多重宇宙（Multiverse）」

> 状态：`[待评审] 设想中的架构升级，待定`
>
> 目标：把当前“一个服务器对应一个固定 Space、只供自己和伴侣使用”的产品，升级为“同一服务器承载许多 Space；任何两个人都可以创建或加入一个私密 Space；每个 Space 始终最多两个人”的产品。
>
> 本文是架构分析和实施计划，不代表代码已经完成。

## 1. 目标与边界

### 1.1 新产品模型

Einz 的最小产品单元不再是整个服务器，而是一个 Space：

```text
Einz Multiverse / Server
├── Space 1
│   ├── Person A
│   └── Person B（可选，尚未加入时为空）
├── Space 2
│   ├── Person A
│   └── Person B
└── Space N
```

约束：

- 一个 Space 最多两个 Person。
- 一个客户端/Device 严格只能属于一个 Space。
- Server 是多租户密文中继、同步和存储服务，不读取消息明文和 Space Key 明文。
- 客户端只绑定一个 Space，不需要联系人名单、Space 列表或 Space 切换器。Person 与 Device 的现实归属由用户在线下控制，不由 Server 推断。
- “多重宇宙”不是公开社交网络：没有全局用户目录、联系人推荐、模糊搜索或公开空间浏览。

### 1.2 必须先澄清的安全语义

用户提出“客户端生成空间公私钥，地址作为空间地址，空间私钥作为 Space Key”。这里需要拆成两个不同的密钥概念：

1. **Space Identity Key**：非对称身份密钥对，用于标识 Space、签名 Space 元数据或建立可验证的 Space 身份。
2. **Space Content Key**：随机生成的 32 字节对称密钥，用于派生消息和附件密钥。

不能直接把非对称私钥当作当前协议里的 Space Key：

- 当前消息加密使用 XChaCha20-Poly1305，Space Key 是对称密钥；
- 非对称私钥需要不同的密钥类型、格式、用途和轮换语义；
- 如果为了让两个人都能解密而把“空间私钥”复制给双方，它就已经不是“只有创建者持有的私钥”；
- 低熵的自定义 Space ID 不能承担加密授权职责。

建议采用以下分层：

```text
Space Address / Space ID
    └── 由 Space Identity 公钥派生的公开定位符（Ethereum 风格，可由客户端生成）

Space Identity Key（可选，第一阶段可延后）
    └── public key 参与 Space 身份和元数据签名

Space Content Key（真正的 Space Key）
    └── 随机 32 字节对称密钥
        ├── HKDF → Message Key
        └── HKDF → Attachment Key
```

第一阶段不必引入 Space Identity Key 的完整签名体系。最小可行方案是：客户端生成高熵随机 `space_id` 和随机 `space_key`，创建者用自己的 Device 公钥封装 Space Key；第二个人加入时，由创建者或服务端经过授权流程把 Space Key 安全地封装给第二个人的 Device 公钥。后续再增加 Space Identity Key，用于防止 Space 元数据被替换和支持可验证分享链接。

### 1.3 Space Address 与内部 ID

Space 的用户可见地址可以采用 Ethereum 风格：

```text
space_address = EIP-55(0x + last20Bytes(Keccak-256(space_public_key)))
```

注意：这里必须是 Keccak-256，不是标准 SHA3-256。地址的 20 字节截断和 EIP-55 大小写校验适合做分享、二维码和精确查找，但地址本身是公开定位符，不应直接当作加入授权；加入仍需要一次性 join token、创建者确认或其他明确授权。

有两种实现路线：

- **Ethereum 兼容路线**：Space Identity Key 使用 secp256k1，按 Ethereum 原生规则从未压缩公钥派生地址。优点是可使用成熟的 Ethereum 工具；代价是客户端新增 secp256k1 密钥体系，与当前 libsodium/X25519 体系并行。
- **Ethereum 风格路线（推荐第一版）**：继续使用现有密码库生成 Space Identity 公钥，只复用 Keccak-256、取后 20 字节和 EIP-55 编码。外观和校验规则与 Ethereum 地址一致，但不声称能被 Ethereum 钱包当作账户使用，避免引入第二套签名算法。

两条路线的实际取舍如下：

| 方案               | 优点                                                                                                             | 缺点                                                                                                                                                                                        | 适用条件                                                          |
| ------------------ | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| 真正 Ethereum 兼容 | 地址可被 Ethereum 钱包、区块链浏览器和 Web3 工具识别；未来可以复用 secp256k1 签名、账户恢复和生态工具            | 引入 secp256k1 与现有 libsodium 并行；需要明确 Space Identity Key、Device Key、Space Key 三套密钥的边界；增加密钥生成、存储、备份、轮换和审计复杂度；Ethereum 地址兼容不等于加入权限或 E2EE | Einz 明确要和钱包、链上身份、ENS、签名或 Web3 生态互操作          |
| Ethereum 风格      | 保留现有 libsodium/X25519/Ed25519 技术栈；实现简单、依赖少、测试面小；地址仍然短、可复制、可扫码、带 EIP-55 校验 | 不能被 Ethereum 钱包当作账户使用；不能直接复用 Ethereum 签名和恢复工具；需要明确向用户说明“外观像 Ethereum 地址，但不是链上地址”                                                            | Einz 只需要全球唯一、可读、可校验的 Space Address，不需要链上功能 |

因此当前更推荐第二种：使用现有密码库生成独立的 Space Identity 公钥，再用 Keccak-256 + EIP-55 生成地址。它只增加一套 Space 身份公钥，不增加 secp256k1。Device Key 继续负责设备认证和封装 Space Key，Space Content Key 继续负责消息/附件加密。

只有在产品路线明确包含“连接 Ethereum 钱包、用链上账户签署 Space、ENS/链上身份绑定”等需求时，才值得选择真正兼容路线。否则“Ethereum 风格”已经满足地址体验，兼容 secp256k1 带来的复杂度没有实际收益。

地址、内部 ID 和认证公钥应明确分离：

| 字段               | 建议格式                                  | 用途                            |
| ------------------ | ----------------------------------------- | ------------------------------- |
| `space_address`    | `0x` + 40 个十六进制字符，EIP-55 checksum | 用户分享、二维码、精确查找      |
| `space_id`         | UUID（推荐 UUIDv7；也可 UUIDv4）          | Server 内部主键、外键和日志关联 |
| `space_public_key` | 密钥库规定的原始公钥编码                  | 地址派生、未来 Space 元数据签名 |
| `space_key`        | 随机 32 字节对称密钥                      | 消息/附件内容加密，永不作为地址 |

Server 必须对 `space_address` 建唯一索引，即使 160 位地址碰撞概率极低，也不能只依赖概率；地址冲突时重新生成 Space Identity Key。`space_id` 不应直接暴露给普通用户，也不应使用地址作为所有业务表的主键。

同一套 Space Identity Key 可以派生多个地址表示：公钥是稳定根，地址算法是确定性派生函数，因此理论上是 `1:n`。例如同一公钥可以有 `address_v1`（Ethereum 风格十六进制）、未来的二维码编码或其他网络格式。但每个派生函数都必须有明确的版本、输入字节规范和 checksum 规则；上线后的默认地址算法不能静默更换。

建议数据库保留一个 canonical `space_address`，必要时另建 `space_address_aliases(space_id, version, address)` 保存旧版本或兼容格式。地址只是 Space 的定位视图，不是密钥本身、不是 Space Content Key，也不是加入授权凭证。

### 1.4 Person ID、Device ID 与 `personA/B` 的去留

为了适应一个 Server 上无限增长的 Space，`personA`、`personB`、`dev1`、`dev2` 这类顺序编号不应继续作为实体 ID。但当前不需要建立全球自然人 `person_id`：同一个现实中的人可以在不同 Space 中拥有不同的 Space 内成员身份，Server 不应自动把它们关联起来。

- `device_id` 推荐使用随机 UUIDv4，作为稳定的数据库和协议引用标识；Device 的真正密码学身份仍然是 `public_key`，UUID 不能替代签名/挑战响应。
- 如果希望 Device ID 自包含、无需服务端分配，可以增加 `public_key_fingerprint = base32(BLAKE2b-256(canonical_public_key))`，或用它替代 UUID 作为内部引用。但不建议把原始 Base64/Hex 公钥直接塞进 `device_id`。
- `person_id` 可以升级为 UUID，但只在 `space_id` 作用域内解释。它代表该 Space 的伴侣记录，不是全球自然人的账号 ID；如果只有两位固定伴侣，`partner_slot` 已足够表达空间内的区分，`person_id` 主要用于稳定引用和未来同一伴侣多设备。
- `personA/B` 降级为 TUI 引导未提供名字时，Server 为两位伴侣生成的默认显示用户名；伴侣槽位本身用 `partner_slot = 0/1` 表达。它们不是全局 ID，也不是 `person_id`。
- `message_id`、`attachment_id`、`invite_id`、`join_request_id` 也建议使用 UUID，避免多 Space 下的顺序编号、枚举和碰撞。
- `server_sequence` 仍然可以是每个 Space 内从 1 开始的整数，因为它是同步游标，不是全球实体 ID。

推荐的伴侣约束是 `UNIQUE(space_id, partner_slot)` 和 `UNIQUE(space_id, person_id)`；设备约束是全局唯一 `device_id`、全局唯一 `public_key` 加上一个 active `space_id`。这表达了“每个 Space 两个伴侣槽位”和“每个 Device 只能绑定一个 Space”，但不试图判断多个 Device 是否属于同一个自然人。

### 1.5 现在的 Space Person 与未来的实名 Identity

当前建议保留三层概念，不要把它们命名成同一个 `person_id`：

```text
Space Member
├── space_id
├── partner_slot: 0 / 1
├── person_id: Space 内部 UUID（可选但推荐保留）
└── display_name / gender

Device
├── device_id: 全局设备引用
├── space_id
├── person_id: 指向当前 Space 的成员
└── public_key: 设备认证身份

Future Account / Real Identity（未来可选）
├── account_id: 全局账号或实名身份 ID
└── account_memberships: 明确授权后关联到一个或多个 Space Member
```

`partner_slot` 是最稳定、最符合当前产品约束的空间内区分：一个 Space 只有两位伴侣。`person_id` 是空间内伴侣对象的引用；它可以是 UUID，也可以在极简实现中直接使用 `(space_id, partner_slot)` 作为复合引用。推荐保留 UUID，是为了让消息、设备、profile 和未来同一伴侣的多设备引用更清晰，但不要赋予它全球语义。

如果未来要支持“不同 Space 的 Person 绑定到同一个实名用户”，应新增独立的 `account_id` 或 `identity_id`，通过用户主动登录、验证和同意建立映射：

```text
account_id 1 ── n account_memberships
                         ├── (space_id=A, person_id=X)
                         └── (space_id=B, person_id=Y)
```

这个映射必须是显式、可撤销、最小暴露的。不能因为两个 Device 使用过相似名字、公钥或地址，就由 Server 自动推断它们属于同一个人；否则“私密 Space”会被跨空间关联，破坏当前的隐私边界。

#### 原始公钥作为 `device_id` 的权衡

优点：

- 自包含、天然全局唯一，不需要 Server 分配 `dev1/dev2` 或 UUID；
- 设备 ID 与 challenge-response 使用的认证公钥天然对应，调试时容易验证“这个 ID 属于哪把钥匙”；
- 设备首次离线生成身份后即可得到自己的引用 ID，适合创建 Space 和离线导入。

缺点：

- 原始公钥通常是几十字节，放在 URL、日志、JSON、文件名和 UI 中都很笨重；Base64 还包含 `+`、`/`、`=`，容易发生转义和规范化问题；
- 公钥一旦轮换，原始公钥形式的 `device_id` 就会改变；如果想保留“同一台设备”的逻辑身份，还需要额外的 key rotation/alias 机制；
- 公钥虽然不是私钥，但它是稳定的全局可关联标识，跨 Space 复用时会暴露“这些设备可能属于同一人”的元数据；
- 不同算法、编码、版本或公钥格式会产生不同的字符串 ID，迁移和比较容易出错；
- 数据库索引、外键和人工排查都不如 UUID 简洁。

因此推荐三层分离：`device_id = UUIDv4` 作为稳定业务引用，`public_key` 作为认证凭据，`public_key_fingerprint` 作为可选的稳定指纹和排障显示。若产品明确不需要设备密钥轮换，并且偏好自包含身份，也可以采用公钥指纹作为 `device_id`；不要使用未经规范化的原始公钥字符串。

## 2. 当前架构的真实限制

### 2.1 Server 级别的单一 Space

当前 `server/src/config.ts` 的 `loadConfig()` 从 `meta.space_id` 读取或生成唯一 Space ID，`ServerConfig` 只有一个 `space_id`。应用启动时把它作为所有请求的空间上下文。

这意味着：

- Server 只有一个逻辑租户；
- 空间地址不是客户端创建的，而是服务器启动时生成的内部值；
- `/health` 返回全局空间的用户名称和性别；
- `devices` 表没有 `space_id`，设备天然属于这个全局 Space；
- `invites`、`challenges`、`sessions`、推送和 WebSocket 都隐式绑定到全局 Space。

### 2.2 已有 `space_id` 字段不能直接解决问题

`messages` 和 `attachments` 已有 `space_id` 字段，`key_escrow` 也按 `space_id` 存储。这是有利的基础，但不足以完成多空间：

- `messages.server_sequence` 当前是全局 `UNIQUE`，而协议语义是按 Space 独立递增的序号；
- `devices.device_id`、`sessions`、`challenges`、`push_tokens` 没有完整的 Space 归属；
- `invites` 只有 `person_id`，没有空间、创建者、目标成员和授权过期语义；
- `meta` 使用全局 key-value，`person_name:*`、`person_gender:*` 会在多个 Space 之间冲突；
- `server/src/ws.ts` 的连接和广播需要改为按 `space_id` 分组；
- `auth` 当前只验证设备是否存在和 active，不能验证“这个 session 对某个 Space 有权限”。

### 2.3 当前客户端默认只有一个 Space

App 当前在启动页探测 `/health`，以“名称表是否为空”推断 create/join；向导完成后把一个 `server + spaceId + spaceKey + token` 写入启动锁和本地状态，然后直接进入 ChatPage。

CLI/TUI 当前把一个 `DeviceStore` 视为一个 Space，`server`、`spaceId`、`spaceKey`、`sessionToken` 都是单值；`/space` 是重新接入当前唯一空间，不是空间选择器。

因此多空间不能只改首屏按钮，但客户端不需要成为多空间容器：Server 负责承载多个租户，客户端只需把当前单值配置明确建模为“唯一绑定的 Space Profile”。

## 3. 推荐的目标架构

### 3.1 Server 数据模型

建议新增明确的多租户表，不再使用 `meta` 表承载业务空间状态：

```sql
spaces (
  space_id              TEXT PRIMARY KEY,
  space_address         TEXT NOT NULL UNIQUE,
  space_public_key      TEXT NOT NULL UNIQUE,
  custom_id             TEXT UNIQUE,
  display_name          TEXT,
  status                TEXT NOT NULL DEFAULT 'active',
  max_members           INTEGER NOT NULL DEFAULT 2,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL
)

space_members (
  space_id              TEXT NOT NULL REFERENCES spaces(space_id),
  person_id             TEXT NOT NULL,
  partner_slot          INTEGER NOT NULL,
  display_name          TEXT,
  gender                TEXT,
  status                TEXT NOT NULL DEFAULT 'active',
  joined_at             INTEGER NOT NULL,
  PRIMARY KEY (space_id, person_id),
  UNIQUE (space_id, partner_slot)
)

devices (
  device_id             TEXT PRIMARY KEY,
  space_id              TEXT NOT NULL REFERENCES spaces(space_id),
  person_id             TEXT NOT NULL,
  public_key            TEXT NOT NULL UNIQUE,
  public_key_fingerprint TEXT NOT NULL UNIQUE,
  status                TEXT NOT NULL DEFAULT 'active',
  device_name           TEXT,
  last_seen             INTEGER,
  created_at             INTEGER NOT NULL,
  UNIQUE (space_id, public_key)
)
```

其中 `space_id`、`person_id`、`device_id` 都使用 UUID；`personA/B` 只作为默认显示用户名，`partner_slot` 单独表达两位伴侣的位置。现有业务表需要明确的 Space 归属和约束：

```sql
messages:
  PRIMARY KEY (space_id, message_id)
  UNIQUE (space_id, server_sequence)
  INDEX (space_id, server_sequence)

attachments:
  UNIQUE (space_id, attachment_id)

sessions:
  session_token, space_id, device_id, expires_at

challenges:
  challenge_id, space_id, device_id, expires_at, used

push_tokens:
  space_id, device_id, platform, token

key_escrow:
  space_id PRIMARY KEY, package, updated_at

invites / join_requests:
  space_id, target_person_id, created_by_device_id,
  status, expires_at, used_by
```

备注：`device_id` 必须全局唯一，并且设备登记后只能拥有一个 active `space_id`。`person_id` 仍然是 Space 内部身份，不应被当成全球账号 ID；同一个人可以在线下控制多个 Device，而这些 Device 可以分别绑定同一个或不同的 Space。Server 只强制 Device 与 Space 的一对一，不判断多个 Device 是否属于同一个自然人。

### 3.2 空间状态机

Space 不应只有“存在/不存在”两个状态，至少需要：

```text
creating → waiting_for_partner → active
                         └──────→ expired / archived
active   → archived / suspended
```

核心规则由数据库事务强制：

- 创建时成员数为 1；
- 加入时必须锁定 Space 行，确认 active 且成员数仍为 1，再插入第二个成员；
- 已有 2 人时统一返回 `SPACE_FULL`；
- 并发两个加入请求只能有一个成功；
- 空间创建失败或长期无人加入时可回收地址，但地址复用需要谨慎，建议第一阶段永不复用。

### 3.3 空间地址、用户自定义 ID 与隐私

建议同时提供三种概念，但不要混为一个字段：

| 概念            | 用途                                    | 是否可猜     | 是否可授权加入               |
| --------------- | --------------------------------------- | ------------ | ---------------------------- |
| `space_id`      | 服务端内部主键                          | 否，随机高熵 | 否，单独不够                 |
| `space_address` | 用户分享/扫码的 Ethereum 风格地址或深链 | 否           | 只用于定位；加入必须另有授权 |
| `custom_id`     | 易读的自定义短 ID                       | 可能可猜     | 绝不能单独授权               |

推荐地址格式：`e1_<base58url(random 128/256 bit)>`，或使用版本化深链：
`https://einz.tic.cc/join/<opaque-token>`。

推荐把地址中的高熵部分作为查找和加入凭证的一部分；`custom_id` 只做精确查找，服务端返回最小公开信息（例如空间名称、是否等待第二人），不返回成员姓名、性别、消息数量或设备信息。

对于“搜索地址或用户自定义 ID”：

- MVP 只支持精确匹配，不做模糊搜索；
- `custom_id` 必须全局唯一、规范化、保留字过滤、长度限制和频率限制；
- 仅凭可猜的 `custom_id` 不能直接加入，否则任何人都可以撞库进入空间；
- 推荐加入流程仍需要高熵 join token、创建者批准，或创建者在线确认一次；
- 地址被分享后是否可重复使用，需要产品明确。默认建议：地址可查找，但每次加入都生成一次性、短时效 join session，避免地址永久成为万能钥匙。

### 3.4 密钥与加入授权

建议的创建流程：

1. 客户端生成 Device Key Pair。
2. 客户端随机生成 `space_id`、`space_key`，可选生成 Space Identity Key Pair。
3. 客户端生成创建请求，把 `space_id`、地址承诺、创建者 Device 公钥、Space 元数据和“用创建者 Device 公钥封装的 Space Key”提交 Server。
4. Server 创建 Space 和第一个 `space_member`，不获得 `space_key` 明文。
5. 创建者生成邀请地址/二维码。

推荐的加入流程：

1. 第二个人输入高熵地址、扫描深链，或输入 `custom_id` 找到等待中的 Space。
2. 客户端生成新的 Device Key Pair。
3. 客户端提交 join request，包含 Device 公钥和一次性客户端随机数。
4. 创建者客户端看到待加入请求，核对名字/短码后确认。
5. 创建者客户端用第二个人的 Device 公钥封装 `space_key`，将密封包上传 Server，或通过 Server 的一次性中继交付。
6. 第二个人取回只属于自己的密封包，用 Device 私钥解开 `space_key`，完成认证并进入 Space。

如果产品坚持“输入地址后无需对方在线、直接加入”，则地址必须是不可猜的 bearer secret；`custom_id` 仍然只能定位，不能直接授权。这个取舍应在产品评审中明确记录。

### 3.5 认证与 Session

当前 challenge-response 是“设备对全局 Server 认证”。新模型应变成“设备对某个 Space 认证”：

- challenge 请求带 `space_id` 或 opaque join session；
- challenge 记录 `space_id + device_id`；
- verify 后的 session 保存 `space_id + device_id + person_id`；
- 每个受保护 API 从 bearer token 得到唯一 Space 上下文，不接受客户端随意传入的 `space_id` 覆盖权限；
- token 只对一个 Space 有效，避免一个 token 横跨多个空间；
- 一个设备只能拥有一个 active Space session；设备已绑定 Space 后再次创建/加入其他 Space 必须返回 `DEVICE_ALREADY_BOUND`，避免把“无账号 Device Key”误扩展成多空间身份；
- WebSocket URL 必须包含 Space-scoped token，广播按 `space_id` 分组。

### 3.6 消息序号与实时通道

当前消息同步已经使用 `space_id` 概念，但实现需要改为真正的租户隔离：

- `server_sequence` 改成每个 Space 独立递增；
- 所有查询必须 `WHERE space_id = session.space_id`；
- WebSocket connection 保存 `space_id`，`message.new` 只广播给同一 Space 的其他设备；
- `key.rotation`、`peer.online/offline`、profile 更新也只广播给同一 Space；
- 推送 payload 只携带当前 Space 的 opaque 标识，不泄漏其它 Space；
- 附件路径应按 `space_id/attachment_id` 分目录，并在下载时从 session 校验 Space；
- 头像和 profile 读取不能再按全局 person_id 直接公开，至少变成 `space_id + person_id` 作用域。

## 4. 客户端本地架构升级

### 4.1 从单实例配置升级为单 Space Profile

当前 AppLockPayload、ServerSettings、ChatPage 参数和 CLI DeviceStore 都将一个 Space 作为单值。这个方向可以保留，但需要把“单一服务器空间”改成“当前客户端绑定的唯一 Space”，并增加明确的绑定状态：

```text
LocalSpaceProfile
├── localSpaceId / spaceId
├── address / customId / displayName
├── myPersonId
├── deviceId / publicKey / privateKey
├── encryptedSpaceKey
├── keyVersion
├── sessionToken / tokenExpiry
├── lastServerSequence
├── pending messages
├── local messages
└── local attachments
```

建议分层：

- `SpaceProfile`：本客户端唯一的空间名称、地址、成员状态和本地绑定状态；
- `SpaceCredentialStore`：该 Space 的 Device 私钥、Space Key 包、session；
- `SpaceLocalDatabase`：消息、附件、同步状态绑定这一个 `space_id`；
- `ChatSession`：构造时明确接收这一个 `SpaceProfile`，不能再从 Server 全局状态猜空间；
- AppLock：PIN 解锁该 Space 的加密凭证包；不需要为多个 Space 设计解锁和切换流程。

### 4.2 本地数据迁移

当前单空间版本的数据迁移到新的 `LocalSpaceProfile`：

1. 读取旧的 `server / spaceId / spaceKey / deviceId / token`。
2. 生成本地 Space Profile，标记来源为 `legacy-migrated`。
3. 把现有消息、附件、sync state 绑定到该 Space。
4. 成功迁移后才删除旧的单值字段；迁移失败保留旧数据并显示可恢复错误。
5. 当前用户不需要重新注册或重新下载历史消息。

Server 端迁移也必须单独设计：

- 旧数据库中唯一 `meta.space_id` 迁移为一条 `spaces` 记录；
- 旧 `devices` 全部绑定到这条 Space；
- 旧 messages/attachments/key_escrow 绑定到这条 Space；
- 旧 invites、sessions、challenges 绑定到这条 Space；
- 迁移完成后只切换 schema version，不同时做业务删除。

## 5. 用户界面与流程变化

### 5.1 首屏：从“探测后自动判断”改为“空间入口”

当前流程是：

```text
连接固定 Server → /health → 名称为空=create，否则=join → 进入向导
```

目标流程应是：

```text
启动
  ↓
选择/确认 Server（第 0 页）
  ↓
Space 首页（第一页）
  ├── 新建私密空间
  ├── 加入已有空间
  └── 我的空间（已有本地空间时）
```

建议不要再使用 `/health` 返回“全局用户是否存在”来决定角色。`/health` 只能报告服务可用性、协议版本和能力；空间状态必须通过用户选择和受保护的 Space API 获取。

### 5.2 新建空间流程

推荐页面步骤：

1. **新建空间**
   - 空间名称（可选，仅用于本地和对方看到的显示名）；
   - 自定义 ID（可选，明确提示这是可被猜到的查找名，不是安全凭证）；
   - 继续。
2. **生成密钥**
   - 客户端生成 Device Key 和 Space Key；
   - 不向普通用户展示私钥、Base64 或内部密钥类型；
   - 创建请求提交后，服务端返回 Space Address。
3. **空间已创建，等待第二个人**
   - 显示空间名称、短地址、二维码/分享链接；
   - 提供复制地址、分享、稍后再邀请；
   - 显示成员状态：`1/2，等待另一位成员`。
4. **本人资料**
   - 名字、性别等资料；
   - 注意：这些是 Space 内 profile，不是全局账号资料。
5. **安全设置**
   - PIN/生物识别；
   - 可选口令托管和恢复方式；
   - 完成后进入 ChatPage。

创建完成后，用户不应被阻塞在“必须马上邀请”的页面；可以进入空间，等对方以后加入。

### 5.3 加入已有空间流程

推荐页面步骤：

1. **输入空间地址**
   - 支持粘贴地址、扫描二维码、输入精确 custom ID；
   - 地址格式错误、找不到、空间已满、空间已归档分别提示；
   - custom ID 查找必须有频率限制和最小返回信息。
2. **确认空间信息**
   - 显示空间名称和 `1/2` 状态；
   - 不显示对方私人资料，除非创建者已经明确设置为可见；
   - 显示“加入需要创建者确认”或“该地址本身是一次性加入凭证”，不能模糊处理。
3. **设置本人资料**
   - 名字、性别、设备名；
   - 客户端生成本机 Device Key。
4. **等待/确认加入**
   - 若采用双方确认：显示 pending 状态，支持取消和重新检查；
   - 若采用高熵地址直接授权：显示“加入成功”但仍需校验 Space Key 密封包。
5. **解锁 Space Key**
   - 用本机 Device 私钥解密密封包；
   - 设置 PIN/生物识别；
   - 进入 ChatPage。

### 5.4 已有空间的启动流程

客户端已经绑定 Space 后，不再进入新建/加入向导，也不显示空间列表：

```text
启动 → 本地 PIN/生物识别 → 唯一 Space → ChatPage
```

如果本地没有绑定 Space，才显示“新建空间 / 加入已有空间”；如果绑定记录损坏或用户主动退出空间，显示恢复、重新绑定或清除本地数据的明确流程，不能自动创建第二个 Space。

Space Address 不应默认暴露在通知和系统日志中。空间名称、对方显示名和未读数直接显示在唯一的 ChatPage 顶部即可。

### 5.5 等待第二个人的产品状态

“只有一人”的 Space 是合法中间态，不是错误：

- ChatPage 可以进入；
- 顶部显示 `等待第二位成员`；
- 允许生成/刷新一次性邀请链接；
- 不允许第三个人加入；
- 第二个人加入后，创建者收到本地系统消息和实时状态更新；
- 如果第二个人取消，Space 仍可继续等待。

## 6. API 和协议升级清单

建议新增或重构为以下接口。路径只是建议，最终以 `docs/PROTOCOL.md` 的版本化协议为准。

### 6.1 公共空间入口接口

```text
GET  /health
     只返回服务健康、协议版本、能力，不返回全局 person_names

POST /spaces
     创建 Space，提交客户端生成的 space_address/space_public_key、创建者 Device 公钥、密封 Space Key、可选 custom_id

GET  /spaces/lookup?address=...
GET  /spaces/lookup?custom_id=...
     精确查找，只返回最小公开状态
```

### 6.2 加入和授权接口

```text
POST /spaces/{space_id}/join-requests
     新 Device 提交公钥和加入请求

GET  /spaces/{space_id}/join-requests
     现有成员查看待处理请求

POST /spaces/{space_id}/join-requests/{id}/approve
     现有成员批准，并提交给新 Device 的 Space Key 密封包

POST /spaces/{space_id}/join-tokens
     现有成员生成一次性高熵邀请凭证

POST /spaces/join
     用地址/一次性 token 完成加入，必须事务性检查成员数
```

### 6.3 已认证接口的统一原则

现有 `/messages`、`/sync`、`/attachments`、`/devices`、`/space`、`/key-escrow`、`/push/register`、WebSocket 都需要：

- 从 session 取 `space_id`；
- 所有 SQL 带 Space 条件；
- 错误区分 `SPACE_NOT_FOUND`、`SPACE_FULL`、`NOT_A_MEMBER`、`JOIN_PENDING`、`JOIN_EXPIRED`；
- 不允许客户端仅通过请求 body 的 `space_id` 越权切换空间；
- API 响应按协议版本增加字段，旧客户端不能误把多空间响应当单空间响应。

## 7. Server 运维与全球化准备

### 7.1 多租户隔离是第一优先级

必须建立自动化测试，证明：

- Space A 的 token 不能读 Space B 的消息、附件、头像、设备和托管包；
- Space A 的 WebSocket 不收到 Space B 的广播；
- `server_sequence`、消息数量、清理任务和附件路径不会跨空间串联；
- 一个 Space 满员后不能被并发请求突破两人限制；
- 自定义 ID 查找不会暴露成员和消息元数据。

### 7.2 数据库与部署

当前 SQLite 单机架构可以先继续使用，但要做这些准备：

- 所有查询使用 prepared statements 和复合索引；
- 为 `spaces.space_address`、`spaces.custom_id`、`messages(space_id, server_sequence)`、`devices(space_id, person_id)` 建索引；
- 处理数据库备份、恢复和 Space 级归档；
- 附件按 Space 分目录或对象存储 prefix；
- 增加请求频率限制、创建空间限制、custom ID 抢注限制和 join 尝试限制；
- 增加容量监控：Space 数量、活跃 Space、消息/附件占用、每 Space 限额；
- 全球用户上线前再评估 PostgreSQL、对象存储、队列和多实例 WS；不要在多租户 schema 尚未稳定前提前引入复杂基础设施。

### 7.3 Server 不应成为“账号中心”的隐性版本

Server 承载多个 Space，但客户端不是多空间容器。第一阶段不引入全局账号、联系人和好友系统；一个 Device Key 绑定一个 Space。用户如果有多个 Device，可以在线下决定每个 Device 加入同一个或不同的 Space。

换机、增加设备或更换伴侣都应通过明确的设备注册/退出流程完成；Server 不把多个 Device 自动合并成同一个 Person，也不因它们属于同一个人而强制它们进入同一个 Space。

## 8. 兼容、迁移和版本策略

### 8.1 协议版本

建议把当前单空间协议标为 `v1-single-space`，新协议标为 `v2-multiverse`：

- Server 启动时记录 schema version 和 protocol capabilities；
- App/TUI 连接后读取能力，不支持 `spaces` 的旧 Server 给出明确升级提示；
- v1 客户端不要连上 Multiverse Server 后静默读取错误空间；
- 迁移期 Server 可以同时服务旧 Space 和新 Space，但所有旧请求必须明确映射到迁移出的 legacy Space；
- 迁移完成后再删除 `meta.space_id` 的业务读取路径。

### 8.2 旧用户迁移

迁移脚本应是幂等的：

```text
legacy meta.space_id
        ↓
spaces(id=legacy_space_id, custom_id=null, status=active)
        ↓
旧 devices → space_members + devices.space_id
旧 messages/attachments/key_escrow → legacy_space_id
旧 invites/sessions/challenges → legacy_space_id
```

App 首次升级时把旧凭证包包装成一条本地 Space 记录。用户看到的是原来的聊天空间，不需要重新输入地址。

### 8.3 数据迁移验收

- 迁移前后消息数量、最大 sequence、附件数量、Space Key version 一致；
- 双端历史消息可以解密；
- 未读数和本地 pending 队列不丢；
- 旧 session 不能访问新建 Space；
- 迁移失败可重试，不破坏原库；
- 迁移后启动不会因为 `/health` 不再返回全局 names 而误进入错误向导。

## 9. 分阶段实施计划

### Phase U0：产品和安全决策 `[待评审]`

- 确认 Space Address 只作为公开定位符，加入授权由一次性 token/创建者确认承担。
- 确认采用 Ethereum 兼容地址，还是沿用现有密码库并只采用 Ethereum 风格的 Keccak-256 + EIP-55 地址编码；第一版建议后者。
- 确认 `space_id`、`person_id`、`device_id` 使用 UUID，`personA/B` 只作为无名成员的默认显示用户名。
- 确认 `custom_id` 只精确查找，不提供模糊搜索。
- 确认加入是否需要创建者在线批准。
- 确认一台客户端只能绑定一个 Space，并由 Server 拒绝跨 Space 再绑定。
- 确认 Person 不做全局身份识别；同一个人可在线下控制多个 Device，并分别绑定同一个或不同的 Space。
- 确认“退出当前 Space、重新绑定或创建新 Space”是否需要清晰的危险确认和本地数据导出。
- 产出 `docs/SPACE_MODEL.md`、`docs/PROTOCOL_MULTIVERSE.md`、`docs/E2EE_MULTIVERSE.md`。

### Phase U1：服务端多租户基础 `[待开发]`

- 新增 `spaces`、`space_members`、`join_requests` 或一次性 join token 表。
- 迁移 `devices`、`sessions`、`challenges`、`invites`、`push_tokens` 的 Space 归属。
- 修正消息 sequence 为 `(space_id, sequence)`。
- 把鉴权上下文改为 Space-scoped session。
- 把消息、附件、托管、头像、设备、WS 广播全部加租户隔离。
- 实现创建 Space、精确 lookup、空间满员事务、基础 join。
- 补齐跨空间越权和并发加入测试。

### Phase U2：密钥分发和加入协议 `[待开发]`

- 定义 Space Key 的创建者封装、第二成员封装和密钥轮换流程。
- 实现 `POST /spaces` 和 join request/approve 或一次性 token。
- 将现有邀请码从“加入全局 Space 的 person 邀请”改为“加入特定 Space 的一次性授权”。
- 保持 Server 只存 sealed key package，不接触 Space Key 明文。
- 验证创建、加入、拒绝、过期、重复使用、Space 满员和设备撤销。

### Phase U3：App 单 Space Profile 和首屏 `[待开发]`

- 本地数据库把旧单值配置正式整理为唯一 Space Profile 和绑定状态。
- 将 AppLock、MessageRepository、ChatPage、同步和附件缓存明确绑定到这一个 Space。
- 第 0 页保留服务器连接/探测；第一页改为空间入口：新建、加入、已有空间。
- 新建流程显示地址/二维码/等待第二人。
- 加入流程支持地址、二维码、精确 custom ID，并显示等待确认/已满/失败状态。
- 已有空间直接进入唯一 ChatPage，不增加 Space 列表或联系人页。

### Phase U4：CLI/TUI 对齐 `[待开发]`

- `DeviceStore` 保留单 Space 结构，但增加绑定状态和空间地址字段。
- 未绑定时启动显示新建/加入；已绑定时直接进入唯一 Space。
- 增加 `/space address`、`/space create`、`/space join <address>` 等命令；不增加联系人或空间切换命令。
- 新建后可打印地址、二维码数据和一次性邀请信息。
- 保留旧单空间 store 自动迁移。

### Phase U5：迁移、运营和全球化 `[待开发]`

- 执行旧库迁移和客户端兼容。
- 增加匿名创建/查找/join 频率限制和 abuse 防护。
- 增加备份、归档、删除 Space、数据导出和空间级恢复。
- 做多实例 WS、对象存储、数据库扩展的容量评估。
- 进行跨区域网络、时区、语言、地址复制和 Unicode custom ID 测试。

## 10. 关键验收标准

### 功能

- 同一 Server 上可以创建至少两个互不相干的 Space。
- Space A 的两个人只能看到 Space A 的消息；Space B 同理。
- 一个新 Space 可以只有一个人，第二个人稍后加入。
- Space 已有两人时，第三个 join 永远失败。
- 一个已经绑定 Space 的 Device 再次尝试创建/加入其他 Space 时，服务端拒绝并返回 `DEVICE_ALREADY_BOUND`。
- 用户第二次启动直接进入已有 Space，不重复走新建/加入引导。
- 旧单空间用户升级后历史消息和附件仍可解密。

### 安全

- Server 数据库中没有 Space Key 明文。
- 低熵 custom ID 不能直接越权加入。
- 任一 Space token 不能访问其他 Space 的任何资源。
- WebSocket、Push、附件下载、头像读取均有 Space 边界。
- 并发加入不会把成员数从 1 绕过到 3。
- Space Key 轮换后撤销设备不能读取新消息。

### 体验

- 首屏用户能明确理解“新建空间”和“加入已有空间”的区别。
- 新建后能复制/分享地址，不需要手工处理私钥和 Base64。
- 输入错误地址、空间已满、等待批准、邀请过期都有明确可恢复路径。
- 唯一 Space 页面能显示对方、未读数和离线状态，但不显示其他 Space 的任何信息。
- 用户不会因为 Server 有其他 Space 就看到其他人的姓名、性别、消息或空间列表。

## 11. 建议的第一批代码切入点

按依赖关系，第一批不应从 UI 开始，而应从协议和数据模型开始：

1. 在 `shared` 中定义 `SpaceSummary`、`SpaceMembership`、`JoinRequest`、`SpaceScopedSession` 和 Multiverse API 类型。
2. 在 `shared` 中统一 UUID、Ethereum 风格 `space_address` 和 EIP-55 校验/规范化逻辑，地址只定位不授权。
3. 在 `server/src/db.ts` 建立 schema version 和 `spaces/space_members`，先完成 legacy Space 迁移。
4. 把 `server/src/config.ts` 的全局 `ServerConfig.space_id` 改成 server capabilities/config，不再代表业务 Space。
5. 把 `auth.ts`、`devices.ts`、`messages.ts`、`attachments.ts`、`escrow.ts`、`ws.ts` 的权限边界改为 session Space 上下文。
6. 先用 CLI 做两个 Space 的隔离 e2e，再改 App 的向导；否则 UI 看似完成但底层仍是单租户。
7. App 最后接入唯一 Space Profile 和首屏流程，并补迁移测试、Widget 测试和真机测试。

## 12. 当前建议的产品决策

为了控制第一版复杂度，建议先采用：

- Space Address：使用同一套 Space Identity Key 派生 canonical Ethereum 风格地址（`0x` + 20 字节 Keccak-256 + EIP-55 checksum）；后续可以从同一公钥派生其他版本地址，但必须保留版本和 alias，不改变旧地址语义；
- Custom ID：可选、精确查找、不能单独授权；
- 加入授权：创建者确认 + 一次性 join token；
- Space Key：继续使用独立的随机对称 Space Content Key，不把非对称 Space 私钥当作内容密钥；
- Space Identity Key：先不做完整签名体系，保留字段和版本位；
- 每个 Device：只能绑定一个 Space；多个 Device 是否属于同一个人由用户在线下控制，Device 可以分别绑定同一个或不同的 Space；
- PIN：一个本机 PIN 解锁唯一 Space 的加密凭证；
- Server：先保持 Node + SQLite 单实例，优先做正确的租户隔离和迁移，再扩容；
- 用户发现：不做全球公开搜索，只允许精确地址/custom ID lookup；
- 旧单空间：迁移成一个普通 Space，不要求用户重新注册。

这套方案能实现“全球用户共享同一 Einz 服务、每个 Space 仍然只有两个人”，同时保留当前 E2EE、Local-First、Server 只存密文的核心原则。
