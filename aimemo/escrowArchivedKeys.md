# 密保箱纳入归档 Space Key（修复轮换后新设备旧消息不可读）

> **状态：`[待评审]`**（老板确认讨论后再转 `[待开发]`，2026-09-14）
> **关联**：KEY_ESCROW.md §7/§13、E2EE.md §9.2、productLens §4.4

## 1. 问题

密保箱 payload 只含**当前** Space Key：`{space_key, space_id, key_version}`。

轮换过密钥的空间里，新设备凭密保口令接入后拿不到归档密钥 → 旧 key_version 的
消息**永远解不开**（服务器信封还带旧 key_version，历史全量重拉也解不出明文）。

`SpaceKeyRing.rotate()`（shared/lib/src/crypto/keyring.dart）已实现轮换算法，
但**全项目零调用点**：App 无轮换入口、TUI 无、Server 无轮换端点——轮换目前
实际不可执行，归档密钥场景尚未真实发生过。backup/restore（CLI）是唯一携带
`archived_space_keys` 的载体。

## 2. 方案（老板已定：三端一起到位）

### 2.1 payload 结构 v2（可选字段，向后兼容）

```json
{ "space_key": "…", "space_id": "…", "key_version": 2,
  "archived_space_keys": [ {"key_version": 1, "space_key": "…"} ] }
```

- `archived_space_keys` 可选，缺省 = 空数组 = 旧包语义；
- 结构与 CLI store 的 `archived_space_keys` 一致（E2EE.md §9.2），不发明新格式；
- Server 零改动（永不解析包内容，PROTOCOL.md §7 承诺）。

### 2.2 shared（核心）

- `EscrowPayload` 加可选字段 `archivedSpaceKeys`（默认 const []）；
- `createPackage(..., archivedSpaceKeys: …)` 写入；
- `openPackage` 宽松解析（坏字段丢弃不抛）。

### 2.3 写端（upload 调用点）

| 调用点 | 改动 |
| --- | --- |
| `lock_page._syncEscrow`（App 解锁重传） | `AppLockPayload` 加可选 `archivedSpaceKeysB64`（JSON 数组串，随锁包存 SecureStore，受 PIN 保护；不进 app_state 明文） |
| `chat_page` 改口令上传 | 从 widget payload 取归档字段一并重传 |
| `setup_page` 首次上传 | 新设备无归档，传空 |
| CLI `escrow upload` | store.archivedSpaceKeys 直接带上 |
| TUI 上传点 | store 同 CLI |

### 2.4 读端（新设备接入）

口令接入 `fetch()` 解出 payload → 归档密钥随 `EscrowPayload` 返回 → 写入本端
锁包（SecureStore）。**自愈**：任何持有完整密钥环的设备解锁重传一次，密保箱即
补全；存量旧格式密保箱在下次解锁重传时自动升级，无需迁移脚本。

### 2.5 兼容性

| 场景 | 行为 |
| --- | --- |
| 旧客户端读新包 | fromJson 手写提取字段，多余字段被忽略 → 兼容 |
| 新客户端读旧包 | 字段缺省 = 空 → 行为同现状 |
| 混合版本空间 | 先升级方重传 → 后升级方自然获得 |

### 2.6 测试

- shared：createPackage/openPackage 往返（带/不带归档字段）；旧格式兼容解析；
- app_lock_test：AppLockPayload 归档字段持久化往返；
- CLI 冒烟：escrow upload 带归档 → fetch 解出。

## 3. 连带发现：轮换入口缺失（独立后续任务，未定）

`SpaceKeyRing.rotate()` 全项目无调用：App 菜单无「轮换 Space Key」入口、TUI 无、
Server 无轮换端点。productLens §12 说「撤销必须触发轮换」，但撤销 → 轮换的
自动化链路不存在。

