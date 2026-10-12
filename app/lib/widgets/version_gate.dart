import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/server_config.dart';
import '../l10n/app_localizations.dart';
import 'linkified_text.dart';

/// 版本闸（2026-10-04）：服务端在 `/health` 里声明 `cold_app_version` 时，
/// **低于它的客户端在首屏弹一个关不掉的升级窗口**——"服务端已经不支持你了"。
///
/// 2026-10-10 起分**温度三态**（老板定）：`hot_app_version` = 当前正热用的版本；
/// `cold_app_version` = 冻结线（当前可用的最低版本）；介于两者之间 = **cooling
/// （正在冷却，弹可关闭的提醒，不拦人）**；低于冻结线 = **frozen（冻结，弹关不掉的
/// 升级窗口）**。注意 cold 是"线"不是"态"——状态只有 cooling / frozen。
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

/// 版本闸级别（2026-10-10 起温度三态：hot / cooling / frozen）。
///
/// - [frozen]：低于**冻结线**（cold_app_version）→ 弹**关不掉**的升级窗口（拦人）；
/// - [cooling]：低于**当前热版本**（hot_app_version）但未低于冻结线 → **正在冷却**，
///   弹**可关闭**的升级提醒（不拦人）；
/// - [none]：已达热版本，或服务端什么都没设。
enum VersionGateLevel { none, cooling, frozen }

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

/// 本机版本是否已冻结（frozen：低于服务端冻结线，不可用）。
///
/// [appVersion] 为空（拿不到包信息）/ [coldVersion] 为空（服务端不设冻结线）→ 一律
/// 判为"未冻结"（false）：宁可漏拦，不误拦。拿不到自己的版本就无从比较，
/// 把用户锁在门外是比"放行一个旧版本"更糟的错误。
bool isAppVersionFrozen(String appVersion, String? coldVersion) {
  if (appVersion.trim().isEmpty) return false;
  final cold = coldVersion?.trim() ?? '';
  if (cold.isEmpty) return false;
  return compareAppVersions(appVersion, cold) < 0;
}

/// 版本闸级别判定（2026-10-10）：服务端下发的两个版本号 + 本机版本 → 弹哪种窗。
///
/// **frozen 优先**：低于冻结线就是"冻结"（被拦着的人不需要再看到冷却提醒）；
/// 否则低于热版本 → **cooling**（正在冷却）；都不低（或服务端没设 /
/// 版本号空串）→ **none**。
///
/// [appVersion] 为空（拿不到包信息）→ 一律 **none**：宁可漏拦/漏提醒，不误拦
/// （与 [isAppVersionFrozen] 同一政策）。
VersionGateLevel appVersionGateLevel(
  String appVersion, {
  String? coldVersion,
  String? hotVersion,
}) {
  if (appVersion.trim().isEmpty) return VersionGateLevel.none;
  final cold = coldVersion?.trim() ?? '';
  final hot = hotVersion?.trim() ?? '';
  if (cold.isNotEmpty && compareAppVersions(appVersion, cold) < 0) {
    return VersionGateLevel.frozen;
  }
  if (hot.isNotEmpty && compareAppVersions(appVersion, hot) < 0) {
    return VersionGateLevel.cooling;
  }
  return VersionGateLevel.none;
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

/// 启动时核对版本级别；低于冻结线（frozen）弹**关不掉**的升级窗口，冷却中弹可关闭的提醒。
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
  if (!health.ok) return;

  final current = await (appVersion ?? appVersionString)();
  final level = appVersionGateLevel(current,
      coldVersion: health.coldAppVersion,
      hotVersion: health.hotAppVersion);
  if (level == VersionGateLevel.none || !context.mounted) return;

  await showDialog<void>(
    context: context,
    // 只有 frozen（低于冻结线）才关不掉（点外面不行、返回键/ Esc 也不行）：拦着的人
    // 给一个能划走的窗就等于没拦。**冷却**级别可关闭——它只是"有新版本"的提醒，
    // 产品上用户有权忽略（老板 2026-10-10 定）。
    barrierDismissible: level != VersionGateLevel.frozen,
    builder: (ctx) => level == VersionGateLevel.frozen
        ? _FrozenUpgradeDialog(
            currentVersion: current,
            coldVersion: health.coldAppVersion!,
            downloadUrl: health.appDownloadUrl,
          )
        : _CoolingUpgradeDialog(
            hotVersion: health.hotAppVersion!,
            downloadUrl: health.appDownloadUrl,
          ),
  );
}

/// 升级入口 URL 统一处理：能打开就外部浏览器打开，打不开（无浏览器/地址非法）
/// 静默——链接原样显示在窗口里，用户还能手抄。
Future<void> openAppDownloadUrl(BuildContext context, String? url) async {
  if (url == null || url.isEmpty) return;
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    // 打不开（无浏览器/地址非法）→ 让用户手抄：地址本身就在下面那行文本里
  }
}

/// **冻结**升级窗（关不掉）：本版本已 frozen（低于冻结线），服务端不再支持。
class _FrozenUpgradeDialog extends StatelessWidget {
  const _FrozenUpgradeDialog({
    required this.currentVersion,
    required this.coldVersion,
    this.downloadUrl,
  });

  final String currentVersion;
  final String coldVersion;
  final String? downloadUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final url = downloadUrl;
    final hasUrl = url != null && url.isNotEmpty;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Center(child: Text(l10n.upgradeFrozenTitle)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.upgradeFrozenBody(coldVersion, currentVersion)),
            if (hasUrl) ...[
              const SizedBox(height: 10),
              // 链接本身可点（= 点「下载新版本」按钮，开外部浏览器）；
              // LinkifiedText 渲染蓝字+下划线，与全 app 链接样式一致
              LinkifiedText(url, style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
        actions: [
          if (hasUrl)
            FilledButton(
              onPressed: () => openAppDownloadUrl(context, downloadUrl),
              child: Text(l10n.upgradeFrozenDownload),
            ),
        ],
      ),
    );
  }
}

/// **冷却**升级窗（可关闭，2026-10-10）：当前版本正在冷却——仍可用，但有更新的热版本。
///
/// 与 [_FrozenUpgradeDialog] 的区别就在语气与可关闭性：没有"重新检查"
/// （它不是故障，没有"再问一次服务器"的意义），关闭 = 用户选择忽略，下次
/// 启动再提醒（老板 2026-10-10 定：每次启动都提示，不做本地记忆）。
class _CoolingUpgradeDialog extends StatelessWidget {
  const _CoolingUpgradeDialog({
    required this.hotVersion,
    this.downloadUrl,
  });

  final String hotVersion;
  final String? downloadUrl;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final url = downloadUrl;
    final hasUrl = url != null && url.isNotEmpty;
    return AlertDialog(
      title: Center(child: Text(l10n.upgradeCoolingTitle)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.upgradeCoolingBody(hotVersion)),
          if (hasUrl) ...[
            const SizedBox(height: 10),
            // 链接本身可点（= 点「下载新版本」按钮），同 _FrozenUpgradeDialog
            LinkifiedText(url, style: const TextStyle(fontSize: 12)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.upgradeCoolingLater),
        ),
        if (hasUrl)
          FilledButton(
            onPressed: () => openAppDownloadUrl(context, downloadUrl),
            child: Text(l10n.upgradeCoolingDownload),
          ),
      ],
    );
  }
}
