# Einz — iOS 打包与真机安装指引（docs/IOS.md）

> **状态：** v3.0（2026-09-14：切到 Faronear 付费账号 + Ad Hoc 1 年签名，**已实测**——
> 构建 → 装到 iPhone 11，bundle `cc.tic.einz.ios`）。
> v1.0（bundle `com.example.onlyspace`、仓库 `git.tic.cc/fon/only`）、v2.0（`cc.tic.einz`
> + 免费个人团队 7 天 profile）均已过时——以本文档为准。

---

## 0. 当前配置速览

| 项 | 值 | 备注 |
| --- | --- | --- |
| Bundle ID | **`cc.tic.einz.ios`** | 已配在 `app/ios/Runner.xcodeproj` |
| Team ID | **`CQ6733CTMV`** | Faronear Co. Ltd.（**付费**账号） |
| 签名证书 | `Apple Distribution: Faronear Co. Ltd. (CQ6733CTMV)` | SHA-1 `5914DE2D…`，2026-09-14 → **2027-09-14**；私钥 `FaronearPrikey` 在本机登录钥匙串 |
| Ad Hoc profile | **`Einz Dist Adhoc`**（UUID `458acdea-…`） | 1 年，含 iPhone 11 + iPhone XR + 一台旧设备 |
| App Store profile | `Einz Dist AppStoreConnect` | 1 年，**同 bundle id**（当前不上架，备用） |
| 证书/密钥保管位置 | `/Volumes/repodisk/simsim_key/cert-apple-苹果应用证书/20260914/` | `.p12` + `.cer` + CSR + 口令文件（`3_certpassword.simsim.js`）——**勿入 git** |
| 生产服务器 | `https://einz.tic.cc` | 代码默认值，真机开箱可用 |
| 部署目标 | iOS 15.0 | |
| 本机 Flutter | 3.47.2（`~/development/flutter`） | 需 `export PATH="$HOME/development/flutter/bin:$PATH"` |
| SPM | **必须关闭** | `flutter config --no-enable-swift-package-manager`（用 CocoaPods + 本地 libsodium pod） |
| APNs 推送 | **未接入** | 工程缺 Push Notifications capability；服务端 `sendPushHint` 仍为日志占位。不影响聊天（WS 兜底） |

### ⚠️ 与旧版的两处关键差异

1. **团队换了**：原 `37KQR6645B`（Leiqin Lu 个人）是**免费**团队——它签发的 profile **只有 7 天**，
   App 每 7 天要重装。现已切到 Faronear（付费，1 年）。
2. **Bundle ID 变了**：App ID 全局唯一，`cc.tic.einz` 已被个人团队占用，所以 Faronear 团队下
   用 **`cc.tic.einz.ios`**。bundle id 变了 = 手机上是**另一个 App**：
   - 旧的 `cc.tic.einz` 仍留在手机上（可手动删掉），新版是**全新容器**；
   - 新版首次打开需**用邀请码 + 密保口令重新接入秘境**（服务端密文还在，历史会回来）。

---

## 1. 前置检查（拷进去直接跑）

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
cd /Volumes/repodisk/productX/einz/app

flutter doctor                              # iOS 工具链应为 ✅（Xcode / CocoaPods）
flutter config --list | grep swift          # 必须 enable-swift-package-manager: false
xcrun devicectl list devices                # 手机需 available (paired)；拿到 UDID
security find-identity -v -p codesigning    # 需出现 "Apple Distribution: Faronear Co. Ltd. (CQ6733CTMV)"
ls ~/Library/MobileDevice/Provisioning\ Profiles/ | grep -i 458acdea   # Ad Hoc profile 已装
```

手机侧一次性准备：

1. **设置 → 隐私与安全性 → 开发者模式** 打开（需重启手机）；
2. Ad Hoc（Distribution）签名**不需要**手动信任证书；
3. 建议同 Wi-Fi（无线调试）或 USB 连线（更稳）。

> **换电脑 / 重装钥匙串后要补两步**：
> ① 导入证书：`security import <3_证书.p12> -k ~/Library/Keychains/login.keychain-db -P <口令> -A`
> （口令见同目录 `3_certpassword.simsim.js`）；
> ② 装 profile：把 `.mobileprovision` 复制为
> `~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision`。

---

## 2. 玩法 A：构建 Ad Hoc IPA → 装到手机（当前主路径）

```bash
export PATH="$HOME/development/flutter/bin:$PATH"
cd /Volumes/repodisk/productX/einz/app

# ① 构建（Release 走手动签名 + ios/exportOptionsAdhoc.plist 指定的证书与 profile）
flutter build ipa --release --export-options-plist=ios/exportOptionsAdhoc.plist
#    约 2 分钟；产物：build/ios/ipa/einz.ipa（13.7MB）

