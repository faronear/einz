# OnlySpace 部署与 AB 互通操作手册（Onboarding）

从零开始：VPS 部署 → A/B 双设备生成身份 → 创建空间 → 认证/托管 → 邀请码 → TUI 接入 → 双端互通对话。

> 适用：两人私密空间（person-a / person-b），服务器自建，客户端 TUI（Mac / Windows）。

---

## 术语速览

| 概念                      | 说明                                                                                                |
| ------------------------- | --------------------------------------------------------------------------------------------------- |
| **space_id**              | 空间唯一标识（UUID），`config` 命令生成，写入白名单与 store                                         |
| **Space Key**             | 32B 随机空间密钥（端到端加密用），创建者生成，B 凭口令从托管包获取                                  |
| **口令（passphrase）**    | 创建者 escrow upload 时设定，B 凭它解出 Space Key。**别和邀请码混淆**                               |
| **邀请码（invite_code）** | 一次性 24h 有效，白名单**外**的新设备登记用（白名单内的设备用不到）                                 |
| **白名单**                | VPS `deployment/config/config.json` 的 devices 数组；数据库 devices 表为判定源（重启时 UPSERT 同步） |
| **person id**             | 使用者身份（如 `luk` / `fanr`）：同一个人多台设备填相同值，"自己/对方"按它判断；一个空间最多两个 person（同 person 多设备允许） |

---

## 阶段 0：准备（VPS + 本机）

```bash
# ① VPS：拉最新代码 + 重建 server
ssh 你的VPS
cd /faronear/only            # ← 你的实际部署目录（下同，按需替换）
git pull
cd deployment
# 首次部署（或 .env 丢失后重建）：生成备份密钥
cp .env.example .env         # 模板在仓库里（.gitignore 不覆盖，git pull 不影响）
python3 -c "import os,base64;print(base64.b64encode(os.urandom(32)).decode())"   # 生成新密钥
# ↑ 把输出粘贴到 .env 的 ONLYSPACE_DB_BACKUP_KEY= 后面（只用于 npm run backup 归档加密）
docker compose up -d --build server
curl -s https://only.tic.cc/health    # 期望 {"status":"ok",...}
# 💡 全新部署时 config.json 尚未生成，Server 会进入"空转模式"正常启动：
#    /health 可探活，但无 active 设备 → 业务接口（auth/发消息/登记）全部拒绝，
#    日志打印 ⚠️ 空转提示。完成阶段 2 生成白名单、阶段 3 部署 config.json 后
#    docker compose restart server 即恢复正常（无需先放占位文件）。

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

> 💡 **也可以在 TUI 里按引导完成初始化**（空间已创建后更省事）：
> 直接 `dart run bin/onlyspace_tui.dart`（不传 `--store`）→ 无设备时自动引导：
> 问设备名 → 自动生成身份并存入 `~/.onlyspace/[设备名].json` → **问"你的身份（person id）"**（与 A 约定不同的值，如 `fanr`；同一个人多台设备填相同值）→
> 服务器探测 → 邀请码/口令接入 → 认证 → 直接进 TUI（init 一体化，无需敲 CLI 命令）。
> ⚠️ 若 A **正在创建空间**、需要把 B 公钥提前写进白名单，仍需用上面的 CLI 命令拿公钥。

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
  --person luk \                    # 你的 person id（默认 person-a，可自定义如 luk）
  --peer-person fanr \              # 对方的 person id（默认 person-b，与 B 引导输入保持一致）
  --space-id "$SPACE_ID" \
  --out-config /tmp/prod-config.json \
  --out-sealed-peer /tmp/sealed-b.txt
```

> 输出物：`/tmp/prod-config.json`（白名单：space_id + dev-a1/dev-b1 公钥）、`/tmp/sealed-b.txt`（给 B 的 sealed 副本，备用）。
>
> 💡 ① 步的设备身份也可在 TUI 内按引导生成（`dart run bin/onlyspace_tui.dart` 无 store 时自动 init 并存入 `~/.onlyspace/[设备名].json`）。⚠️ 但 **② 步创建空间（生成 Space Key + 白名单）目前仍需本 CLI 命令**（TUI 创建者路径待实现）。

---

## 阶段 3：部署白名单到 VPS + 重启

