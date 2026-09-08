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
  showTopNoticeOn(Overlay.of(context, rootOverlay: true), message,
      duration: duration);
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
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
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
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Einz 粉蓝品牌渐变：图标天蓝（左上）→ 图标粉（右下）
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0x8CFFFFFF), // 半透明白细边（浅粉白背景上描出卡片）
                      width: 1,
                    ),
                    // 粉调柔投影：浅粉白纸感背景下自然浮起
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x59D6529C), // 粉强调 35% alpha
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
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
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                              shadows: [
                                Shadow(
                                  color: Color(0x33000000),
                                  offset: Offset(0, 1),
                                  blurRadius: 2,
                                ),
                              ],
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
      ),
    );
  }
}
