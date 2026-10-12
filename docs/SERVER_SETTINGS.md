 k

# 服务器地址设置

> 定稿 2026-09-19。本文描述的是**当前实现**，不是设想。

## 1. 基本策略

服务器地址**不是最终用户可配置项**。它只服务于两件事：

1. **开发时临时切换开发环境**（指向 localhost / staging）；
2. **出厂域名的容灾冗余**（主域名失效时老 App 自己连上备用入口）。

由此推出一条贯穿两端的规则：

> **地址每次启动算一次，永不落盘。**
> 不写 `app_state`、不写锁包（`AppLockPayload`）、不写 TUI 的 store。

**为什么不做"用户可配置服务器"**

- 产品上不做自建/开源：未来若有除本人之外的用户，直接用提供的服务器。
- 真要换域名，重新打包发布好过让用户在老 App 里做复杂操作。
- 落到 store / 锁包里的地址会变成**隐式状态**：某台设备静默连着另一台服务器，本人还想不起来。宁可每次手输——那个"烦"本身就是"该去改配置"的警报。

**一个必须分清的概念**

|                                  | 换**域名**（同服务多入口） | 换**服务器**（另一套数据）   |
| -------------------------------- | -------------------------- | ---------------------------- |
| 例子                             | einz.tic.cc → 备案域名     | 迁移到另一台机               |
| `spaceId` / `token` / 通道密钥对 | **不变**                   | 全部失效                     |
| 需要清库 + 重新入网吗            | 不需要                     | **需要**（且要对方重新邀请） |
| 怎么办                           | 候选域名自愈（§4）         | 重新打包 + 通知用户          |

## 2. 三层优先级

| 层  | 来源                                                                | 生效范围                   | 怎么改                                   |
| --- | ------------------------------------------------------------------- | -------------------------- | ---------------------------------------- |
| 1   | 命令行`--server <地址>`                                             | **本次进程**（仅本次生效） | 启动时传参                               |
| 2   | 编译期`kEinzServer`（`--dart-define-from-file=localConfig.*.json`） | **这个包**（烘进二进制）   | 改配置文件 + 重新`flutter run` / `build` |
| 3   | 出厂候选域名`kServerCandidates`                              | 这个包                     | 改常量 + 重新发布                        |

三层都不需要解锁就能读到（地址不在锁包里），所以**锁屏页显示的与解锁后实际连的必然是同一个值**。

TUI 的第 2、3 档是同一套语义、不同载体：第 2 档 = `cli/localConfig.json` 的 `server`
（运行时读，改完重启即生效），第 3 档 = `_kServerCandidates`。两端保持同构，
是为了让 TUI 测试能提前暴露域名容灾问题（老板 2026-09-19）。

## 3. 各端对照

|              | TUI                                                                           | App（桌面端）                                                                           | App（手机端）            |
| ------------ | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------ |
| 硬编码托底   | `_kPrimaryServercli/bin/einz_tui.dart:181`                                    | `kPrimaryServerapp/lib/data/server_config.dart:32`                                      | 同桌面端                 |
| 配置文件     | `cli/localConfig.json`**运行时**读（`_configuredServers()`）；**支持单个地址或多个地址的数组**——多地址时只在数组内并发探测；没有配置则在出厂候选域名里探测（`_defaultServer()`） | `app/localConfig.*.json`**编译期** `--dart-define-from-file`（`server_config.dart:28`）；没有则并发探测出厂候选域名（`resolveServer()`） | 同桌面端                 |
| 启动参数     | `--server <地址>`                                                             | `--server <地址>`                                                                       | 无（移动端没有启动参数） |
| 运行期命令   | `/server [地址]`、`/status`                                                   | 「关于秘境」页显示地址                                                                  | 同桌面端                 |
| 配置读不到时 | 源码运行（`dart run`）：打一行提示再走候选域名（不静默）；**打包产物（AOT）：不打**——产物里本来就没有 localConfig.json，走出厂候选域名是预期行为（老板 2026-09-21） | —                                                                                       | —                        |
| 持久化       | **无**                                                                        | **无**                                                                                  | **无**                   |

