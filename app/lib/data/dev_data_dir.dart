import 'dart:io';

import 'package:flutter/foundation.dart';

/// dev 运行的数据目录隔离：`--dart-define=einzDevDataDir=<子目录名>`。
///
/// **为什么需要它**：`flutter run -d macos` 起出来的 debug 版与装机的那份正式客户端
/// **是同一个 app**（同一个 bundle id → 同一个沙盒容器 → 同一个 `einz.sqlite`），
/// 直接连开发服务器就等于拿正式数据去试，所以"只敢看看、不敢动"。
/// 想改 bundle id 把它们变成两个 app 是做得到的，但**走不通**：Debug 配置是自动签名，
/// Xcode 对一个没注册过的新 bundle id 找不到 provisioning profile，直接构建失败
/// （2026-09-22 实测：`No profiles for 'cc.tic.einz.dev' were found`）。要真做就得在
/// Xcode 里新建 configuration/scheme + 让 Xcode 注册新 App ID + 把 entitlements 里的
/// `keychain-access-groups` 参数化——那是另一件事。
///
/// 于是改用等效做法：**不动 bundle id，把这次运行用到的目录全部挪到基础目录下的
/// `dev-*/` 子目录里**。用到的三处（DB 在 Documents、附件在 Application Support、
/// 媒体缓存在 Caches）都经 [applyDevDataDir]；密钥那半边由 SecureStore 的
/// `einzSecurePrefix` 负责（见 `secure_store.dart`）。两者合起来，debug 版有自己
/// 的库、自己的附件、自己的缓存、自己的密钥条目，正式那份一个字节都不碰。
///
/// 用法见 `package.json` 的 `app-mac-run-local` / `app-mac-run-localConfig`。
///
/// ⚠ 发布脚本与 CI 绝不传这两个 define（同 `docs/SERVER_SETTINGS.md` §6 的红线）。
/// 另外这里的开关**只在非 release 构建里生效**（[devDataDirIsolated] 内含
/// `!kReleaseMode`），所以万一真被烘进发布包，也只是被忽略，不会让正式版"看起来没数据"。
const String kDevDataDir = String.fromEnvironment('einzDevDataDir');

/// 本次运行是否启用 dev 数据目录隔离。
bool get devDataDirIsolated => !kReleaseMode && kDevDataDir.isNotEmpty;

/// 在 [base] 目录下追加 dev 子目录并确保存在。
///
/// 只在 [devDataDirIsolated] 为真时调用（DB 那处是这个用法：`databaseDirectory` 传
/// null 等于"用 drift 默认"，所以生产路径连一次函数调用都不多）。
Future<Directory> devSubDir(Future<Directory> Function() base) async {
  final dir = await base();
  final sub = Directory('${dir.path}${Platform.pathSeparator}$kDevDataDir');
  await sub.create(recursive: true); // create 幂等，已存在时 no-op
  return sub;
}

/// 统一入口：启用隔离 → dev 子目录；否则原样返回基础目录（**生产行为不变**）。
Future<Directory> applyDevDataDir(Future<Directory> Function() base) =>
    devDataDirIsolated ? devSubDir(base) : base();