```bash
scp /tmp/prod-config.json root@你的VPS:/faronear/only/deployment/config/config.json

# 全新部署（容器尚未启动）：up；已有容器：restart
ssh 你的VPS "cd /faronear/only/deployment && docker compose up -d --build server"
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

> 💡 如果设备身份是在 **TUI 里按引导创建的**（存为 `~/.onlyspace/[设备名].json`），上面命令的 `--store` 请换成实际文件名（如 `~/.onlyspace/dev-a1.json`）。CLI `auth`/`escrow` 没有自动发现，必须显式指定路径。

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
dart run bin/onlyspace_tui.dart   # 不传 --store：自动发现 ~/.onlyspace/ 下的设备
# 自动使用已有设备（阶段 2 CLI 创建的 a.json，或 TUI 内创建的 [设备名].json），
# 多台会列出选择；无设备才引导 init（存入 ~/.onlyspace/[设备名].json）
# 首次运行会问"你的身份（person id）"（如 luk，与阶段 2 的 --person 一致）——之后不再问
# 启动探测 https://only.tic.cc/health → 能连 → 直接进 TUI（不询问服务器）
# 状态栏 WS:● 在线；输入消息回车发送
```

---

## 阶段 7：B 进入 TUI（Windows）

```powershell
cd 你的only目录\cli
dart run bin/onlyspace_tui.dart   # 不传 --store：自动发现 %USERPROFILE%\.onlyspace\ 下的设备
# 自动使用已有设备（b.json 或 TUI 内创建的 [设备名].json），多台会列出选择
# 首次运行会问"你的身份（person id）"（与阶段 2 的 --peer-person 保持一致，如 fanr）
# 启动探测 → 能连 → 引导继续：
#   - 无 Space Key → 问"接入方式" → 回车=1 口令接入
#   - 口令: faronear（⚠️ 输口令，不是邀请码；Windows 隐藏回显无星号，回车提交）
#   - ✅ 口令接入成功 → 认证成功 → 进入 TUI
```

> B 走"白名单外新设备"体验：先 `init` 一台 dev-b2 → TUI 引导输入邀请码（阶段 5）→ ✅ 登记成功 → 再口令接入。

---

## 阶段 8：AB 互通验证

| 验证项       | 操作                          | 期望                                                               |
| ------------ | ----------------------------- | ------------------------------------------------------------------ |
| A/B 在线     | 各自 TUI 状态栏               | `WS:● 在线`                                                        |
| A→B 消息     | A 输入消息回车                | B 消息区实时出现（WS 推送）                                        |
| B→A 消息     | B 输入消息回车                | A 消息区实时出现                                                   |
| 对方消息样式 | 看消息区                      | 对方粉色背景、自己绿色前缀                                         |
| 退出恢复     | `/exit`                       | 正常回命令行（无需 Ctrl-C）                                        |
| 服务器重设   | `/server https://only.tic.cc` | 重连并认证                                                         |
| 服务器地址   | 启动引导                      | 默认 only.tic.cc，能连零打扰；连不上才引导输入；`/server` 显性重设 |

---

## 常见坑速查

| 症状                                    | 原因                                           | 处理                                                                                  |
| --------------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------- |
| `sealOpen` libsodium 失败               | 白名单公钥与 store 私钥不匹配（db 残留旧公钥） | 确认部署了`/tmp/prod-config.json` 并 `docker compose restart server`（UPSERT 已修复） |
| 口令接入`FormatException: 备份解密失败` | **口令输成了邀请码**                           | 口令是`faronear`（A 上传托管包时设的）                                                |
| invite 报`path must be of type string`  | VPS 宿主机 Node 旧 / env 未传                  | 显式传宿主机路径 env；别用 sudo；旧 Node 兼容已修复                                   |
| 启动 255 崩溃                           | 旧代码渲染/终端问题                            | 已全部修复（git pull 后重试）                                                         |
| 二次启动还问服务器                      | 旧代码                                         | 新版有探测+持久化，能连不再询问                                                       |
| `/health` 正常但 auth 报握手失败        | 本机翻墙/网络抖动                              | 关闭翻墙或加直连规则；ApiClient 已带 3 次瞬时重试                                     |

---

## 说明

- 白名单修改（换公钥/加设备）后必须 `docker compose restart server`（db 由 UPSERT 同步）
- 撤销设备：白名单外设备仍可被 server 拒绝；被撤销设备重启不复活
- 服务端监控：`GET /health`（免鉴权）、`docker logs -f` 看请求日志（`LOG_LEVEL=quiet` 可关）
