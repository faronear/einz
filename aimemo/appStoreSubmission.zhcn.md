# Einz App Store 上架准备 — Review Notes 模板 与 Privacy Nutrition Labels 口径 `[已实现→待提审使用]`

2026-10-19。承接 accountDesign.zhcn.md 的上架讨论与「内置演示秘境」（方案 A，见 worklog 2026-10-19 与 `app/lib/data/demo_space.dart`）。本文档是**提审时的操作物料**：每次提审从 §1 复制粘贴，§2 作为 App Store Connect 填表的对照口径。中国大陆区不考虑（ICP 备案前置，见 accountDesign §六.5）。

---

## 1. Review Notes 提审模板（每次提审复制到 App Review Information → Notes）

> 说明：审核员读英文，Notes 用英文写；要点顺序按审核员关注度排（怎么进主功能 → 为什么没账号 → 隐私主张 → 联系方式）。

```
Einz is a privacy-first, end-to-end-encrypted messaging app for two
people (usually a couple), or a small invited group of close friends.
There is intentionally NO account or sign-up flow: access is by device
key pairs and invitation links only.

HOW TO EXPLORE THE APP (no setup needed):
1. Launch the app. On the wizard entry screen ("Create" / "Join" cards),
   tap the link at the bottom: "Take a look around first".
2. This opens a fully functional demo conversation generated locally on
   the device (encrypted with the same code path as real messages).
   You can send messages, long-press a bubble to recall it, open the
   main menu (top-right) to see settings, entrance list, space switching, etc.
   Messages in the demo space never leave the device.
3. To see the real creation flow, go back and tap "Create" — you can
   create a real space and chat; messages sync end-to-end-encrypted via
   our server.

WHY THERE IS NO ACCOUNT: Einz's privacy model stores nothing that could
identify users — the server only sees ciphertext and minimal metadata
(no phone number, no email, no contacts). User identity is a device key
pair; spaces are joined via invitation links. Adding accounts is not
required for any functionality.

PRIVACY: No ads, no analytics SDKs, no tracking. Messages, photos,
videos, voice notes and files are encrypted on-device; the server cannot
decrypt them. Privacy policy: https://www.einz.tic.cc/rules/privacy_policy/

ENCRYPTION EXPORT COMPLIANCE: The app uses only publicly available
standard algorithms (X25519 / XChaCha20-Poly1305 via libsodium, Argon2,
TLS) and qualifies for the exemption (ITSAppUsesNonExemptEncryption=false).

USER-GENERATED CONTENT: There is no public content, no user discovery,
no search, no feed. Spaces are private, membership is by invitation only
(server-enforced static whitelist), and each space is normally two
people. Any user can delete their own messages, delete the whole space,
or revoke their own entrance (cutting off that device) at any time.

CONTACT for review questions: einz@tic.cc
```

**提审前逐项核对**（每次发新版都要过一遍）：

- [ ] 演示入口文案与模板第 1 步一致（改了 `setupEntryDemo` 文案要同步改这里）
- [ ] 演示秘境在新版里仍能进、消息仍能渲染（跑一次 demo 流程）
- [ ] 隐私政策页可访问、内容与新版一致
- [ ] `ITSAppUsesNonExemptEncryption=false` 仍在（iOS/macOS 两份 Info.plist）
- [ ] 联系邮箱 einz@tic.cc 仍能收信
- [ ] 审核期间四域名（yuanjinx/farinear/bittic/…）服务稳定；einz.tic.cc 解析 127.0.0.1 是故意的，别当故障修
- [ ] 截图/预览视频与新版界面一致（App Store Connect 资源）

**方案 B 备选**（若本轮被拒，理由涉及"无法体验真实聊天"）：给审核 Notes 补一条邀请链接（指向预配空间的 join token，对端由 CLI headless bot 自动回复）。届时再做，见 accountDesign 讨论记录。

---

## 2. Privacy Nutrition Labels 填表口径（App Store Connect → App Privacy）

对照口径：privacy_policy 页 + `docs/DATABASE.md`/审计表实现。原则：**数据是否"收集"看是否离开设备**（Apple 定义：transmit off device 即 collected，与是否关联身份无关）。

### 2.1 Data Used to Track You（跨 App 追踪）

- **None**。无广告、无第三方 SDK、无 ATT 追踪。

### 2.2 Data Linked to You（关联到身份的数据）

- **None**。服务器不知道任何 PII：无账号/邮箱/手机号/通讯录；entrance_id 与 install_uid 是随机标识，privacy_policy 已声明不用于画像。
- 注意：**头像与显示名/性别**若走服务端同步，口径上属于用户自选内容而非 PII 标识符——但保守起见，如有疑问填 "Other User Content"（见 2.3），**不要**勾 "Identifiers"（install_uid 不是 Apple 意义上可关联真身的 identifier，且我们绝不拿它关联身份）。

### 2.3 Data Not Linked to You（收集但不关联身份）

