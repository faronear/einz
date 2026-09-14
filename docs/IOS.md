# Einz — iOS 打包与真机安装指引（docs/IOS.md）

> **状态：** v2.0（2026-09-14 重写，玩法 A 已实测通过：`flutter build ios --release`
> + `devicectl` 直接安装到 iPhone 11）。
> v1.0 里的 bundle id（`com.example.onlyspace`）、仓库地址（`git.tic.cc/fon/only`）、
> 「当前无付费账号」等说法均已过时——以本文档为准。

---

## 0. 当前配置速览

| 项 | 值 | 备注 |
| --- | --- | --- |
| Bundle ID | `cc.tic.einz` | 已配在 `app/ios/Runner.xcodeproj`（`PRODUCT_BUNDLE_IDENTIFIER`） |
| Team ID | `37KQR6645B` | 个人团队（Leiqin Lu / `yuanjinwx@outlook.com`），已配在 `DEVELOPMENT_TEAM` |
| 签名身份 | `Apple Development: yuanjinwx@outlook.com (K5L5J4Z8TB)` | 有效期 2026-09-10 → 2027-09-10 |
| 生产服务器 | `https://einz.tic.cc` | 代码默认值（`app/lib/data/server_settings.dart`），真机开箱可用 |
| 部署目标 | iOS 15.0 | |
| 本机 Flutter | 3.47.2（`~/development/flutter`） | 需 `export PATH="$HOME/development/flutter/bin:$PATH"` |
| SPM | **必须关闭** | `flutter config --no-enable-swift-package-manager`（本项目用 CocoaPods + 本地 libsodium pod） |
| APNs 推送 | **未接入** | Dart 侧有注册逻辑、`AppDelegate.swift` 有 MethodChannel，但工程缺 Push Notifications capability；服务端 `sendPushHint` 仍是日志占位。不影响聊天（WS 兜底） |

### ⚠️ 账号级别提醒（2026-09-14 实测发现）

当前 team `37KQR6645B` 签发的 provisioning profile 有效期**只有 7 天**
（2026-09-14 → 2026-09-21）——这是**免费个人团队**的特征，付费会员是 1 年。

所以：**如果已续费付费会员，要确认续费的是哪个账号**。本机 keychain 里另有一张
`Apple Distribution: Faronear Co. Ltd. (CQ6733CTMV)`（2025-07-15 已过期），以及配套的
Ad Hoc/profile 文件（2024 年就过期了）——看起来 Faronear 公司账号才是那个"付费/机构"账号。
若续费的是它，需要在 Xcode 登录该 Apple ID、重新生成证书与 profile，并把本工程的
`DEVELOPMENT_TEAM` 换成 `CQ6733CTMV`。

影响：

- **玩法 A（开发安装）不受影响**——现在就能用，但 **7 天后 App 会打不开**，重跑一次玩法 A 即续期；
- **玩法 B（Ad Hoc）必须有付费账号的 Distribution 证书**，免费个人团队做不了。

---

## 1. 前置检查（拷进去直接跑）

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
cd /Volumes/repodisk/productX/einz/app

flutter doctor                              # iOS 工具链应为 ✅（Xcode / CocoaPods）
flutter config --list | grep swift          # 必须 enable-swift-package-manager: false
xcrun devicectl list devices                # 手机需为 available (paired)；拿到 UDID
security find-identity -v -p codesigning    # 出现 "Apple Development: yuanjinwx@…" 即可签名
```

手机侧一次性准备：

1. **设置 → 隐私与安全性 → 开发者模式** 打开（需重启手机）；
2. 首次装完 App 后若提示"不受信任的开发者"：**设置 → 通用 → VPN与设备管理 →
   开发者 App → 信任**；
3. 建议手机和 Mac 同 Wi-Fi（无线调试）或直接 USB 连线（更稳）。

---

## 2. 玩法 A：装到自己（或伴侣）的手机 —— 最快，无需 Archive

这是 2026-09-14 实测通过的路径，全程约 1–2 分钟（首次编译更久）。

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
cd /Volumes/repodisk/productX/einz/app

# ① 构建 release 包（默认连生产 https://einz.tic.cc，不需要任何额外参数）
flutter build ios --release
#    产物：build/ios/iphoneos/Runner.app

# ② 装到手机（UDID 用第 1 步 devicectl list devices 里的那一串）
xcrun devicectl device install app \
  --device 00008030-0005306011F9402E \
  build/ios/iphoneos/Runner.app

# ③ 命令行启动（可选）。手机必须已解锁，否则报 "device was not unlocked"
xcrun devicectl device process launch \
  --device 00008030-0005306011F9402E cc.tic.einz
```

> **别加** `--dart-define-from-file=local_config.ios.json`：那个文件把服务器指到
> `http://localhost:3000`，手机连不上。真机测试就用默认的生产地址。
> 真要临时换服务器：自己建 `local_config.json` 再
> `flutter build ios --release --dart-define-from-file=local_config.json`。

**图形界面等价做法**（想看日志/断点调试时用）：

