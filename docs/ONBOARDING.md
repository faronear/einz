# Einz 部署与 AB 互通操作手册（Onboarding）

从零开始：VPS 部署（**无需任何配置文件**）→ 首个设备自举成为创建者 → 口令托管 → 邀请码 → 对方加入 → 双端互通对话。

> 适用：两人私密空间（person-a / person-b），服务器自建，客户端 TUI（Mac / Windows）。
> 自主模式：**不需要 config.json**——server 首启自动生成 space_id，白名单完全靠动态登记（首个设备免邀请码自举为创建者，之后设备凭邀请码加入）。

---

## 术语速览

| 概念                      | 说明                                                                                                                                                                         |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **space_id**              | 空间唯一标识（UUID）。**server 首启自动生成并持久化**（db meta 表），`/health` 可查看；登记响应会带回给客户端                                                                |
| **Space Key**             | 32B 随机空间密钥（端到端加密用），创建者生成，对方凭口令从托管包获取                                                                                                         |
| **口令（passphrase）**    | 创建者 escrow upload 时设定，对方凭它解出 Space Key。**别和邀请码混淆**                                                                                                      |
| **邀请码（invite_code）** | 一次性（默认 24h 有效），创建者生成、白名单外新设备登记用                                                                                                                    |
| **person id**             | 后台规范 id（personA / personB，服务端分配）；自定义名称（如`lukas` / `steffi`）存名称表用于显示；"自己/对方"按规范 id 判断；一个空间最多两个 person（同 person 多设备允许） |
| **自举（bootstrap）**     | 空间 0 台设备时，第一个登记的设备免邀请码自动成为**创建者**（拥有生成邀请码权限）                                                                                            |
| **白名单**                | 数据库 devices 表（动态登记，运行时可写，**无需 config.json 种子**）；撤销（revoked）实时生效                                                                                |

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
# {"status":"ok","space_id":"<自动生成的UUID>",...}   ← 首次启动自动生成 space_id，无需任何配置
docker compose logs -f server   # 查看日志（启动/登记/邀请码等事件；Ctrl+C 停止跟踪）

# ② 本机（Mac）：拉最新代码
cd /Users/Shared/productX/only && git pull

