# 改名与数据契约评审：42c8dc86..HEAD

| 项目 | 内容 |
| ---- | ---- |
| 日期 | 2026-09-23 |
| 评审人 | AtomCode（qwen3.8-27b） |
| 评审对象 | 分支 `feature/multiSpace` 上 `42c8dc8621d6b4a74efc06fabe193397487132a6..HEAD`（评审时 HEAD = `3b9cd2b`，33 个提交，156 文件，+6590/−5182） |
| 评审重点 | 前后端数据与逻辑（不看文案）：业务逻辑漏洞、改名引发的不一致、缺陷 |
| 改动主线 | ① 全量改名 device→entrance / person→partner / device_uid→install_uid；② 附件按空间分片落盘（服务端 `files/<space_id>/<前2位>/<id>` + App 缓存同构分目录）；③ 备份/恢复支持 `--space`；④ 逻辑修正（同设备重复加入拦截、两人同名拒绝、重置语义、TUI `/device(s)` 别名保留） |
| 方法 | 全局改名残留 grep；前后端 wire / DB / 本地持久化契约逐字段核对；新逻辑针对性读码；测试验证 |
| 验证结果 | server `npm test` 全过（0 fail）、`tsc --noEmit` 干净；shared `dart test` 52 全过；app 相关测试（setup_join_duplicate_space / multi_space_isolation / message_repository）35 例全过。cli 的 pty e2e 未跑（与本次重点关联度低，耗时）。注：`code_review` 工具 deep 模式因 diff 达 1.4MB 全部维度失败，结论完全来自逐文件独立核对 |

---

## 一、高危（上线前必须处置）

### H1 服务端存量库无改名迁移——旧库升级会启动崩溃或静默失配

`server/src/db.ts` 把建表语句直接改成新表名/新列名（`entrances`/`entrance_id`/`partner_id`/`install_uid`/`sender_entrance_id`/`sender_partner_id` 等），迁移段**没有任何**"旧 `devices` 表/旧列 → 新结构"的搬数逻辑。旧生产库升级后的实际后果：

- `messages` 表因 `IF NOT EXISTS` 保留旧表（旧列名）。若旧表还是全局唯一 `server_sequence`，触发重建迁移时 `INSERT ... SELECT ... sender_entrance_id ... FROM messages` 会直接 **"no such column" 启动崩溃**；若已是复合唯一则不重建，此后每次 `/sync` 查询报 "no such column" → 500。
- `entrances` 是新建空表，旧 `devices` 数据（登记/公钥/会话/push/回执/escrow）全部留在旧表无人读取 → 所有存量通道变 `missing`。

项目已用 `c7d0eee`（DEPLOYMENT.md §5.5「上线前彻底重置」）把"清 `data/` + 客户端重置两边一起做"作为处置手段——**这是有意识的选择，不是漏了**。但注意：

1. 一旦漏做或只做一半（只清服务端），后果是"App 能开、连不上、本地还留着旧历史"（文档自己也写了），且旧数据物理上还在旧表里，**不可自动找回**。
2. 建议做成发布 checklist 的硬门禁（重启前校验 `data/` 为空或备份在案），而不是靠文档自觉。

### H2 wire 协议字段全量改名，但 `X-Protocol-Version` 仍是 1——无干净的版本边界

服务端 `PROTOCOL_VERSION = 1` 未动，而所有 wire 字段都变了：`sender_device_id→sender_entrance_id`（消息信封）、`device_id→entrance_id` / `person_id→partner_id`（WS payload、challenge）、WS 类型 `device.revoked→entrance.revoked`、`/space` 响应 `devices→entrances` / `person_names→partner_names`、create/join 响应 `partnerSlot→slot` 等。后果：旧客户端连新服务端**协议版本校验能通过**，然后是一串隐蔽失败——`POST /messages` 直接 400（缺 `sender_entrance_id`）、`/space` fromJson 崩、收不到 `entrance.revoked`（旧客户端等 `device.revoked` → 被撤销后不自毁、带着死通道反复 401）。

与 H1 同根：整族重置是前提，但协议版本没随 breaking change 递增，等于放弃了"旧客户端明确报版本不匹配"这道干净的护栏。

**建议**：协议版本升到 2（服务端对 v1 明确 400 PROTOCOL_VERSION_MISMATCH），成本一行，换可诊断性。

---

## 二、中危（缺陷/语义削弱）