| Apple 数据类型                                  | 填不填  | 子项                                                                        | 依据                                                                                                                                                               |
| ----------------------------------------------- | ------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **User Content**                                | ✅ 填   | Other User Content Types                                                    | 消息/附件**密文**与成员自选的显示名、性别、头像上服务器（端到端加密内容服务器不可读，但确实离机传输 → 按定义算 collected；密文不可读 + 无身份关联 → "Not Linked"） |
| **Diagnostics**                                 | ✅ 填   | Other Diagnostic Data（审计元数据：时间、大小、序列号、push token 前 8 位） | server/audit.ts 只记元数据，哨兵断言保证无密文/明文                                                                                                                |
| **Identifiers**                                 | ❌ 不填 | —                                                                           | 随机 entrance/install 标识不关联真身、不可跨 app（见 2.2 备注）                                                                                                    |
| **Usage Data**                                  | ❌ 不填 | —                                                                           | 无分析、无广告交互、无产品互动遥测（last_seen 在线状态属于服务运行所必需且不持久画像；若被问询按"App Functionality"解释）                                          |
| **Location / Contacts / Financial / Sensitive** | ❌ 不填 | —                                                                           | 完全不涉及                                                                                                                                                         |

### 2.4 健康声明顺序提醒

- 填表先答 "Do you or your third-party partners collect data from this app?" → **Yes**（按 Apple 定义离机传输即 collected，2026-10-20 实填口径；答 No 会生成与隐私政策页矛盾的 "Data Not Collected" 标签）。
- 然后在 "data not linked to you" 下手动添加 2.3 表中 ✅ 的两类。多填比漏填安全——Apple 审核对 label 与实际不符（尤其漏报）比多报严格得多。

### 2.5 与隐私政策页的一致性

- policy 说「服务器存什么」= 2.3 的 User Content（密文+成员资料）与 Diagnostics（元数据）两条，口径一致 ✓
- policy 说「不收集不分析聊天内容」指明文/内容分析，与"密文离机算 collected"不矛盾（Notes 与 label 均已如实说明）。

---

## 3. 状态记录

| 项                                                                | 状态                                             |
| ----------------------------------------------------------------- | ------------------------------------------------ |
| 隐私政策页（含邮箱 einz@tic.cc）                                  | ✅ 已备（2026-10-19，commit e5e46a8a）           |
| 出口合规标记 iOS                                                  | ✅ 已有（2026-09-21）                            |
| 出口合规标记 macOS                                                | ✅ 已补（2026-10-19，commit a48dc78f）           |
| distribution profile `Einz Dist Appstore`（App ID `cc.tic.einz`） | ✅ 本机已装（早期 `cc.tic.einz.ios` 尝试已废弃） |
| 内置演示秘境（方案 A）                                            | ✅ 已实现（2026-10-19，commit 8b1357fb）         |
| Review Notes 模板                                                 | ✅ 本文 §1                                       |
| Nutrition Labels 口径                                             | ✅ 本文 §2（提审时照填）                         |
| 正式开发者账号（Team CQ6733CTMV 付费）                            | ✅ 已有                                          |
| ASC 建档物料（名称/描述/分级/URL 等）                             | ✅ 本文 §4（照填 App Store Connect）             |

---

## 4. App Store Connect 建档物料（2026-10-19 起草）

> 主语言英文（不考虑中国区；App 内已支持中英，zh 描述为可选的二级本地化，先给英文，zh 版照译即可）。

### 4.1 基本信息

| 字段                | 填写                                                    | 说明                                                                                   |
| ------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Platform            | iOS（+ macOS 可后建）                                   | 先 iOS                                                                                 |
| App Name            | `Einz — Your Secret Realm`                              | 23 字符；老板 2026-10-20 定夺：名称吃 realm 品牌红利（原 `Einz — Private Space` 弃用） |
| Subtitle            | `End-to-end encrypted`                                  | 30 字符内；核心卖点                                                                    |
| Bundle ID           | `cc.tic.einz`                                           | 与 profile 一致                                                                        |
| Primary Language    | English (U.S.)                                          |                                                                                        |
| Copyright           | `Faronear Co. Ltd.`                                     | 与 Team CQ6733CTMV 实体一致（老板核对全称）                                            |
| Category（一级）    | **Social Networking**                                   | 私密社交是主定位                                                                       |
| Category（二级）    | **Lifestyle**                                           | 或 Communication——备选，二者都行，老板拍板                                             |
| Support URL         | `https://www.einz.tic.cc/`                              | 首页含 Getting started / 隐私政策                                                      |
| Marketing URL       | `https://www.einz.tic.cc/about/what_is_einz/`（可留空） |                                                                                        |
| Privacy Policy URL  | `https://www.einz.tic.cc/rules/privacy_policy/`         | 必填                                                                                   |
| 邮箱（审核联系）    | `einz@tic.cc`                                           |                                                                                        |
| Release on approval | **Manual release**（建议）                              | 首版过审后自己挑时间发布；也可自动                                                     |

### 4.2 描述（Description，≤4000 字符）

