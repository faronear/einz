import 'dart:async';

import 'package:flutter/material.dart';

import 'clickable.dart';

OverlayEntry? _currentEntry;
Timer? _dismissTimer;

/// 对话页用的「状态条下方」额外偏移：状态胶囊高 `kStatusAvatarSize`(40) + 下 margin 6。
///
/// **为什么不用测量**：状态胶囊的高度由头像决定（`kStatusAvatarSize = 40`，左块没有纵向
/// 内边距），加 `margin 4 / 6` 就是常量。`kStatusAvatarSize` 定义在 chat_page.dart，
/// 而 chat_page import 了本文件——**不能反向 import**（会成环），所以这里写死 46 并注明来源。
///
/// 背景（老板 2026-10-05）：通知原先**故意**盖住状态条（2026-09-10 为躲开标题栏里的
/// 汉堡菜单），但现在状态胶囊里也有可点对象了（对方芯片 / 头像 / 邀请链接）→ 改为落在
/// 它**下方**（消息列表顶部，那一带没有可点对象）。
const double kNoticeExtraTopBelowStatusBar = 46;

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
  double extraTop = 0,
}) {
  showTopNoticeOn(
    Overlay.of(context, rootOverlay: true),
    message,
    duration: duration,
    extraTop: extraTop,
  );
}

/// 向指定（根）Overlay 显示顶部通知；重复调用替换当前显示中的通知。
void showTopNoticeOn(
  OverlayState overlay,
  String message, {
  Duration duration = const Duration(seconds: 4),
  double extraTop = 0,
}) {
  _dismissTimer?.cancel();
  _currentEntry?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    // ⚠️ 这层 `DefaultTextStyle` 是**修 bug 用的，别删**（2026-10-05 定位到根因）：
    //
    // 通知是插进**根 Overlay** 的，`OverlayEntry` 不是任何路由 `Material` 的后代 →
    // 里面的文字拿不到 `Material` 提供的 `bodyMedium`，只能继承 `MaterialApp`
    // **故意**设的兜底样式 `_errorTextStyle`（flutter/lib/src/material/app.dart:45）：
    //      红字 / 48px / w900 / **黄色双下划线** / fontFamily 'monospace'
    // 通知自己的 `TextStyle` 只覆盖 color/fontSize/fontWeight/height，于是
    // **decoration 与 fontFamily 会漏过来**（实测确认：underline + 黄 + double +
    // monospace）→ 每行文字下方一道黄线（"两条" = 文字有两行）。
    // 这就是"换底色 / 加透明 / 改描边全治不好"的原因：黄线不是我们画的，是**继承**来的；
    // 2026-09-08 与 2026-09-10 那两次"换色解决"只是错觉。
    // Flutter 官方注释给的办法正是"放进 `Material`，或另设 `DefaultTextStyle`"
    // （同上文件 39~44 行）——这里取后者，放在**所有通知的唯一入口**，一处管全部。
    builder: (overlayContext) => DefaultTextStyle(
      style: Theme.of(overlayContext).textTheme.bodyMedium ?? const TextStyle(),
      child: _TopNoticeBanner(
        message: message,
        duration: duration,
        extraTop: extraTop,
        onDismissed: () {
          if (entry.mounted) entry.remove();
          if (_currentEntry == entry) _currentEntry = null;
        },
      ),
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
    this.extraTop = 0,
  });

  final String message;
  final Duration duration;
  final VoidCallback onDismissed;

  /// 额外下移量（对话页传 `kNoticeExtraTopBelowStatusBar` = 落到状态胶囊下方）。
  final double extraTop;

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
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 4 + widget.extraTop,
      left: 0,
      right: 0,
      child: Clickable(
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
                  // **深底浅字**（老板 2026-10-05 定）：通知是"临时抢注意力"的东西，
                  // 浅粉白那版和状态条一个风格、落在它下方时抓不住眼睛。
                  // ⚠️ 2026-09-08 / 09-10 曾把"文字下面的黄色横线"误判成配色问题，反复在
                  // 浅底/深底之间来回改——**那是错的**。黄线真因是根 Overlay 里的文字
                  // 继承了 `MaterialApp` 的兜底样式 `_errorTextStyle`（黄色双下划线 +
                  // monospace），与底色无关；已在 `showTopNoticeOn` 一处修掉
                  // （见那里的注释与 `test/notice_style_test.dart`）。**配色现在可以自由选。**
                  color: const Color(0xFF33415A), // 深蓝灰（= 通知正文原本的颜色，仍在品牌色系内）
                  // 与对话页「状态胶囊」同一个圆角（chat_page 的 circular(24)）——
                  // 两边数值要一起改。注意：24 比通知自身高度的一半还大，会被 Flutter
                  // 钳到"半高"，所以两者画出来都是**完整的胶囊弧**（视觉一致，老板 2026-10-05）。
                  borderRadius: BorderRadius.circular(24),
                  // 深底不需要描边（浅粉描边是浅底版的）
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0x3333415A), // 深底压在浅背景上要"浮起来"，影子稍重
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Padding(
                  // 做薄（老板 2026-10-05）：通知现在落在消息列表上方，越薄遮挡越少。
                  // 左边 12（略小于右 14）：行首是图标，图标自身有留白，视觉上才居中。
                  padding: const EdgeInsets.fromLTRB(12, 6, 14, 6),
                  child: Row(
                    children: [
                      // 通知图标（老板 2026-10-05 定）：小喇叭——"这是在播报一件事"。
                      // 换掉了原来的白底品牌 Logo 徽章（那个白方块在深底上是全条最亮的
                      // 东西、比文字还抢眼）。
                      // 试色：品牌粉 #D6529C（老板 2026-10-05 让试"品牌粉"）。
                      // 注：粉在深蓝灰底上对比度约 2.7:1（做装饰图形够看，但不是高对比）；
                      // 若要"整条都换成品牌粉"，则 13px 白字在 #D6529C 上只有 ~3.8:1，
                      // 低于正文可读线（现在深底是 ~9:1）——那是另一档，得老板点头。
                      const Icon(Icons.campaign,
                          size: 16, color: Color(0xFFD6529C)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          // 浅字（深底上可读；不加粗、无任何装饰）
                          style: const TextStyle(
                            color: Color(0xFFFFF5FA),
                            fontSize: 13,
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