### M1 App 媒体缓存 `deleteAll()` 在分片后失效——「整机重置」留解密明文

`MediaCache.deleteAll()`（media_cache.dart:48）实现是顶层 `dir.list()` 且 `entity is! File` 就跳过。分片后缓存文件全在 `<cache>/<spaceId>/` 子目录里，顶层只有目录 → **实际一个文件都删不掉**。调用点正是 `resetLocalData()`（整机重置）。"重置回到新设备状态"的隐私承诺被打破：全部空间的解密媒体明文残留。对比 `AttachmentStore.clear()` 用 `delete(recursive: true)` 是对的——只此一处漏了。

**修法**：`deleteAll` 改 `dir.delete(recursive: true)`（或递归 list）。一行级修复，建议本次就补。

### M2 TUI store JSON 键改名无旧键回读——存量 TUI 通道身份丢失

`EntranceStore.fromJson` 直接按新键（`entrance_id`/`partner_id`/`install_uid`/`slot`/`partner_names`…）读，旧 store 文件（`device_id`/`person_id`/`device_uid`/`partner_slot`…）加载后这些字段全为 null/空。`space_id`/`space_key`/密钥对键名没变还留着 → 用户拿着 Space Key 但 `entranceId` 为 null → challenge 无法向服务端自证身份 → **服务端那条通道成了客户端够不到的孤儿**（还占着通道额度）。

文档重置步骤（§5.5）只写了 `rm -f ~/.einz/*.json`——**只覆盖默认目录，`--store` 显式指定的多通道文件在别处，会漏清**，恰好命中这个失效模式。

**建议**：① 文档补一句"清掉所有 `--store` 用过的文件"；② fromJson 加旧键回读（`json['entrance_id'] ?? json['device_id']` 等），成本很低，升级平滑。

### M3 App profile 旧 JSON 键不回填——升级后名字显示为空

`app_lock.dart` loadProfile 只读 `partnerName`/`entranceName`，旧 app_state 里存的 `personName`/`deviceName` 读不回来（键名改了、JSON 是旧值）。后果是显示层退化（"关于我"/通道名空 → 重置闸门降级为打固定确认词，有兜底、不丢功能）。同样一行级回读可修。

### M4 重复加入拦截对 `install_uid=NULL` 不生效（有意为之，但约束被削弱）

`joinSpace` 的 dup 检查 `if (uid != null)`——存量行/未升级客户端不带 install_uid 时服务端不拦，第二条通道照插，第一条变孤儿（客户端凭证被覆盖、服务端那条仍 active 占额度）。代码注释明确"客户端是主拦点、服务端是第二道"。App 有 preflight 闸门没问题；**TUI 若 store 里 install_uid 为 null（旧文件），两层闸门都没有**，产品级"一设备一空间一通道"约束实际可绕过。低概率，但值得知道。

### M5 单空间备份的 entrances 清理/导出按 partner 反查，会波及同身份的其他空间通道

`restoreSpace` 的 `DELETE FROM entrances WHERE partner_id IN (该空间的 partners)` 会**先删掉同一身份在其他空间的通道行**，随后 INSERT 又把它们插回来（exportSpaceRows 同样按 partner 反查、把它们也导出了）。同文件备份+恢复时净效果无损，但：①"单空间备份"实际不是纯单空间（含同身份他空间通道行及其 `last_seen` 等会回滚到备份时点）；②未来导出/清理两侧口径若改动不同步就是坑。建议加注释固化"导出与清理必须同口径"的不变式（entrances 无 space_id 列，精确圈定需 join sessions 或明确接受现状）。

### M6 两人同名校验是严格字符串相等

服务端 `creatorName === peerName`、App 端 `partner == _creatorName.text.trim()` 都不归一化大小写/空白。"Lukas" 与 "lukas" 可过。实际危害有限（join 选身份是选 slot 不是按名字串匹配），但与"同名无法判别身份"的初衷有缝隙。低。

---

## 三、命名残留/不一致（改名清扫的漏网）

