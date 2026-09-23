# Einz — 部署手册（docs/DEPLOYMENT.md）

> **状态：** v1.0（Phase 0–4 完成后整理，命令均经本机实测）
> **适用场景：** 从零部署 Einz 并开始试用——服务器（Docker Compose + Caddy 或裸 Node）+ 两台设备（当前 CLI 测试端 / Flutter App）。
> **关联文档：** `docs/E2EE.md`（密码学）、`docs/PROTOCOL.md`（协议）、`docs/DATABASE.md`（存储）、`docs/ONBOARDING.md`（AB 互通操作手册）。

---

## 1. 部署形态（先读，避免误解）

```text
┌─────────────┐   REST / WS   ┌──────────────┐   REST / WS   ┌─────────────┐
│  设备 A      │◄────────────►│  Server       │◄────────────►│  设备 B      │
│  (TUI/App)  │  只见密文     │  在册设备表   │  只见密文     │  (TUI/App)  │
└─────────────┘   E2EE        │  哑转发器     │   E2EE        └─────────────┘
                              └──────────────┘
```

- **一个空间 = 两个人**（`space_members` 两个身份槽位），同一身份可多台设备；一个 Server
  可承载**多个互不可见的空间**（Multiverse，2026-09-12 起）。
- **E2EE 全链路**：Server 只见密文（消息、附件均为密文 + 元数据）。
- **设备白名单在数据库里**（`devices` 表）：设备由 `POST /spaces` / `POST /spaces/join`
  自助登记，无需服务器配置文件；未登记/已撤销设备一律拒绝（401/403）。
- **撤销语义**：撤销 = 标记 `revoked` + 清会话/Push Token + WS 断开；**不**轮换 Space Key
  （见 `docs/SECURITY.md` §3）。

**仓库角色速览：**

| 目录          | 角色                                                  | 运行方式                                       |
| ------------- | ----------------------------------------------------- | ---------------------------------------------- |
| `server/`     | Node.js + TypeScript 哑转发器                         | `npm run build && node dist/app.js`，或 Docker |
| `shared/`     | 纯 Dart 核心（crypto/protocol/sync），CLI 与 App 共用 | 库，不独立运行                                 |
| `cli/`        | Dart **TUI** 客户端（最完整的客户端实作）             | `dart run bin/einz_tui.dart --store <store> --server <url>` |
| `app/`        | Flutter 手机客户端（V1 骨架 + 本地库）                | `flutter run`（真机验证待环境）                |
| `deployment/` | Docker Compose + Caddy（生产单机部署）                | `docker compose up -d`                         |

---

## 2. 快速试用（本机 5 分钟，无 Docker）

> 前置：Node ≥ 20、Dart ≥ 3.12；libsodium（Windows 需设 `LIBSODIUM_PATH`，见 §7）。
> **不需要任何服务器配置文件**：设备登记与白名单都在数据库里，由客户端自助完成
> （Multiverse）。v1 时代的静态白名单 `server/config/config.json` 与脚本 CLI
> `cli/bin/einz.dart` 已随 2026-09-15 收敛删除。

### 2.1 启动服务器

```bash
cd server
npm install
npm run build            # tsc 编译到 dist/
node dist/app.js         # 默认 :3000；PORT=3000 可指定；数据落在 server/data/
```

看到 `[einz] server listening on :3000` 即就绪。`GET /health` 返回
`{ "status": "ok", "protocol_version": "v2-multiverse", "capabilities": [...] }`。

### 2.2 两台设备接入（TUI）

**终端 A —— 第一台设备（创建秘境）：**

```bash
cd cli && dart pub get
dart run bin/einz_tui.dart --store /tmp/a.json --server http://localhost:3000
```

按引导走：选 `c` 创建秘境 → 输入我的名字/性别、伴侣名字/性别 → 设置共享口令 →
客户端生成 Space Key、上传口令密保箱、签发会话，直接进入会话（状态栏 ● 在线）。
在会话里执行 `/invite` 会打印**邀请链接**（`https://<host>/join/<token>`，24 小时一次性）。

**终端 B —— 第二台设备（加入秘境）：**

```bash
dart run bin/einz_tui.dart --store /tmp/b.json --server http://localhost:3000
```