# ③ 可选：清掉旧设备身份（重走会生成全新空间；不清也能走，旧 store 会被覆盖）
rm -f ~/.einz/*.json
mkdir -p ~/.einz
```

> 💡 server 处于"未初始化"状态（0 台设备）时，业务接口（auth/发消息）会拒绝——**首个设备自举后即自动激活**，全程无需重启、无需配置文件。

---

## 阶段 1：B 端（Windows）生成设备身份

> 身份必须在 B 自己的机器上生成（私钥留本机）。**也可以跳过本阶段**——B 直接用 TUI 引导，登记时自动生成身份。

```powershell
cd 你的only目录\cli
dart run bin/einz.dart init --store "$env:USERPROFILE\.einz\b.json" --device-id dev-b1
# 用 TUI 引导时无需手动 init（见阶段 5）
```

---

## 阶段 2：A 端（Mac）创建空间（首设备自举）

**方式一：TUI 全自动（推荐）**——直接启动，引导会完成：生成身份 → 自举登记（成为创建者）→ 生成 Space Key → 上传口令托管包 → 生成邀请码：

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz_tui.dart   # 不传 --store：自动发现/创建设备
# 引导流程：
# 引导流程（设备身份自动生成，登记后由服务端分配 dev1 等规范 id）：
#   你的名称（如 lukas）→ 设备名称（显示用，如 MacBook）
#   ✅ 首设备自举成功（你是空间创建者，分配为 dev1 / personA）
#   设置托管口令:（如 faronear，对方凭它接入）
#   ✅ 口令托管包已上传
#   对方名称（如 steffi）→ ✅ 邀请码已生成（发给对方，绑定 personB）
# 直接进入 TUI，状态栏 WS:● 在线
```

**方式二：CLI 分步命令**（等价流程）：

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz.dart init --store ~/.einz/a.json --device-id dev-a1
# ① 首设备自举登记（免邀请码，成为创建者；--person 是你的名称，如 lukas）
dart run bin/einz.dart enroll --store ~/.einz/a.json \
  --server https://einz.tic.cc --person lukas [--device-name MacBook]
# ✅ 登记成功: device_id=dev1 person_id=personA space_id=<服务端的UUID>
# ② 上传口令托管包（store 无 Space Key 时自动生成）
dart run bin/einz.dart auth --store ~/.einz/a.json --server https://einz.tic.cc
dart run bin/einz.dart escrow --action upload \
  --store ~/.einz/a.json --server https://einz.tic.cc --passphrase 'faronear'
# ✅ 口令托管包已上传
```

---

## 阶段 3：A 生成邀请码（创建者客户端）

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz.dart invite --store ~/.einz/a.json \
  --server https://einz.tic.cc --person personB --name steffi [--hours 24]
# ✅ 邀请码已生成（24h 有效，一次性）: XXXX-XXXXX-XXXXX-XXXXX
# 把邀请码离线发给对方（绑定 personB=steffi；给自己加设备用 --person personA）
```

> TUI 方式创建空间时**已自动生成**邀请码（阶段 2 引导里打印），此命令用于之后随时补发。权限：任一 active 设备均可生成（第一/第二使用者都能邀请自己的其他设备）。

---

## 阶段 4：A 进入 TUI（Mac，日常使用）

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz_tui.dart   # 不传 --store：自动发现 ~/.einz/ 下的设备
# 自动使用已有设备（a.json 或 [设备名].json），多台会列出选择
# 启动探测 https://einz.tic.cc/health → 能连 → 直接进 TUI（不询问服务器）
# 状态栏 WS:● 在线；输入消息回车发送
```

---

## 阶段 5：B 进入 TUI（Windows，加入空间）

```powershell
cd 你的only目录\cli
dart run bin/einz_tui.dart   # 不传 --store：自动发现 %USERPROFILE%\.einz\ 下的设备
# 引导流程（空间已有设备 → 走邀请码登记）：
# 引导流程（空间已有设备 → 走邀请码登记；设备身份自动生成）：
#   你的名称（如 steffi）→ 设备名称（显示用，如 Windows）
#   ⚠️ 自举失败（空间已有创建者）→ 输入邀请码: XXXX-XXXXX-XXXXX-XXXXX
#   ✅ 邀请码登记成功（分配为 dev2 / personB）
#   无 Space Key → 问"接入方式" → 回车=1 口令接入
#   口令: faronear（⚠️ 输口令，不是邀请码；Windows 隐藏回显无星号，回车提交）
#   ✅ 口令认证成功 → 认证成功 → 进入 TUI
```

> 同一人加第二台设备：TUI 引导时名称填**相同值**（如 steffi）、邀请码再生成一个即可（同 person 多设备不受两 person 上限影响）。

---

## 阶段 6：AB 互通验证

| 验证项       | 操作                          | 期望                                                       |
| ------------ | ----------------------------- | ---------------------------------------------------------- |
| A/B 在线     | 各自 TUI 状态栏               | `WS:● 在线`                                                |
| A→B 消息     | A 输入消息回车                | B 消息区实时出现（WS 推送）                                |
| B→A 消息     | B 输入消息回车                | A 消息区实时出现                                           |
| 对方消息样式 | 看消息区                      | 对方粉色背景、自己绿色前缀（**同 person 多设备互显"我"**） |
| 退出恢复     | `/exit`                       | 正常回命令行（无需 Ctrl-C）                                |
| 服务器重设   | `/server https://einz.tic.cc` | 重连并认证                                                 |
| 邀请码       | 创建者`/invite` 之外          | 需补发时用 CLI`dart run bin/einz.dart invite ...`          |

---

## 常见坑速查

| 症状                                    | 原因                         | 处理                                                                           |
| --------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------ |
| server 日志报"缺少配置文件"             | 旧版本行为（已移除）         | `git pull` 后 server 不再读 config.json（自主模式），无需配置文件              |
| 首设备自举失败/被要求邀请码             | 空间已有设备（你不是第一个） | 这是正常加入者路径：输入创建者给的邀请码即可                                   |
| 口令接入`FormatException: 备份解密失败` | **口令输成了邀请码**         | 口令是创建者 escrow upload 时设的（如 faronear），不是邀请码                   |
| 只有`/health` 可用、业务全拒            | 空间 0 台设备（未自举）      | 让第一个设备走一次引导（自举）即激活，无需重启                                 |
| 生成邀请码报 403                        | 非创建者调用`invite`         | 邀请码只能由**首设备自举的 person** 生成（TUI 引导自动完成或 CLI invite 命令） |
| 启动 255 崩溃                           | 旧代码渲染/终端问题          | 已全部修复（git pull 后重试）                                                  |
| `/health` 正常但 auth 握手失败          | 本机翻墙/网络抖动            | 关闭翻墙或加直连规则；ApiClient 已带 3 次瞬时重试                              |

---

## 说明

- **无 config.json**：space_id 由 server 首启自动生成（db meta 表持久化）；白名单 = devices 表（动态登记）
- **信任模型**：空间 0 台设备时，**第一个登记的设备成为创建者**（先到先得）——私有部署场景适用；创建者拥有生成邀请码的唯一权限
- **两 person 上限**：空间内 distinct person ≤2（同 person 多设备允许）；新 person 登记/发邀请码时由 server 强制检查
- 撤销设备：`DELETE /devices/:id`（需认证）；被撤销设备重启不复活，且触发密钥轮换
- 服务端监控：`GET /health`（免鉴权）、`docker compose logs -f server`（启动/登记/邀请码事件）
