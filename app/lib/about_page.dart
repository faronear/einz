import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'brand_logo.dart';
import 'data/local_database.dart';
import 'data/server_settings.dart';
import 'l10n/app_localizations.dart';

/// 「关于」页要展示的三项信息。
typedef AboutInfo = ({String version, String buildNumber, String server});

/// 「关于秘境」页：版本号 + 当前服务器地址 + 一句话说明。
///
/// 入口在对话页和向导页的右上角菜单（两项都叫「关于秘境」）。
/// 版本号读的是打包时写进产物的 CFBundleShortVersionString / versionName
/// （yymm.ddhh.mm，见 scripts/appVersion.js），不是 pubspec 里那个写死的 1.0.0。
/// 服务器地址读本设备持久化值，没改过就是默认 einz.tic.cc。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.db, this.server});

  /// 测试注入用；不给就用全局库。
  final LocalDatabase? db;

  /// 当前生效的服务器地址（命令行 --server 覆盖或本设备持久化值）；给则直接用，
  /// 不给则回退读本设备持久化值。
  final String? server;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<AboutInfo> _info = _load();

  Future<AboutInfo> _load() async {
    final pkg = await PackageInfo.fromPlatform();
    final server = widget.server ??
        await ServerSettings(widget.db ?? LocalDatabase.shared).load();
    return (version: pkg.version, buildNumber: pkg.buildNumber, server: server);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutPageTitle)),
      body: SafeArea(
        child: FutureBuilder<AboutInfo>(
          future: _info,
          builder: (context, snapshot) {
            final info = snapshot.data;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: BrandLogo(size: 72, radius: 16)),
                  const SizedBox(height: 18),
                  Text(
                    l10n.aboutIntro,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                  // 服务器地址可长按选中复制（排查连不上时最常问的就是这个）
                  _InfoRow(label: l10n.aboutServerLabel, value: info?.server ?? '…'),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 一行「标签 + 值」，值可长按选中复制。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

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
      ],
    );
  }
}
