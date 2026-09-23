# Einz CI 打包指南

CI 统一使用 **GitHub Actions**（工作流文件：`.github/workflows/buildMultiPlatform.yml`），覆盖 Android / iOS / macOS / Windows 四个目标，全部产物上传到 GitHub Release（`latest` tag，每次构建覆盖）。

| 产物 | job | 构建机 | 签名 |
| --- | --- | --- | --- |
| Android APK（`einz-app-android.apk`） | `android` | ubuntu-latest | **release 签名**，用 secrets 里的 keystore（**与本地同一把**，可互相覆盖安装） |
| Windows GUI（`einz-app-windows.zip`）+ CLI（`einz-tui-windows.zip`，exe+dll 一包） | `windows` | windows-latest | 无需签名 |
| macOS GUI（`einz-app-macos.zip`） | `macos` | macos-latest | 配了 Developer ID secrets 则签名+公证；未配则 ad-hoc |
| macOS CLI 分架构（`einz-tui-macos-x64` / `einz-tui-macos-arm64`，下载对应架构的） | `macos-cli` | macos-15-intel (x64) / macos-latest (arm64) | 无需签名 |
| Linux CLI（`einz-tui-linux-x64.tar.gz`，含二进制 + 运行说明） | `linux-cli` | ubuntu-latest | 无需签名 |
| iOS（`einz-app-ios-appstore.ipa`，**App Store 包**） | `ios` | macos-latest | 签名 + 进 latest；**构建成功即自动传 TestFlight**（见 `IOS.md` §4.3） |

---

## 一、触发方式

1. **push main 自动跑**（2026-09-21 起）：改代码即验证。纯文档/记忆改动（`docs/**`、
   `aimemo/**`、`**.md`）被 `paths-ignore` 挡掉，不触发；`v*` tag 一律触发全平台。
2. **手动 Run workflow**：仓库页 → **Actions** → **Multi Platform Build** → **Run workflow**，
   `platform` 选择：`all`（默认）/ `android` / `ios` / `macos` / `windows` / `linux`（仅 TUI）。
3. 构建完成后：
   - **Artifacts**：构建详情页下载（仅登录用户可见）
   - **Release**：仓库 Releases → `Latest Build`（`latest` tag，每次构建覆盖，访客无需登录即可下载）
   - **TestFlight**：iOS job 成功即自动上传（`IOS.md` §4.3）

---

## 二、签名配置（secrets）

仓库 **Settings → Secrets and variables → Actions**。

### Android（4 个，2026-09-21 起）

CI 用**与本地同一把** release keystore 签名——否则签名不同的包不能互相覆盖安装，而
`build.gradle.kts` 在没有 `key.properties` 时会**静默退回 debug 签名**（CI 绿但装不上）。

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `app/android/android.keystore.jks` 的 Base64（`base64 -i android.keystore.jks \| gh secret set …`） |
| `ANDROID_KEYSTORE_PASSWORD` | `key.properties` 里的 `storePassword` |
| `ANDROID_KEY_PASSWORD` | `key.properties` 里的 `keyPassword` |
| `ANDROID_KEY_ALIAS` | `key.properties` 里的 `keyAlias` |

job 内的做法：keystore 解码到 `$RUNNER_TEMP`、properties 只写 keystore 路径与别名，
**口令走环境变量**（`EINZ_STORE_PASSWORD` / `EINZ_KEY_PASSWORD`，gradle 优先读它们，
见 `build.gradle.kts` 的 C3 设计）→ 口令不落盘。构建后用 `apksigner` 断言签名者不是
`CN=Android Debug`（不写死指纹，换 keystore 无需改）。

### iOS（6 个）

完整步骤（生成 base64、取 ASC API key、验证）见 **`IOS.md` §4.3**。摘要：

| Secret | 用途 |
| --- | --- |
| `IOS_P12_CERTIFICATE` / `IOS_P12_PASSWORD` | Apple Distribution 证书 + 口令 |
| `IOS_APPSTORE_PROVISIONING_PROFILE` | `Einz Dist Appstore` 描述文件（Base64） |
| `ASC_API_KEY_ID` / `ASC_API_ISSUER` / `ASC_P8_KEY` | TestFlight 上传用的 App Store Connect API key |

