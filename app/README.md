# einz（Flutter App）

Einz 的手机端：双人私密空间客户端（E2EE 聊天 + 附件 + 语音）。

- 加解密与协议实现全部在 `../shared/`（与 TUI 共用，无分叉）；本目录只做 UI 与本地库。
- 本地库 `drift`（SQLite），密钥进 Keychain/Keystore（见 `../docs/DATABASE.md` §4）。
- 运行：`flutter run --dart-define-from-file=localConfig.ios.json`（或 `npm run ios-run-dev`）；
  打包与签名见 `../README.md` 与 `../docs/DEPLOYMENT.md`。
- 服务器地址**不是用户可配置项**（只服务于开发切换与出厂域名容灾），每次启动由
  `--server` > 编译期 `dart-define` > 出厂候选域名算出，不落任何持久层，详见
  `lib/data/server_config.dart` 与 `../docs/SERVER_SETTINGS.md`。
- 桌面端两个启动参数（`open -a Einz --args …`）：
  - `--server <地址>`：本次启动指向开发服务器（打包后测完即可原包发布）；
  - `--reset`：确认后清空本设备数据，回到新设备入网起点（测试后清场）。
- 上手流程（创建/加入秘境）见 `../docs/ONBOARDING.md`。
