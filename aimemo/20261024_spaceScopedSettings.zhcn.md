# 空间作用域设置全谱：「应用于本机所有秘境」的四种方案

**整理日期**：2026-10-24（老板复查触发：邮件通知走哪套？一次 apply-for-all 会成为未来新空间的默认值吗？）
**关联设计**：20260918_multiSpaceDesign.zhcn.md（多空间总体设计）、20261009_voiceTranscript.zhcn.md §15.1（转写设置）

---

## 要回答的问题

多个设置弹层都有「应用于本机所有秘境」勾选框（settingsScopeAll）。勾选后，**之后新建的空间**会继承这个值吗？

**答案不统一——共四种方案**，核心差异在「勾选时写什么」和「新空间读什么」。

---

## 总表

| 设置 | 存储 | 勾选「所有秘境」的落地 | 之后新建的空间继承？ |
|---|---|---|---|
| 语音转写（方式+自动） | 本地 app_state | 写**全局键** + 清所有 per-space 覆盖 | **是** |
| 附件存储 | 本地 app_state | 同上 | **是** |
| 墓碑显示 | 本地 app_state | 同上 | **是** |
| 阅后即焚 | 本地 app_state | 逐空间写 per-space 键，**不写全局** | 否（默认关闭） |
| 邮件通知 | **服务端**（API，按空间各一份） | API 扇出到当时所有空间 | 否（服务端无绑定） |
| 界面主题 | 本地全局键（无空间维度） | 无勾选框（本就全局） | 是（本就全局） |
| 成员名/通道名（改名类） | 服务端 + 本地 profile | API 扇出 + 本地 profile 同步改写 | 否 |

---

## 方案 A：全局键 + 清覆盖（mixin 三兄弟）

**类**：SpaceScopedSetting mixin（app/lib/data/space_scoped_setting.dart）
**使用方**：VoiceTranscriptSettings（engine/auto 两个键）、AttachmentStorageSettings、TombstoneSettings

- 键两层：per-space `space.<spaceId>.<key>`；全局 `<key>`（v7 多空间上线前的旧键，存量回退源）
- 写：save() → 写 scopedKey；saveAll() → 写全局键 + clearSpaceOverrides()（删所有 space.*.<key> 行，Dart 侧精确匹配首尾，不用 SQL LIKE——键名里的 _ 是通配符会误伤）
- 读：scoped → 全局 → 默认（转写多一层 legacy voice_transcript_auth 单键派生）
- **新空间**：per-space 没有 → 读到全局值 → **继承**，直到该空间自己存过一次值
- 代码：space_scoped_setting.dart（saveAll:39 / clearSpaceOverrides:48）

## 方案 B：本地逐空间扇出（阅后即焚）

**类**：BurnAfterSettings（自有 scoped 键，**不用** mixin）

- 勾选落地：_saveBurnAllSpaces（chat_page.dart:5965）——当前空间先落，再遍历 VaultSession.current.spaces 逐个写各自的 per-space 键，best-effort（单空间失败静默）。**全局键从不被写**
- 读：scoped → 全局（仅 v7 前 legacy 回退）→ 默认 0（关闭）
- **新空间**：读不到任何键 → 默认关闭，**不继承**
- 例外：若库里有 v7 前的旧全局 burn_after_seconds，新空间会经 legacy 路径继承它——但那是老版本留下的，不是 apply-for-all 写的
- 设计理由：焚毁是破坏性功能（到期自动删），新空间默认关闭是安全侧

## 方案 C：服务端设置 + API 扇出（邮件通知）

**无本地设置类**，逻辑在 chat_page.dart；本地 app_state **零键**（2026-10-24 实测 dev 库确认）

- 读：getNotifyEmail(当前空间 token)——无回落链，每空间独立
- 写：setNotifyEmail / deleteNotifyEmail（当前空间）；勾选才 _fanoutOtherSpaces（chat_page.dart:3087）——用 Vault 里各空间的会话调同一个 API，best-effort
- **新空间**：服务端无绑定 = 「未设置」，**不继承**
- 两个附带后果：
  1. 扇出只覆盖**当时解锁在场**的空间（VaultSession 内存态；某空间这次没解锁/ token 空 → 收不到，静默）
  2. 换设备/重装后，邮件绑定**跟随服务端**恢复——与方案 A/B 的纯本地设置相反（那些换设备即丢）

## 方案 D：无空间维度（界面主题）

UiStyleSettings 存全局键，设备级设置，弹层不渲染勾选框。

## 改名类（附）

成员名/通道名（「我的身份」「当前通道」弹窗的勾选框）：API 扇出 + _rewriteOtherSpacesProfile（chat_page.dart:3110）把本地各空间 profile 同步改写。不是键值设置，新空间名字走创建流程，不参与继承。

---

## 2026-10-24 修复的 bug（教训案例）

VoiceTranscriptSettings._ScopedKey.write 曾误传**裸 key**（全局）而非 scopedKey——不勾「所有秘境」的保存也污染全局键，所有空间经读时回退全部中招（老板实测）。修复=传 scopedKey；v12 迁移把存量全局值认领进各空间 per-space 键后删全局键。

**教训**：mixin 的语义正确性依赖每个使用方写对键——writeSetting(scopedKey, …) 是唯一正确写法（tombstone/attachment 本来就对，转写曾错）。新增走 mixin 的设置类时，先对照这三个类的 save/load 再写。

---

## 待评审：不一致要不要统一

现状是「按风险分级」：破坏性/上送类（焚毁、远程托管）偏安全侧（不覆盖未来空间），偏好类（转写/墓碑/附件存储）覆盖未来空间。两个统一方向：

- **统一到全局语义**（阅后即焚/邮件通知也写全局）：未来新空间跟着设置——方便，但焚毁类有「惊喜删消息」风险
- **统一到扇出语义**（mixin 三兄弟也只覆盖当时空间）：新空间走默认——可预测，但勾选框文案「所有秘境」名不副实

未决议，等老板拍板。

---

## 代码索引

| 内容 | 位置 |
|---|---|
| mixin 本体（saveAll/clearSpaceOverrides） | app/lib/data/space_scoped_setting.dart |
| 转写设置（读回落/legacy 派生） | app/lib/data/voice_transcript_settings.dart |
| 附件存储 / 墓碑（正确写法参照） | app/lib/data/attachment_storage_settings.dart / tombstone_settings.dart |
| 阅后即焚 + 扇出 | app/lib/data/burn_after_settings.dart；chat_page.dart:5965 _saveBurnAllSpaces |
| 邮件通知 + 扇出 | chat_page.dart:3087 _fanoutOtherSpaces；3315-3323（停用）/ 3370-3378（保存） |
| 改名扇出 + profile 改写 | chat_page.dart:3110 _rewriteOtherSpacesProfile |
| 勾选框渲染 | app/lib/widgets/option_picker_sheet.dart（scopeAllLabel）；burn_duration_sheet.dart |
| 测试 | app/test/voice_transcript_settings_test.dart（隔离语义）；local_database_migration_test.dart（v12） |
