import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../brand_logo.dart';
import '../data/server_config.dart';
import '../l10n/app_localizations.dart';

/// 「关于」弹层要展示的版本信息（版本号 + 构建号）。
typedef AboutInfo = ({String version, String buildNumber});

/// 「关于秘境」内容 = 底部弹层（老板 2026-09-25：内容不多，不再用独立页面）。
///
/// 入口在对话页、向导页、锁屏页的右上角菜单（三项都叫「关于秘境」），以及
/// 对话页顶栏 logo+品牌名（点击等同菜单项）。
/// 版本号读的是打包时写进产物的 CFBundleShortVersionString / versionName
/// （yymm.ddhh.mm，见 scripts/appVersion.js），不是 pubspec 里那个写死的 1.0.0。
/// 服务器地址读 [effectiveServer]（启动时定好的进程全局量）——锁屏态与解锁后读的
/// 是同一个变量，不可能不一致（地址不进锁包，见 `data/app_lock.dart`）。
class AboutSheet extends StatefulWidget {
  const AboutSheet({super.key});

  /// 各处菜单/入口统一从这个静态方法打开（ showModalBottomSheet）。
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => const AboutSheet(),
    );
  }

  @override
  State<AboutSheet> createState() => _AboutSheetState();
}

class _AboutSheetState extends State<AboutSheet> {
  late final Future<AboutInfo> _info = _load();

  Future<AboutInfo> _load() async {
    final pkg = await PackageInfo.fromPlatform();
    return (version: pkg.version, buildNumber: pkg.buildNumber);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 标题样式与留白同「界面语言」/「更多通道」等弹层：居中、上 14 下 10
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Center(
              child: Text(l10n.aboutPageTitle,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16)),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: FutureBuilder<AboutInfo>(
                future: _info,
                builder: (context, snapshot) {
                  final info = snapshot.data;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: BrandLogo(size: 72, radius: 16)),
                      const SizedBox(height: 18),
                      Text(
                        l10n.aboutIntro,
                        textAlign: TextAlign.left,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                      ),
                      const SizedBox(height: 28),
                      const Divider(),
                      const SizedBox(height: 12),
                      // 版本号带构建号：报问题时两个都要，构建号才能对到具体那一次打包
                      _InfoRow(
                        label: l10n.aboutVersionLabel,
                        value: info == null
                            ? '…'
                            : '${info.version} (${info.buildNumber})',
                      ),
                      const SizedBox(height: 14),
                      // 服务器地址可长按选中复制（排查连不上时最常问的就是这个）。
                      // 非出厂域名（--server / 编译期覆盖）时标注，避免把开发包当正式包。
                      _InfoRow(
                        label: l10n.aboutServerLabel,
                        value: effectiveServer,
                        note: isDevServer ? l10n.aboutServerDevNote : null,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行「标签 + 值」，值可长按选中复制。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.note});

  final String label;
  final String value;

  /// 值下方的补充说明（小字、弱化色），null = 不展示。
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        SelectableText(value, style: theme.textTheme.bodyLarge),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(
            note!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
