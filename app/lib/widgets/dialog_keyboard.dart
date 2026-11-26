import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 确认/选择类弹窗的键盘支持共享件（老板 2026-11-26）：
/// - [showEscDialog]：Esc 等同点按「取消」（pop(false)/null），并给弹窗内
///   按钮套上键盘聚焦描边（[dialogKeyboardFocusStyle]）；
/// - [dialogKeyboardFocusStyle]：聚焦加 2px 深色描边，Tab 切换焦点一眼可辨。

/// 为什么必须子树覆写而不能靠路由默认行为：Flutter 的 `_DismissModalAction`
/// 只在 `route.barrierDismissible == true` 时启用（见 widgets/routes.dart），
/// 而我们的确认弹窗全是 `barrierDismissible: false` 禁误触——路由层 Esc 处理
/// 被整体禁用，Esc 按了没反应。这里在弹窗子树里注册更近的
/// DismissIntent → pop(false)（"点取消"），优先级高于路由默认，误触保护
/// （点外面不关）不受影响。
class EscDialog extends StatelessWidget {
  const EscDialog({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 聚焦描边**基于现有主题样式叠加**，不从零构造——否则会把全局主题里
    // FilledButton 的 96×50 尺寸盖掉，弹窗里取消/发送两颗按钮就一大一小
    //（老板 2026-11-26 实测反馈）。
    final theme = Theme.of(context);
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
        // 给弹窗内所有 TextButton/FilledButton 套聚焦描边（Tab 切换可见）
        child: Theme(
          data: theme.copyWith(
            textButtonTheme: TextButtonThemeData(
              style: dialogKeyboardFocusStyle(
                  theme.textButtonTheme.style ?? TextButton.styleFrom()),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: dialogKeyboardFocusStyle(theme.filledButtonTheme.style ??
                  FilledButton.styleFrom()),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// [showDialog] 的键盘增强替身：Esc = 取消（pop(false)/null）+ 按钮聚焦描边。
/// 其余参数与 showDialog 相同；barrierDismissible 等误触保护原样透传。
Future<T?> showEscDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => EscDialog(child: builder(ctx)),
  );
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
