# Einz — 一次性配置手册（docs/SETUP.md）

> **状态：** Draft v0.1（Phase 0 产出）
> **适用场景：** 首次部署 Einz——两台设备 + 一台服务器，一次性建立信任关系。
> **关联文档：** `docs/E2EE.md` §7（密钥分发）、§8（认证）；`docs/PROTOCOL.md`；`aimemo/productLens.zhcn.md` §5。

---

## 1. 目标与产物

**目标：** 让两台设备各持一份 Space Key、服务器只认两台白名单设备，全程服务器不接触任何明文。

**配置产物清单：**

| 产物 | 内容 | 保存位置 |
| --- | --- | --- |
| `config.json` | space_id + 两台设备（device_id / person_id / 公钥 / status） | 服务器（禁止提交 Git） |
| 设备 A 密封副本 | `sealed_space_key_a`（仅 A 可解） | 一次性流转，导入 A |
| 设备 B 密封副本 | `sealed_space_key_b`（仅 B 可解） | 一次性流转，导入 B |
| 恢复码 | 12 词助记词或打印二维码 | **用户离线保存**（Server 不接触） |

---

## 2. 前置条件

- 一台服务器（VPS，已装 Docker 与 Docker Compose，或 Node ≥ 22）。
- 两台手机（iOS / Android），各安装 Einz App（分发见 productLens §13）。
- 一个域名（用于 Caddy HTTPS/WSS，如 `space.example.com`）。

---

## 3. 配置流程

```text
┌─ 设备 A ─┐      ┌─ 设备 B ─┐      ┌─ 配置工具 ─┐      ┌─ 服务器 ─┐
│ 首次启动  │      │ 首次启动  │      │（CLI/脚本）│      │          │
│ 生成身份钥│      │ 生成身份钥│      │            │      │          │
│ 导出公钥A │─────►│          │      │            │      │          │
│          │      │ 导出公钥B │─────►│ 生成SpaceKey│      │          │
│          │      │          │      │ 密封给A、B  │      │          │
│          │      │          │      │ 生成config  │─────►│ 加载白名单│
│ 解封并保存│◄─────│          │      │ 密封副本    │      │          │
│ SpaceKey │      │ 解封并保存│◄─────│            │      │          │
│          │      │ SpaceKey │      │            │      │ 启动服务  │
└──────────┘      └──────────┘      └────────────┘      └──────────┘
```

### 步骤 1：两台设备生成身份密钥

- 设备 A、B 首次启动 App / CLI，各自生成 X25519 身份密钥对（E2EE.md §3）。
- **私钥只留在设备安全存储（Keychain / Keystore），永不外传。**
- 导出公钥（base64），交给配置阶段使用。

> 现状：客户端（App / CLI）尚在开发（Phase 0 待装 Dart SDK）；当前可先用 Node 侧脚本或冒烟测试中的 `TestDevice` 生成密钥对验证流程（`server/test/smoke.test.ts`）。

### 步骤 2：生成 Space Key 并密封（配置工具）

配置工具（计划为 Dart CLI 子命令，[待开发]）执行：

```text
1. space_id = UUIDv7
2. space_key = randombytes(32)
3. sealed_a = crypto_box_seal(space_key, pubKeyA)
4. sealed_b = crypto_box_seal(space_key, pubKeyB)
5. 输出：config.json + 密封副本 A + 密封副本 B
```

- 密封副本用公钥 A/B 分别加密：**只有对应设备能解开**（E2EE.md §7.1）。
- 产物格式：`einz-config-v1`（E2EE.md §7.1）。

### 步骤 3：登记服务器白名单

把 `config.json` 放到服务器（或 `deployment/config/config.json`），内容示例：

```json
{
  "space_id": "0192…",
  "devices": [
    { "device_id": "dev-a1", "person_id": "person-a", "public_key": "base64…", "status": "active" },
    { "device_id": "dev-b1", "person_id": "person-b", "public_key": "base64…", "status": "active" }
  ]
}
```

- 该文件**禁止提交 Git**（已在 `.gitignore`）。
- 服务器启动时加载为静态白名单：不在其中的设备一律拒绝（E2EE.md §7.3）。

### 步骤 4：导入设备（解封 Space Key）

- 设备 A 导入自己的密封副本 → 用本机私钥 `crypto_box_seal_open` 解出 Space Key → 存入安全存储。
- 设备 B 同理。
- 导入后删除密封副本临时文件（避免再次流转）。

### 步骤 5：启动服务器

**本地开发：**

```bash
cd server
cp config/config.json.example config/config.json   # 填入真实白名单
npm install && npm run build
npm run dev
```

**生产部署：**

```bash
cd deployment
cp ../server/config/config.json.example ./config/config.json
# 修改 Caddyfile 域名 → space.example.com
docker compose up -d --build
```

- 生产强制 HTTPS/WSS（Caddy 自动签证书）；验证 `https://space.example.com/space` 返回鉴权错误而非连接失败。

---

## 4. 配置验证清单

| 检查项 | 方法 | 期望 |
| --- | --- | --- |
| 白名单生效 | 用未登记公钥的设备请求 `/auth/challenge` | 403 |
| 认证闭环 | A 完成 challenge-response | 拿到 session_token |
| E2EE 闭环 | A 发密文 → B 同步 → B 解密 | 明文只在两端 |
| Server 无明文 | 检查 `data/app.db` 的 messages 表 | 只有 ciphertext |
| 恢复码 | 导出备份并尝试导入 | 可恢复 |

> 端到端自动化验证已由 `server/test/smoke.test.ts` 覆盖（认证 / E2EE 密文 / 幂等 / 同步 / 白名单 / 明文隔离 / WS 实时）。

---

## 5. 后续操作

### 换机恢复（模型 A）

1. 新设备安装 → 输入恢复码 → 解密导入备份（E2EE.md §10）。
2. 新设备生成新身份密钥 → 公钥加入 `config.json` → 重启服务器。

### 撤销设备与密钥轮换

1. `DELETE /devices/:id`（服务器返回 `key_rotation_required: true`）。
2. 剩余可信设备生成新 Space Key（key_version +1），重新密封分发（E2EE.md §9）。
3. 服务器 `config.json` 中移除被撤销设备。

### 备份（运维）

- 定期备份 `deployment/data/`（app.db 用 SQLite Backup API，禁止直接复制运行中的 db）+ 加密文件目录（DATABASE.md §6）。

---

## 6. 安全注意事项

- 配置阶段的操作（密钥生成、密封、导入）应在**受控环境**进行，避免在共享/公共电脑上执行。
- 密封副本流转后立即销毁；恢复码务必离线保存多份。
- `config.json`、私钥、恢复码三者分开存放，任一单独泄露都不足以解密历史消息（密文在 Server、密钥在设备、恢复码在用户）。