`cli/localConfig.json` 的查找顺序（TUI）：

1. **当前工作目录**——`cd cli && dart run bin/einz_tui.dart`（npm scripts 都这么干）
   走的就是这条，既有语义；
2. **可执行文件同目录**（仅打包产物）——把 `localConfig.json` 放在二进制旁边就生效，
   拷到别的机器也跟着走。

优先级仍是 `--server > localConfig.json > 出厂候选域名`（产物同样接受 `--server`）。

⚠ `dart compile exe` **只编译 Dart 代码，不打包任何数据文件**——localConfig.json 不会进
产物（它本来也是 gitignore 的本地文件，模板 `cli/localConfig.example.json`）。产物运行时若
cwd 下有 localConfig.json 照样读（自建服务器场景）；没有就走出厂候选域名，且**不再打印
「未找到」提示**（那条只对源码运行有意义：提醒你 cwd 不对、实际连的不是以为的服务器）。

## 4. 域名容灾：候选列表

```
// App：app/lib/data/server_config.dart   ／   TUI：cli/bin/einz_tui.dart
kServerCandidates  = [kPrimaryServer, 'https://einz.yuanjinx.com',
                      'https://einz.farinear.cn', 'https://einz.bittic.cn']
_kServerCandidates = [_kPrimaryServer, 'https://einz.yuanjinx.com',
                      'https://einz.farinear.cn', 'https://einz.bittic.cn']
// 加备用域名 = 两边各加一行常量（+ 重新构建/发布）+ 服务器端 Caddy 站点/证书先行就绪
// 四个入口指向**同一台服务器**（tic.cc 全球、其余国内备案），身份相同、不需要清库。
// 多入口同时抗：单域名 DNS 注入（§4.1 DoH 兜底的姊妹防线）、备案/注册商故障。
```

探测语义：候选**并发**探测，**谁先返回 200 就用谁**（不是"列表第一个优先"——顺序只
影响全不通时的兜底与语义）。

- `resolveServer()`（App）/ `_defaultServer()`（TUI）：命令行 / 本机配置**不探测**，直接用；否则对候选**并发**探测，取第一个 `/health` 成功的（主域名挂掉时不必干等 3s 超时才试备用）。
- 全部不通 → 回主域名，由向导页的 4s 自动重试兜底。
- **重试也回候选列表**（App，2026-09-21）：启动那一刻若网络还没就绪，地址会被钉死在
  兜底主域名；此前向导页的 4s 重试只死磕这一个地址，备用入口就再也用不上了。现在每轮
  重试先 `resolveServer(null)` 并发重选一次（谁通换谁，首屏那行「正在连接 <地址>」随之
  更新），再探测新地址。开发覆盖（`--server` / 编译期 dart-define）不参与重选——那是人为
  指定的地址，不该被候选列表劫持。
- 老 App 加一个备用域名后**自愈**，不需要用户更新，也不需要在 App 里做任何操作。

### 4.1 DNS 污染兜底（DoH + IP 钉扎，2026-10-11）

背景：部分网络（家庭路由器 / 运营商网关）对明文 UDP-53 查询做**抢答注入**——伪造应答
（假 IP + TTL 3600）抢先到达，系统解析被污染约 1 小时，客户端连不上服务器（2026-10-11
排查：`einz.yuanjinx.com` 在老板家庭宽带被注入 `23.248.192.114`；手机蜂窝正常）。

机制（`shared/lib/src/protocol/dns_fallback.dart`，App / CLI / WS 三端共用）：

