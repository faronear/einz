import 'dart:async';

import 'package:flutter/material.dart';

import '../brand_logo.dart';

OverlayEntry? _currentEntry;
Timer? _dismissTimer;

/// 顶部通知（替代底部 SnackBar——不遮挡输入框等底部功能按钮）。
///
/// 用法：`showTopNotice(context, '文案')`。如需在 async 间隙 / 路由 pop 之后
/// 显示，先在 await 前同步捕获根 Overlay：
/// `final overlay = Overlay.of(context, rootOverlay: true);` 再调
/// `showTopNoticeOn(overlay, '文案')`（避免 use_build_context_synchronously）。
void showTopNotice(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  showTopNoticeOn(
    Overlay.of(context, rootOverlay: true),
    message,
    duration: duration,
  );
}

/// 向指定（根）Overlay 显示顶部通知；重复调用替换当前显示中的通知。
void showTopNoticeOn(
  OverlayState overlay,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  _dismissTimer?.cancel();
  _currentEntry?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _TopNoticeBanner(
      message: message,
      duration: duration,
      onDismissed: () {
        if (entry.mounted) entry.remove();
        if (_currentEntry == entry) _currentEntry = null;
      },
    ),
  );
  _currentEntry = entry;
  overlay.insert(entry);
}

/// 顶部通知条：贴顶下滑入场 + 停留后上滑退场；点击可提前关闭。
class _TopNoticeBanner extends StatefulWidget {
  const _TopNoticeBanner({
    required this.message,
    required this.duration,
    required this.onDismissed,
  });

  final String message;
  final Duration duration;
  final VoidCallback onDismissed;

  @override
  State<_TopNoticeBanner> createState() => _TopNoticeBannerState();
}

class _TopNoticeBannerState extends State<_TopNoticeBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _slide = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _dismissTimer = Timer(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      // 完全覆盖对话顶部「双方在线状态条」（老板要求 2026-09-10）：top 与状态条
      // 同高开始（padding.top + kToolbarHeight + 4 = 状态条 margin top）——此前
      // top +8 再叠加内层 Padding top 8，背景从状态条中部开始、只遮下半部分。
      // 不用 SafeArea（top 已显式避开状态栏，避免重复内边距）。
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 4,
      left: 0,
      right: 0,
      child: GestureDetector(
        onTap: _dismiss,
        child: FadeTransition(
          opacity: _slide,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -1),
              end: Offset.zero,
            ).animate(_slide),
            child: Padding(
              // top 0：背景贴 Positioned top，与状态条同高开始往下绘制
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // 简化视觉（老板要求 2026-09-10）：清淡浅粉白底，不用粉蓝
                  // 渐变；浅粉细描边 + 淡灰影浮起，不抢眼
                  color: const Color(0xFFFFF5FA), // 浅粉白纸感（同 Scaffold 背景）
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0xFFE9D5E0), // 浅粉描边（同输入框描边）
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0x1F33415A), // 淡灰影（12% 深蓝灰）
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      // 白色圆角徽章 + 品牌 Logo
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.all(Radius.circular(9)),
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(3),
                          child: BrandLogo(size: 22, radius: 6),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          // 深蓝灰常规字重（清淡底上可读；不加粗、无任何装饰）
                          style: const TextStyle(
                            color: Color(0xFF33415A),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