```
Einz is a secret realm for you and the people who matter — end-to-end
encrypted, local-first, and account-free.

YOUR SECRET REALM
Create a space and invite someone with a single link. Everything inside
— messages, photos, videos, voice notes, and files — is encrypted on
your device before it ever leaves it. Not even we can read it.

NO ACCOUNTS. NO TRACE.
There is no sign-up, no phone number, no email, no profile to find.
Who you are is a key pair on your device. Your server only ever sees
ciphertext.

BUILT FOR PRIVACY, BY DESIGN
· End-to-end encryption (XChaCha20-Poly1305) on every message and file
· Local-first: your history lives on your device, not in our cloud
· Burn-after-read messages that vanish on a timer
· Recall any message — for everyone
· PIN lock with auto-lock timer, and a demo mode to explore first

GROUPS TOO
Create a duo space for two, or a group space for the people you choose.
Membership is by invitation only — there is no discovery, no search,
no feed, and no public content. Ever.

Einz will never show you ads, never profile you, and never sell data.
Privacy isn't a feature here. It's the architecture.
```

### 4.3 Keywords（100 字符，逗号分隔无空格）

```
private,messenger,encrypted,E2EE,secure,chat,secret,diary,couple,notes,vault
```

> 覆盖：私密聊天 / 加密 / 情侣 / 日记 / 保险柜场景词。Name/Subtitle 里的词不计入，别重复。

### 4.4 What's New（首版）

```
First release on the App Store.
```

### 4.5 年龄分级问卷（Age Rating）— 照此作答

| 问题                                                          | 答                     | 依据                                            |
| ------------------------------------------------------------- | ---------------------- | ----------------------------------------------- |
| Cartoon/Fantasy Violence, Realistic Violence（含 blood/gore） | No                     | 无此内容                                        |
| Sexual Content / Nudity                                       | No                     | 无此内容                                        |
| Profanity / Crude Humor                                       | No                     | 无                                              |
| Alcohol/Tobacco/Drugs                                         | No                     | 无                                              |
| Medical information                                           | No                     | 无                                              |
| Gambling（含 simulated）                                      | No                     | 无                                              |
| Contests / Contests with real prizes                          | No                     | 无                                              |
| Horror/Fear themes                                            | No                     | 无                                              |
| Unrestricted web access                                       | **No**                 | App 无内嵌浏览器/任意 WebView                   |
| **User-Generated Content**                                    | **Yes**                | 聊天消息即 UGC（如实答）                        |
| → 分级结果                                                    | 预期 **12+**（因 UGC） | 若出 17+ 属正常，照单全收——别为了低分级隐瞒 UGC |

> UGC 答 Yes 后 ASC 会问 "Do you have report/block/moderation?"——Notes/描述里的「无公开内容、邀请制白名单、可删除一切」就是回答口径；如有自由文本框，写：_"No public content or discovery. Spaces are invite-only with a server-enforced member whitelist; users can delete any message, delete their space, or revoke their own device access at any time."_

### 4.6 截图 / 预览

| 项       | 要求                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 尺寸     | 6.9"（1320×2868 或 1290×2796）与 6.5"（1284×2778 / 1242×2688）两组，各至少 1 张（建议 3–6 张）；iPad 另备 13"（2064×2752）                                                                                                                                                                                                                                                                                                                |
| 内容定稿 | 2026-10-20 老板拍板 5 张英文版（全部演示秘境摆拍）：`app/screenshots/iphone_6_9/` 01 向导入口 / 02 分流页（Duo/Group）/ 03 聊天主界面 / 04 阅后即焚设置 / 05 锁屏码设置。**ASC 6.9" 槽位最多传 4 张**，建议上传：02 分流页（开篇——一眼看懂双人/群组两种形态，老板认为比 01 入口页更好）→ 03 聊天主界面 → 04 阅后即焚 → 05 锁屏码；01 入口页留作备选。逻辑：聊天软件功能大同小异，Einz 突出隐私——分流页讲形态、后三张讲体验+两个隐私杀手锏 |
| 摆拍注意 | 别用真实空间截图（会暴露真实聊天）；演示秘境专为这个场景存在。自动化流水线：`app/integration_test/screenshots_test.dart` + `screenshots_drive.sh`（文件握手 + simctl 截图）；模拟器需 en-US + app 全新安装（demo 才按英文种入）                                                                                                                                                                                                           |
| 预览视频 | 可选；如做，演示秘境里录收发/焚化动画最直观                                                                                                                                                                                                                                                                                                                                                                                               |

### 4.7 提交前还差的账号动作（老板手动）

1. App Store Connect 建 App 记录（Bundle `cc.tic.einz`）；
2. `buildIos.sh appstore --upload`（`ASC_API_KEY_ID`/`ASC_API_ISSUER` 已在脚本就绪位）出首个正式包；
3. 填 §4.1–4.5 + Nutrition Labels（§2 口径）+ Review Notes（§1 模板）；
4. 提审。
