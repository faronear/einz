# Einz CI 打包指南

本文档说明如何用 CI 打包 Einz 的 Android APK 和 iOS 安装包，无需本机安装 Xcode / Android SDK。

| 产物 | CI 平台 | 构建机 | 签名 | 前置条件 |
| --- | --- | --- | --- | --- |
| Android debug APK | Gitea Actions（自建 git.tic.cc） | iMac 2019（macOS + OrbStack，64 GB 内存 / 2 TB SSD） | debug 自动签名，无需 keystore | Gitea 启用 Actions + iMac 注册 act_runner |
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

### 1.3 在 iMac 2019 上安装 act_runner（OrbStack 方案）

构建机：iMac 2019（Intel，64 GB 内存 / 2 TB SSD）——内存、磁盘远超构建需求，可并行多个构建；CPU 为 6–8 核 Intel，单任务构建约 10–20 分钟（首次）/ 3–5 分钟（增量）。

**① 安装 OrbStack**（macOS 轻量 Docker 运行时，性能优于 Docker Desktop，Intel Mac 支持）：

```bash
brew install orbstack      # 或官网 https://orbstack.dev 下载安装
# 启动后确认 docker 可用：
docker version
```

**② 下载并安装 act_runner**（注意是 **darwin_amd64**——iMac 2019 为 Intel 芯片；版本见 https://gitea.com/gitea/act_runner/releases）：

```bash
curl -sSL -o act_runner.tar.gz \
  https://gitea.com/gitea/act_runner/releases/download/v0.2.11/act_runner_0.2.11_darwin_amd64.tar.gz
tar -xzf act_runner.tar.gz && sudo mv act_runner /usr/local/bin/
```

**③ 注册到 git.tic.cc**（交互式）：

```bash
act_runner register
# 按提示填写：
#   - Gitea 地址：https://git.tic.cc
#   - 注册令牌：§1.2 生成的 reg_xxx
#   - 标签：保持默认（含 ubuntu-latest，工作流使用该标签）
```

**④ 以 Docker 模式启动**（OrbStack 提供 Docker socket，act_runner 直接复用）：

```bash
act_runner daemon
```

**⑤ 开机自启**（可选）：用 launchd 托管，新建 `~/Library/LaunchAgents/com.gitea.act-runner.plist`（`ProgramArguments` 指向 `/usr/local/bin/act_runner daemon`，`RunAtLoad` 为 true），然后 `launchctl load ~/Library/LaunchAgents/com.gitea.act-runner.plist`。

注册时注意：
- Gitea 地址填 `https://git.tic.cc`
- 标签保持默认（`ubuntu-latest` 等），工作流使用 `ubuntu-latest`
- Gitea Actions 没有远程唤醒机制：iMac 休眠时不会接活，建议系统设置关闭自动休眠，或保持电源唤醒
- 若改用 Linux 服务器作 runner：步骤同上，二进制换 `act_runner_<版本>_linux_amd64.tar.gz`，进程托管用 systemd（官方提供 `act_runner.service` 模板）

### 1.4 验证

推送任意改动到 main 分支，在 Gitea 仓库页 **Actions** 标签查看构建日志；构建成功后可在构建详情的 **Artifacts** 下载 `einz-debug-apk`。

### 1.5 Runner 网络要求与镜像

构建过程需要访问：GitHub（下载 Flutter SDK、拉取公共 action、sqlite3 预编译库）、Gradle Maven 仓库、pub.dev。若 runner 机器（iMac）出口受限，在 act_runner 环境（或 Gitea 仓库 Secrets）配置镜像变量：

| 变量 | 国内镜像值 |
| --- | --- |
| `FLUTTER_STORAGE_BASE_URL` | `https://storage.flutter-io.cn` |
| `PUB_HOSTED_URL` | `https://pub.flutter-io.cn` |

> APK 目前为 **debug 签名**，仅用于测试分发。如需上架/正式发布，需先创建 release keystore 并配置 `app/android/key.properties`（见 aimemo/worklog 待办），工作流再做对应调整。

---

## 二、iOS：Codemagic 云构建

### 2.1 Codemagic 连接仓库

1. 注册/登录 [Codemagic](https://codemagic.io)（建议用 Apple 或 GitHub 账号登录）。
2. **Add application → 选择 Other / 自定义 Git 服务**，用 SSH 方式添加自建 Gitea 仓库 `https://git.tic.cc/fon/einz`（按页面提示添加 Codemagic 的 SSH 公钥到 Gitea 账号的 SSH Keys）。
3. 选中应用后进入构建设置。

### 2.2 配置 Apple 签名

1. Codemagic 页面左侧 **Signing → iOS**，按向导登录 Apple Developer 账号（或配置 App Store Connect API Key）。
2. 确认 App 的 bundle id 为 **`cc.tic.einz`**，Codemagic 会自动创建/匹配证书与 Provisioning Profile。
3. 若签名向导生成新的证书，需要把对应私钥保存在 Codemagic 中，并（如需发布 App Store）在 Apple 开发者后台的 Certificates/Profiles 中确认对应条目存在。

### 2.3 构建

项目根目录已含 `codemagic.yaml`。在 Codemagic 页面选择 **Start build → 使用 codemagic.yaml**，选择 `ios-release` 工作流：

- 每次构建约 20–40 分钟（首次因依赖下载更久），免费额度 500 分钟/月。
- 产物 IPA 出现在构建页面的 **Artifacts**：`app/build/ios/ipa/*.ipa`（已签名）。
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
