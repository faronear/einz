# Einz — 远程访问 iMac 操作手册（docs/REMOTE.md）

> **用途：** 办公室 iMac（主力开发机）↔ 家里 MacBook Air 的远程屏幕连接。
> **场景：** iMac 在办公室（内网，无公网 IP），人带 MacBook Air 回家后远程看屏/操作。
> **方案：** 路线 1 = Apple ID 屏幕共享（主力）；路线 2 = Tailscale + 原生连接（备用）。
> **最后更新：** 2026-09-04

---

## 0. iMac 端现状（已确认就绪，无需再动）

| 项目 | 状态 |
| --- | --- |
| 屏幕共享（端口 5900） | ✅ 监听中（ARDAgent 运行） |
| 远程登录 SSH（端口 22） | ✅ 监听中 |
| Tailscale | ✅ 已装 1.94.1，已登录，在线：`doombase` = `100.100.9.1`（账号 lukerlu@） |
| Apple ID（iCloud） | `luk.lu@icloud.com`（屏幕共享路线需与此同一账号） |
| 系统版本 | macOS 15.7.7（Sequoia） |
| 用户账户 | `luk` |
| 自动睡眠 | ✅ 已关闭（sleep 0 / displaysleep 0）——远程期间不会休眠断连 |
| 局域网 IP | `192.168.1.127`（仅同网段可用，回家后请走下面的跨网络路线） |

> 若 iMac 重启过，可用 `netstat -an | grep 5900` 自查屏幕共享是否还在监听。

---

## 路线 1（主力）：Apple ID 屏幕共享

> 依赖 Apple 中继，无需端口转发；**两台 Mac 须登录同一 Apple ID** 且 **MacBook Air 为 macOS 15+**（Apple 账户连接是 Sequoia 新增功能）。

### MacBook Air 操作步骤

| 步骤 | 操作 |
| --- | --- |
| 0 | 检查系统版本：🍎 → 关于本机。**需 macOS 15+**；若低于 15 请先升级，或改用路线 2 |
| 1 | 系统设置 → 顶部确认**已登录 `luk.lu@icloud.com`**（与 iMac 同一 Apple ID） |
| 2 | 打开「屏幕共享」App（Spotlight 搜"屏幕共享"，或 Finder → 前往 → 连接服务器） |
| 3 | 工具栏输入 **`DoomBase`**（iMac 主机名）连接；或在 Finder 边栏「网络 / 所有连接」中找到 DoomBase 点"共享屏幕" |
| 4 | 弹出登录：用户名 `luk` + iMac 开机密码 |
| 5 | 若问「标准 / 高性能」→ 选**标准**（高性能要求两端 Apple 芯片，iMac 是 Intel 不支持） |

### 故障排查

- 连接被拒 / 找不到 DoomBase → iMac 屏幕共享的「允许访问」范围受限：在 iMac 上 系统设置 → 通用 → 共享 → 屏幕共享 → 允许访问 设为「所有用户」（或「仅这些用户」时把 `luk` 加进去）。
- 提示无法通过 Apple 账户连接 → 确认 MacBook Air 的 Apple ID 与 iMac 完全一致（`luk.lu@icloud.com`），且两端都已开启 iCloud 登录。
- Apple 服务不可达（网络问题）→ 改用路线 2。

---

## 路线 2（备用）：Tailscale + 原生连接

> Tailscale 组虚拟局域网（P2P 加密，经 STUN/UDP 打洞；打洞失败自动走 DERP 中继），无时长限制、数据不过第三方商业服务器。

### MacBook Air 操作步骤

| 步骤 | 操作 |
| --- | --- |
| 1 | 安装 Tailscale（App Store 或 [tailscale.com](https://tailscale.com)），**登录同一账号 `lukerlu@`** |
| 2 | 确认设备列表出现 `doombase`（IP `100.100.9.1`） |
| 3 | 看屏幕：Finder → 前往 → 连接服务器 → 输入 `vnc://100.100.9.1` → 用户名 `luk` + 密码 |
| 4 | 命令行（可选）：终端 → `ssh luk@100.100.9.1`（可看日志 / 跑命令，无需图形界面） |

### 故障排查

- 设备列表没有 doombase → 两台设备确认登录的是**同一** Tailscale 账号（lukerlu@）。
- vnc 连接卡顿 → 走的是 DERP 中继（P2P 打洞失败），属正常降级，操作仍可用。
- 两侧都装了 Tailscale 后也可用 `tailscale status` 互相 ping 通再连。

---

## 综合提醒

1. **出门前在办公室确认一次**：iMac 屏幕共享「允许访问」是否含 `luk`（否则回家连不上还得跑回来）。
2. **iMac 保持开机联网**：已关闭自动睡眠；若办公室断电/断网则远程失效。
3. **应急兜底**：两个路线都失败时，SSH（22 端口）仍可用——至少能看日志、执行命令。
4. **安全**：Apple ID 与 Tailscale 均用个人账号，注意密码强度；远程期间不要做敏感操作（如输银行卡），屏幕内容对 Apple/网络可见性保持清醒。
