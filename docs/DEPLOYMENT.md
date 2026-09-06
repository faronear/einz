# Einz — 部署手册（docs/DEPLOYMENT.md）

> **状态：** v1.0（Phase 0–4 完成后整理，命令均经本机实测）
> **适用场景：** 从零部署 Einz 并开始试用——服务器（Docker Compose + Caddy 或裸 Node）+ 两台设备（当前 CLI 测试端 / Flutter App）。
> **关联文档：** `docs/E2EE.md`（密码学）、`docs/PROTOCOL.md`（协议）、`docs/DATABASE.md`（存储）、`docs/SETUP.md`（一次性配置的设计稿；本文档给出命令级实作）。

---

## 1. 部署形态（先读，避免误解）

```text
┌─────────────┐   REST / WS   ┌──────────────┐   REST / WS   ┌─────────────┐
│  设备 A      │◄────────────►│  Server       │◄────────────►│  设备 B      │
│  (CLI/App)  │  只见密文     │  静态白名单   │  只见密文     │  (CLI/App)  │
└─────────────┘   E2EE        │  哑转发器     │   E2EE        └─────────────┘
                              └──────────────┘
```

- **固定两人一空间**：一个 `space_id` 对应两台设备（A/B），无动态配对。
- **E2EE 全链路**：Server 只见密文（消息、附件均为密文 + 元数据）。
- **静态白名单**：`config.json` 声明可信设备；不在其中的设备一律拒绝（403）。
- **撤销语义**：撤销 = 白名单移除 + 清会话/Push Token + WS 断开 + 通知剩余设备轮换 Space Key（E2EE.md §9）。

**仓库角色速览：**

| 目录          | 角色                                                  | 运行方式                                       |
| ------------- | ----------------------------------------------------- | ---------------------------------------------- |
| `server/`     | Node.js + TypeScript 哑转发器                         | `npm run build && node dist/app.js`，或 Docker |
| `shared/`     | 纯 Dart 核心（crypto/protocol/sync），CLI 与 App 共用 | 库，不独立运行                                 |
| `cli/`        | Dart CLI 测试端（当前最完整的客户端实作）             | `dart run bin/einz.dart <命令>`                |
| `app/`        | Flutter 手机客户端（V1 骨架 + 本地库）                | `flutter run`（真机验证待环境）                |
| `deployment/` | Docker Compose + Caddy（生产单机部署）                | `docker compose up -d`                         |

---

## 2. 快速试用（本机 5 分钟，无 Docker）

> 前置：Node ≥ 20、Dart ≥ 3.12；libsodium（Windows 需设 `LIBSODIUM_PATH` 指向 `libsodium.dll`，见下文）。

### 2.1 准备两个终端

**终端 A（服务器）：**

```bash
cd server
npm install
npm run build            # tsc 编译到 dist/
cp config/config.json.example config/config.json   # 占位配置，稍后用 CLI 生成真实白名单
```

**终端 B（配置 + 设备，用 CLI）：**

```bash
cd cli
dart pub get
```

> macOS/Linux 提示：若 CLI 报 libsodium 加载失败，先设置
> `export LIBSODIUM_PATH="/opt/homebrew/lib/libsodium.dylib"`（Homebrew 安装一般自动探测，无需设置）。

### 2.2 生成两台设备身份 + 一次性配置（白名单 + Space Key 分发）

CLI 命令（在 `cli/` 目录，下面 `$W` 是临时工作目录，如 `/tmp/einz-trial`）：

```bash
W=/tmp/einz-trial && mkdir -p $W

# 1) 设备 A/B 各自生成 X25519 身份密钥（私钥只留在本机 store）
dart run bin/einz.dart init --store "$W/a.json" --device-id dev-a1
dart run bin/einz.dart init --store "$W/b.json" --device-id dev-b1

# 2) 取 B 的公钥，A 侧生成 Space Key 并输出：
#    - config.json（服务器白名单 + space_id）
#    - envelope-b.txt（密钥信封：密封给 B 的 Space Key 副本）
PUB_B="$(dart run bin/einz.dart pubkey --store "$W/b.json")"
dart run bin/einz.dart config \
  --store "$W/a.json" --peer-pubkey "$PUB_B" \
  --space-id "space-demo" \
  --out-config "$W/config.json" --out-envelope-peer "$W/envelope-b.txt"

# 3) B 导入密钥信封，解出 Space Key
dart run bin/einz.dart import \
  --store "$W/b.json" --envelope-file "$W/envelope-b.txt" --space-id "space-demo"
```

