# Einz CI 打包指南

本文档说明如何用 CI 打包 Einz 的 Android APK 和 iOS 安装包，无需本机安装 Xcode / Android SDK。

| 产物 | CI 平台 | 构建机 | 签名 | 前置条件 |
| --- | --- | --- | --- | --- |
| Android debug APK | Gitea Actions（自建 git.tic.cc） | Linux x64 服务器（Docker） | debug 自动签名，无需 keystore | Gitea 启用 Actions + 注册 gitea-runner |
| iOS IPA | Codemagic（云） | Codemagic 云 macOS | Apple 开发者签名 | Apple Developer 账号 + Codemagic 配置 |

---

## 一、Android APK：Gitea Actions

工作流文件：`.gitea/workflows/build-apk.yml`（push 到 main / 推 v* 标签 / 手动触发，产物为 debug 签名 APK）。

### 1.1 Gitea 启用 Actions

编辑 Gitea 配置文件 `app.ini`，追加/修改：

```ini
[actions]
ENABLED = true
```

重启 Gitea 服务生效。

### 1.2 生成注册令牌

**方式一（Web UI，推荐）：** Gitea 管理员登录后，访问 `https://git.tic.cc/-/admin/actions/runners`（站点管理 → Actions → Runners），点击**生成注册令牌**，得到一长串随机字符串（仅显示一次，妥善保存）。同一个令牌可注册多个 runner，重置后才失效。

**方式二（命令行，SSH 到 Gitea 服务器）：**

```bash
sudo -u git gitea --config /etc/gitea/app.ini actions generate-runner-token
```

> ⚠️ 注意：注册令牌是 Actions runner 专用令牌（一长串随机字符，无 `reg_` 前缀要求），**不是** API 个人访问令牌——`generate-access-token` 生成的令牌不能用于注册 runner。

### 1.3 在 Linux x64 服务器上安装 gitea-runner

构建机：任意 Linux x86_64 服务器（2 核 / 4 GB 以上内存，装 Docker）。**注意：必须是 x86_64**——Android 构建工具 aapt2 无 linux-arm64 版，ARM 主机无法直接构建（详见下方说明）。海外网络直连镜像源更省事。首次构建约 10–20 分钟（依赖下载 + 编译），增量 3–5 分钟。

**① 安装 Docker**（多数云镜像不含 Docker）：

```bash
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker
docker version
```

**② 下载并安装 gitea-runner**（注意：runner 项目已由 act_runner 更名为 **gitea-runner**；x86_64 服务器用 `linux-amd64`；版本见 https://gitea.com/gitea/act_runner/releases）：

```bash
sudo curl -sSL -o /usr/local/bin/gitea-runner \
  https://gitea.com/gitea/act_runner/releases/download/v3.3.2/gitea-runner-3.3.2-linux-amd64
sudo chmod +x /usr/local/bin/gitea-runner
gitea-runner --version
```

**③ 注册到 git.tic.cc**：

```bash
gitea-runner register --no-interactive --instance https://git.tic.cc --token <注册令牌>
# 或交互式：gitea-runner register，按提示输入地址与令牌，标签保持默认（含 ubuntu-latest）
```

**④ 用 systemd 常驻**（开机自启、崩溃自动拉起）。新建 `/etc/systemd/system/gitea-runner.service`：

```ini
[Unit]
Description=Gitea Runner
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/gitea-runner daemon
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gitea-runner
systemctl status gitea-runner   # active (running) 即成功
```

注册时注意：
- Gitea 地址填 `https://git.tic.cc`
- 标签保持默认（`ubuntu-latest` 等），工作流使用 `ubuntu-latest`
- **为何必须 x86_64**：Android 构建工具 aapt2 只有 linux-x86_64 版（无 linux-arm64），ARM 主机会报 `AAPT2 ... Syntax error`；即使配 QEMU 模拟也伴随动态链接库缺失等连锁问题，故不推荐 ARM 主机，直接选 x86_64 服务器最省事。

### 1.4 验证

推送任意改动到 main 分支，在 Gitea 仓库页 **Actions** 标签查看构建日志；构建成功后可在构建详情的 **Artifacts** 下载 `einz-debug-apk`。

### 1.5 Runner 网络要求与镜像

构建过程需要访问：GitHub（下载 Flutter SDK、拉取公共 action、sqlite3 预编译库）、Gradle Maven 仓库、pub.dev。**海外 runner 直连即可，无需任何镜像配置**；仅当 runner 位于国内且出口受限时，才在 gitea-runner 环境（或 Gitea 仓库 Secrets）配置镜像变量：

