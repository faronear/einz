# OnlySpace

两个人的私密聊天与共享私人空间。E2EE、Local-First、固定两人一空间。

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

| 文档 | 内容 |
| --- | --- |
| `docs/E2EE.md` | 密钥层级、派生、配置分发、认证、轮换、恢复 |
| `docs/PROTOCOL.md` | REST + WebSocket 协议唯一权威 |
| `docs/DATABASE.md` | 双端 SQLite schema 与迁移 |
| `docs/DEPLOYMENT.md` | **部署手册（从零部署 + 快速试用 + 备份恢复/撤销轮换运维 + 故障排查）** |
| `docs/IOS.md` | **iOS 构建与真机验证指引（Mac 环境）** |
| `docs/updateServer.md` | **服务器更新流程（git push/pull 版，另一台电脑照做即可）** |
| `docs/KEY_ESCROW.md` | **口令托管密钥方案（`[待评审]`：换设备/朋友接入凭口令，Server 仍只见密文）** |
| `docs/SETUP.md` | 一次性配置设计稿（命令级实作见 DEPLOYMENT.md §2/§4） |

## 快速开始（Server）

```bash
cd server
cp config/config.json.example config/config.json   # 填入两台设备公钥
npm install
npm run dev
```
