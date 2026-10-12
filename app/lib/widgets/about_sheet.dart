import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../brand_logo.dart';
import '../data/server_config.dart';
import '../l10n/app_localizations.dart';
import 'clickable.dart';
import 'version_gate.dart';

/// 下载入口（老板 2026-10-12）：GitHub releases 的 latest 页（与服务端
/// `appDownloadUrl` 同一地址）。`latest` 是 GitHub 的固定别名， releases 置顶
/// 即指向它——不跟具体版本号，永不过期。
const String _kReleasesUrl =
    'https://github.com/faronear/einz/releases/tag/latest';

/// 链接色：品牌深蓝 #2271F7（与 LinkifiedText / 「邀请加入」链接同源）。
const Color _kLinkColor = Color(0xFF2271F7);

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
///
/// **连接状态行（2026-10-11；2026-10-12 改口径）**：只探测**启动时定下的活
/// 地址** [effectiveServer]（复用带 DoH 兜底的 [probeServer]）——可达显示
/// "已连接"，不可达如实显示"无法连接"。**不再尝试其他候选**：候选切换/兜底
/// 是启动探测的事，About 是状态展示不是连接管理器（老板 2026-10-12：开发
/// 环境连 localhost 断开时，跑去显示连上了线上域名没有意义）。
class AboutSheet extends StatefulWidget {
  const AboutSheet({super.key, this.probe});

  /// 探测函数（测试注入 fake；生产用 [probeServer]，自带 DoH 兜底）。
  final Future<ServerHealth> Function(String server)? probe;

  /// 各处菜单/入口统一从这个静态方法打开（ showModalBottomSheet）。
  static Future<void> show(BuildContext context,
      {Future<ServerHealth> Function(String server)? probe}) {
    return showModalBottomSheet<void>(
      context: context,
      // 允许用满窗高（与「我的通道」等弹层同口径，老板 2026-10-02）：
      // 窗口缩小先保持弹层高度，压到上边沿才一起往下压。
      isScrollControlled: true,
      builder: (_) => AboutSheet(probe: probe),
    );
  }

  @override
  State<AboutSheet> createState() => _AboutSheetState();
}

class _AboutSheetState extends State<AboutSheet> {
  late final Future<AboutInfo> _info = _load();

  /// 只探测**启动时定下的活地址** [effectiveServer]（2026-10-12 老板决策）：
  /// About 是状态展示，不是连接管理器——重新去连其他候选没有意义（候选切换/
  /// 兜底是启动探测的事，App 的实际连接也一直走 effectiveServer）。断开就如实
  /// 显示断开，不尝试其他地址。true = 可达。
  late final Future<bool> _reachable = _probeEffective();

  Future<AboutInfo> _load() async {
    final pkg = await PackageInfo.fromPlatform();
    return (version: pkg.version, buildNumber: pkg.buildNumber);
  }

  Future<bool> _probeEffective() async {
    final probe = widget.probe ?? probeServer;
    return (await probe(effectiveServer)).ok;
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
                      // 下载入口（版本号下一项，老板 2026-10-12）：整行可点 →
                      // 外部浏览器打开 releases 页；打不开（无浏览器/地址非法）
                      // 静默——URL 原样展示在行里，用户能手抄（同 version_gate
                      // 的 openAppDownloadUrl 口径）
                      _InfoRow(
                        label: l10n.aboutDownloadLabel,
                        value: _kReleasesUrl,
                        onTap: () => openAppDownloadUrl(context, _kReleasesUrl),
                      ),
                      const SizedBox(height: 14),
                      // 服务器地址可长按选中复制（排查连不上时最常问的就是这个）。
                      // 非出厂域名（--server / 编译期覆盖）时标注，避免把开发包当正式包。
                      _InfoRow(
                        label: l10n.aboutServerLabel,
                        value: effectiveServer,
                        note: isDevServer ? l10n.aboutServerDevNote : null,
                      ),
                      const SizedBox(height: 14),
                      FutureBuilder<bool>(
                        future: _reachable,
                        builder: (context, snap) {
                          // 判定用 connectionState 而非 hasData：探测结果是
                          // bool，全部路径都有数据；不可达是 false——若按
                          // hasData 判定会把"无法连接"显示成"检测中"
                          // （首版实现的真实 bug，测试抓出）。
                          final String value;
                          final Color? valueColor;
                          if (snap.connectionState == ConnectionState.waiting) {
                            value = l10n.aboutStatusChecking;
                            valueColor = null;
                          } else if (snap.data == true) {
                            value = l10n.aboutStatusConnected;
                            valueColor = Theme.of(context).colorScheme.primary;
                          } else {
                            value = l10n.aboutStatusUnreachable;
                            valueColor = Theme.of(context).colorScheme.error;
                          }
                          return _InfoRow(
                            label: l10n.aboutStatusLabel,
                            value: value,
                            valueColor: valueColor,
                          );
                        },
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

/// 一行「标签左 --- 值右」（老板 2026-10-12：标签与值放同一行，不再上下两行），
/// 值可长按选中复制；补充说明仍在下方独占一行。
///
/// [onTap] 非空 = 这一行是入口（如「下载」）：整块可点（老板口径：别让用户去点
/// 中某个小控件），值渲染成 app 统一链接样式（蓝字 #2271F7 + 下划线）且文字
/// 本身也可点——点哪都是同一个动作。
class _InfoRow extends StatelessWidget {
  const _InfoRow(
      {required this.label,
      required this.value,
      this.note,
      this.valueColor,
      this.onTap});

  final String label;
  final String value;

  /// 值下方的补充说明（小字、弱化色），null = 不展示。
  final String? note;

  /// 值的颜色（连接状态语义色），null = 默认。
  final Color? valueColor;

  /// 行点击动作，null = 普通展示行（值可选中复制）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // baseline 对齐：标签小字（labelMedium）与值大字（bodyLarge）字基线一致
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: onTap == null
                  // 普通行：值可长按选中复制（排查连不上时最常问的就是服务器地址）
                  ? SelectableText(value,
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: valueColor))
                  // 入口行：链接样式 + 文字本身可点（与整行 Clickable 同一动作）
                  : Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: value,
                            style: (theme.textTheme.bodyLarge ??
                                    const TextStyle())
                                .copyWith(
                              color: _kLinkColor,
                              decoration: TextDecoration.underline,
                              decorationColor: _kLinkColor,
                            ),
                            recognizer: TapGestureRecognizer()..onTap = onTap,
                          ),
                        ],
                      ),
                      textAlign: TextAlign.right,
                    ),
            ),
          ],
        ),
        if (note != null) ...[
          const SizedBox(height: 4),
          // note 也属于 value 侧（如开发地址标注）：与值同侧**右对齐**。
          // ⚠️ 必须先撑满整行（SizedBox width infinity）——Column 的
          // crossAxisAlignment.start 会把 Text 收缩到文字自然宽，框=字宽时
          // textAlign 不起作用（老板 2026-10-12 实测：热重启后 note 仍靠左）。
          SizedBox(
            width: double.infinity,
            child: Text(
              note!,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
    // 入口行整块可点（含标签与留白）；普通行不包，少一层无关手势
    return onTap == null ? row : Clickable(onTap: onTap, child: row);
  }
}
