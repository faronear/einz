# 服务器更新流程（git push/pull 版）

> **用途：** 在任意电脑上把新代码更新到 only.tic.cc 生产服务器。
> **适用：** 口令托管（KEY_ESCROW.md）、以及以后任何 Server 代码变更。
> **原则：** 变更均向后兼容（新增表/端点，存量接口与数据不动；新表由 `CREATE TABLE IF NOT EXISTS` 启动自动创建）；server 代码构建进 Docker 镜像，**必须 `--build` 重建**。
> 关联文档：docs/DEPLOYMENT.md §9（本章节的仓库内原版）。

---

## 0. 另一台电脑首次准备（只做一次）

```bash
# 1) 安装 git（Windows 装 Git for Windows；macOS/Linux 自带或 brew/apt 安装）

# 2) 配置 git.tic.cc 凭据：
#    - 浏览器登录 git.tic.cc → 用户设置 → 访问令牌（生成一个有 repo 权限的令牌）
#    - 保存凭据（Windows 用 Git Credential Manager，首次 push 时弹窗粘贴令牌即可）
git config --global credential.helper manager

# 3) 克隆仓库（文档随仓库一起下来，之后都在仓库内操作）
git clone https://git.tic.cc/fon/only
cd only

# 4) （CLI 实测才需要）安装 Node ≥ 20 / Dart ≥ 3.12 / libsodium：
#    - macOS（Homebrew）：brew install node dart-sdk libsodium
#    - Linux：apt install libsodium-dev（或按发行版），一般自动探测常见路径，无需设置
#    - 非标准路径时：export LIBSODIUM_PATH="/path/to/libsodium.dylib"（macOS）/ ".so"（Linux）
```

---

## 1. VPS 一次性初始化（把现有部署目录转为 git 工作树，只做一次）

```bash
# VPS 上执行
export EINZ_ROOT=/opt/einz
cd $EINZ_ROOT
git init
git remote add origin https://git.tic.cc/fon/only
git fetch origin
git checkout -b main origin/main
git update-index --assume-unchanged deployment/Caddyfile   # 关键：Caddyfile 保留 VPS 域名，pull 不再覆盖
git status --short                                          # 应只显示本地未跟踪项（data/ .env 等）
```

**为什么安全：**

- 本地化文件 `deployment/.env`（备份密钥）、`server/data/`、`deployment/config/`、`*.db`
  全部在仓库 .gitignore 中 → git 操作不触碰，**本地数据零风险**；
- 唯一例外 `deployment/Caddyfile`：仓库内是占位域名 `private.example.com`，
  VPS 部署时已 sed 成真实域名（only.tic.cc）→ 用 `assume-unchanged` 标记，pull 不覆盖。

---

## 2. 每次版本更新（日常就这两段）

### 2.1 本机：提交并推送

```bash
cd <仓库路径>        # 例：cd only 或 cd /Users/Shared/productX/only
git add -A
git commit -m "feat: 你的改动说明"
git push origin main
```

### 2.2 VPS：拉取 → 重建 → 验证

```bash
cd $EINZ_ROOT
git pull --ff-only
cd deployment
docker compose up -d --build server      # server 代码进镜像，必须 --build
docker compose ps                         # 确认 running/healthy

# 验证新端点已生效（401 = 端点活；404 = 尚未生效）
curl -s -o /dev/null -w "%{http_code}" https://only.tic.cc/key-escrow
```

> Caddy 容器与 `deployment/.env` 无需改动。

---

## 3. 客户端实测（以口令托管为例，本机 macOS/Linux）

```bash
cd /Users/Shared/productX/only/cli
dart run bin/einz.dart escrow --action upload --store /tmp/a.json \
  --server https://only.tic.cc --passphrase "你的接入口令"
# 期望：✅ 口令托管包已上传

dart run bin/einz.dart escrow --action download --store /tmp/b.json \
  --server https://only.tic.cc --passphrase "你的接入口令"
# 期望：✅ 口令托管包已解出 Space Key
```

> `/tmp/a.json`/`/tmp/b.json` 为设备 store 文件路径（本机 /tmp/ 或按需生成：`init` 后 `config`/`import`）。

---

## 4. 回滚

```bash
cd $EINZ_ROOT
git log --oneline -5                      # 找上一版本 commit
git checkout <上一commit> -- server/ deployment/ shared/
cd deployment && docker compose up -d --build server
```

---

## 5. 注意事项

| 项                | 说明                                                                                                                                                                                           |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 存量数据          | 不受影响（messages/devices/会话等不动，新表初始为空）                                                                                                                                          |
| 白名单            | 无需改动（既有设备认证不受影响）                                                                                                                                                               |
| Caddy / HTTPS     | 无需改动（Caddyfile 已 assume-unchanged）                                                                                                                                                      |
| 备份密钥          | `docker-compose.yml` 已原生支持从 `deployment/.env` 读取 `EINZ_DB_BACKUP_KEY`（.env 被 gitignore 忽略、pull 不覆盖）——**pull 覆盖 compose 也不影响密钥注入**，无需再手动改 compose             |
| 旧部署升级        | 若 .env 里还是旧变量名 `EINZ_BACKUP_KEY`（2026-08 前部署）：手动改名为 `EINZ_DB_BACKUP_KEY` 后 `docker compose up -d --build server`——否则 backup 脚本找不到新变量名会拒绝执行（防误备份明文） |
| App 侧            | 需重新安装 APK 才能启用新 UI（CLI 不受影响）                                                                                                                                                   |
| 首次在 VPS 用 git | 先 `git config --global user.email/user.name`（避免提交时报错）                                                                                                                                |
| pull 冲突         | 若 `git pull` 报冲突：多半是 Caddyfile 被误改——先 `git checkout -- deployment/Caddyfile` 还原，再 `git update-index --assume-unchanged deployment/Caddyfile`                                   |
