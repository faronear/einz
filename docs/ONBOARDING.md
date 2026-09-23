# Einz 部署与 AB 互通操作手册（Onboarding）

从零开始：VPS 部署（**无需任何配置文件**）→ A 创建空间 → 上传口令密保箱 → 生成邀请链接 →
B 加入（口令取钥）→ 双端互通对话。

> 适用：两人私密空间，服务器自建，客户端 TUI（Mac / Windows）或 App。
> **Multiverse（v2）**：一个 Server 可承载多个互不可见的空间；通道登记与白名单都在数据库里，
> 没有静态配置文件。v1 时代的脚本 CLI（`cli/bin/einz.dart`）、20 位邀请码、密保信封分发
> 已随 2026-09-15 收敛删除，本文流程全部按 v2。

---

## 新机环境准备（换电脑 / 从零搭建）

| 依赖        | 版本要求            | 安装方式（macOS）        | 备注                                                         |
| ----------- | ------------------- | ------------------------ | ------------------------------------------------------------ |
| Node.js     | ≥ 22                | `brew install node`      | Server 运行时                                                |
| Dart SDK    | 3.x（实测 3.13.2）  | `brew install dart-sdk`  | **公式名是 dart-sdk 不是 dart**                              |
| libsodium   | 最新（实测 1.0.22） | `brew install libsodium` | shared/CLI 加密依赖；非标准路径需设 `LIBSODIUM_PATH`（见下） |
| Flutter SDK | 3.x stable          | 见下"Flutter 安装"       | app 端                                                       |

- Homebrew 路径：**Intel Mac** 为 `/usr/local`，**Apple Silicon** 为 `/opt/homebrew`；`pkg-config --modversion libsodium` 可验证。
- **Flutter 安装（中国网络镜像）**：Google storage 与 GitHub 不可达时使用镜像 `storage.flutter-io.cn`（注意选对 arm64 / x64 包），解压到 `~/development/flutter` 并加 PATH；需 ≥9GB 磁盘空闲。
- **Docker 容器化开发（`cli/dart-docker.sh`）注意**：仓库所在卷必须能被 Docker 枚举目录。macOS 上外部 APFS 卷（挂载标志 `noowners`，如 `/Volumes/xxx`）Docker 无法枚举目录（`dart run` 报 `PathAccessException: Operation not permitted`）——**把仓库放到 `~/` 下**（如 `git clone ... ~/einz`），符号链接不能解决。

**开发侧踩坑补充（改 server/shared 代码时勿回退）：**

1. **base64 变体**：libsodium-wrappers 默认 URL-safe 无填充；协议统一**标准 base64 + 填充**（`ORIGINAL` 变体）——server/src/crypto.ts 与测试统一显式 `sodium.base64_variants.ORIGINAL`。
2. **sync 响应必须补 `v:1`**（PROTOCOL.md §5.2）：`v` 是协议常量未入库，漏了客户端解析崩溃。
3. **npm 依赖**：`libsodium-wrappers` 的 ESM 入口在 Node ESM 下损坏（缺 libsodium.mjs），server 统一用 `createRequire` 强制加载 CJS 构建。
4. **LIBSODIUM_PATH**：shared 加载 libsodium 优先环境变量 `LIBSODIUM_PATH`，其次 macOS Homebrew 路径；非标准路径安装（含 Windows DLL）必须显式设置（见 DEPLOYMENT.md）。
5. **WS 凭证走握手头**（2026-09-15 评审 H4）：`Authorization: Bearer <session_token>`，**不再**是 `?token=`（URL 会进反代日志）。

---

## 术语速览

| 概念 | 说明 |
| --- | --- |
| **space_id / space_address** | 空间唯一标识（UUID）与对外地址（由空间公钥经 Keccak-256 + EIP-55 派生）。创建空间时由客户端生成 space_id 一并提交 |
| **Space Key** | 32B 随机空间密钥（端到端加密用），创建者本地生成；加入方凭**口令**从口令密保箱取回 |
| **口令（passphrase）** | 创建空间时设定，两人共用；对方凭它解出 Space Key。**别和邀请链接混淆** |
| **邀请链接 / join token** | 一次性（默认 24h、用后作废），创建者 `/invite` 生成；B 拿它加入空间 |
| **partner / slot** | 空间内两个身份槽位：`0`=创建者/第一人，`1`=伴侣/第二人。partner_id 是空间内随机 UUID；同一身份可多条通道（"自己/对方"按 partner_id 判断） |
| **通道登记** | 由 `POST /spaces`（创建者）/ `POST /spaces/join`（凭 join token）完成，**同时签发绑定该空间的会话**——没有独立的登记步骤 |
| **通道在册状态** | `entrances` 表（`active` / `revoked`）；未登记 → 401/403 `FORBIDDEN`（只警告），已撤销 → 403 `ENTRANCE_REVOKED`（客户端自毁本地数据），无需任何配置文件 |