- 探测（App `probeServer` / TUI `_probeServer`）直连失败 → 用 **DoH** 重新解析域名
  （doh.pub 优先、dns.alidns.com 兜底、cloudflare-dns.com 收尾——海外用户兜底；
  加密查询无法被链路注入）→ 拿到真 A 记录后**钉扎**（pin）进进程级表 → 立即重探一次。
- 钉扎后所有连接（REST / WS / 探测）经 `HttpClient.connectionFactory` 直连钉扎 IP，
  **TLS 仍按真实域名校验**（SNI + 证书验证不变，全链路无 `onBadCertificate`）——假 IP
  拿不出合法证书，只会握手失败，不会被中间人。
- 自愈：钉扎 IP 连不上（服务器搬迁后陈旧）→ 连接层自动清钉扎，下一轮探测重新 DoH；
  每主机 60s 内最多 DoH 一次（向导页 4s 重试循环不会打爆 DoH）。
- 钉扎表会话级内存、**永不落盘**（与 §1 地址纪律一致）；IP 字面量 / localhost 不触发
  DoH；健康网络零 DoH 流量（首次探测即成功直接返回）。

## 5. 开发工作流

**手机 / 模拟器（debug）**

```bash
flutter run --dart-define-from-file=localConfig.ios.json     # 或 npm run ios-run-dev
```

改完配置文件必须**停掉重跑**——`hot reload / hot restart` 不会重新读 dart-define。

**桌面端（打包后测、原包发布）**

桌面端没有模拟器，所以流程是：打包 → 用 `--server` 指向开发服务器测 → 测完直接发这个包（包里烘的是出厂域名）：

```bash
open -a Einz --args --server http://localhost:3000      # macOS（走原生桥读启动参数）
```

测完本机数据属于开发服务器（连生产既用不了、也没有别的入口能卸掉），清场用
**对话页菜单 → 高级 → 解绑设备**（桌面/手机同一入口：清本设备数据 → 回入网起点）。

**macOS debug（源码运行，不打包）**

`flutter run -d macos` 也能临时切服务器，两条路径都固化成 npm script 了：

| 脚本                               | 走哪一层                                                      | 等价命令                                                                          |
| ---------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `npm run app-mac-run-local`       | 第 1 层：运行期 `--server`                                    | `cd app && flutter run -d macos -a --server=http://localhost:3000`                 |
| `npm run app-mac-run-localConfig` | 第 2 层：编译期 dart-define（读 `app/localConfig.macos.json`） | `cd app && flutter run -d macos --dart-define-from-file=localConfig.macos.json`   |

`-a/--dart-entrypoint-args` 之所以能当 `--server` 用：桌面端工具把它拼进 app 可执行文件的
argv（`flutter_tools/lib/src/desktop_device.dart:125`），而原生桥读的正是
`ProcessInfo.processInfo.arguments`——和发布包 `open --args` 走**同一条代码路径**。
注意 `hot reload / hot restart` 不会重读 dart-define（同移动端），改了要停掉重跑。

**两个脚本都会把这次运行"关进小房间"**，所以可以放开手点。debug 版与装机的那份正式
客户端**是同一个 app**（同 bundle id → 同沙盒容器 → 同一个 `einz.sqlite`），脚本额外传
两个 define 把数据分开：

- `--dart-define=einzDevDataDir=dev` → SQLite / 附件 / 媒体缓存统统落进各自基础目录下的
  `dev/` 子目录（`app/lib/data/dev_data_dir.dart`），正式库一个字节都不动；
- `--dart-define=einzSecurePrefix=einz.secure.dev.` → SecureStore 换 key 前缀，Keychain
  条目与正式版分开（**必须**：同前缀会互相覆盖，正式那份被覆盖就是丢密钥）。

两个开关都**只在非 release 构建生效**，且发布脚本与 CI 绝不传（§6 红线）。

⚠ 直接 `flutter run -d macos`（不经过脚本）**没有这层隔离**——它和你装机的那份共用同一个
容器库，等于拿正式数据连开发服务器。