产物（**config.json 禁止提交 Git**，私钥/恢复码离线保管）：

| 产物                      | 内容                               | 去向                              |
| ------------------------- | ---------------------------------- | --------------------------------- |
| `$W/config.json`          | space_id + A/B 白名单              | 服务器`server/config/config.json` |
| `$W/envelope-b.txt`       | 密钥信封（密封 Space Key，仅 B 可解）  | 导入 B 后删除                     |
| `$W/a.json` / `$W/b.json` | 设备 store（身份密钥 + Space Key） | 本机保存                          |

### 2.3 启动服务器并双端收发

```bash
# 终端 A：把生成的 config.json 拷到 server/config/ 后启动
cp "$W/config.json" server/config/config.json
cd server && node dist/app.js          # 默认 :3000；可用 PORT=3000 指定
```

```bash
# 终端 B：双端认证 + 发消息 + 同步
dart run bin/einz.dart auth  --store "$W/a.json" --server http://127.0.0.1:3000
dart run bin/einz.dart send  --store "$W/a.json" --server http://127.0.0.1:3000 --message "你好，B！"
dart run bin/einz.dart sync  --store "$W/b.json" --server http://127.0.0.1:3000   # B 应解出明文
```

**实时聊天（WS）：** 终端 1 跑 `listen`，终端 2 发消息，实时收到：

```bash
dart run bin/einz.dart listen --store "$W/b.json" --server http://127.0.0.1:3000
# 另开终端：
dart run bin/einz.dart send --store "$W/a.json" --server http://127.0.0.1:3000 --message "实时消息"
```

**发图片/语音（附件）：**

```bash
dart run bin/einz.dart attach --store "$W/a.json" --server http://127.0.0.1:3000 \
  --file ./photo.jpg --type image --caption "看看这个"
dart run bin/einz.dart fetch --store "$W/b.json" --server http://127.0.0.1:3000 \
  --attachment-id <附件ID> --out ./photo-b.jpg     # 下载→sha256 校验→解密→写文件
```

**CLI 命令总览：**

| 命令                                                                                            | 用途                                                           |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `init --store <s> --device-id <id>`                                                             | 生成本机身份密钥对                                             |
| `pubkey --store <s>`                                                                            | 导出公钥（base64）                                             |
| `config --store <s> --peer-pubkey <b64> --space-id <id> --out-config <c> --out-envelope-peer <f>` | 生成 Space Key + 白名单 + 密钥信封                            |
| `import --store <s> --envelope-file <f> --space-id <id> [--key-version N]`                     | 导入密钥信封（轮换导入用 --key-version）                       |
| `auth --store <s> --server <url>`                                                               | challenge-response 认证，拿 session_token                      |
| `send --store <s> --server <url> --message <文本>`                                              | 加密发送（先入队，失败自动补发；`--server` 可省略=纯离线入队） |
| `sync --store <s> --server <url> [--after N]`                                                   | 增量同步（翻页拉全量 → 落库 → 推进锚点 → 补发队列）            |
| `listen --store <s> --server <url>`                                                             | WS 实时接收 message.new（断线 2s 重连，重连前先 /sync 补齐）   |
| `attach --store <s> --server <url> --file <p> [--type image\|video\|voice] [--caption <t>]`     | 附件加密上传                                                   |
| `fetch --store <s> --server <url> --attachment-id <id> [--out <p>]`                             | 附件下载解密                                                   |
| `history --store <s>`                                                                           | 解密本地历史（按 key_version 选密钥）                          |
| `rotate --store <s> --peer-pubkey <b64> --out-envelope-peer <f>`                               | 轮换 Space Key（key_version+1，旧密钥归档）                    |
| `backup --store <s> --out <f>`                                                                  | 本地加密备份（生成 12 词恢复码）                               |
| `restore --in <f> --recovery-code <12词> [--store <s>]`                                         | 恢复码解密还原                                                 |

> 其余部分（生产部署 / 备份恢复 / 撤销轮换 / 安全边界 / 故障排查）见下节。

