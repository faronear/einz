import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 确认/选择类弹窗的键盘支持共享件（老板 2026-11-26）：
/// - [EscDialog]：Esc 等同点按「取消」（pop(false)/null）；
/// - [dialogKeyboardFocusStyle]：按钮聚焦时加 2px 深色描边，Tab 切换焦点一眼可辨。

/// 对话框路由默认把 Esc 映射为 maybePop，而我们的确认弹窗都是
/// `PopScope(canPop: false)` 禁误触——结果就是 Esc 按了没反应。这里用
/// 子树级 Shortcuts/Actions 覆写 DismissIntent 的处理：Esc → pop(false)
/// （即"点取消"），误触保护只针对点外面/系统返回，不针对 Esc。
///
/// 键事件从焦点所在节点向上冒泡，所以无论焦点在哪个按钮/输入框上都生效。
class EscDialog extends StatelessWidget {
  const EscDialog({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop(false);
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

/// 弹窗按钮的键盘聚焦样式：聚焦加 2px 深色描边（默认聚焦着色太淡，
/// Tab 切换时分不清焦点在哪），失焦/悬浮走原样式的处理。
ButtonStyle dialogKeyboardFocusStyle(ButtonStyle base) => base.copyWith(
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: Colors.black.withValues(alpha: 0.6), width: 2)
            : const BorderSide(color: Colors.transparent),
      ),
    );