| # | 位置 | 残留 | 性质 |
|---|------|------|------|
| L1 | `shared/lib/src/protocol/api_client.dart:190` | 注释 "生成邀请码（POST /invites…）" 挂在 `postMessage` 上方 | 已删端点的死注释，位置都错 |
| L2 | `cli/bin/einz_tui.dart:1255` | 注释 "存 `[device-id].json`" | 旧术语 + 事实错误（实际固定 `myeinz.json`） |
| L3 | `docs/DEPLOYMENT.md §5.5` | "安装级 `device_uid`" | 本批新增的文档自己用旧术语（应 install_uid） |
| L4 | `server/src/spaces.ts:355` | 409 message "this device already has an entrance…" | 面向用户的报错里 device 未改干净（语义是"本设备"），且同文件其他报错为中文、中英混；App 端映射了自有文案，仅 TUI 直显时可见 |
| L5 | `server/src/spaces.ts:191` | `newJoinToken(spaceId, "creator")` 写入 `created_by_entrance` 列 | 列名是 entrance_id，存的却是字面量 "creator"（既有设计），改名后更刺眼，建议加注释或改列语义 |
| L6 | `app/lib/data/app_lock.dart:53` | profile 注释只列 3 字段，实际还读写 gender/slot 4 字段 | 注释不全（改名前就缺） |

代码层改名本身干净：`deviceUid|device_uid|deviceName|personName|person_slots|partnerSlot` 等旧标识符在 app/cli/server/shared 全部 0 残留；剩余 "device" 只出现在合法语境（APNs device token、HTML viewport、注释历史说明、TUI 有意保留的 `/device(s)` 别名）。

---

## 四、对这批命名修改的独立意见

**概念层面：三个改名都是真改进，术语体系第一次自洽了。**

1. **device→entrance**：旧名最大的问题是 "device" 一词过载了两层——物理设备（跨空间一台）和登记项（安装×空间一条），`devices` 表装的其实是后者，读代码持续踩坑。`entrance`（通道）精确钉死登记项层，物理层交给 `install_uid`，GLOSSARY 里"安装×秘境=通道"的定义至此名实相符。**这批改名里价值最大的一个。**
2. **person→partner**：贴合"两人私密空间"的产品定位，有"另一半"的情感指向，比中性的 person 好。小瑕疵：`partner_id` 同样指自己（空间里两位成员都叫 partner），"partner 指自己"语义略别扭；更中性的选择是 `member`，但在两人空间里太泛、丢失产品气质。**接受 partner**；唯一提醒：若产品将来扩到多人空间，这词装不下了。
3. **device_uid→install_uid**：真修复。它的生命周期是安装级（卸载重装/整机清空即轮换），一台物理机可有多份安装，旧名 device_uid 暗示的"设备级"是错的。

**执行层面：改得彻底，但时机和代价管理是问题所在。** 改名波及面 = 代码 + 服务端 DB + 客户端持久化文件 + wire 协议 + 文档，这次只干净地完成了第一项：

- wire 变了、协议版本没动（H2）——改名应与协议版本治理**联动**，breaking wire change 必须 bump；
- 服务端 DB schema 变了、没迁移（H1）——改 DB 名的成本在数据存在的那一刻就开始累积，**越早改越便宜**，压到上线前做等于把成本全部推迟到最贵的时点（只能用"清库重来"消化）;
- 本地持久化（TUI store、app profile JSON）是"没人当它是协议、但其实也是协议"的东西，旧键无回读（M2/M3）。

**一句话结论**：术语体系改对了，但这次是"把协议变更当重构做了"。

---

## 五、后续行动

| 优先级 | 事项 | 成本 |
| ------ | ---- | ---- |
| 本次就补 | M1：`MediaCache.deleteAll` 改递归删 | 1 行 |
| 本次就补 | M2/M3：TUI store / App profile 旧键回读 | 各几行 |
| 本次就补 | H2：`PROTOCOL_VERSION` 1→2，服务端对 v1 明确 400 | 1 行 |
| 上线门禁 | H1：DEPLOYMENT §5.5 进发布 checklist（重启前校验 `data/` 为空或备份在案）；§5.5 补"清所有 `--store` 用过的文件"（M2 配套） | 流程 |
| 待办 | M4：TUI 旧 store 无 install_uid 时的第二道闸门（或文档明示该限制） | 小 |
| 待办 | M5：`restoreSpace` 加"导出/清理同口径"不变式注释 | 注释 |
| 待办 | M6：同名校验是否做 trim/大小写归一（产品决策） | 决策 |
| 待办 | L1–L6：命名残留清扫 | 各 1 行 |

**未验证项**：cli 的 pty e2e（`guide_*`/`reset_returns_to_guide_check` 等）未跑；如需可单独跑。