---

## 3. 生产部署（Docker Compose + Caddy，单机）

### 3.1 目录与前置

```text
deployment/
├── Caddyfile             # 域名 + TLS 自动签发 + 反代 + WSS 升级
├── docker-compose.withcaddy.yml  # 模板：内置 caddy + server 两个服务（部署时拷贝为 docker-compose.yml）
├── docker-compose.nocaddy.yml    # 模板：无内置 Caddy，由系统级 Caddy 反代 127.0.0.1:3000（可选）
├── config/config.json    # 白名单（禁止提交 Git；由 2.2 生成后拷入）
└── data/                 # 数据卷映射：einz.sqlite.db + files/ + backups/
```

前置：一台 VPS（域名 DNS 指向它，开放 80/443）、Docker + Compose。

### 3.2 部署步骤

```bash
# 1) 按 2.2 生成 config.json（或用后续 3.3 的命令级流程）
cp "$W/config.json" deployment/config/config.json

# 2) 改域名：deployment/Caddyfile 中 private.example.com → 你的域名

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
# 域名解析 + TLS 正常（应返回鉴权错误而非连接失败）
curl -s https://<你的域名>/space | head -c 200        # 期望 401/403 JSON
# 白名单外设备拒绝（dev-evil 未登记）
curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST https://<你的域名>/auth/challenge \
  -H 'Content-Type: application/json' -d '{"device_id":"dev-evil"}'   # 期望 403
```

CLI 设备改用 `--server https://<你的域名>` 即可远程使用（WS 地址自动为 `wss://`）。

### 3.4 端口与数据目录

| 项        | 位置（容器内）           | 说明                                         |
| --------- | ------------------------ | -------------------------------------------- |
| `einz.sqlite.db`  | `/data/einz.sqlite.db` | SQLite（消息密文、设备表、会话、push token） |
| 附件 blob | `/data/files/`           | 密文文件，按 attachment_id 前 2 位分片       |
| 备份产物  | `/data/backups/`         | `npm run backup` 的加密归档                  |
| 白名单    | `/config/config.json`    | 只读挂载，启动时加载                         |
| 服务端口  | `3000`（expose，仅内网） | 由 Caddy 反代对外                            |

---

## 4. 一次性配置（命令级实作，替代 SETUP.md 的"[待开发]"标注）

SETUP.md §3 的设计流程已由 CLI 实现（2.2 已演示）。要点重申：

1. **身份密钥**：`init` 生成 X25519 密钥对，私钥只留在设备 store。
2. **Space Key 分发**：`config` 生成 32B 随机 Space Key，分别 `crypto_box_seal` 给 A/B——只有对应设备能解开（E2EE.md §7.1）。
3. **白名单登记**：`config.json`（space_id + devices）放进服务器后启动；`syncWhitelistToDb` 会在启动时登记进 devices 表，撤销状态不被覆盖（Phase 4 加固）。
4. **导入与销毁**：`import` 解封后删除密钥信封临时文件。
5. **恢复码**：`backup` 命令会生成 12 词恢复码（E2EE.md §10），**离线保存多份，Server 不接触**。

> 安全操作建议：密钥生成/密封/导入在受控环境进行；`config.json`、设备私钥、恢复码三者分开存放——任一单独泄露都不足以解密历史消息。

---

## 5. 运维手册

### 5.1 服务器备份 / 恢复（SQLite Backup API + 加密归档）

```bash
cd server   # 或 docker compose exec server npm run backup

# 备份（需 EINZ_DB_BACKUP_KEY，base64 32B）
export EINZ_DB_BACKUP_KEY="<部署时生成的密钥>"
npm run backup -- --verify
# 产物：data/backups/backup-<ts>.json（AES-256-GCM 加密的 einz.sqlite.db + files/ + config.json）

# 恢复（覆盖当前数据，先停服务再执行）
npm run restore -- data/backups/backup-<ts>.json
```

- **为什么用 SQLite Backup API**：`einz.sqlite.db` 运行中直接复制可能损坏；Backup API 在线备份安全（DATABASE.md §6）。
- **演练建议**：定期执行"备份 → 删除 data → 恢复 → 重启验证消息仍在"（Phase 4 已提供完整演练流程，见 `cli/test/phase4_e2e.sh` 段 7–8 及 worklog）。
- **备份密钥保管**：与服务器数据分开存放（如密码管理器）；丢失密钥 = 备份不可恢复。

