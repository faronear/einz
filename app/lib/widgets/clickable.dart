import 'package:flutter/material.dart';

/// 可点击区域（桌面端**鼠标变手型** + 统一交互反馈）。
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
/// 交互反馈全 app 统一（老板 2026-10-10）：有单击语义的 `Clickable` 在子组件
/// **上层**叠一层遮罩——桌面鼠标悬浮淡色（black@5%），桌面单击 / 手机点按或
/// 长按深色（black@10%）。放上层而不是用 InkWell（ink 画在子组件下层，会被
/// 图片/头像等不透明子项盖住），所以任何子组件（图片、圆头像、自定义裁剪）
/// 都能正确显示反馈。遮罩形状可用 [borderRadius] / [circle] 跟随子组件轮廓，
/// 深底场景可用 [overlayColor] 换成白色系。纯长按的仍无反馈。
class Clickable extends StatefulWidget {
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
    this.overlayColor,
    this.borderRadius,
    this.circle = false,
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

  /// 遮罩色基色（默认黑；深底场景传白色，透明度按悬浮/按压档自动套）。
  final Color? overlayColor;

  /// 遮罩圆角（跟随子组件轮廓，如圆角图片卡片）。
  final BorderRadius? borderRadius;

  /// 遮罩圆形（跟随圆形子组件轮廓，如头像）。
  final bool circle;

  final Widget? child;

  @override
  State<Clickable> createState() => _ClickableState();
}

class _ClickableState extends State<Clickable> {
  bool _hovered = false;
  bool _pressed = false;

  // 手型/反馈只认**单击类**手势（tap/doubleTap/secondaryTap）：纯长按的（消息
  // 气泡菜单）保持默认箭头、无反馈，把手型留给真正"一点就有动作"的对象
  // （老板 2026-09-28）
  bool get _interactive =>
      widget.onTap != null ||
      widget.onDoubleTap != null ||
      widget.onSecondaryTap != null;

  static const double _hoverAlpha = 0.05; // 悬浮：淡色遮罩
  static const double _pressedAlpha = 0.10; // 按压/长按：深色遮罩

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (!_interactive) {
      return MouseRegion(
        // MouseCursor.defer：不可点时别把光标改成手型（那是在骗人）
        cursor: MouseCursor.defer,
        child: GestureDetector(
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          onLongPress: widget.onLongPress,
          onLongPressStart: widget.onLongPressStart,
          onLongPressEnd: widget.onLongPressEnd,
          onLongPressUp: widget.onLongPressUp,
          onSecondaryTap: widget.onSecondaryTap,
          behavior: widget.behavior,
          child: child,
        ),
      );
    }
    final base = widget.overlayColor ?? Colors.black;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTap: widget.onSecondaryTap,
        // 长按相关手势也挂在这里（维持原有语义）；按压深色遮罩用 onTapDown 感知，
        // 手机长按与桌面单击都能看到
        onLongPress: widget.onLongPress,
        onLongPressStart: widget.onLongPressStart,
        onLongPressEnd: widget.onLongPressEnd,
        onLongPressUp: widget.onLongPressUp,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        behavior: widget.behavior,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            child!,
            // 前景遮罩：悬浮淡色 / 按压深色，统一全 app 可点击元素的反馈
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _pressed
                      ? _pressedAlpha
                      : (_hovered ? _hoverAlpha : 0.0),
                  duration: const Duration(milliseconds: 120),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // 色相由 [overlayColor] 定（默认黑），浓度由 AnimatedOpacity
                      // 按悬浮/按压档控制——这里给不透明色避免二次稀释
                      color: base,
                      shape: widget.circle
                          ? BoxShape.circle
                          : BoxShape.rectangle,
                      borderRadius:
                          widget.circle ? null : widget.borderRadius,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
