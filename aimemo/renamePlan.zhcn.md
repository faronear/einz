# 字段改名计划：`device_id` → `entry_id`、`person_id` → `partner_id`/`member_id`

状态：**`[已定，待执行]`**（2026-09-22 起草并拍板；**执行推迟到 M3 收尾、多空间上线稳定之后**）
关联：`docs/GLOSSARY.md`（术语分层，改名的全部依据）、`aimemo/multiSpaceDesign.zhcn.md` §3.7

---

## 0. 目标、不变量、非目标

**目标**：把 `docs/GLOSSARY.md` 定的三层（物理设备 / 安装 / 登记项）与"人"的层在
**wire + DB + 代码 + 文档**里一次理清。当前 `device_id` 实际是"登记项 id"、
`person_id` 实际是"秘境内的插槽身份 id"，两个名字都名不副实。

**不变量**（任何一步都不许破）：

1. **用户零感知**：界面文案、功能、数据一律不变（UI 用词已单独定过，见 GLOSSARY §命名约定）；
2. **老客户端不坏**：双名期内新旧客户端都能正常收发，**含生产上那 4 台设备**；
3. **老本地数据不丢**：老锁包 / 老 store / 老 drift 行必须仍能读出身份（🔴 最容易出事，见 §4）。

**非目标**：

- **不引入全局 person 身份**。老板的方向是"一个真人（person）→ 多个秘境里的多个 partner"，
  但那是**产品/隐私决策**（服务器将能确定"同一个真人出现在多个秘境"，比 `device_uid`
  更进一步），要单独设计；本次改名只是**把 `person_id` 这个名字腾出来**，不改数据模型。
- **不改 UI 用词**（界面继续用「设备」，只在跨秘境歧义处加限定词，已落地）。
- **不改 `/devices/*` HTTP 路径**（见 §5 D2）。

## 1. 改名对照

| 现在 | 改成 | 所属层 |
| --- | --- | --- |
| `device_id` / `deviceId` | `entry_id` / `entryId` | **登记项**（安装 × 秘境） |
| `person_id` / `personId` | `member_id` / `memberId`（D1 已定） | **秘境内的插槽身份** |
| `person_name` / `person_names` / `person_genders` / `person_slots` | `member_*`（D3 已定） | 同上的显示名 / 性别 / 槽位 |
| `sender_person_id`（外层信封字段） | `sender_member_id` | 消息的发送者身份 |
| `partner_slot` / `partner_name` / `partner_gender` | **不动** | 它们是"第二人专属"的既有词（见 D1 说明），不在本次范围 |
| 服务端 DB 列（7 处） | 同左（一次性迁移） | 服务端内部 |
| （将来）`person_id` | — | 留给**真人**的全局身份，本次不动 |

## 2. 改动面（实测计数，2026-09-22）

| 类别 | server/src | shared/lib | app/lib | cli | 合计 |
| --- | --- | --- | --- | --- | --- |
| `device_id` / `deviceId` | 141（含 19 个 JSON 键） | 10 | 99 | 56 | **306** |
| `person_id` / `personId` | 114 | 36 | 172 | 137 | **459** |
| `person_name` 类 | 35 | 26 | 43 | 107 | **211** |
| 合计（wire + 代码） | | | | | **≈ 976** |

另有：服务端 DB 列 7 处、drift 本地表列、TUI store JSON 键、**锁包 JSON 键**；
`docs/` + `aimemo/` 约 166 处文字需同步。绝大多数是机械替换，**难点在边界与兼容，不在数量**。

## 3. 迁移机制（alias 三期）

**地基已有**：REST 用请求头 `X-Protocol-Version`、WS 用握手 `?pv=` 做硬校验
（`server/src/app.ts:assertProtocolVersion`），v1 → v2 那次协议收敛就是靠它切轨道；
`VaultPayload.fromJson` 也有"旧格式读取时归一"的先例。**双名并存在本项目很好做**：
`device_id` 几乎只出现在响应里，客户端主动发送它的只有
`POST /auth/challenge` 请求体与 `POST /devices/:id/revoke` 路径参数两处。

### P1 准备（服务端单侧，零客户端影响）

1. `devices` 加一列 `last_proto_version INTEGER`（WS 里也记 `?pv=`）：**只在值变化时写**
   （进程内缓存去重，仿 `server/src/audit.ts` 的 `lastSyncByDevice` 手法），避免写风暴；
2. `assertProtocolVersion` 从"必须等于 1"改为**接受 {1, 2}**（唯一改动点，一行集合判断）；
3. **双名映射集中在一个文件**（新增 `server/src/protocolAliases.ts`）：入参读新回退旧、
   出参同时写新旧两套键。**禁止散落到各 handler** —— 否则 P3 永远删不干净；
4. 兼容性回归测试：老客户端对响应里**多出来的未知键必须宽容**（Dart 按 key 取，多余键无害，
   但要用测试钉住，别让它哪天变成严格校验）。

### P2 客户端切新名（跨端发布一轮）

1. `shared/`（App 与 TUI 共用）先改 → **App iOS/Android/macOS + TUI 一起发**；
2. 客户端**读新键、回退旧键**（新客户端也能连未升级的服务端，灰度更稳），并上报 `pv=2`；
3. 本地持久化三处一律"**读旧回退、写新**"：
   - 锁包 `AppLockPayload`（PIN 密文，见 §4 R1）、
   - TUI `DeviceStore`（store.json，含 `history` 里的老信封）、
   - App drift 本地表（`sender_person_id` 等列）。

