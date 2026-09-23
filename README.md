# Einz

双人私密共享聊天空间。端到端加密 (E2EE)、本地优先 (Local-First)、固定两人一空间。

## 仓库结构

```text
docs/        设计文档（E2EE / PROTOCOL / DATABASE / SETUP）
server/      Node.js + TypeScript 服务器（多空间哑转发器，通道在册状态在库里）
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
| `docs/PROTOCOL_MULTIVERSE.md` | 多空间（Multiverse）协议：space 地址、加入闭环、空间隔离与成员鉴权    |
| `docs/DATABASE.md`     | 双端 SQLite schema 与迁移                                                    |
| `docs/SECURITY.md`     | **安全模型与安保政策（威胁模型、现有控制、明确不做、事件处置手册）**         |
| `docs/DEPLOYMENT.md`   | **部署手册（从零部署 + 快速试用 + 备份恢复/撤销轮换运维 + 故障排查）**       |
| `docs/ONBOARDING.md`   | **部署与 AB 互通操作手册（从零到双端对话）**                                 |
| `docs/CI.md`           | **CI 打包指南（GitHub Actions 多平台构建，产物上传 Release）**               |
| `docs/IOS.md`          | **iOS 构建与真机验证指引（Mac 环境）**                                       |
| `docs/updateServer.md` | **服务器更新流程（git push/pull 版，另一台电脑照做即可）**                   |
| `docs/KEY_ESCROW.md`   | **口令托管密钥方案（换设备/朋友接入凭口令，Server 仍只见密文）**              |
| `docs/REMOTE.md`       | **远程访问 iMac 手册（Apple ID 屏幕共享 + Tailscale 两条路线）**             |

## 快速开始（Server）

```bash
cd server
npm install
npm run dev
```

可选：`server/config/serverConfig.json`（本机配置，不入 git）里的 `maxSpaces`
（0=不限 / 1=单空间 / n=上限，改后重启生效）。

## 本地开发配置（App）

本地调试不想连生产服务器（如连本机 `http://localhost:3000`）时，**不要直接改
`app/lib/data/server_settings.dart`**——用 gitignore 的本机配置覆盖：

```bash
cd app
cp localConfig.example.json localConfig.json   # 按需修改里面的 kEinzServer
flutter run --dart-define-from-file=localConfig.json   # flutter run/build 都支持此参数
```

- 本仓有**三个**本机配置文件，都不入 git（已 .gitignore），只有模板 `localConfig.example.json` 入库：
  - `app/localConfig.ios.json` / `app/localConfig.android.json` —— **分平台**，被下方 npm 脚本直接引用；
  - `app/localConfig.json` —— 通用，手动加 `--dart-define-from-file=localConfig.json` 时用。
- 打包入口：iOS release 用 `npm run build-prod-ios`（连生产服务器 einz.tic.cc）；Ad Hoc 安装包用
  `npm run build-ios-adhoc`（含 `--install` 变体），App Store 用 `npm run build-ios-appstore` /
  `npm run upload-ios-appstore`；Android 用 `npm run build-prod-apk`。
- 本机调试（已含 `--dart-define-from-file`，指向 localhost:3000）：iOS 模拟器 `npm run ios-run-dev` /
  `ios-run-dev-new`（+ `ios-refresh` 热重载、`ios-reload` 热重启），Android 模拟器 `npm run apk-run-dev` /
  `apk-run-dev-new`。`scripts/build_ios.sh` 已移除，相关能力并入 npm 脚本。
- 调试入口（手动）：`flutter run --dart-define-from-file=localConfig.json -d <UDID>`（run 同样支持）
- 服务端对应：`server/config/serverConfig.json`（不入 git）的 `maxSpaces`（0=不限 / 1=单空间 / n=上限，改后重启生效）