**含义澄清（回答老板 2026-09-14 提问）**：App 端轮换入口 = 撤销设备流程中
（或独立菜单），由剩余在网设备生成新 Space Key、本地归档旧密钥、重传密保箱
（本方案落地后归档密钥随密保箱分发），新消息用新 key_version。不是用户手动
"换钥匙"的操作概念，而是撤销安全闭环的一部分。TUI 确实也没有。

**触发方式设计（老板 2026-09-14 提出，两条并行）：**

1. **撤销联动（自动）**：设备撤销成功 → Server 广播 `space.rotated` 事件 →
   在网设备各自本地执行 rotate + 归档 + 重传密保箱。需 Server 新增广播事件
   （或复用 device.revoked 事件即触发）；
2. **用户主动（手动入口）**：聊天页 ⋯ 菜单「轮换 Space Key」（确认弹窗说明
   后果）→ 本端 rotate → 通知对端设备自动跟随（对端收到事件/下次上线时
   同步新密钥）。

**主动轮换的适用场景**（为什么值得有）：怀疑某段通信环境不安全、怀疑密钥
材料曾暴露但设备未被撤销、定期卫生习惯。注意：主动轮换**不能撤销任何设备**
的接入权（那仍靠白名单），它只使"过去泄露的密钥"对未来密文失效——定位是
"假设最坏情况后的止损"，与撤销联动是互补而非重复。

**实现顺序建议**：先落本方案（归档密钥随密保箱分发），再做轮换入口
（Server 广播 + App/TUI 两端联动），否则轮换后对端拿不到新密钥/归档密钥，
闭环不成立。

## 4. 工作量

1. shared EscrowPayload/KeyEscrowService（~1h）
2. AppLockPayload 归档字段 + App 各接入/重传点（~1-2h）
3. CLI/TUI 调用点（~0.5h）
4. 文档 KEY_ESCROW.md / E2EE.md §9.2 交叉引用（~0.5h）

---

## 5. 评审意见（2026-09-14，CodeBuddy 会话复核）

> 方向认可：payload v2 加可选字段、Server 零改动、解锁重传自愈、格式沿用
> `archived_space_keys` 不发明新格式——都能落地，且 §3"轮换入口全未实现"经核实
> 属实（`SpaceKeyRing.rotate()` 确无生产调用点）。以下两点建议在开工前定一下。

### 5.1 `upload()` 是覆盖式写包 → 归档集合可能被"缺件的设备"写小

`KeyEscrowService.upload()` 用当前设备的密钥环整体重建 payload 覆盖服务端。
设备 B 若在某次轮换时离线（本地缺该版本的归档密钥），它下次解锁重传就会把密保箱的
`archived_space_keys` 写少，把设备 A 已补进去的版本挤掉——"自愈"变成"互相覆盖"。

**建议：上传前先 fetch 现有包 → 与本地归档做 max-union → 再上传。** App 的
`_syncEscrow` 本来就已经 `getKeyEscrow()` + `openPackage()` 验过一次口令（防旧口令
覆盖），顺手把归档并进去即可，成本≈0。CLI/TUI 的上传点同理。

### 5.2 影响面需在文档与 productLens 里对齐措辞

归档密钥入箱后，"拿到密保口令"= 能解**该 Space 的全部历史**（不再只是当前密钥）。
这与产品意图一致（凭口令全量恢复），但 productLens §4.4 与本文档相邻处写着
"轮换不能追溯历史"——那句讲的是**被撤销设备已同步的密文**，与"密保箱可解历史"
是两回事，建议两处各加一句限定，避免将来读成自相矛盾。

### 5.3 顺带：`docs/KEY_ESCROW.md` 两处笔误（与本文档无关，见者顺手改）

- 表格"盐 每次托管随机生成（32B）"→ 实为 16B（`crypto_pwhash_SALTBYTES`）；
- 同表把口令派生/加密/信封的出处标为 `backup.dart` → 规范位置已是
  `shared/lib/src/crypto/passphrase_crypto.dart`（backup 仅 re-export）。