选 `j` 加入 → 粘贴 A 给的邀请链接（或令牌）→ 选择自己是哪一个身份（1/2）→
输入 A 设置的共享口令（用它从口令密保箱取回 Space Key，同时完成设备登记 + 签发会话）→
进入会话。

> `server/config/serverConfig.json`（不入 git，可选）里 `maxSpaces` 控制**新空间数量上限**：
> `0`=不限、`1`=退回单空间、`n`=最多 n 个；改后重启生效。当前为 `0` 时服务端启动会打一条
> "等于对公网开放建空间"的告警——自用建议设成 1~2。

### 2.3 双端收发

TUI 里**直接输入文字回车即发送**（无需子命令）；对方在线时经 WS 实时到达，离线时下次
`/sync` 或下次启动自动补齐。图片/视频/语音/文件用输入栏的「+」面板或 `/attach <file>`；
点消息里的附件编号用 `/open <序号>` 打开。

App 端同理：设置页选「创建秘境」或「加入秘境」，扫令牌二维码 / 粘贴邀请链接，再输共享口令。

**TUI 命令总览**（`/help` 也能看）：

| 命令 | 用途 |
| --- | --- |
| `/space` | 空间状态 / `/space create` 新建 / `/space join <链接>` 加入 |
| `/invite` | 生成一次性邀请链接（24h，凭它可开通一条新通道） |
| `/auth` | 激活/续期会话（challenge-response，对**当前**服务器） |
| `/passphrase [random]` | 设置/修改共享口令（`random` 生成随机 12 词） |
| `/pin` | 设置/修改启动锁 PIN |
| `/devices` | 列出秘境内的设备与在线状态 |
| `/device <名称>` / `/myname <名称>` | 改本设备名 / 改自己的显示名 |
| `/sync` / `/history` | 手动增量同步 / 看本地解密历史 |
| `/attach <file>` / `/open <序号>` | 上传附件 / 打开消息里的附件 |
| `/backup` | 导出加密备份（12 词恢复码） |
| `/server [url]` | 不带参数 = 显示当前服务器地址；带地址 = 切换本次会话的服务器（仅本次生效，不落盘） |
| `/status` | 排障快照（只读）：服务器地址与来源、线路、实时连接、对方在线、绑定、设备、同步锚点、数据文件路径 |
| `/exit` | 退出 |

> 更完整的操作手册见 `docs/ONBOARDING.md`；协议细节见 `docs/PROTOCOL.md`。

## 3. 生产部署（Docker Compose + Caddy，单机）

### 3.1 目录与前置

```text
deployment/
├── Caddyfile             # 域名 + TLS 自动签发 + 反代 + WSS 升级
├── docker-compose.withcaddy.yml  # 模板：内置 caddy + server 两个服务（部署时拷贝为 docker-compose.yml）
├── docker-compose.nocaddy.yml    # 模板：无内置 Caddy，由系统级 Caddy 反代 127.0.0.1:3000（可选）
├── config/               # 可选：serverConfig.json（服务端参数，见下；整个目录已 gitignore）
└── data/                 # 数据卷映射：einz.sqlite.db + files/ + backups/
```

前置：一台 VPS（域名 DNS 指向它，开放 80/443）、Docker + Compose。

**服务端配置（可选）**：`deployment/config/serverConfig.json` 会被挂到容器
`/config/`，由 `EINZ_CONFIG` 指向——当前唯一字段 `maxSpaces`（新空间数量上限：
`0`=不限、`1`=退回单空间、`n`=最多 n 个；改后**重启容器**生效）。文件不存在时服务端
照常启动（走默认值 `0`）。示例：

```bash
mkdir -p deployment/config
echo '{"maxSpaces": 1}' > deployment/config/serverConfig.json
```

> 本机开发（非 Docker）同理：放 `server/config/serverConfig.json`（同名字段、
> 同样不入 git，见 §2.2）——两种形态都是"config/ 目录 + serverConfig.json"，
> 只是部署时由 `EINZ_CONFIG` 指到容器里的 `/config/`。

### 3.2 部署步骤

```bash
# 1) 改域名：deployment/Caddyfile 中 private.example.com → 你的域名

# 3) 备份密钥：生成 32 字节 base64 密钥（npm run backup 需要，见 §5）
python3 -c "import os,base64;print(base64.b64encode(os.urandom(32)).decode())"
# 记下输出，写入服务器环境（例如 docker-compose.yml 或 .env，勿入库）

# 4) 起服务
cd deployment
EINZ_DB_BACKUP_KEY=<上一步输出> docker compose up -d --build
docker compose ps                       # 两个服务均 healthy/running
```

