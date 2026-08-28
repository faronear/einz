# OnlySpace — 跨机器交接手册（HANDOFF）

> **用途：** 从本机（macOS, `/Users/Shared/product-产品/only`）迁移工作到另一台电脑继续开发。
> **最后更新：** 2026-08-28（Windows 续接已完成，见 §3/§4 状态）
> **git HEAD：** `ece01e8`（5 个提交，工作树干净，无远程仓库）→ **Windows 续接后已推进**

---

## 1. 如何把仓库搬到新电脑

仓库当前**没有远程**，二选一：

**方式 A（推荐）：git bundle 单文件**
```bash
# 本机生成（已随本手册生成，见仓库根 onlyspace.bundle 或重新生成）
cd <本机仓库>
git bundle create onlyspace.bundle --all

# 新电脑
git clone onlyspace.bundle only
cd only
```

**方式 B：建立远程仓库**（如 AtomGit / git.tic.cc）
```bash
git remote add origin <远程URL>
git push -u origin main
```

---

## 2. 新电脑需要安装的环境

| 依赖 | 版本 | 安装方式（macOS） | 备注 |
| --- | --- | --- | --- |
| Node.js | ≥ 22 | `brew install node` | Server 运行时 |
| Dart SDK | 3.11 | `brew install dart-sdk` | **公式名是 dart-sdk 不是 dart** |
| libsodium | 最新 | `brew install libsodium` | shared/CLI 加密依赖（Dart 侧加载 /opt/homebrew/lib/libsodium.dylib） |
| Flutter SDK | 3.x stable | 见下"Flutter 安装" | 任务 #16 用 |

**Flutter 安装（中国网络镜像）：**

```bash
# Google storage 与 GitHub 在本机不可达；使用中国镜像：
curl -L -o /tmp/flutter.zip \
  "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.41.0-stable.zip"
mkdir -p ~/development && cd ~/development
unzip -q /tmp/flutter.zip        # 需 ≥9GB 磁盘空闲（解压后 4-5GB）
export PATH="$PATH:$HOME/development/flutter/bin"
flutter --version
```

**磁盘提示：** 本机安装 Flutter 失败正是因为磁盘只剩 5.8GiB。新电脑请先确认 ≥9GB 空闲。

---

## 3. 当前进度（Phase 0 状态）

| 模块 | 状态 | 验证方式 |
| --- | --- | --- |
| `docs/`（E2EE/PROTOCOL/DATABASE/SETUP） | ✅ 完成 | — |
| `server/` Node+TS 服务 | ✅ 完成 | `cd server && npm install && npm run build && npm test`（冒烟全过） |
| `shared/` 纯 Dart 核心包 | ✅ 完成 | `cd shared && dart pub get && dart analyze && dart test`（8 项单测全过） |
| `cli/` 测试端 + 配置工具 | ✅ 完成 | `cd cli && dart pub get && dart analyze` |
| 端到端验收 `cli/test/e2e.sh` | ✅ 通过 | `cd cli && bash test/e2e.sh` |
| `deployment/` docker-compose + Caddy | ✅ 完成 | — |
| **#16 Flutter app/ 骨架** | ✅ **已完成（Windows 续接）** | `flutter create . --platforms=ios,android`，接入 `onlyspace_shared`，`dart analyze` + `flutter test` 全过 |
| Phase 1 消息 MVP | ⏸ 下一步 | — |

---

## 4. 新电脑续接步骤

```bash
# 1. 环境就绪后验证
node --version && dart --version && flutter --version

# 2. 装依赖并跑全部验证
cd server && npm install && npm run build && npm test
cd ../shared && dart pub get && dart analyze && dart test
cd ../cli && dart pub get && dart analyze && bash test/e2e.sh

# 3. 完成任务 #16：Flutter app/ 骨架
cd app
flutter create . --platforms=ios,android --project-name onlyspace
# 在 app/pubspec.yaml 添加:
#   onlyspace_shared:
#     path: ../shared
# 然后把 lib/ 接入 shared 核心包（UI 骨架见 projectPlan Phase 3）

# 4. 更新 aimemo/projectPlan.md 与 worklog，提交
```

---

## 5. 已知踩坑备忘（已修复，勿回退）

1. **base64 变体**：libsodium-wrappers 默认 URL-safe 无填充；协议统一**标准 base64 + 填充**（`ORIGINAL` 变体）。改 server/src/crypto.ts 与测试时勿回退。
2. **WS token 必须 URL 编码**（PROTOCOL.md §8.1）：session_token 含 `+`/`=`。
3. **sync 响应必须补 `v:1`**（PROTOCOL.md §5.2）：`v` 是协议常量未入库。
4. **Dart 加载 libsodium**：shared 的 `loadDynamicLibrary` 优先 `LIBSODIUM_PATH` 环境变量，其次 macOS Homebrew 路径——新电脑若用非 Homebrew 路径装 libsodium，需设置 `LIBSODIUM_PATH`。
5. **npm 依赖**：`libsodium-wrappers` 的 ESM 入口在 Node ESM 下损坏，server 统一用 `createRequire` 加载 CJS 构建。
