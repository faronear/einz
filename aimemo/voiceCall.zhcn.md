# Einz 语音实时通话方案（voiceCall）

> 状态：**[待评审]**（2026-09-18 由讨论整理，尚未开工；评审通过后才进入 `projectPlan.md` 任务列表）
> 依据：`aimemo/productLens.zhcn.md` §14.2 V2 候选「语音/视频通话（WebRTC + STUN/TURN，成熟方案，不自研）」
> 关联：`docs/PROTOCOL.md` §8 WebSocket、`docs/SECURITY.md`、`docs/IOS.md` §0.1、`server/src/push.ts`

---

## 1. 一句话结论

用 **WebRTC（`flutter_webrtc`）+ 自建 coturn**，只做**前台语音通话**（双方都开着 App 才能呼通），
**不做后台呼入**，因此**不接推送**。媒体优先 P2P 直连，打不通时用 TURN 兜底。
TURN 只转发密文，不削弱 E2EE。整体工作量中等，主要风险在原生插件的构建可行性。

---

## 2. 需求边界（老板 2026-09-18 拍板）

| # | 议题 | 结论 | 影响 |
| - | ---- | ---- | ---- |
| 1 | 用户分布 | 国内各地，个位数熟人 | 跨运营商/跨省，P2P 打洞成功率偏低 |
| 2 | 后台呼入 | **不做**（老板 2026-09-18 确认「完全能接受」） | 砍掉 APNs/PushKit/CallKit、FCM/厂商推送、前台服务保活——**这是最大的一块** |
| 3 | IP 暴露 | **可接受** | 默认 P2P 直连，不做「始终中转（隐藏 IP）」开关 |
| 4 | 桌面端 | **放弃** | 只做 iOS / Android；`flutter_webrtc` 桌面支持差，不做适配 |
| 5 | 服务器 | 境内、境外（Oracle 美国）都有，可按需更换 | 信令留美国，TURN 摆国内 |

**「不做后台呼入」的确切语义**：iOS 上 App 退后台几十秒后 WebSocket 即被挂起。
因此真实效果是「**双方都得开着 Einz 才能呼通**」，对方在后台时点过去会无人接听。
UI 必须明确区分「对方不在线 / 振铃中未接 / 已拒绝」，别让人以为功能坏了。

---

## 3. 技术选型

- **媒体栈**：WebRTC（`flutter_webrtc`）。**不自研**——回声消除、抖动缓冲、丢包补偿、码率自适应都在里面。
- **信令**：复用现有 WebSocket（`docs/PROTOCOL.md` §8），服务端仍是哑转发，只加 `call.*` 帧。
- **打洞/兜底**：自建 **coturn**（同时提供 STUN 与 TURN）。
  - STUN 放美国即可（只用来问自己的公网映射，与延迟无关）。
  - **不使用 `stun.l.google.com`**——国内不可靠。
- **编码**：Opus（WebRTC 默认），单向约 24–32 kbps，双向 ~60 kbps。两人产品并发极低，带宽成本可忽略。

### 3.1 TURN ≠ 解密式「中转」（重要澄清）

| 类型 | 服务器做什么 | 能否解密内容 |
| ---- | ------------ | ------------ |
| **TURN**（本方案） | 原样转发 UDP 包 | **不能**——媒体是 DTLS-SRTP 端到端加密，TURN 手里没有密钥 |
| SFU/MCU（Zoom 那类） | 收流、转码、混音、分发 | 能（至少能拿到明文流） |

所以加 TURN **不修改 E2EE 承诺**（「含秘境自身也读不到」依然成立），它和 `server/` 的哑转发器同性质：
只搬密文，代价是带宽，不是信任。副产品：走 TURN 时对方只能看见 TURN 服务器 IP，看不见你的真实 IP。

### 3.2 部署拓扑

```text
信令（call.* 帧）  →  einz.tic.cc（Oracle 美国）   ← 现状不变，只加帧类型
STUN               →  美国同一台 coturn            ← 零成本
TURN 兜底          →  国内服务器                   ← 关键：跨境 UDP 丢包会让兜底链路半残
```

客户端同时配两个 TURN（国内主 + 美国备），ICE 自行择优。实际降级顺序：
**P2P 直连 → 国内 TURN → 美国 TURN**（后两者对用户都是「能打通」）。