| 变量 | 国内镜像值 |
| --- | --- |
| `FLUTTER_STORAGE_BASE_URL` | `https://storage.flutter-io.cn` |
| `PUB_HOSTED_URL` | `https://pub.flutter-io.cn` |

> APK 目前为 **debug 签名**，仅用于测试分发。如需上架/正式发布，需先创建 release keystore 并配置 `app/android/key.properties`（见 aimemo/worklog 待办），工作流再做对应调整。

### 1.6 原生库（libsodium）校验

`app/android/app/src/main/jniLibs/<abi>/libsodium.so` 是 **vendored 预编译库**，有两个
**本机模拟器测不出**的坑（只有真机/特定设备才暴露）：

1. **16KB 页对齐**：Android 15+ 的 16KB 页设备要求每个 LOAD 段 `p_align >= 0x4000`，
   4KB 对齐（`0x1000`）的 .so 在这些设备上 `dlopen` 直接失败 → 表现为"加载不了 libsodium"；
2. **符号完整性**：libsodium 符号只在运行时经 `DynamicLibrary.open('libsodium.so')` 解析，
   少一个符号就要跑起来才炸。

替换/升级该库后**务必**跑一次（退出码非 0 = 有问题）：

```bash
python3 app/android/checkNativeLibs.py
```

重编配方（NDK r28 起默认 16KB，关键是 `-Wl,-z,max-page-size=16384`）写在该脚本头部注释里。

---

## 二、iOS：Codemagic 云构建

### 2.1 Codemagic 连接仓库

1. 注册/登录 [Codemagic](https://codemagic.io)（建议用 Apple 或 GitHub 账号登录）。
2. **Add application → 选择 Other / 自定义 Git 服务**，用 SSH 方式添加自建 Gitea 仓库 `https://git.tic.cc/fon/einz`（按页面提示添加 Codemagic 的 SSH 公钥到 Gitea 账号的 SSH Keys）。
3. 选中应用后进入构建设置。

### 2.2 配置 Apple 签名

1. Codemagic 页面左侧 **Signing → iOS**，按向导登录 Apple Developer 账号（或配置 App Store Connect API Key）。
2. 确认 App 的 bundle id 为 **`cc.tic.einz.ios`**。
3. **描述文件要传两个，只传证书不够**：`Einz_Dist_Adhoc.mobileprovision` 与 `Einz_Dist_AppStoreConnect.mobileprovision`。
   工程 Release 配置写死了 `PROVISIONING_PROFILE_SPECIFIER = "Einz Dist Adhoc"`
   （见 `app/ios/Runner.xcodeproj/project.pbxproj`），archive 阶段必须有它，导出阶段再由
   `exportOptionsAppStore.plist` 重签成 App Store 的。少传 Adhoc 会报
   `No profile for team 'CQ6733CTMV' matching 'Einz Dist Adhoc' found`。
4. 若签名向导生成新的证书，需要把对应私钥保存在 Codemagic 中，并（如需发布 App Store）在 Apple 开发者后台的 Certificates/Profiles 中确认对应条目存在。

### 2.3 构建

项目根目录已含 `codemagic.yaml`。在 Codemagic 页面选择 **Start build → 使用 codemagic.yaml**，选择 `ios-release` 工作流：

- 每次构建约 20–40 分钟（首次因依赖下载更久），免费额度 500 分钟/月。
- 产物 IPA 出现在构建页面的 **Artifacts**：`app/build/ios/ipa/*.ipa`（已签名）。
- 工作流里显式带了 `--export-options-plist=ios/exportOptionsAppStore.plist`，产物是 App Store / TestFlight 包；
  去掉它默认导出方式不是 app-store，传 TestFlight 会被拒。
- 可配置自动上传 TestFlight：在 Codemagic 页面 **Publishing → App Store Connect** 开启，或用 `codemagic.yaml` 的 `publishing` 段。

### 2.4 说明

- iOS 15.0 部署目标、CocoaPods（含本地 libsodium pod）由 `flutter build ipa` 在构建机自动处理。
- 若构建报 Swift Package Manager 与 CocoaPods 冲突，在构建脚本中先执行 `flutter config --no-enable-swift-package-manager`（已在 codemagic.yaml 中预置）。

---

## 三、日常使用流程

```text
改代码 → push main
        ├─ Gitea Actions 自动打 debug APK（几分钟）→ 下载分发测试
        └─ 需要 iOS 包时：Codemagic 手动/自动触发 ios-release → 下载 IPA → TestFlight/分发
```
