import 'package:flutter/material.dart';

import '../data/ui_style_settings.dart';
import '../l10n/app_localizations.dart';

/// 界面风格选择弹层：列出全部风格（目前：素雅纯色 / 渐变粉蓝），每项 = 一张
/// 预览图 + 名称 + 一句描述；点选即保存并立即生效（uiStyleNotifier 通知聊天页
/// 重建），弹窗保持打开——用户不离开弹窗即可看到大致效果，右上角 ✕ 或下滑关闭。
///
/// 与语言切换（点选即关窗）不同：风格切换需要"边看边试"，因此弹层自身监听
/// uiStyleNotifier 刷新选中态，不随点选关闭。
class UiStylePickerSheet extends StatefulWidget {
  const UiStylePickerSheet({super.key, required this.settings});

  final UiStyleSettings settings;

  @override
  State<UiStylePickerSheet> createState() => _UiStylePickerSheetState();
}

class _UiStylePickerSheetState extends State<UiStylePickerSheet> {
  late String _active;

  @override
  void initState() {
    super.initState();
    // 与全局通知同步：切换后即显示新选中项（首帧取当前通知值）
    _active = uiStyleNotifier.value;
    uiStyleNotifier.addListener(_onUiStyleChanged);
  }

  @override
  void dispose() {
    uiStyleNotifier.removeListener(_onUiStyleChanged);
    super.dispose();
  }

  void _onUiStyleChanged() {
    if (mounted) setState(() => _active = uiStyleNotifier.value);
  }

  Future<void> _apply(String style) async {
    if (style == _active) return; // 已激活：不重复保存
    await widget.settings.save(style); // 保存 → notifier 通知 → 选中态/聊天页背景刷新
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text('界面风格 / Interface style',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.chatPageStyleSheetClose,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          for (final option in kUiStyleOptions)
            _StyleOptionCard(
              option: option,
              active: option == _active,
              onTap: () => _apply(option),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// 单个风格选项卡：预览图 + 名称 + 描述 + 选中对勾（激活项浅粉底）。
class _StyleOptionCard extends StatelessWidget {
  const _StyleOptionCard({
    required this.option,
    required this.active,
    required this.onTap,
  });

  final String option;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Material(
        color: active ? scheme.secondaryContainer.withValues(alpha: 0.55) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                _StylePreview(option: option),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kUiStyleLabels[option]!,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        kUiStyleDescriptions[option]!,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (active)
                  const Icon(Icons.check, color: Color(0xFF2271F7)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 风格预览缩略图（程序化绘制，无需图片资源）：迷你聊天页示意——背景按风格
/// （浅粉纯色 / 粉蓝渐变）+ 一左一右两枚迷你气泡（天蓝=对方、粉=我）。
class _StylePreview extends StatelessWidget {
  const _StylePreview({required this.option});

  final String option;

  @override
  Widget build(BuildContext context) {
    final gradient = option == 'gradient';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 92,
        height: 64,
        decoration: BoxDecoration(
          gradient: gradient ? kBrandGradient : null,
          color: gradient ? null : const Color(0xFFFFF5FA),
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 34,
                height: 10,
                decoration: BoxDecoration(
                  color: const Color(0xFF3BAFFD).withValues(alpha: 0.30),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
            const Spacer(),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 34,
                height: 10,
                decoration: BoxDecoration(
                  color: const Color(0xFFD6529C).withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