### P3 收尾（服务端单侧，由遥测触发，不拍脑袋）

1. 判定可以删旧名：

   ```sql
   SELECT COUNT(*) FROM devices
    WHERE status = 'active' AND (last_proto_version IS NULL OR last_proto_version < 2);
   ```

   结果为 0 且**持续 ≥ 30 天**才动手；
2. `protocolAliases.ts` 删旧读旧写；`assertProtocolVersion` 收紧；文档/术语表收尾。

## 4. 风险（按严重度）

| 级别 | 风险 | 处理 |
| --- | --- | --- |
| 🔴 R1 | **锁包是 PIN 密文**：老密文解出来的 JSON 用的是旧键。新代码若不回退读，老用户解锁后 `deviceId` 读成 null → **直接进不了聊天**（比"显示错名字"严重得多） | P2 必须"读旧回退、写新"，且**加一条用真·旧格式密文的测试**；不改写老密文（下次写盘自然升级） |
| 🟡 R2 | 老本地历史：drift `local_messages.sender_person_id`、TUI store 的 `history` 信封 | 渲染路径回退读旧键；TUI store 老文件必须能读 |
| 🟡 R3 | 双名期内两套名字并存 → 可读性反而不如现在 | 用"只在序列化边界映射 + 单文件"把并存限制住；P3 尽早删 |
| 🟢 R4 | 服务端 DB 列名 | 建议**跟着改**（SQLite `RENAME COLUMN`，一次性迁移、客户端零影响）；客户端 drift 列名**保留**（本地不可见，改要重建表） |
| 🟢 R5 | 那 4 台生产设备可能长期不升级 → 旧名删不掉 | 接受长期双名；或推动升级后按 §3 P3 判定 |

## 5. 决策（2026-09-22 已定）

| # | 决定 |
| --- | --- |
| **D1** | `person_id` → **`member_id`**（与表名 `space_members` 一致、不偏袒插槽；见下方分析：`partner` 在本仓库已是"第二人专属"词，用它会让 slot 0 也叫 partner）。`partner_slot` 是否改 `slot` **不在本计划内**（不强求） |
| **D2** | HTTP 路径**不改**，只改字段。遗留一处表面不一致：`POST /devices/person-name` 的路径里 `devices` / `person` 两个词都旧了——本次保留（路径改名要路由双注册，收益低） |
| **D3** | 名字类字段**一起改** → `member_name` / `member_names` / `member_genders` / `member_slots`（DB 列本来就是中性的 `display_name`） |
| **D4** | 两个改名**合并到同一个协议窗口**：一次双名期、一次跨端发布、一次遥测判定 |
| **D5** | **等 M3 收尾、多空间上线稳定后再执行**；不和功能改动混在一批（改名机械量大，混着做会让 review 失效） |

### D6（执行前定，我的倾向）

`POST /spaces` 创建时带两个名字：`person_name`（创建者/slot 0）与 `partner_name`（第二人/slot 1）。
机械统一会让这对读成 `member_name` + `partner_name`（不对称）。我倾向：

- **`person_name` → `creator_name`**（与 `partner_name` 成对、更可读），
- `partner_name` / `partner_gender` / `partner_slot` **保持不动**；

即：**泛称（按 id 索引的表）用 `member_*`，具体插槽用 `creator_*` / `partner_*`**。
若老板想要"一路机械替换"，那就统一成 `member_name`，也可接受。

### D1 专门分析：`partner_id` vs `member_id`

老板的模型是"一个真人（person）→ 多个秘境里的多个 partner"，`partner` 指"秘境里的一位"。
**方向没问题，但本仓库里 `partner` 已经有既定含义，且是"插槽 1 专属"**：

- `db.ts`："伴侣（partner_slot=1）"；`spaces.ts`："伴侣（第二人）预置"；
- 向导的 `partnerName` / `partnerGender` = **第二人（slot 1）**的名字/性别。

也就是说，现在 `partner` ≈ `slot 1`，而 `person_id` 是**两个插槽都有**的。直接改名会让
slot 0（创建者）的身份也叫 `partner_id` —— 与"partner = 伴侣 = 第二人"直接打架。

两条路都可行，选一条：

- **(a) `member_id`（我推荐）**：与表名 `space_members` 一致、不偏袒任何插槽，
  零语义冲突，改动最省（`partner_slot` 也可择机改 `slot`，但不强求）；
- **(b) `partner_id`**：符合老板的产品心智，但**必须同时**把 `partner_slot` 改名
  （建议 → `slot`），并把 create 向导里"伴侣"字样只留给第二人 —— 否则 `partner`
  一词同时表示"两位之一"和"第二位"。

## 6. 执行清单（拍板后按此走）

- [x] 拍 D1–D5（2026-09-22）
- [ ] 定 D6（创建时两个名字字段的叫法）
- [ ] P1：遥测列 + 版本双接受 + `protocolAliases.ts` + 未知键兼容测试
- [ ] P2：`shared/` 改 → 三端发布 → 客户端读新回退旧 + 锁包老密文测试
- [ ] 观察 `last_proto_version` 分布（`npm run audit` 或直接 SQL）
- [ ] P3：删旧名（≥30 天无老版本活跃设备）
- [ ] 文档收尾：`docs/GLOSSARY.md` 的"暂不改"段落改写为"已改"；术语表加版本对照
