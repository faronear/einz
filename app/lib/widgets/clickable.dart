import 'package:flutter/material.dart';

/// 可点击区域（桌面端**鼠标变手型**的 [GestureDetector]）。
///
/// 为什么需要它：Material 的可点组件（`InkWell` / `IconButton` / `TextButton`…）
/// 在桌面端**默认就是手型光标**，而裸 `GestureDetector` **不会**变——于是同一个界面里
/// 有的地方是手型、有的不是，鼠标移过去要靠"猜这里能不能点"（老板 2026-09-26：
/// "全局可单击的东西都应该变手型，全局统一"）。
///
/// 用法：把裸 `GestureDetector` 换成 `Clickable`，参数同名透传。回调整体为 null 时
/// 光标保持默认（不假装可点）。
///
/// 只负责光标，**不**加悬浮变色/涟漪——那些交给 Material 系组件（`InkWell`）。
class Clickable extends StatelessWidget {
  const Clickable({
    super.key,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onLongPressStart,
    this.onLongPressEnd,
    this.onLongPressUp,
    this.onSecondaryTap,
    this.behavior = HitTestBehavior.deferToChild,
    this.child,
  });

  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressUp;
  final VoidCallback? onSecondaryTap;
  final HitTestBehavior behavior;
  final Widget? child;

  bool get _interactive =>
      onTap != null ||
      onDoubleTap != null ||
      onLongPress != null ||
      onLongPressStart != null ||
      onLongPressEnd != null ||
      onLongPressUp != null ||
      onSecondaryTap != null;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // MouseCursor.defer：不可点时别把光标改成手型（那是在骗人）
      cursor: _interactive ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onLongPress: onLongPress,
        onLongPressStart: onLongPressStart,
        onLongPressEnd: onLongPressEnd,
        onLongPressUp: onLongPressUp,
        onSecondaryTap: onSecondaryTap,
        behavior: behavior,
        child: child,
      ),
    );
  }
}