运维注意：
- Oracle 云安全组默认只开 22/80/443，需手动放行 **UDP 3478** 与中继端口段（如 49152–65535）；国内机同理。
- 国内机跑 TURN 的备案问题：纯 UDP、不提供网页访问，按经验一般不触发，但机房政策不一。
  → 客户端 TURN 地址写成**可配置项（支持 `IP:port`，不强制域名）**，被卡就换 IP 直连。先试，不提前纠结。

---

## 4. 分阶段计划

### Phase A — 可行性验证（先做，半天~一天）

**目标：在写任何产品代码之前，证明 `flutter_webrtc` 能在本项目的构建链路上跑通。**

- [ ] 最小 demo：两个按钮（发起/接听），无 UI、无协议、硬编码 SDP 交换
- [ ] 验证 Xcode 26.3（本机天花板，见 `docs/IOS.md` §0.1）能编过 iOS 真机包
- [ ] 验证 Android 构建 + Codemagic CI 能过（注意：本项目已有 `device_info_plus` 的 pub cache 补丁先例，
      新增原生插件会放大构建风险）
- [ ] 两台真机（跨网络）能否打通音频
- [ ] **验收**：听到对方声音且无回声。若此步不过，整个方案回退到「对讲机模式」（§6）

> 这是唯一可能翻车的点。先试掉它，后面的工作量预估才有意义。

### Phase B — 前台语音通话 MVP（进行中）

分支 **`feat/voiceCall`**（从 `main` 开出，按最终产品做；Phase A 的验证分支 `feat/voiceCallPhaseA` 保留）

- [x] **协议**（2026-09-26）：`docs/PROTOCOL.md` §8.4「通话信令」；`shared` 加 `kWsTypeCall*` 常量与
      `WsCallEvent`，并**给 `WsClient` 补了发送能力**（此前只有 `listen` 没有 `add`，客户端根本发不出帧）
- [x] **服务端**（2026-09-26）：`call.*` 同 space 哑转发——只转发认识字段、`call_id` 1–64 字符、
      `sdp` ≤32KiB、**按通道限流 120 帧/10s**（`call.ice` 一通电话几十条，不限流等于免费放大器）；
      不落库、不进 `server_sequence`、不参与状态机。**改动需老板重启服务端生效**
- [x] **客户端服务**（2026-09-26）：`VoiceCallService`——发起/振铃/接听/拒接/挂断/忙线/超时状态机，
      trickle ICE，接通后重设音频会话（Phase A 教训：不重设会出现「connected 但没声音」）+ 通话期间常亮
- [x] **UI**（2026-09-26）：聊天页顶部栏通话按钮；振铃（来电=接听/拒绝、去电=取消）与通话中
      （静音/免提/挂断/计时）全屏层；振铃时写明「双方都要在前台」；结束走顶部提示条
- [x] 权限与依赖：`flutter_webrtc` + `wakelock_plus`；iOS `UIBackgroundModes=audio`；
      Android `MODIFY_AUDIO_SETTINGS` / `CHANGE_NETWORK_STATE`
- [x] 多语言：19 个通话键（中英）
- [ ] **通话记录**：聊天流里的记录（已接/未接/时长）——**双向同步为 system 消息**
- [ ] **真机自测**：两端装包后跑通一次（服务端需先重启）

### Phase C — TURN 兜底（按需，观察后再做）

- [ ] 美国机部署 coturn（仅 STUN），客户端接入
- [ ] **上线后统计实际 P2P 成功率**
- [ ] 若经常打不通 → 国内机部署 TURN，客户端配置（主备双 TURN）

### 明确不做

- 后台呼入 / 推送 / CallKit / FCM / 厂商通道
- 视频通话
- 桌面端（macOS / Windows / Linux）
- 「始终中转（隐藏 IP）」开关
- 自研音频传输（在现有 WS 上裸传 PCM）——无回声消除、无抖动缓冲，不可用

---

## 5. 通话信令草案（待评审）

走现有 WS JSON 文本帧，**不落库、不进 `server_sequence`**（断线重连不需要补通话信令）：

| 方向 | type | payload | 说明 |
| ---- | ---- | ------- | ---- |
| C→S | `call.invite` | `{ call_id, media: ["audio"] }` | 发起；服务端广播给同 space 的对端设备 |
| C→S | `call.accept` | `{ call_id }` | 接听 |
| C→S | `call.reject` | `{ call_id, reason }` | 拒接（reason: `declined` / `busy`） |
| C→S | `call.hangup` | `{ call_id }` | 挂断（通话中或振铃中均可） |
| C→S | `call.offer` | `{ call_id, sdp }` | SDP offer |
| C→S | `call.answer` | `{ call_id, sdp }` | SDP answer |
| C→S | `call.ice` | `{ call_id, candidate }` | ICE 候选（多次） |
| S→C | 以上同名帧 | 同 payload + `from_device_id` | 服务端原样转发给对端 |

