# Einz

双人私密共享聊天空间。端到端加密 (E2EE)、本地优先 (Local-First)、固定两人一空间。

## 仓库结构

```text
docs/        设计文档（E2EE / PROTOCOL / DATABASE / SETUP）
server/      Node.js + TypeScript 服务器（静态白名单哑转发器）
shared/      纯 Dart 共享核心（crypto / protocol / sync）—— App 与 CLI 共用
cli/         Dart CLI 测试端（无 UI，Phase 0–4 测试驱动）
app/         Flutter 手机客户端（V1）
deployment/  Docker Compose + Caddy
aimemo/      记忆与工作空间（productLens / projectPlan / worklog / userProfile）
```

## 设计文档

| 文档                   | 内容                                                                         |
| ---------------------- | ---------------------------------------------------------------------------- |
| `docs/E2EE.md`         | 密钥层级、派生、配置分发、认证、轮换、恢复                                   |
| `docs/PROTOCOL.md`     | REST + WebSocket 协议唯一权威                                                |
| `docs/DATABASE.md`     | 双端 SQLite schema 与迁移                                                    |
| `docs/DEPLOYMENT.md`   | **部署手册（从零部署 + 快速试用 + 备份恢复/撤销轮换运维 + 故障排查）**       |
| `docs/IOS.md`          | **iOS 构建与真机验证指引（Mac 环境）**                                       |
| `docs/updateServer.md` | **服务器更新流程（git push/pull 版，另一台电脑照做即可）**                   |
| `docs/KEY_ESCROW.md`   | **口令托管密钥方案（`[待评审]`：换设备/朋友接入凭口令，Server 仍只见密文）** |
| `docs/SETUP.md`        | 一次性配置设计稿（命令级实作见 DEPLOYMENT.md §2/§4）                         |
| `docs/REMOTE.md`       | **远程访问 iMac 手册（Apple ID 屏幕共享 + Tailscale 两条路线）**             |

## 快速开始（Server）

```bash
cd server
npm install
npm run dev
```

可选：`server/einz_server_config.json`（本机配置，不入 git）里的 `maxSpaces`
（0=不限 / 1=单空间 / n=上限，改后重启生效）。

## 本地开发配置（App）

本地调试不想连生产服务器（如连本机 `http://localhost:3000`）时，**不要直接改
`app/lib/data/server_settings.dart`**——用 gitignore 的本机配置覆盖：

```bash
cd app
cp local_config.example.json local_config.json   # 按需修改里面的 kEinzServer
flutter run --dart-define-from-file=local_config.json   # flutter run/build 都支持此参数
```

- `app/local_config.json` **不入 git**（已 .gitignore）——覆盖 `kEinzServer` 等启动参数（`String.fromEnvironment`），不污染 commit
- 打包入口：`npm run build-ios`（iOS release，连生产服务器 einz.tic.cc）；Android 出包用 `npm run build-apk`。本机调试带本地配置用 `npm run ios-run` / `npm run ios-run-new`（已含 `--dart-define-from-file=local_config.json`，指向 localhost:3000）。`scripts/build_ios.sh` 已移除，相关能力并入 npm 脚本。
- 调试入口：`flutter run --dart-define-from-file=local_config.json -d <UDID>`（run 同样支持，手动加参数即可）
- 服务端对应：`server/einz_server_config.json`（不入 git）的 `maxSpaces`（0=不限 / 1=单空间 / n=上限，改后重启生效）