### 5.2 客户端备份 / 恢复（恢复码，模型 A）

```bash
# 设备导出（生成 12 词恢复码，离线保存）
dart run bin/einz.dart backup --store "$W/a.json" --out "$W/backup-a.json"
# ⚠️ 恢复码打印后请立即离线妥善保存（丢失即无法恢复）

# 换机恢复（新设备：恢复密钥 → 重新生成身份 → 登记白名单）
dart run bin/einz.dart restore --in "$W/backup-a.json" --recovery-code "<12词>" --store "$W/a-new.json"
# 之后：init 新身份 → 更新 config.json 白名单 → 重启服务器（E2EE.md §10.2）
```

### 5.3 设备撤销 + Space Key 轮换

**场景：** 手机丢失/失窃 → 撤销该设备，防止其继续收新消息。

```bash
# 1) A 撤销 B（DELETE /devices/dev-b1；Server 返回 key_rotation_required: true，
#    并广播 key.rotation 给剩余设备 + 关闭 B 的 WS 连接）
curl -X DELETE http://127.0.0.1:3000/devices/dev-b1 \
  -H "Authorization: Bearer <A的session_token>"

# 2) 剩余设备 A 收到 key.rotation 通知 → 立即轮换（key_version+1，旧密钥归档）
dart run bin/einz.dart rotate \
  --store "$W/a.json" --peer-pubkey "$PUB_B" --out-envelope-peer "$W/envelope-v2.txt"

# 3) 若 B 是误撤（仍可信）：B 导入新版本密钥（旧密钥自动归档）
dart run bin/einz.dart import \
  --store "$W/b.json" --envelope-file "$W/envelope-v2.txt" --space-id "space-demo" --key-version 2

# 4) 服务器 config.json 移除被撤销设备 → 重启服务器生效
```

- 轮换后：**新消息用新密钥**，旧消息仍用归档密钥解密（`history` 命令自动按 key_version 选密钥）。
- 被撤销设备：无法认证（403）/同步/发送；其旧 WS 连接已被服务端关闭。

### 5.4 数据目录备份策略（汇总）

| 数据                           | 手段                                    | 频率建议        |
| ------------------------------ | --------------------------------------- | --------------- |
| Server einz.sqlite.db + files + config | `npm run backup`（加密归档到 backups/） | 每日（可 cron） |
| 客户端密钥 + 历史              | `backup` 命令（恢复码加密）             | 每次重大变更后  |
| 恢复码 / 备份密钥              | 离线多份                                | 永久            |

---

## 6. 安全边界清单（V1 发布前已审查加固）

| 边界           | 机制                                                                            | 说明                                                |
| -------------- | ------------------------------------------------------------------------------- | --------------------------------------------------- |
| 白名单         | `config.json` + `isActiveDevice`（叠加数据库 revoked 状态）                     | 未登记设备 403；撤销后立即拒绝认证/同步/发送        |
| 服务端只见密文 | E2EE 全链路（消息/附件均为密文 + 元数据）                                       | `messages` 表只有 ciphertext（冒烟测试验证）        |
| 路径遍历       | `attachment_id` 字符集白名单 + `resolve` 路径包含检查（读写双侧）               | 失陷白名单设备也无法越出`files/`（V1 审查 P1 修复） |
| WS 撤销实时性  | 撤销即关闭被撤销设备连接（close 4403）                                          | 无法继续收新消息广播（P2 修复）                     |
| 备份加密       | Server 备份 AES-256-GCM（`EINZ_DB_BACKUP_KEY`）；客户端备份恢复码 Argon2id 派生 | 备份文件离库不泄露                                  |
| 供应链         | Gradle 镜像`distributionSha256Sum` 锁定官方校验和                               | 构建工具链不可被镜像篡改（P3 修复）                 |
| 认证           | challenge-response（一次性、5 分钟过期）；session_token 服务端签发              | 防重放                                              |
| 前向保密       | Space Key 简单派生（已接受的代价，E2EE.md §11.1）                               | 轮换 + 安全存储缓解                                 |

