import 'package:flutter/material.dart';

/// 弹层右上角的关闭圆钮（老板 2026-10-24）：圆形淡灰底 + 关闭图标，与标题行
/// 水平对齐。各底部弹层（选项/阅后即焚/通道/成员/About 等）标题行右上角各挂
/// 一个——弹层本就支持下滑/点外部关闭，这个钮给鼠标用户一个明确的可见出口
/// （桌面端没有下滑手势）。
///
/// 放置方式：标题行从 `Center` 改为 `Stack`（标题仍居中），本钮
/// `Positioned` 钉右上角；或直接放进标题 `Row` 尾部。点按 = `Navigator.pop`。
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({super.key, this.tooltip = 'Close'});

  /// 无障碍/悬浮提示文案（调用方传 l10n.close）。
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      // 圆形淡灰底（与「添加秘境」等淡灰大按钮同色系）；尺寸收紧不喧宾夺主
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.05),
        shape: const CircleBorder(),
      ),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      iconSize: 18,
      color: Theme.of(context).colorScheme.outline,
      icon: const Icon(Icons.close),
      onPressed: () => Navigator.of(context).pop(),
    );
  }
}
