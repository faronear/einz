# einz（Flutter App）

Einz 的手机端：双人私密空间客户端（E2EE 聊天 + 附件 + 语音）。

- 加解密与协议实现全部在 `../shared/`（与 TUI 共用，无分叉）；本目录只做 UI 与本地库。
- 本地库 `drift`（SQLite），密钥进 Keychain/Keystore（见 `../docs/DATABASE.md` §4）。
- 运行：`flutter run --dart-define-from-file=localConfig.ios.json`（或 `npm run ios-run-dev`）；
  打包与签名见 `../README.md` 与 `../docs/DEPLOYMENT.md`。
- 上手流程（创建/加入秘境）见 `../docs/ONBOARDING.md`。