> 想更彻底（debug 版与正式版是两个 app、两个沙盒容器、各自 TCC 权限、可并排运行）就得换
> bundle id：需要单独注册 App ID + provisioning profile（Debug 是自动签名，Xcode 对没注册
> 过的新 id 找不到 profile 会直接构建失败：`No profiles for 'cc.tic.einz.dev' were found`），
> 而且 `Runner/DebugProfile.entitlements` 里的 `keychain-access-groups` 是硬编码的
> `cc.tic.einz`，换 id 后还要参数化成 `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`。
> 目前没做，理由见 `app/lib/data/dev_data_dir.dart` 文件头。

**TUI**

```bash
npm run tui2local-1     # 脚本里已绑定 --store + --server（tui2local = tui to localhost）

# 想验"多入口容灾"（主入口挂了自动切备用）时，把 cli/localConfig.json 的 server
# 写成数组即可——只在数组内并发探测，全不通就回第一个并追问地址，不会回落生产：
#   { "server": ["http://localhost:3000", "http://127.0.0.1:3901"] }
# 注：App 侧只支持单值——dart-define 传数组会被 Flutter 字符串化成 `[a, b]`（不是
# 合法 JSON，见 flutter_command.dart 的 extractDartDefines），所以容灾验证放在 TUI 做。
dart run bin/einz_tui.dart --server http://localhost:3000     # 临时覆盖
```

## 6. ⚠ 发布包的红线

**正式打包绝不带 `--dart-define-from-file`**：它会把开发地址烘进产物，而这个值**无法救回**——清数据、卸载重装都改不掉，桌面端还能靠 `--server` 临时顶，移动端连启动参数都没有。

现有 release 脚本（`package.json`：`app-apk-build-release` / `app-ios-build-adhoc` / `appstore` / `release`、`buildIos.sh`）与 CI（`codemagic.yaml`）都不传该参数。万一真烘进去了，「关于秘境」页会把地址标成**「开发地址（非生产）」**（`isDevServer`，`about_page.dart:74`），发出去前还有机会发现。

## 7. 查看当前地址

- App：「关于秘境」页（对话页 / 向导页 / 锁屏页右上角菜单），地址可长按复制；非出厂域名时标注「开发地址」。
- TUI：`/status`（服务器地址 + 是本机默认还是本次覆盖、线路、WS、对方在线、绑定、同步锚点、数据文件路径），或 `/server` 不带参数。

## 8. 不做什么（以及将来要做的代价）

**现在不做**：用户/运维在 App 里填服务器地址的能力；TUI store 里持久化地址（已删字段）。

**若将来要支持自建服务器**，需要的不只是加个输入框：

1. 地址变回持久数据——放 `app_state`，**不要放锁包**（锁包解锁前读不到，会重现"锁屏显示与解锁后不一致"）；
2. "改地址" = **换身份**：`spaceId` / `token` / 通道密钥对全是那台服务器上的，必须清库 + 重新走入网（邀请链接或共享口令）；
3. 本地库建议"换服务器就清"，不要做多服务器共存（会给同步锚点、附件缓存、空间管理各加一个维度）；
4. 移动端 release 包连 http / 自签证书会失败（ATS、Android cleartext），这是真实障碍；
5. 若多空间方案落地，`server` 会变成 **per-space 属性**，现在的进程级单例 `effectiveServer` 要推翻。

## 9. 迁移注意（本次改造的副作用）

- **App 老锁包里的 `server` 字段被忽略**：升级后一律用当前构建算出的地址。生产设备无感（锁包里的值本来就＝出厂域名）；开发机上若某台是用 dev 包入的网，升级后不带 `--server` 会指向生产，需要带 `--server`，或用「高级 → 解绑设备」清库重来。
- **TUI 老 store 里的 `server` 字段被忽略**：读时忽略，下次保存自然清掉。想让某个 store 固定连某台服务器，请用脚本绑定 `--store` + `--server`。
