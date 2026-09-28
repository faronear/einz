import 'package:flutter/material.dart';

/// 可点击区域（桌面端**鼠标变手型**的 [GestureDetector]）。
///
/// 为什么需要它：Material 的可点组件（`InkWell` / `IconButton` / `TextButton`…）
/// 在桌面端**默认就是手型光标**，而裸 `GestureDetector` **不会**变——于是同一个界面里
/// 有的地方是手型、有的不是，鼠标移过去要靠"猜这里能不能点"（老板 2026-09-26：
/// "全局可单击的东西都应该变手型，全局统一"）。
///
/// 用法：把裸 `GestureDetector` 换成 `Clickable`，参数同名透传。**单击/双击/右键**
/// 任一存在时光标变手型；**只有长按**的（如消息气泡长按弹菜单）光标保持默认箭头
/// ——长按没有"点"的语义，全部手型会让气泡与真正可单击的引用块/链接分不清
/// （老板 2026-09-28：仅在能单击的对象上显示手型）。
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

  // 手型只认**单击类**手势（tap/doubleTap/secondaryTap）：纯长按的（消息气泡
  // 菜单）保持默认箭头，把手型留给真正"一点就有动作"的对象（老板 2026-09-28）
  bool get _interactive =>
      onTap != null || onDoubleTap != null || onSecondaryTap != null;

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
