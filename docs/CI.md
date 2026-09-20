# Einz CI 打包指南

CI 统一使用 **GitHub Actions**（工作流文件：`.github/workflows/buildMultiPlatform.yml`），覆盖 Android / iOS / macOS / Windows 四个目标，全部产物上传到 GitHub Release（`latest` tag，每次构建覆盖）。

| 产物 | job | 构建机 | 签名 |
| --- | --- | --- | --- |
| Android APK（`einz-app-android.apk`） | `android` | ubuntu-latest | release 签名，无需 keystore |
| Windows GUI（`einz-gui-windows.zip`）+ CLI（`einz-tui-windows.exe` + `libsodium.dll`） | `windows` | windows-latest | 无需签名 |
| macOS GUI（`einz-gui-macos.zip`） | `macos` | macos-latest | CI 上临时禁签名（无证书） |
| macOS CLI 通用二进制（`einz-tui-macos`，x64+arm64 lipo 合成） | `macos-cli` + `macos-cli-combine` | macos-13 (x64) / macos-latest (arm64) | 无需签名 |
| iOS IPA（`einz-ios`，Ad Hoc） | `ios` | macos-latest | 配置 secrets 后签名；未配置则产出未签名 IPA |

---

## 一、触发方式

1. 打开 GitHub 仓库页 → **Actions** → **Multi Platform Build** → **Run workflow**
2. `platform` 选择：`all`（默认，Android+Windows+macOS）/ `android` / `ios` / `macos` / `windows`
3. 构建完成后：
   - **Artifacts**：构建详情页下载（仅登录用户可见）
   - **Release**：仓库 Releases → `Latest Build`（`latest` tag，每次构建覆盖，访客无需登录即可下载）

push / tag 自动触发**已注释停用**（老板偏好仅手动触发，避免每次 push 都跑 CI）；需要时取消 yml 中 `push: tags: v*` 段的注释。

---

## 二、iOS 签名配置（secrets）

iOS job 检测到 secrets 才会签名打包 Ad Hoc IPA；未配置时自动产出未签名 IPA（用于模拟器/无签名场景）。

需在仓库 **Settings → Secrets and variables → Actions** 配置三个 secrets：

| Secret | 内容 |
| --- | --- |
| `IOS_P12_CERTIFICATE` | Apple 开发证书 .p12 的 **Base64**（`base64 -i cert.p12 \| pbcopy`） |
| `IOS_P12_PASSWORD` | 导出 .p12 时设置的密码 |
| `IOS_PROVISIONING_PROFILE` | 描述文件 `Einz_Dist_Adhoc.mobileprovision` 的 **Base64** |

注意事项（沿用自 Codemagic 时代的经验）：

- bundle id 为 `cc.tic.einz.ios`，工程 Release 写死 `PROVISIONING_PROFILE_SPECIFIER = "Einz Dist Adhoc"`，**必须传 Adhoc 描述文件**，缺了会报 `No profile for team 'CQ6733CTMV' matching 'Einz Dist Adhoc' found`；
- 导出阶段由 `app/ios/exportOptionsAdhoc.plist` 控制，产物是 Ad Hoc IPA；如需上 TestFlight/App Store 需换成 `exportOptionsAppStore.plist` 并配对应 profile。

---

## 三、构建细节备忘

- **版本号**：`scripts/appVersion.js` 是唯一出处，构建号 `yymmddhh`、版本 `yymm.ddhh.mm`，各平台统一。
- **Android 内存**：公共 runner 仅 7GB，job 里用 `GRADLE_OPTS=-Xmx3G` 覆盖 gradle.properties 的 `-Xmx8G`，否则 Gradle 跑约 16 分钟被 OOM killer 杀掉（exit 143）。
- **macOS GUI**：CI 无开发证书，构建前用 sed 临时把 pbxproj 改成 Manual + `-` 签名（不改仓库文件）。
- **macOS CLI**：Dart 不支持 macOS 跨架构编译，`macos-cli` 用 matrix 在两个 runner 上各编一份，`macos-cli-combine` 用 lipo 合成通用二进制。
- **Windows libsodium**：GUI（sodium FFI）和 CLI 运行时都需要 `libsodium.dll`，构建时从 libsodium 官方 release 下载 1.0.20 MSVC 版，一份打进 GUI zip，一份与 CLI exe 一同上传；用户解压后 dll 与 exe 同目录即可运行。
- **pub cache 补丁**：Android job 会先跑 `scripts/patchPubCache.sh`（open_filex / video_thumbnail 的 AGP 9 兼容补丁），本地构建同样需要（见 package.json 各构建脚本）。
- **Android 原生库校验**：`app/android/app/src/main/jniLibs/<abi>/libsodium.so` 是 vendored 预编译库，替换/升级后必须跑 `python3 app/android/checkNativeLibs.py`（校验 16KB 页对齐与符号完整性，配方见脚本头注释）——这两个坑本机模拟器测不出，只有真机暴露。

---

## 四、日常使用流程

```text
改代码 → push main
        └─ 需要包时：GitHub Actions 手动 Run workflow（选平台）
           → 完成后从 Release "Latest Build" 下载 / 或从构建页 Artifacts 下载
```