> 说明：`docker-compose.yml` 已预置 `EINZ_DB_BACKUP_KEY=${EINZ_DB_BACKUP_KEY}` 注入
> （由 compose 自动读取 `deployment/.env` 提供，.env 已在 .gitignore、不入库）。
> 未设置时 `npm run backup` 会拒绝执行（防误备份明文）。

### 3.3 验证部署

```bash
# 健康检查（免协议版本头）
curl -s https://<你的域名>/health | head -c 200       # 期望 {"status":"ok",...}
# 域名解析 + TLS 正常（应返回鉴权错误而非连接失败；注意要带协议版本头）
curl -s -H 'X-Protocol-Version: 1' https://<你的域名>/space | head -c 200   # 期望 401/403 JSON
# 缺协议版本头 → 400（硬校验）
curl -s -o /dev/null -w '%{http_code}\n' https://<你的域名>/space            # 期望 400
# 未登记设备拒绝（dev-evil 不在 devices 表）
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST https://<你的域名>/auth/challenge \
  -H 'Content-Type: application/json' -H 'X-Protocol-Version: 1' \
  -d '{"device_id":"dev-evil","space_id":"whatever"}'   # 期望 403
```

客户端改用 `--server https://<你的域名>`（TUI）/ 设置页填域名（App）即可远程使用（WS 自动为 `wss://`）。

### 3.4 端口与数据目录

| 项               | 位置（容器内）           | 说明                                         |
| ---------------- | ------------------------ | -------------------------------------------- |
| `einz.sqlite.db` | `/data/einz.sqlite.db`   | SQLite（消息密文、设备表、会话、push token） |
| 附件 blob        | `/data/files/`           | 密文文件，按 attachment_id 前 2 位分片       |
| 备份产物         | `/data/backups/`         | `npm run backup` 的加密归档                  |
| 空间与成员       | `/data/einz.sqlite.db`   | `spaces` / `space_members` / `join_tokens` 同库 |
| 服务端口         | `3000`（expose，仅内网） | 由 Caddy 反代对外                            |

---

## 4. 接入闭环（v2 要点）

v1 时代那份《一次性配置手册》（静态白名单 config.json + 密保信封离线分发 Space Key 的
设计稿）已随 Multiverse 删除——当前流程看 `docs/ONBOARDING.md` 与本文 §2.2。要点重申：

1. **身份密钥**：客户端首启生成 X25519 密钥对，私钥只留在设备（App 用 Keychain/Keystore，
   TUI store 是明文 JSON 的测试驱动）。
2. **Space Key 分发**：创建者本地生成 32B Space Key，用**口令（Argon2id）加密**成密保箱托管
   到 Server（`POST /spaces` 创建时一并上传）；加入方用同一口令取回
   （`POST /spaces/{id}/key-escrow`，免认证、防爆破靠限速）。另有密保信封（用对方公钥
   `crypto_box_seal` 密封）作为离线备用路径（E2EE.md §7.1）。
3. **设备登记**：由 `POST /spaces`（创建者）/ `POST /spaces/join`（凭一次性 join token）完成，
   同时签发绑定该空间的会话——不再有独立的登记步骤，也没有静态白名单文件。
4. **恢复码**：TUI `/backup` 生成 12 词恢复码（E2EE.md §10；App 侧导出入口已删），
   **离线保存多份，Server 不接触**。

> 安全操作建议：口令、设备私钥、恢复码三者分开存放——任一单独泄露都不足以解密历史消息。

---

## 5. 运维手册

### 5.1 服务器备份 / 恢复（SQLite Backup API + 加密归档）

```bash
cd server   # 或 docker compose exec server npm run backup

# 备份（需 EINZ_DB_BACKUP_KEY，base64 32B）
export EINZ_DB_BACKUP_KEY="<部署时生成的密钥>"
npm run backup -- --verify
# 产物：data/backups/backup-<ts>.json（AES-256-GCM 加密的 einz.sqlite.db + files/）

# 恢复（覆盖当前数据，先停服务再执行）
npm run restore -- data/backups/backup-<ts>.json
```

