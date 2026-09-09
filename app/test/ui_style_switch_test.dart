// 回归测试：界面风格切换（菜单「界面风格」→ 弹窗 → 点选即生效且不关窗预览）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/ui_style_settings.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回空消息页（只测菜单/风格交互，不涉网络）。
class _FakeApi extends ApiClient {
  _FakeApi() : super('http://fake');

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    return (
      messages: <MessageEnvelope>[],
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: 0,
      hasMore: false,
    );
  }
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  // uiStyleNotifier 是全局通知器：每个用例前重置为默认纯色，避免跨用例残留
  setUp(() {
    uiStyleNotifier.value = 'plain';
  });

  Future<LocalDatabase> pumpChatPage(WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-demo',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync/风格异步加载完成
    return db;
  }

  // 聊天页背景渐变层定位器（Key 区分：弹窗预览图也有渐变但无此 Key）
  final gradientBackground = find.byKey(const ValueKey('chatPageGradientBackground'));

  /// 输入栏悬浮圆角条（gradient 风格专属形态：半透明白 + 圆角 24，不顶左右两头）。
  final inputPill = find.byWidgetPredicate((w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).color == Colors.white.withValues(alpha: 0.85) &&
      (w.decoration as BoxDecoration).borderRadius == BorderRadius.circular(24));

  testWidgets('界面风格弹窗：两风格+描述展示；点选即生效且不关窗；持久化', (WidgetTester tester) async {
    final db = await pumpChatPage(tester);

    // 默认素雅纯色：无渐变背景层
    expect(gradientBackground, findsNothing, reason: '默认纯色风格不应有渐变背景');

    // 打开菜单 → 界面风格
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('界面风格'), findsOneWidget, reason: '菜单项应为「界面风格」');
    await tester.tap(find.text('界面风格'));
    await tester.pumpAndSettle();

    // 弹窗：标题 + 两个风格（名称+描述）
    expect(find.text('界面风格 / Interface style'), findsOneWidget);
    expect(find.text('素雅纯色 / Plain'), findsOneWidget);
    expect(find.text('渐变粉蓝 / Gradient'), findsOneWidget);
    expect(find.textContaining('浅粉纯色背景'), findsOneWidget, reason: '纯色风格应有一句描述');
    expect(find.textContaining('粉蓝渐变背景'), findsOneWidget, reason: '渐变风格应有一句描述');

    // 点选渐变粉蓝 → 立即生效：弹窗不关闭 + 聊天页背景出现渐变
    await tester.tap(find.text('渐变粉蓝 / Gradient'));
    await tester.pumpAndSettle();
    expect(find.text('界面风格 / Interface style'), findsOneWidget, reason: '点选后弹窗应保持打开（预览不关窗）');
    expect(gradientBackground, findsOneWidget, reason: '点选渐变后聊天页背景应切换为渐变');

    // 全屏渐变（同向导）：body 延伸到 AppBar 之后、AppBar 透明、输入栏为悬浮圆角条
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.extendBodyBehindAppBar, isTrue, reason: '渐变风格下 body 应延伸到 AppBar 之后（全屏渐变）');
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, Colors.transparent, reason: '渐变风格下 AppBar 应透明（露出渐变）');
    expect(inputPill, findsOneWidget, reason: '渐变风格下输入栏应为不顶左右两头的悬浮圆角条');

    // 持久化：已保存为 gradient
    final settings = UiStyleSettings(db);
    expect(await settings.load(), 'gradient', reason: '风格选择应持久化到本地');

    // 再点回素雅纯色 → 渐变背景消失、弹窗仍在
    await tester.tap(find.text('素雅纯色 / Plain'));
    await tester.pumpAndSettle();
    expect(find.text('界面风格 / Interface style'), findsOneWidget);
    expect(gradientBackground, findsNothing, reason: '切回纯色后渐变背景应移除');
    final scaffoldAfter = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffoldAfter.extendBodyBehindAppBar, isFalse, reason: '切回纯色后恢复原有布局（body 不从 AppBar 后延伸）');
    expect(inputPill, findsNothing, reason: '切回纯色后输入栏恢复全宽透明');
    expect(await settings.load(), 'plain');

    // 右上角 ✕ 关闭弹窗
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('界面风格 / Interface style'), findsNothing, reason: '点 ✕ 后弹窗应关闭');
    expect(tester.takeException(), isNull);
  });

  testWidgets('重启（新 ChatPage）后从持久化恢复渐变风格', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 预置：上次选择了渐变粉蓝
    await UiStyleSettings(db).save('gradient');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-demo',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pumpAndSettle();
    expect(gradientBackground, findsOneWidget, reason: '重启后应从持久化恢复渐变风格');
  });

  testWidgets('渐变风格下输入栏上方无截断空隙（消息列表直达输入栏）', (WidgetTester tester) async {
    // 模拟真机 insets（状态栏 59 / 底部 Home 条 34）：SafeArea 会应用 MediaQuery 顶部
    // inset——输入栏如果保留 top inset，消息列表底部会停在输入栏上方约一屏高的空隙处，
    // 渐变透出但消息到不了（老板实测：约 2 个输入框高度的截断区）
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Builder(
        builder: (context) {
          final mq = MediaQuery.of(context);
          return MediaQuery(
            data: mq.copyWith(
              padding: const EdgeInsets.only(top: 59, bottom: 34),
            ),
            child: ChatPage(
              server: 'https://einz.tic.cc',
              spaceId: 'space-demo',
              deviceId: 'dev-a',
              spaceKey: spaceKey,
              keyVersion: 1,
              token: 'tok',
              db: db,
              api: _FakeApi(),
              enableWs: false,
            ),
          );
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 切到渐变风格
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('界面风格'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('渐变粉蓝 / Gradient'));
    await tester.pumpAndSettle();

    // 消息列表底部应直达输入栏顶部（无 SafeArea 顶部 inset 造成的空隙）
    final listRect = tester.getRect(find.byType(ListView).first);
    final pillRect = tester.getRect(inputPill);
    expect(listRect.bottom, closeTo(pillRect.top, 0.5),
        reason: '消息列表应直达输入栏，输入栏上方不应有渐变截断空隙');
  });
}