设计要点：
- 服务端**不解析** sdp/candidate，只校验 `call_id` 形状与空间归属 —— 保持哑转发器性质。
- 振铃超时、忙线判定由**客户端**自行计时，服务端不参与通话状态机（避免服务端状态与重连纠缠）。
- 一人多设备（V2）时 invite 广播给对端全部设备，任一 accept 后其余自动 cancel —— 本期不涉及，仅预留。

---

## 6. 备选方案：对讲机模式（若 Phase A 失败或嫌重）

在**已实现的语音消息**上加「按住即发、松手就发」，零 NAT 问题、零服务器带宽、零推送依赖，
工作量约为语音通话的 1/10。缺点：不实时。
若老板想要的只是「说话比打字快」，这个就够；要的是「随时能听见对方」，才必须走 WebRTC。

---

## 7. 工作量量级

| 模块 | 量级 | 备注 |
| ---- | ---- | ---- |
| Phase A 可行性验证 | 小 | 半天~一天 |
| 信令（协议 + 服务端 + shared） | 小 | 复用现有 WS 与空间隔离 |
| `flutter_webrtc` 接入 | 中 | 原生插件，构建风险集中在这里 |
| 通话 UI + 通话记录 | 中 | 含 l10n |
| coturn（STUN 部分） | 小 | 一个容器 + 两行配置 |
| 国内 TURN（Phase C） | 中 | 部署 + 安全组 + 备案观察 |
| ~~推送 / CallKit / FCM~~ | — | **已砍** |

整体：**中等**（相比完整版「大」——完整版的量级几乎全在后台呼入上）。

---

## 8. 风险与开放问题

1. **构建可行性（最高风险）**：`flutter_webrtc` 是重原生插件，本项目已在 `device_info_plus` 上踩过 pub cache /
   Xcode SDK 的坑（`app/pubspec.yaml:57` 注释、`docs/IOS.md` §0.1），新增插件会放大 Codemagic 与本机构建的不确定性。**Phase A 必须先行。**
2. **P2P 成功率未知**：国内跨运营商场景经验值偏低，需实测数据才能决定 Phase C 是否必要。
3. **验证成本落在老板身上**：通话只能真机 A/B 测，我这边只能跑 `flutter analyze`。
4. **待定**：通话记录是否双向同步？未接来电要不要在 App 图标角标体现（无推送则做不到，跳过）？
5. **待定**：通话期间是否暂停现有的阅后即焚 / 轮询逻辑？（倾向：通话中仍正常收发消息）

---

## 9. 评审要点

| # | 问题 | 结论 |
| - | ---- | ---- |
| 1 | 认可「只有前台能呼通」这个体验代价吗？ | ✅ **已确认（2026-09-18）：完全能接受** |
| 2 | 同意 Phase A（最小 demo）先行？ | ✅ **已确认（2026-09-18）：同意** |
| 3 | TURN 先不做，等实测 P2P 成功率再定？ | ⏳ 待定（**建议：先不做**，只上 STUN） |
| 4 | 通话记录双向同步，还是各自本地留痕？ | ⏳ 待定（**建议：双向同步**，双方都该看到「未接」） |
| 5 | iOS 要不要声明 `UIBackgroundModes=audio`？ | ⏳ 待定（**建议：加**，一行 plist。只保持**已建立的通话**在锁屏/切后台时不断，仍不能用于**呼入**；非上架分发，无审核风险） |
| 6 | Phase A 落地方式：独立 git 分支 + App 内临时调试页（`--dart-define` 开关），SDP 用手动粘贴交换、零服务端改动；验证失败直接弃分支 | ⏳ 待定（**建议：照此执行**） |
| 7 | 验证真机组合：iOS↔iOS / iOS↔Android / 都测？ | ⏳ 待定（**建议：先 iOS↔iOS 跑通，再补 Android**） |

### 权限现状（已核对，Phase A 无需改动）

- iOS `app/ios/Runner/Info.plist:31` 已有 `NSMicrophoneUsageDescription` ✅
- Android `app/android/app/src/main/AndroidManifest.xml:7` 已有 `RECORD_AUDIO` ✅