- 恢复会**先删后写**：`files/` 整个清空重建，库写到 `EINZ_DB` 指向的文件
  （默认 `data/einz.sqlite.db`，连 `-wal`/`-shm` 一起删，避免旧 WAL 被重放进恢复的库）。
  备份里的 `app.db` 只是内部条目名，不是落盘文件名。

- **为什么用 SQLite Backup API**：`einz.sqlite.db` 运行中直接复制可能损坏；Backup API 在线备份安全（DATABASE.md §6）。
- **演练建议**：定期执行"备份 → 删除 data → 恢复 → 重启验证消息仍在"（Phase 4 已提供完整演练流程，见 `cli/test/phase4_e2e.sh` 步骤 9–10 及 worklog）。
- **备份密钥保管**：与服务器数据分开存放（如密码管理器）；丢失密钥 = 备份不可恢复。

### 5.2 客户端备份 / 恢复（恢复码，模型 A）

**导出**：TUI 里 `/backup`（生成 12 词恢复码）。⚠️ App 侧的恢复码导出入口已按老板决策删除
（`app_lock.dart`：PIN 丢失即无法解锁本设备密钥包），所以**恢复码目前只能从 TUI/CLI 侧产生**。
⚠️ 恢复码打印后请立即离线妥善保存（丢失即无法恢复）。

**换机恢复**：新设备先正常接入（`/space join` 拿回 Space Key）后，用恢复码在 App 里
导入历史备份（E2EE.md §10.2）。v1 时代的 `einz.dart backup/restore` 命令行已随脚本 CLI
删除。

### 5.3 设备撤销（**不**轮换 Space Key）

**场景：** 手机丢失/失窃 → 撤销该设备，阻止它继续收新消息。

```bash
# 1) 撤销某台设备（POST /devices/<device_id>/revoke）：标记 revoked + 清 Push Token +
#    清会话，并关闭它的 WS 连接（Server 不再下发 key.rotation —— 轮换方案已决定不做）
#    **必须带共享口令**（2026-09-16）：撤销会让该设备自毁本地数据，属不可逆操作。
#    授权范围 = 同 space 内可互撤（自己的另一台设备，或伴侣的设备）。
curl -X POST http://127.0.0.1:3000/devices/dev-b1/revoke \
  -H "Authorization: Bearer <A的session_token>" \
  -H "Content-Type: application/json" \
  -d '{"passphrase":"<共享口令>"}'

# 2) 完成——撤销实时生效，不需要重启服务器、也不需要改任何配置文件
```
- device_id 是 UUID（`GET /devices` 可见），不是 `dev1/dev2` 那种序号（v1 遗留叫法）。
- 口令错 → `401 ESCROW_VERIFY_FAILED`（设备毫发无损）；同空间口令尝试过多 → `429`；
  空间还没设置共享口令 → `409 PASSPHRASE_NOT_SET`（先在任一在册设备上 `/passphrase` 设置）。

- 被撤销设备：无法认证（403 `DEVICE_REVOKED`）/ 同步 / 发送；其旧 WS 连接已被服务端关闭。
- 被撤销设备**上线即自毁本地数据**（App `_onDeviceRevoked`：清锁包 + 消息 + 附件 + 媒体缓存；
  TUI `_exitRevoked`：清 store 文件 + 附件缓存后退出）。
- **别把"清空/重置服务端库"当撤销手段**：库一清，设备行就不存在了，客户端只会收到
  403 `FORBIDDEN`（未登记）→ 按 2026-09-16 的语义**只警告、不清本地数据**，用户仍能看本地历史。
  要真正撤销请用 §5.3 的 `POST /devices/:id/revoke`（带共享口令；那才会发 `device.revoked` /
  返回 `DEVICE_REVOKED`）。
- **不需要**轮换 Space Key：撤销的效力来自设备被标记 `revoked`（它取不到新密文）+ 自毁。
  怀疑密钥材料被提取（越狱/镜像泄露）时的止损流程见 `docs/SECURITY.md` §4.2（替代方案 = 重建空间）。
- 已同步的历史密文不可追回（设备端已解密数据的固有属性）。

### 5.4 数据目录备份策略（汇总）

