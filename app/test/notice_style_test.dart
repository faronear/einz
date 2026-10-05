import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/top_notice.dart';

/// 通知条文字的**样式**回归测试（2026-10-05）。
///
/// 背景：通知插在**根 Overlay** 里，`OverlayEntry` 不是任何路由 `Material` 的后代
/// → 文字只能继承 `MaterialApp` 故意设的兜底样式 `_errorTextStyle`
/// （`flutter/lib/src/material/app.dart:45`）：**黄色双下划线** + `fontFamily: monospace`。
/// 表现是"通知文字下面有两条黄色横线"（每条文字行一道），
/// 而且**换底色/加透明度/改描边都治不好**——黄线不是画上去的，是继承来的；
/// 2026-09-08、2026-09-10 两次"换色解决"都是错觉，直到 2026-10-05 才定位到这里。
///
/// 修法见 `showTopNoticeOn`：给 OverlayEntry 套一层主题的 `DefaultTextStyle`。
/// 这条断言就是钉住它——**如果哪天有人把那一层删了，这个测试会红**。
void main() {
  testWidgets('通知文字不该继承 MaterialApp 的兜底样式（黄双下划线 / monospace）',
      (WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));
    await tester.pump();

    // 用两行文案——现象是"每行一道黄线"，两行即老板说的"两条"。
    showTopNotice(ctx, 'No PIN set.\nNext launch goes straight into the space.');
    await tester.pump();

    final paragraph = tester.renderObject<RenderParagraph>(
      find.text('No PIN set.\nNext launch goes straight into the space.'),
    );
    final style = paragraph.text.style!;

    expect(style.decoration ?? TextDecoration.none, TextDecoration.none,
        reason: '继承来的 TextDecoration.underline 就是那道黄线（勿删 showTopNoticeOn '
            '里的 DefaultTextStyle）');
    expect(style.decorationColor, isNot(const Color(0xFFFFFF00)),
        reason: '0xFFFFFF00 是 Flutter 兜底样式的黄色下划线颜色');
    expect(style.decorationStyle ?? TextDecorationStyle.solid,
        isNot(TextDecorationStyle.double),
        reason: '双下划线同样来自兜底样式');
    expect(style.fontFamily, isNot('monospace'),
        reason: '兜底样式的 fontFamily 会一起漏过来（安卓上表现为等宽字体）');

    // 通知自己的风格应保持：深底浅字（老板 2026-10-05 定）
    expect(style.color, const Color(0xFFFFF5FA));
    expect(style.fontSize, 13);
  });
}
