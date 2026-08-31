# OnlySpace 部署与 AB 互通操作手册（Onboarding）

从零开始：VPS 部署 → A/B 双设备生成身份 → 创建空间 → 认证/托管 → 邀请码 → TUI 接入 → 双端互通对话。

> 适用：两人私密空间（person-a / person-b），服务器自建，客户端 TUI（Mac / Windows）。

---

## 术语速览

| 概念 | 说明 |
|---|---|
| **space_id** | 空间唯一标识（UUID），`config` 命令生成，写入白名单与 store |
| **Space Key** | 32B 随机空间密钥（端到端加密用），创建者生成，B 凭口令从托管包获取 |
| **口令（passphrase）** | 创建者 escrow upload 时设定，B 凭它解出 Space Key。**别和邀请码混淆** |
| **邀请码（invite_code）** | 一次性 24h 有效，白名单**外**的新设备登记用（白名单内的设备用不到） |
| **白名单** | VPS `deployment/config/config.json` 的 devices 数组；数据库 devices 表为判定源（重启时 UPSERT 同步） |

---

## 阶段 0：准备（VPS + 本机）

```bash
# ① VPS：拉最新代码 + 重建 server
ssh 你的VPS
cd /faronear/only            # ← 你的实际部署目录（下同，按需替换）
git pull
cd deployment
docker compose up -d --build server
curl -s https://only.tic.cc/health    # 期望 {"status":"ok",...}

# ② 本机（Mac）：拉最新代码
cd /Users/Shared/productX/only && git pull

# ③ 可选：清掉旧设备身份（重走会生成全新空间；不清也能走，旧 store 会被覆盖）
rm -f ~/.onlyspace/a.json ~/.onlyspace/b.json
mkdir -p ~/.onlyspace
```

---

## 阶段 1：B 端（Windows）生成设备身份

> 身份必须在 B 自己的机器上生成（私钥留本机）。单机体验可在 Mac 生成后把 store 文件拷给 B。

```powershell
cd 你的only目录\cli
dart run bin/onlyspace.dart init --store "$env:USERPROFILE\.onlyspace\b.json" --device-id dev-b1
dart run bin/onlyspace.dart pubkey --store "$env:USERPROFILE\.onlyspace\b.json"
# ↑ 记下输出的 B 公钥（base64），离线发给 A
```

---

## 阶段 2：A 端（Mac）生成身份 + 创建空间

```bash
cd /Users/Shared/productX/only/cli

# ① A 生成设备身份
dart run bin/onlyspace.dart init --store ~/.onlyspace/a.json --device-id dev-a1

# ② 创建空间：生成 Space Key + 白名单 config.json（含 A/B 公钥）+ sealed 副本
SPACE_ID=$(python3 -c "import uuid;print(uuid.uuid4())")
dart run bin/onlyspace.dart config \
  --store ~/.onlyspace/a.json \
  --peer-pubkey "<阶段1拿到的B公钥>" \
  --space-id "$SPACE_ID" \
  --out-config /tmp/prod-config.json \
  --out-sealed-peer /tmp/sealed-b.txt
```

> 输出物：`/tmp/prod-config.json`（白名单：space_id + dev-a1/dev-b1 公钥）、`/tmp/sealed-b.txt`（给 B 的 sealed 副本，备用）。

---

## 阶段 3：部署白名单到 VPS + 重启

```bash
scp /tmp/prod-config.json root@你的VPS:/faronear/only/deployment/config/config.json

ssh 你的VPS "cd /faronear/only/deployment && docker compose restart server"
ssh 你的VPS "curl -s https://only.tic.cc/health"   # ok；space_id 应是新 UUID
```

> 第一台设备只能手动加白名单（server 启动要求 ≥1 台 active 设备）；之后的设备走邀请码动态登记。重启时 UPSERT 会把 db 公钥同步为 config.json 的新值。

---

## 阶段 4：A 认证 + 上传口令托管包

```bash
cd /Users/Shared/productX/only/cli

# ① A 认证（challenge-response）
dart run bin/onlyspace.dart auth --store ~/.onlyspace/a.json --server https://only.tic.cc
# ✅ 认证成功: space_id=<新UUID>

# ② A 上传口令托管包（B 凭口令接入；口令务必记住：faronear）
dart run bin/onlyspace.dart escrow --action upload \
  --store ~/.onlyspace/a.json --server https://only.tic.cc \
  --passphrase 'faronear'
# ✅ 口令托管包已上传（Server 只存密文）
```