| 数据                                   | 手段                                    | 频率建议        |
| -------------------------------------- | --------------------------------------- | --------------- |
| Server einz.sqlite.db + files          | `npm run backup`（加密归档到 backups/） | 每日（可 cron） |
| 客户端密钥 + 历史                      | `backup` 命令（恢复码加密）             | 每次重大变更后  |
| 恢复码 / 备份密钥                      | 离线多份                                | 永久            |

---

## 6. 安全边界清单（V1 发布前已审查加固）

| 边界           | 机制                                                                            | 说明                                                |
| -------------- | ------------------------------------------------------------------------------- | --------------------------------------------------- |
| 设备在册状态   | `devices` 表 + `isActiveDevice`（v2：由 spaces create/join 自助登记）           | 未登记设备 403；撤销后立即拒绝认证/同步/发送        |
| 服务端只见密文 | E2EE 全链路（消息/附件均为密文 + 元数据）                                       | `messages` 表只有 ciphertext（冒烟测试验证）        |
| 路径遍历       | `attachment_id` 字符集白名单 + `resolve` 路径包含检查（读写双侧）               | 失陷白名单设备也无法越出`files/`（V1 审查 P1 修复） |
| WS 撤销实时性  | 撤销即关闭被撤销设备连接（close 4403）                                          | 无法继续收新消息广播（P2 修复）                     |
| 备份加密       | Server 备份 AES-256-GCM（`EINZ_DB_BACKUP_KEY`）；客户端备份恢复码 Argon2id 派生 | 备份文件离库不泄露                                  |
| 供应链         | Gradle 镜像`distributionSha256Sum` 锁定官方校验和                               | 构建工具链不可被镜像篡改（P3 修复）                 |
| 认证           | challenge-response（一次性、5 分钟过期）；session_token 服务端签发              | 防重放                                              |
| 前向保密       | Space Key 简单派生（已接受的代价，E2EE.md §11.1）                               | 安全存储隔离；不轮换的取舍见 SECURITY.md §3        |

**威胁模型提醒（SECURITY.md §3/§4.1）：** 被撤销设备已持有的历史密文无法收回（设备端已解密数据的固有属性）；它读不到**之后**的新消息，靠的是设备在册状态（`/sync` 403）而非轮换。

---

## 7. 故障排查

| 症状                                   | 原因                                                      | 处理                                                        |
| -------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------- |
| Server 起不来 / 端口占用               | 端口被占或 Node 版本过低（需 ≥20）                        | 换 `PORT=`；`node -v` 确认版本                              |
| `curl /space` 401/403                  | 正常（未认证）                                            | 按 §3.3 验证                                                |
| CLI 报 libsodium 加载失败              | 未设`LIBSODIUM_PATH`（或 libsodium 装在非标准路径）       | `export LIBSODIUM_PATH="/opt/homebrew/lib/libsodium.dylib"` |
| `/auth` 失败 403 `FORBIDDEN`           | 设备未登记（常见：**服务端库被清空/重置**，或换了新库）    | 客户端只警告、数据不丢；查 devices 表是否有该 device_id。库被重置时用备份恢复库，或让设备重新 `/space join` |
| `/auth` 失败 403 `DEVICE_REVOKED`      | 该设备已被明确撤销（§5.3）                                | 设备端已自毁本地数据，只能重新 `/space join` 入网           |
| 发消息一直"发送中"                    | WS 未连上 / 会话失效                                      | `/auth` 重新激活；或看服务端日志 `[req] WS /ws connect`     |
| `/sync` 拉不到对方消息                 | 锚点已推进 / 网络 / 设备被撤销                            | 用 `/sync` 前先在本地库清锚点排查（或看服务端审计表）        |
| `fetch` 报 sha256 不匹配               | 附件密文损坏或元数据过期                                  | 重新`sync` 拉元数据后重试                                   |
| WS 连不上                              | 反代未开 WSS / token 未 URL 编码                          | 检查 Caddy；token 含`+`/`=` 需编码（客户端自动处理）        |
| `flutter analyze`/`build` 中文路径报错 | 仓库路径含非 ASCII（已知缺陷）                            | 拷贝到纯 ASCII 路径构建（如`/tmp/einz-build`），产物拷回    |
| 撤销后设备仍能认证                     | Server 版本过旧（未含 Phase 4 撤销感知）                  | 重新`npm run build` 部署                                    |
| 备份命令拒绝执行                       | 未设置`EINZ_DB_BACKUP_KEY`                                | 设置 base64 32B 密钥（§3.2/§5.1）                           |

