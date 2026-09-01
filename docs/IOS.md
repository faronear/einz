# Einz — iOS 构建与真机验证指引（docs/IOS.md）

> **状态：** v1.0（代码层就绪：Info.plist 权限、libsodium 静态库集成、APNs 注册代码；构建/签名/真机验证需在 **macOS + Xcode** 上执行，本文档逐步指引）
> **前置：** 有 Mac（macOS 14+）、已装 Flutter 3.47+（含 Xcode 15+）、项目可从远程仓库 clone。

---

## 0. 先完成代码同步（macOS 本机，一次）

项目远程仓库：`https://git.tic.cc/fon/only`（老板自建 Gitea，私有）。

- 本机需**推送一次**并让 Git 记住凭据（Personal Access Token，见 DEPLOYMENT.md §0 配置方法）：

```bash
cd /Users/Shared/productX/only
git push -u origin main
# 弹窗时：用户名 = AtomGit 用户名，密码 = 访问令牌（Settings → 访问令牌 生成，勾选 repo 权限）
```

- 确认推送成功后，Mac 侧拉取（见 §2）。

---

## 1. Mac 环境准备

```bash
# 1) 检查工具链（Xcode 需 15+；首次会要求安装 Command Line Tools）
xcode-select --install
flutter doctor        # 期望 iOS 工具链全部 ✅（Xcode / CocoaPods）

# 2) 若 flutter doctor 提示 CocoaPods 缺失：
sudo gem install cocoapods

# 3) 确认 Apple 签名信息（真机需要）：
#    Xcode → Settings → Accounts → 登录 Apple ID（免费账号可真机调试；
#    APNs 推送与 Ad Hoc 分发需要付费账号 99$/年，当前暂无 → 推送验证留待）
```

> **重要**：本工程 `app/ios/Podfile` 存在（引入本地 `libsodium` pod 静态库），Flutter 3.47 默认 Swift Package Manager 时请**强制使用 CocoaPods**：
> `flutter config --no-enable-swift-package-manager`

---

## 2. 拉取代码并构建（无签名验证编译）

```bash
git clone https://git.tic.cc/fon/only
cd only/app

flutter pub get

# 无签名构建（验证编译 + libsodium 静态链接成功）
flutter build ios --debug --no-codesign
# 期望：末尾 "✓ Built .../app-ios-ios.zip" 或 "Xcode build done"

# 模拟器运行（可选；模拟器无 APNs）
flutter run -d <模拟器设备ID>
```

**libsodium 加载验证**（App 打开后看日志）：进入聊天页前会调用 `sodium()`（`DynamicLibrary.process()` 解析静态链接符号）。若报"无法加载 libsodium"：
- 确认 Pods 已安装（`flutter build ios` 会自动 `pod install`；也可手动 `cd ios && pod install`）
- 确认 `Podfile.lock` 中出现 `- libsodium (1.0.20)`
- release 构建若符号被 strip：在 Xcode 工程 Build Settings → `Other Linker Flags` 追加 `-Wl,-export_dynamic`（保持 libsodium 符号可见）

---

## 3. 真机签名与运行

```bash
open ios/Runner.xcworkspace      # Xcode 打开（注意是 .xcworkspace，含 Pods）
```

Xcode 内配置（Target `Runner` → Signing & Capabilities）：
1. **Team**：选择你的 Apple ID 团队（免费账号选 Personal Team；会生成开发签名）
2. **Bundle Identifier**：改为唯一值，如 `com.tic.einz`（免费账号 bundle id 会被追加 team 前缀，正常）
3. 若需推送：添加 **Push Notifications** capability（需付费账号；暂无则跳过，WS/轮询兜底不受影响）
4. 点击 **Run ▶**（连上 iPhone，首次需在手机"设置 → 通用 → VPN与设备管理"信任开发者证书）

真机验证清单：
- [ ] App 启动 → 设置页（设备配置）渲染正常
- [ ] 生成设备密钥 → 公钥展示
- [ ] 粘贴 sealed 副本 → 认证成功 → 进入聊天页
- [ ] 发送消息 → 对方设备（另一台手机/CLI）同步收到明文
- [ ] 附件上传 → 下载解密一致（相机/麦克风/相册权限弹窗出现）
- [ ] APNs：付费账号配置后，杀进程状态下对方发消息能收到"有新消息"提示（无正文）

---

## 4. Ad Hoc 分发（付费账号，暂留待）

1. Xcode → Signing & Capabilities → Team 选付费团队
2. 添加 **Push Notifications** capability，配置 APNs 密钥（Key ID + .p8，存好供 Server 侧 APNs 下发用）
3. 真机运行验证通过后：Product → Archive → Distribute App → **Ad Hoc**（或 Development）
4. 导出 `.ipa`，用第三方工具（爱思助手/TestFlight 等）装到对方 iPhone

> Server 侧 APNs 下发（`sendPushHint`）当前为日志占位（server/src/push.ts）；付费账号就绪后按 PROTOCOL.md §7.3 接入 apn 库（如 `@parse/node-apn`），只发 `{ type: "new_message" }` 提示，绝不携带正文。

---

## 5. 已知点与常见问题

| 现象 | 处理 |
| --- | --- |
| `pod install` 未执行 / Podfile.lock 无 libsodium | `flutter config --no-enable-swift-package-manager` 后重新 `flutter build ios` |
| libsodium 加载失败 | 见 §2 验证项：检查 Pods、`-Wl,-export_dynamic` |
| 免费账号无法真机运行 | 手机信任开发者证书；或改用付费账号 |
| 推送收不到 | APNs 需付费账号 + capability + APNs 密钥（Server 侧）；WS/轮询兜底不受影响 |
| 中文路径构建问题 | macOS 无此问题；Windows 侧继续用外部临时构建 |

---

## 6. 一次全流程（快速参考）

```bash
# Mac（第一次）
git clone https://git.tic.cc/fon/only && cd only/app
flutter config --no-enable-swift-package-manager
flutter pub get && flutter build ios --debug --no-codesign   # 验证编译
open ios/Runner.xcworkspace                                  # 签名 → Run
```