**威胁模型提醒（E2EE.md §9.3）：** 被撤销设备已持有的历史密文无法收回（设备端已解密数据的固有属性）；密钥轮换阻止其读取**之后**的新消息。

---

## 7. 故障排查

| 症状                                   | 原因                                                      | 处理                                                        |
| -------------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------- |
| Server 拒绝启动                        | `config.json` 缺失/格式错（需 space_id + ≥1 active 设备） | 检查`server/config/config.json`；用 CLI `config` 重新生成   |
| `curl /space` 401/403                  | 正常（未认证）                                            | 按 §3.3 验证                                                |
| CLI 报 libsodium 加载失败              | 未设`LIBSODIUM_PATH`（或 libsodium 装在非标准路径）       | `export LIBSODIUM_PATH="/opt/homebrew/lib/libsodium.dylib"` |
| `auth` 失败（403）                     | 设备不在白名单 / 已被撤销                                 | 检查 config.json 与 devices 表状态；重新登记                |
| `send` 提示"已入队（离线）"            | `--server` 省略或未认证                                   | 补`--server`；先 `auth`                                     |
| `sync` 拉不到对方消息                  | 锚点已推进 / 网络 / 白名单                                | 用`--after 0` 强制全量重拉排查                              |
| `fetch` 报 sha256 不匹配               | 附件密文损坏或元数据过期                                  | 重新`sync` 拉元数据后重试                                   |
| WS 连不上                              | 反代未开 WSS / token 未 URL 编码                          | 检查 Caddy；token 含`+`/`=` 需编码（客户端自动处理）        |
| `flutter analyze`/`build` 中文路径报错 | 仓库路径含非 ASCII（已知缺陷）                            | 拷贝到纯 ASCII 路径构建（如`/tmp/einz-build`），产物拷回    |
| 撤销后设备仍能认证                     | Server 版本过旧（未含 Phase 4 撤销感知）                  | 重新`npm run build` 部署                                    |
| 备份命令拒绝执行                       | 未设置`EINZ_DB_BACKUP_KEY`                                | 设置 base64 32B 密钥（§3.2/§5.1）                           |

---

## 8. 验收清单（部署完成后逐项打勾）

- [ ] `https://<域名>/space` 返回鉴权错误（TLS 正常）
- [ ] 白名单外设备 403
- [ ] A→B 发消息，B 同步解出明文；Server 数据库无明文
- [ ] `listen` 实时收到 `message.new`
- [ ] 附件上传→下载解密与原文件一致
- [ ] `npm run backup -- --verify` 成功；恢复演练通过
- [ ] `backup`/`restore`（恢复码）闭环通过
- [ ] 撤销 B：B 认证 403、A 收到 key.rotation、A 轮换后双版本历史可解

## 9. 版本升级（新代码上线）

> 原则：Server 代码变更均为**向后兼容**（新增表/端点，存量接口与数据不动）。
> 新表由 `CREATE TABLE IF NOT EXISTS` 在启动时自动创建，**无需手动迁移**。

### 9.1 代码传输：git pull（主推）——VPS 一次性初始化

> 前置：VPS 已装 git；本地化文件（`deployment/.env`、`server/data/`、`deployment/config/`、`*.db`）
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

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz.dart escrow --action upload --store /tmp/a.json \
  --server https://einz.tic.cc --passphrase "你的接入口令"
dart run bin/einz.dart escrow --action download --store /tmp/b.json \
  --server https://einz.tic.cc --passphrase "你的接入口令"
```

### 9.5 升级注意事项

| 项                       | 说明                                                                                                                                                     |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 存量数据                 | 不受影响（messages/devices/会话等全部不动，新表初始为空）                                                                                                |
| 白名单                   | 无需改动（既有设备认证不受影响）                                                                                                                         |
| Caddy / HTTPS / 备份密钥 | 均无需改动（Caddyfile 已 assume-unchanged，pull 不覆盖）                                                                                                 |
| App 侧                   | 需重新安装 APK 才能启用新 UI（CLI 不受影响）                                                                                                             |
| 回滚                     | `cd $EINZ_ROOT && git log --oneline -5` 找上一版本 → `git checkout <commit> -- server/ deployment/ shared/` → 重新 `docker compose up -d --build server` |