---

## 阶段 0：VPS 部署（不需要任何配置文件）

```bash
# ① VPS：拉最新代码 + 重建 server
ssh 你的VPS
cd /faronear/only            # ← 你的实际部署目录（下同，按需替换）
git pull
cd deployment
# 首次部署（或 .env 丢失后重建）：生成备份密钥
bash deployment/.env.sh         # 模板在仓库里（.gitignore 不覆盖，git pull 不影响）
python3 -c "import os,base64;print(base64.b64encode(os.urandom(32)).decode())"   # 生成新密钥
# ↑ 把输出粘贴到 .env 的 EINZ_DB_BACKUP_KEY= 后面（只用于 npm run backup 归档加密）
docker compose up -d --build server
curl -s https://einz.tic.cc/health
# {"status":"ok","protocol_version":"v2-multiverse","version":"1.0.0","capabilities":["spaces","join-tokens"],...}
docker compose logs -f server   # 查看日志（启动/建空间/通道登记等事件；Ctrl+C 停止跟踪）

# ② 本机（Mac）：拉最新代码
cd /Users/Shared/productX/only && git pull

# ③ 可选：清掉旧通道凭证（重走会生成全新空间；不清也能走，旧 store 会被覆盖）
rm -f ~/.einz/*.json
mkdir -p ~/.einz
```

> `/health` 只返回服务健康、协议版本与能力（不再有 space_id / 消息数 / 在线数——免鉴权端点
> 不吐业务量，2026-09-15 评审 B1）。空间信息在认证后由 `/space` 返回。
>
> 可选：`server/config/serverConfig.json` 的 `maxSpaces` 控制新空间数量上限（0=不限）。
> 自用建议设 1~2，否则等于对公网开放建空间（服务端启动会打告警）。

---

## 阶段 1：A 创建空间（Mac）

TUI 引导会一次完成：生成通道身份 → `POST /spaces` 建空间（登记通道 + 签发会话）→
本地生成 Space Key → 用口令加密上传密保箱 → 打印邀请链接。

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz_tui.dart --server https://einz.tic.cc \
  --store ~/.einz/a.json
# 引导流程：
#   选 c 创建秘境
#   我的名字（如 lukas）+ 性别；伴侣名字（如 Alice，预置在 slot=1，等她加入时确认）
#   设置共享口令（如 faronear，两分钟后对方凭它接入；≥8 位）
#   ✅ 成功创建秘境！地址: 0x…（自动上传密保箱、签发会话、进入会话）
```

进会话后执行 `/invite` 打印**邀请链接**（`https://einz.tic.cc/join/e1_…`，24 小时一次性），
把链接离线发给 B（或让对方扫码）。

> 命令一览：`/help`；空间状态 `/space`；改口令 `/passphrase`；通道名 `/entrance <名>`（别名 `/device`）；
> 我的显示名 `/myname <名>`。

---

## 阶段 2：B 加入空间（Windows）

```powershell
cd 你的only目录\cli
dart run bin/einz_tui.dart --server https://einz.tic.cc `
  --store "$env:USERPROFILE\.einz\b.json"
# 引导流程：
#   选 j 加入秘境
#   粘贴 A 给的邀请链接（或纯 token）
#   ✅ 开通码验证通过 → 选择身份（1=第一人 / 2=伴侣，一般选 2）
#   输入 A 设置的共享口令（⚠️ 输口令，不是邀请链接；Windows 隐藏回显无星号）
#   ✅ 口令验证通过，成功加入秘境（取回 Space Key + 登记通道 + 签发会话）
```

> 同一人加第二条通道：同样选 `j` 加入，身份选**同一个人**（1 或 2 与已有通道一致）——
> 同一 partner 多通道不受"两人上限"限制（那限制只针对新增 partner）。

---

## 阶段 3：日常使用（两端）

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz_tui.dart            # 不传 --store：自动发现 ~/.einz/ 下的通道后列出选择
# 启动探测 /health → 能连 → 直接进 TUI（不询问服务器）；状态栏 ● 在线
# 输入消息回车即发送（无需子命令）
```

---

## 阶段 4：AB 互通验证

