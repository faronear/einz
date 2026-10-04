import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/server_config.dart';
import '../l10n/app_localizations.dart';

/// 版本闸（2026-10-04）：服务端在 `/health` 里声明 `min_app_version` 时，
/// **低于它的客户端在首屏弹一个关不掉的升级窗口**——"服务端已经不支持你了"。
///
/// 为什么要有这道闸（与 `PROTOCOL_VERSION` 的分工）：
/// - `protocol_version` 是 **wire 兼容闸**：版本不符服务端直接 400 / WS 4400，
///   客户端表现为"什么都用不了但不知道为什么"；
/// - 这道闸是 **产品级闸**：协议也许还能用，但某个客户端版本有安全缺陷、或功能
///   已经不可靠 —— 运维改一行配置就能把旧客户端挡在门外，不必改代码、发新版。
///   它同时把"协议不符"这种硬故障变成一句人话。
///
/// 两个刻意的设计：
/// 1. **不阻塞启动**：探测在首帧之后异步跑（3s 超时）。正常客户端只是多一次
///    后台请求，冷启动不受影响；只有真需要升级时才弹窗打断。
/// 2. **只有探到才判**：探不通（离线/服务端挂了）**不弹**——离线仍能看历史，
///    这也是产品承诺；不能因为连不上就把人锁在外面。
///
/// 开发逃生口：`--dart-define=SKIP_VERSION_GATE=true`（见 [kSkipVersionGate]）。
/// 为什么需要它：开发包（`flutter run`）的版本号是 pubspec 里的 `0.0.0`，必然低于
/// 任何真实下限 —— 连着配了闸门的服务器时会被自己挡在门外。
const bool kSkipVersionGate = bool.fromEnvironment('SKIP_VERSION_GATE');

/// 版本号比较（`yymm.ddhh.mm`，见 `scripts/appVersion.js`）。
///
/// 逐段按**整数**比：段内不补零也能正确比较（`"2610.4.12"` 与 `"2610.0400.12"`
/// 是同一个东西，手写配置时容易漏零）。返回 <0 / 0 / >0。
///
/// 解析不出数字的段按 0 处理——宁可把"写错了的版本号"当成很小/相等，也不抛异常：
/// 这道闸的输入来自服务端配置，异常会让客户端启动不了，代价远大于漏拦一次。
int compareAppVersions(String a, String b) {
  final pa = a.split('.');
  final pb = b.split('.');
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final va = i < pa.length ? (int.tryParse(pa[i].trim()) ?? 0) : 0;
    final vb = i < pb.length ? (int.tryParse(pb[i].trim()) ?? 0) : 0;
    if (va != vb) return va < vb ? -1 : 1;
  }
  return 0;
}

/// 本机版本是否已不被服务端支持。
///
/// [appVersion] 为空（拿不到包信息）/ [minVersion] 为空（服务端不设下限）→ 一律
/// **不支持判定为"不支持"**（false）：宁可漏拦，不误拦。拿不到自己的版本就无从比较，
/// 把用户锁在门外是比"放行一个旧版本"更糟的错误。
bool isAppVersionUnsupported(String appVersion, String? minVersion) {
  if (appVersion.trim().isEmpty) return false;
  final min = minVersion?.trim() ?? '';
  if (min.isEmpty) return false;
  return compareAppVersions(appVersion, min) < 0;
}

/// 读本机版本号（打包时注入的 `yymm.ddhh.mm`；取不到返回空串）。
/// 缓存一次：启动 + 弹窗文案都要用，而包信息不会变。
String? _cachedAppVersion;
Future<String> appVersionString() async {
  final cached = _cachedAppVersion;
  if (cached != null) return cached;
  try {
    final pkg = await PackageInfo.fromPlatform();
    _cachedAppVersion = pkg.version;
  } catch (_) {
    _cachedAppVersion = '';
  }
  return _cachedAppVersion!;
}

/// 启动时核对最低版本；不被支持就弹**关不掉**的升级窗口。
///
/// 调用点：`StartupGate.initState`（首屏，所有入口——锁屏 / 向导 / 直接进聊天——
/// 都会先经过它）。探测失败静默返回，不影响任何流程。
Future<void> checkVersionGate(
  BuildContext context, {
  String? server,
  Future<ServerHealth> Function(String)? probe,
  Future<String> Function()? appVersion,
}) async {
  if (kSkipVersionGate) return;
  final probeFn = probe ?? probeServer;
  final target = server ?? effectiveServer;
  if (target.isEmpty) return;

  final ServerHealth health;
  try {
    health = await probeFn(target);
  } catch (_) {
    return; // 探测本身出错：当作连不上，不拦
  }
  if (!health.ok || health.minAppVersion == null) return;

  final current = await (appVersion ?? appVersionString)();
  if (!isAppVersionUnsupported(current, health.minAppVersion)) return;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    // 关不掉：点外面不行、返回键/ Esc 也不行（PopScope）。这是"必须升级"，
    // 给一个能划走的窗口就等于没拦。
    barrierDismissible: false,
    builder: (ctx) => _UpgradeDialog(
      currentVersion: current,
      minVersion: health.minAppVersion!,
      downloadUrl: health.appDownloadUrl,
      // 唯一的逃生口不是"跳过"，而是**重新问一次服务器**：运维刚把配置改回来 /
      // 刚推了新包，用户不必杀进程重启就能继续。
      onRecheck: () {
        Navigator.of(ctx).pop();
        unawaited(checkVersionGate(context,
            server: server, probe: probe, appVersion: appVersion));
      },
    ),
  );
}

class _UpgradeDialog extends StatelessWidget {
  const _UpgradeDialog({
    required this.currentVersion,
    required this.minVersion,
    required this.onRecheck,
    this.downloadUrl,
  });

  final String currentVersion;
  final String minVersion;
  final String? downloadUrl;
  final VoidCallback onRecheck;

  Future<void> _openDownload(BuildContext context) async {
    final url = downloadUrl;
    if (url == null || url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // 打不开（无浏览器/地址非法）→ 让用户手抄：地址本身就在下面那行文本里
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final url = downloadUrl;
    final hasUrl = url != null && url.isNotEmpty;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Center(child: Text(l10n.upgradeRequiredTitle)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.upgradeRequiredBody(minVersion)),
            const SizedBox(height: 10),
            Text(l10n.upgradeRequiredCurrent(currentVersion),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (hasUrl) ...[
              const SizedBox(height: 10),
              // 链接原样显示（可选中）：按钮点不开时还能手抄
              SelectableText(url,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF2271F7))),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: onRecheck,
            child: Text(l10n.upgradeRequiredRecheck),
          ),
          if (hasUrl)
            FilledButton(
              onPressed: () => _openDownload(context),
              child: Text(l10n.upgradeRequiredDownload),
            ),
        ],
      ),
    );
  }
}