---

## 阶段 5：生成邀请码（VPS，白名单外新设备/演示动态登记）

```bash
ssh 你的VPS "cd /faronear/only/server && \
  ONLYSPACE_CONFIG=/faronear/only/deployment/config/config.json \
  ONLYSPACE_DB=/faronear/only/deployment/data/app.db \
  npm run invite -- --person person-b"
# ✅ 邀请码已生成（一次性，24h 有效）: XXXX-XXXXX-XXXXX-XXXXX
```

> ⚠️ 用**宿主机路径**（不是容器内 `/config`、`/data`）；env 必须显式传（别用 sudo）。dev-b1 已在白名单，用不到邀请码；它主要给"白名单外新设备"（可再 init 一台 dev-b2 体验完整动态登记）。

---

## 阶段 6：A 进入 TUI（Mac）

```bash
cd /Users/Shared/productX/only/cli
dart run bin/onlyspace_tui.dart --store ~/.onlyspace/a.json
# 启动探测 https://only.tic.cc/health → 能连 → 直接进 TUI（不询问服务器）
# 状态栏 WS:● 在线；输入消息回车发送
```

---

## 阶段 7：B 进入 TUI（Windows）

```powershell
cd 你的only目录\cli
dart run bin/onlyspace_tui.dart --store "$env:USERPROFILE\.onlyspace\b.json"
# 启动探测 → 能连 → 引导继续：
#   - 无 Space Key → 问"接入方式" → 回车=1 口令接入
#   - 口令: faronear（⚠️ 输口令，不是邀请码；Windows 隐藏回显无星号，回车提交）
#   - ✅ 口令接入成功 → 认证成功 → 进入 TUI
```

> B 走"白名单外新设备"体验：先 `init` 一台 dev-b2 → TUI 引导输入邀请码（阶段 5）→ ✅ 登记成功 → 再口令接入。

---

## 阶段 8：AB 互通验证

| 验证项 | 操作 | 期望 |
|---|---|---|
| A/B 在线 | 各自 TUI 状态栏 | `WS:● 在线` |
| A→B 消息 | A 输入消息回车 | B 消息区实时出现（WS 推送） |
| B→A 消息 | B 输入消息回车 | A 消息区实时出现 |
| 对方消息样式 | 看消息区 | 对方粉色背景、自己绿色前缀 |
| 退出恢复 | `/exit` | 正常回命令行（无需 Ctrl-C） |
| 服务器重设 | `/server https://only.tic.cc` | 重连并认证 |
| 服务器地址 | 启动引导 | 默认 only.tic.cc，能连零打扰；连不上才引导输入；`/server` 显性重设 |

---

## 常见坑速查

| 症状 | 原因 | 处理 |
|---|---|---|
| `sealOpen` libsodium 失败 | 白名单公钥与 store 私钥不匹配（db 残留旧公钥） | 确认部署了 `/tmp/prod-config.json` 并 `docker compose restart server`（UPSERT 已修复） |
| 口令接入 `FormatException: 备份解密失败` | **口令输成了邀请码** | 口令是 `faronear`（A 上传托管包时设的） |
| invite 报 `path must be of type string` | VPS 宿主机 Node 旧 / env 未传 | 显式传宿主机路径 env；别用 sudo；旧 Node 兼容已修复 |
| 启动 255 崩溃 | 旧代码渲染/终端问题 | 已全部修复（git pull 后重试） |
| 二次启动还问服务器 | 旧代码 | 新版有探测+持久化，能连不再询问 |
| `/health` 正常但 auth 报握手失败 | 本机翻墙/网络抖动 | 关闭翻墙或加直连规则；ApiClient 已带 3 次瞬时重试 |

---

## 说明

- 白名单修改（换公钥/加设备）后必须 `docker compose restart server`（db 由 UPSERT 同步）
- 撤销设备：白名单外设备仍可被 server 拒绝；被撤销设备重启不复活
- 服务端监控：`GET /health`（免鉴权）、`docker logs -f` 看请求日志（`LOG_LEVEL=quiet` 可关）