---

## 8. 验收清单（部署完成后逐项打勾）

- [ ] `https://<域名>/space` 返回鉴权错误（TLS 正常）
- [ ] 未登记设备认证 403
- [ ] A→B 发消息，B 同步解出明文；Server 数据库无明文
- [ ] `listen` 实时收到 `message.new`
- [ ] 附件上传→下载解密与原文件一致
- [ ] `npm run backup -- --verify` 成功；恢复演练通过
- [ ] `backup`/`restore`（恢复码）闭环通过
- [ ] 撤销 B：B 认证 403 / 同步 403；A 无需轮换（撤销即阻断 B 取新密文）

## 9. 版本升级（新代码上线）

> 原则：Server 代码变更均为**向后兼容**（新增表/端点，存量接口与数据不动）。
> 新表由 `CREATE TABLE IF NOT EXISTS` 在启动时自动创建，**无需手动迁移**。

### 9.1 代码传输：git pull（主推）——VPS 一次性初始化

> 前置：VPS 已装 git；本地化文件（`deployment/.env`、`server/data/`、`*.db`）
> 均已被仓库 .gitignore 忽略，git 操作不会触碰——**唯一例外是 `deployment/Caddyfile`**
> （仓库内为占位域名 `private.example.com`，VPS 部署时已 sed 为真实域名），需标记
> `assume-unchanged` 防 pull 覆盖。

```bash
# VPS 一次性（把现有部署目录转换为 git 工作树；server/ deployment/ 等
# 会被仓库版本对齐覆盖，data/ .env 等本地数据不受影响）
export EINZ_ROOT=/opt/einz
cd $EINZ_ROOT
git init
git remote add origin https://git.tic.cc/fon/only
git fetch origin
git checkout -b main origin/main
git update-index --assume-unchanged deployment/Caddyfile   # Caddyfile 保留 VPS 域名，pull 不覆盖
git status --short                                          # 应只显示本地未跟踪项（data/ .env 等）
```

> 说明：`git checkout -b main origin/main` 会把仓库代码写入工作树并覆盖同名旧文件
> （server/、deployment/ 等对齐到仓库版本）；本地数据文件因 .gitignore 而保持不动。

### 9.2 每次更新：本机 push → VPS pull → 重建 server 容器

```bash
# 本机（macOS/Linux）：新代码提交并推送到远程仓库
cd /Users/Shared/productX/only
git push origin main
```

```bash
# VPS：拉取 → 重建 server 容器（server 代码进镜像，必须 --build）
cd $EINZ_ROOT
git pull --ff-only
cd deployment
docker compose up -d --build server
docker compose ps                                       # 确认 server 重新 running/healthy
```

> Caddy 容器与 `deployment/.env`（备份密钥、域名等）无需改动。

### 9.3 验证新端点

```bash
# 新端点已注册（401 = 端点活；404 = 尚未生效）
curl -s -o /dev/null -w "%{http_code}" https://einz.tic.cc/key-escrow
```

### 9.4 客户端实测（以口令托管为例，本机 macOS/Linux）

命令行的等价路径已随脚本 CLI 删除，改用 TUI：

```bash
cd cli
dart run bin/einz_tui.dart --store /tmp/a.json --server https://einz.tic.cc
# 会话里执行 /passphrase 设置或修改共享口令（含密保箱重建）
```

### 9.5 升级注意事项

| 项                       | 说明                                                                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 存量数据                 | 不受影响（messages/devices/会话等全部不动，新表初始为空）                                                                                                |
| 设备在册状态             | 无需改动（既有设备与会话不受影响）                                                                                                                         |
| Caddy / HTTPS / 备份密钥 | 均无需改动（Caddyfile 已 assume-unchanged，pull 不覆盖）                                                                                                 |
| App 侧                   | 需重新安装 APK 才能启用新 UI（CLI 不受影响）                                                                                                             |
| 回滚                     | `cd $EINZ_ROOT && git log --oneline -5` 找上一版本 → `git checkout <commit> -- server/ deployment/ shared/` → 重新 `docker compose up -d --build server` |