| 验证项       | 操作                          | 期望                                                       |
| ------------ | ----------------------------- | ---------------------------------------------------------- |
| A/B 在线     | 各自 TUI 状态栏               | `● 在线`                                                   |
| A→B 消息     | A 输入消息回车                | B 消息区实时出现（WS 推送）                                |
| B→A 消息     | B 输入消息回车                | A 消息区实时出现                                           |
| 对方消息样式 | 看消息区                      | 对方粉色背景、自己绿色前缀（**同 partner 多通道互显"我"**） |
| 退出恢复     | `/exit`                       | 正常回命令行（无需 Ctrl-C）                                |
| 服务器重设   | `/server https://einz.tic.cc` | 重连并认证                                                 |
| 补发开通码     | 任一方 `/invite`              | 打印新的 24h 一次性邀请链接（给自己加通道也用它）          |
| 看通道列表   | 任一方 `/entrances`（别名 `/devices`） | 列出**同空间全部通道**（我 + 对方），带序号与在线/已撤销状态 |
| 撤销通道     | `/revoke`（或 `/revoke <序号\|通道名>`） | 选通道 → 输入 `yes` 确认 → 输入共享口令 → 该通道下次联网时**清空本地数据**（不可逆；口令错/无权则毫发无损） |

---

## 常见坑速查

| 症状                                    | 原因                         | 处理                                                                           |
| --------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------ |
| 口令接入报解密失败 / `FormatException`  | **把邀请链接当成口令输了**   | 口令是创建空间时设的那串（如 faronear）；邀请链接是 `/invite` 打印的 24h 一次性凭证 |
| 加入时报 `TOKEN_EXPIRED` / `TOKEN_USED` | 邀请链接过期或已被用过       | 让创建者重新 `/invite` 生成一个                                               |
| `/auth` 报"通道尚未绑定秘境"            | 新 store 还没加入/创建空间   | 先 `/space create` 或 `/space join <链接>`                                     |
| 加入时报 `FORBIDDEN not a member`       | 会话的空间与目标空间不一致   | 该通道已属于另一个空间（一通道一空间）：换 store 或用新通道                    |
| 启动 255 崩溃                           | 旧代码渲染/终端问题          | 已修复（`git pull` 后重试）                                                    |
| `/health` 正常但认证握手失败            | 本机翻墙/网络抖动            | 关闭翻墙或加直连规则；ApiClient 已带 3 次瞬时重试                              |
| 发消息一直"发送中"                      | WS 未连上 / 会话失效         | `/auth` 重新激活；看服务端日志 `[req] WS /ws connect`                          |
| 加入时报 `RATE_LIMITED`（429）          | 同一 IP 的加入/认证请求超限  | 等提示的秒数再试；自用可直接**重启服务端**清空计数（计数在内存），或用 `EINZ_RATELIMIT_AUTH` 调高阈值（默认 60 次 / 5 分钟）。**不是开通码的问题** |
| 加入时报 `RATE_LIMITED`（429）且**休息很久后第一次就中** | 同 IP 上有客户端卡在"重新认证"死循环（2026-09-22 定位：`WsRealtimeService` 续期后没更新 `WsClient` 持有的那份 token → WS 被 4401 关掉 → 立即用旧 token 重连 → 零延迟循环，每轮一次 `POST /auth/challenge`） | **先把那个卡住的客户端退掉/重启**（重启服务端只能清计数，循环会立刻再打满）；客户端已修（`ws_client` 在 token 没变时强制退避 + App 侧补上 `updateToken`） |

---

## 说明

- **无配置文件**：通道与空间全在库里（`spaces` / `space_members` / `entrances`）；`config.json`
  这类静态白名单与 v1 脚本 CLI 已随 2026-09-15 收敛删除。
- **信任模型**：`POST /spaces` 免认证（创建者此刻还没有凭证）——所以 `maxSpaces` 是开放注册的
  总闸；私有部署建议设成 1~2。空间一旦建立，只有持口令 + 有效 join token 的人能进来。
- **会话必带空间**：认证时 `space_id` 必填；无 space 的会话不存在（也访问不到任何数据）。
- **两人上限**：一个空间内 distinct partner ≤2（同 partner 多通道不限）；由 `space_members`
  的两个槽位在数据库层强制。
- **撤销通道**：`POST /entrances/:id/revoke`（需同空间成员认证 + **校验共享口令**）→ 标记
  `revoked` + 清会话/Push Token + 关 WS；
  被撤销通道重启不复活（**不**做密钥轮换，见 `SECURITY.md` §3；止损走重建空间）。
- **服务端监控**：`GET /health`（免鉴权）、`docker compose logs -f server`（含
  `[req]` 请求日志与 WS 连接数）、`server/data/einz.sqlite.db` 的审计表（上下线/发送/接收）。