缺签名 secrets → iOS job 干净跳过构建（不红）；缺 ASC secrets → **明确失败**（上传是既定动作）。
另注：工程 Release 的 `PROVISIONING_PROFILE_SPECIFIER` 写的是 Ad Hoc 描述文件，CI 在构建前
临时改指 App Store（只改 runner 工作区，见 `IOS.md` §3/§4.3）。

---

## 三、构建细节备忘

- **版本号**：`scripts/appVersion.js` 是唯一出处，版本 `yymm.ddhh.mm`、构建号 `yymmddhh`，除 iOS 外各平台统一。
  iOS job **构建号改用 `date -u +%y%m%d%H%M`（到分钟）**：共享脚本的构建号受 Android
  `versionCode ≤ 2100000000` 限制不能加分钟，而 iOS 自动上传后"同一小时内推两次"会撞号被 Apple 拒收。
- **Android 内存**：公共 runner 仅 7GB，job 里用 `GRADLE_OPTS=-Xmx3G` 覆盖 gradle.properties 的 `-Xmx8G`，否则 Gradle 跑约 16 分钟被 OOM killer 杀掉（exit 143）。
- **macOS GUI**：CI 无开发证书，构建前用 sed 临时把 pbxproj 改成 Manual + `-` 签名（不改仓库文件）。
- **macOS CLI**：Dart 不支持 macOS 跨架构编译，`macos-cli` 用 matrix 在 Intel（macos-15-intel）与 Apple Silicon 两个 runner 上各编一份，**分架构直接提供下载**（曾用 lipo 合成通用二进制，但 CI 合成产物运行异常，已取消）。
- **Windows libsodium**：GUI（sodium FFI）和 CLI 运行时都需要 `libsodium.dll`，构建时从 libsodium 官方 release 下载 1.0.20 MSVC 版，一份打进 GUI zip，一份与 CLI exe 一起打进 `einz-tui-windows.zip`（exe 运行时按同目录找 dll，解压即用）。
- **Linux CLI（`linux-cli`，2026-09-21 新增）**：ubuntu-latest 编 x64 一份（Dart 不支持跨架构），打 `einz-tui-linux-x64.tar.gz`（二进制 + `README-linux-tui.txt`）。**不自带 libsodium**：Linux 上打包 `.so` 会被 glibc 版本绑住（runner 是 glibc 2.39，老发行版跑不了），所以只在包里放运行说明，让用户按发行版装（`apt install libsodium23` / `dnf install libsodium`）。ARM 版若要加，换 `ubuntu-24.04-arm` runner 再编一份（该镜像对私有仓库的可用性/计费与 x64 不同，未并入 matrix）。
- **Linux GUI 未发布**：`video_player` / `mobile_scanner` / `open_filex` / `video_thumbnail` 都没有 Linux 实现，要先按平台把视频播放、扫码、打开附件这些入口藏掉或给替代，才能谈发布。
- **pub cache 补丁**：Android job 会先跑 `scripts/patchPubCache.sh`（open_filex / video_thumbnail 的 AGP 9 兼容补丁），本地构建同样需要（见 package.json 各构建脚本）。
- **Android 原生库校验**：`app/android/app/src/main/jniLibs/<abi>/libsodium.so` 是 vendored 预编译库，替换/升级后必须跑 `python3 app/android/checkNativeLibs.py`（校验 16KB 页对齐与符号完整性，配方见脚本头注释）——这两个坑本机模拟器测不出，只有真机暴露。

---

## 四、日常使用流程

```text
改代码 → push main（自动触发；纯 docs/aimemo/*.md 改动不触发）
        └─ 只想跑某个平台：GitHub Actions 手动 Run workflow（选 platform）
           → Android/iOS/macOS/Windows/Linux 产物进 Release "Latest Build"
           → iOS 还自动进 TestFlight（无需额外操作）
```