```bash
open ios/Runner.xcworkspace     # 注意是 .xcworkspace（含 Pods），不是 .xcodeproj
# 左上选 iPhone → 点 ▶ Run
```

---

## 3. 玩法 B：Ad Hoc —— 给第二台手机装（需要付费账号）

productLens 的 V1 分发方案就是这个。前提：**付费开发者账号**，且两台手机的 **UDID 都已登记**
在 Apple Developer 后台（Certificates, Identifiers & Profiles → Devices）。

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
cd /Volumes/repodisk/productX/einz/app

# ① 取两台手机的 UDID（USB 连线更稳；Finder 里点设备也能看）
xcrun devicectl list devices

# ② 确认两台 UDID 已在开发者后台登记（否则 profile 里不含这台设备，装不上）

# ③ 导出 Ad Hoc IPA
flutter build ipa --release --export-method ad-hoc
#    产物：build/ios/ipa/*.ipa
```

装到手机（Mac + USB，手机需解锁）——`devicectl` 只吃 `.app`，所以先解包：

```bash
unzip -q build/ios/ipa/Runner.ipa -d /tmp/einz-ipa
xcrun devicectl device install app --device <UDID> /tmp/einz-ipa/Payload/Runner.app
```

或者用图形化工具更省事：**Apple Configurator 2**（Mac App Store 免费）→ 添加 → App → 选 `.ipa`。

`--export-method` 可选值：`development`（同玩法 A 但产出 IPA）、`ad-hoc`（登记设备免审核安装）、
`app-store`（上架/TestFlight）、`enterprise`（需企业证书，本项目**明确不用**）。

---

## 4. 玩法 C：TestFlight / 上架 App Store —— 当前不做

`aimemo/productLens.zhcn.md` §1.4/§14.1 明确「不上架 App Store、不向第三方分发」，
所以这条路暂不推进。真要做，除命令外还需：

- App Store Connect 建 App 记录（bundle id `cc.tic.einz`）；
- 隐私政策 URL、支持 URL、各尺寸截图、年龄分级；
- `Info.plist` 补 **`ITSAppUsesNonExemptEncryption`**（E2EE 应用必须如实申报出口合规）；
- 过 App Review——两人私有 E2EE 应用有被 4.2（最低功能）拒审的风险。

```bash
flutter build ipa --release --export-method app-store
# 再经 Transporter.app 或 xcrun altool 上传
```

---

## 5. 常见问题

| 现象 | 处理 |
| --- | --- |
| `Signing for "Runner" requires a development team` | Xcode → Settings → Accounts 登录 Apple ID；确认 pbxproj 里 `DEVELOPMENT_TEAM = 37KQR6645B` |
| `No profiles for 'cc.tic.einz' were found` / profile 快过期想换新的 | 删掉 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 里旧的 `cc.tic.einz` 文件，重跑构建让 Xcode 重新签发（2026-09-14 实测有效） |
| 手机提示「无法验证 App」/开发者不受信任 | 设置 → 通用 → VPN与设备管理 → 信任该开发者证书 |
| 之前好好的，App 突然打不开 | 大概率 7 天 profile 到期（免费账号）→ 重跑玩法 A 即续期 |
| `Unable to launch … device was not, or could not be, unlocked` | 手机锁屏了，解锁后重试（**不是签名问题**） |
| 报 `libsodium` 相关链接/加载失败 | 确认 `flutter config --no-enable-swift-package-manager`，再 `flutter build ios`（会自动 `pod install`）；release 若被 strip，Build Settings → Other Linker Flags 加 `-Wl,-export_dynamic` |
| `pod install` 没执行 / `Podfile.lock` 里没有 libsodium | 同上，先关 SPM 再构建 |
| `Missing package product 'FlutterGeneratedPluginSwiftPackage'` | 仓库 pbxproj 曾由 Flutter SPM（3.35+ 默认开启）生成过 Swift Package 引用，禁用 SPM 后残留导致构建失败；已随仓库修复（8 处引用全删）。旧副本请拉取最新代码，或手工删除 `XCLocalSwiftPackageReference` / `XCSwiftPackageProductDependency` / `packageReferences` / `packageProductDependencies` 相关段落 |
| 杀进程后收不到消息提示 | APNs 未接入（工程缺 Push Notifications capability + 服务端 `sendPushHint` 仍是占位）→ 打开 App 时靠 WS／增量同步补齐；见 §0 |
| 磁盘紧张 | `rm -rf ~/Library/Developer/Xcode/DerivedData`（可占数 GB） |

---

## 6. 真机验证清单（装完照着走一遍）

- [ ] App 启动 → 设置页（设备配置）渲染正常
- [ ] 生成设备密钥 → 公钥展示
- [ ] 创建/加入秘境（口令 + PIN）→ 进入聊天页
- [ ] 发消息 → 对方设备（另一台手机 / CLI）同步收到明文
- [ ] 附件：拍照/相册 → 上传 → 对方下载解密一致（会弹相机/麦克风/相册权限）
- [ ] 杀进程后另一端发消息 → 重新打开能同步到（**APNs 未接入，不会有系统推送**）