# ② 装到手机（devicectl 只吃 .app，先解包）
rm -rf /tmp/einz-ipa && mkdir -p /tmp/einz-ipa
unzip -q build/ios/ipa/einz.ipa -d /tmp/einz-ipa
xcrun devicectl device install app --device 00008030-0005306011F9402E /tmp/einz-ipa/Payload/Runner.app
#    iPhone 11 = 00008030-0005306011F9402E ；iPhone XR = 00008020-00130D3A1E92002E
```

也可以把 `.ipa` 拖进 **Apple Configurator 2**（Mac App Store 免费）→ 添加 → App。

**签名用手动指定**（`Runner.xcodeproj` 的 **Release** 配置）：

```
DEVELOPMENT_TEAM            = CQ6733CTMV
PRODUCT_BUNDLE_IDENTIFIER   = cc.tic.einz.ios
CODE_SIGN_STYLE             = Manual
"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "Apple Distribution"
PROVISIONING_PROFILE_SPECIFIER      = "Einz Dist Adhoc"
```

这样**不依赖 Xcode 是否登录了该 Apple ID**（自动签名在没有该账号的环境下会失败）。
Debug / Profile 配置仍是 Automatic（项目默认），用于模拟器开发。

**只想验证编译、不要 IPA**：`flutter build ios --release`。

> 注意：`--export-options-plist` 与 `--export-method` **不能同时给**（Flutter 会直接报错）。

---

## 3. ad-hoc / app-store / development 的区别（容易搞混）

**编译（archive）完全一样**，差别只在**导出**这一步：

| 目的 | 命令 | exportOptions 的 `method` | 用哪种 profile |
| --- | --- | --- | --- |
| 装到已登记设备（免审核） | `flutter build ipa --export-method ad-hoc` | `ad-hoc`（Xcode 15+ 又名 `release-testing`） | Ad Hoc（profile 含设备 UDID） |
| 上架 / TestFlight | `flutter build ipa --export-method app-store` | `app-store`（`app-store-connect`） | App Store Distribution（无设备列表） |
| 本地调试安装 | `flutter build ipa --export-method development` | `development`（`debugging`） | Development |
| 完全自定义 | `--export-options-plist=<plist>` | 自己写在 plist 里 | 自己指定 |

- `--export-method` 只是**便利参数**，内部生成 exportOptions plist。
- 同一个 archive 可**导出多次**，不必重新编译：
  ```bash
  xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive \
    -exportOptionsPlist ios/exportOptionsAdhoc.plist -exportPath /tmp/adhoc-out
  ```
- 本仓库目前只维护 `ios/exportOptionsAdhoc.plist`（`method=ad-hoc`）。要走 App Store 时再建一份
  `method=app-store` 的 plist（profile 用 `Einz Dist AppStoreConnect`）——**bundle id 相同**，
  所以 Ad Hoc 与将来上架是同一个 App，数据容器一致。

---

## 4. 玩法 B：TestFlight / 上架 App Store —— 当前不做

`aimemo/productLens.zhcn.md` §1.4/§14.1 明确「不上架 App Store、不向第三方分发」。
真要做还需：App Store Connect 建 App 记录、隐私政策 URL、支持 URL、截图、年龄分级，以及
`Info.plist` 补 **`ITSAppUsesNonExemptEncryption`**（E2EE 必须如实申报出口合规）、过 App Review
（两人私有 E2EE 应用有被 4.2「最低功能」拒审的风险）。

---

## 5. 常见问题

| 现象 | 处理 |
| --- | --- |
| `No profiles for 'cc.tic.einz.ios' were found` | Ad Hoc profile 没装到本机 → 复制为 `~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision` |
| 签名失败 / 找不到 `Apple Distribution: …` | 钥匙串缺证书+私钥 → 导入 `3_证书.p12`（口令见 `3_certpassword.simsim.js`）；用 `security find-identity -v -p codesigning` 确认 |
| 报 `--export-options-plist is not compatible with --export-method` | 两个参数只能用其一 |
| 这台设备装不上 | UDID 不在 profile 里 → 在开发者后台 Devices 登记，**重新生成 profile**并更新本机那份 |
| `Unable to launch … device was not, or could not be, unlocked` | 手机锁屏了，解锁后重试（**不是签名问题**） |
| 手机提示「无法验证 App」 | Ad Hoc/Distribution 不受此限；若出现，先确认 profile 含该设备 UDID |
| 手机上出现两个 Einz | 旧的 `cc.tic.einz`（个人团队 7 天版）与新的 `cc.tic.einz.ios` 是两个 App → 删掉旧的 |
| 报 `libsodium` 链接/加载失败 | 确认 SPM 已关；`flutter build ios` 会自动 `pod install`；release 被 strip 时加 `-Wl,-export_dynamic` |
| `pod install` 未执行 / `Podfile.lock` 无 libsodium | 同上，先关 SPM 再构建 |
| `Missing package product 'FlutterGeneratedPluginSwiftPackage'` | pbxproj 曾残留 Flutter SPM（3.35+ 默认开启）生成的 Swift Package 引用，禁用 SPM 后残留导致构建失败；**已随仓库修复**（8 处引用全删）。旧副本请拉最新代码，或手工删 `XCLocalSwiftPackageReference` / `XCSwiftPackageProductDependency` / `packageReferences` / `packageProductDependencies` 相关段落 |
| 杀进程后收不到消息提示 | APNs 未接入 → 打开 App 时靠 WS／增量同步补齐（见 §0） |
| 「必须升级 Xcode 才能装 iOS 26 真机」 | **不成立**（2026-09-14 实测）：Xcode 16.1 + iOS 26.3.1 的 iPhone 11，开发安装与 Ad Hoc 安装均成功 |
| 磁盘紧张 | `rm -rf ~/Library/Developer/Xcode/DerivedData`（可占数 GB） |

---

## 6. 真机验证清单（装完照着走一遍）

- [ ] App 启动 → 设置页（设备配置）渲染正常
- [ ] 生成设备密钥 → 公钥展示
- [ ] 创建 / 加入秘境（口令 + PIN）→ 进入聊天页
- [ ] 发消息 → 对方设备（另一台手机 / CLI）同步收到明文
- [ ] 附件：拍照/相册 → 上传 → 对方下载解密一致（会弹相机/麦克风/相册权限）
- [ ] 杀进程后另一端发消息 → 重新打开能同步到（**APNs 未接入，不会有系统推送**）
