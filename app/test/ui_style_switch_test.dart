// 回归测试：界面风格切换（菜单「界面风格」→ 弹窗 → 点选即生效且不关窗预览）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/ui_style_settings.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回编排好的加密消息（模拟 Server 分配
/// server_sequence）；getSpace 返回设备表（dev-a=本人 / dev-b=对方）供 sender 判定。
/// 不传 messages 时返回空消息页（只测菜单/风格交互，不涉网络）。
class _FakeApi extends ApiClient {
  _FakeApi([this.messages = const []]) : super('http://fake');

  final List<MessageEnvelope> messages;

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    var seq = after;
    final withSeq = <MessageEnvelope>[
      for (final env in messages)
        () {
          seq++;
          return MessageEnvelope.fromJson({...env.toJson(), 'server_sequence': seq});
        }(),
    ];
    return (
      messages: withSeq,
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: seq,
      hasMore: false,
    );
  }

  @override
  Future<SpaceResult> getSpace(String token) async {
    return SpaceResult(
      spaceId: 'space-demo',
      devices: const [
        SpaceDevice(deviceId: 'dev-a', personId: 'person-a', status: 'active'),
        SpaceDevice(deviceId: 'dev-b', personId: 'person-b', status: 'active'),
      ],
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

  // 状态条/输入条定位器（Key 精确区分——两者 gradient 形态外观一致，装饰无法区分）
  final statusBar = find.byKey(const ValueKey('chatPageStatusBar'));
  final inputBar = find.byKey(const ValueKey('chatPageInputBar'));

  /// 取 keyed 容器的当前 BoxDecoration（断言悬浮圆角形态/纯色形态用）。
  BoxDecoration? barDecoration(WidgetTester tester, Finder finder) =>
      (tester.widget<Container>(finder).decoration as BoxDecoration?);

  testWidgets('界面风格弹窗：两风格+描述展示；点选即生效且不关窗；持久化', (WidgetTester tester) async {
    final db = await pumpChatPage(tester);

    // 默认素雅纯色：无渐变背景层；状态条已是悬浮圆角（两风格统一，老板要求）
    expect(gradientBackground, findsNothing, reason: '默认纯色风格不应有渐变背景');
    expect(barDecoration(tester, statusBar)?.borderRadius, BorderRadius.circular(24),
        reason: '默认素雅纯色风格的状态条也应为悬浮圆角（不顶左右两头）');

    // 打开菜单 → 界面风格
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('界面风格'), findsOneWidget, reason: '菜单项应为「界面风格」');
    await tester.tap(find.text('界面风格'));
    await tester.pumpAndSettle();

    // 弹窗：标题 + 两个风格（名称+描述）
    expect(find.text('界面风格'), findsOneWidget);
    expect(find.text('素雅纯色'), findsOneWidget);
    expect(find.text('渐变粉蓝'), findsOneWidget);
    expect(find.textContaining('浅粉纯色背景'), findsOneWidget, reason: '纯色风格应有一句描述');
    expect(find.textContaining('粉蓝渐变背景'), findsOneWidget, reason: '渐变风格应有一句描述');

    // 点选渐变粉蓝 → 立即生效：弹窗不关闭 + 聊天页背景出现渐变
    await tester.tap(find.text('渐变粉蓝'));
    await tester.pumpAndSettle();
    expect(find.text('界面风格'), findsOneWidget, reason: '点选后弹窗应保持打开（预览不关窗）');
    expect(gradientBackground, findsOneWidget, reason: '点选渐变后聊天页背景应切换为渐变');

    // 全屏渐变（同向导）：body 延伸到 AppBar 之后、AppBar 透明、状态条/输入条
    // 均为悬浮圆角（不顶左右两头，四角有弧度）
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.extendBodyBehindAppBar, isTrue, reason: '渐变风格下 body 应延伸到 AppBar 之后（全屏渐变）');
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, Colors.transparent, reason: '渐变风格下 AppBar 应透明（露出渐变）');
    expect(barDecoration(tester, inputBar)?.borderRadius, BorderRadius.circular(24),
        reason: '渐变风格下输入栏应为悬浮圆角条');
    expect(barDecoration(tester, statusBar)?.borderRadius, BorderRadius.circular(24),
        reason: '渐变风格下在线状态条应为悬浮圆角条');

    // 持久化：已保存为 gradient
    final settings = UiStyleSettings(db);
    expect(await settings.load(), 'gradient', reason: '风格选择应持久化到本地');

    // 再点回素雅纯色 → 渐变背景消失、弹窗仍在
    await tester.tap(find.text('素雅纯色'));
    await tester.pumpAndSettle();
    expect(find.text('界面风格'), findsOneWidget);
    expect(gradientBackground, findsNothing, reason: '切回纯色后渐变背景应移除');
    final scaffoldAfter = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffoldAfter.extendBodyBehindAppBar, isFalse, reason: '切回纯色后恢复原有布局（body 不从 AppBar 后延伸）');
    expect(barDecoration(tester, inputBar), isNull, reason: '切回纯色后输入栏恢复全宽透明');
    expect(barDecoration(tester, statusBar)?.borderRadius, BorderRadius.circular(24),
        reason: '切回纯色后状态条仍为悬浮圆角（两风格统一）');
    expect(await settings.load(), 'plain');

    // 右上角 ✕ 关闭弹窗
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('界面风格'), findsNothing, reason: '点 ✕ 后弹窗应关闭');
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
    final pillRect = tester.getRect(inputBar);
    expect(listRect.bottom, closeTo(pillRect.top, 0.5),
        reason: '消息列表应直达输入栏，输入栏上方不应有渐变截断空隙');
  });

  testWidgets('渐变风格下消息气泡深色+白字（男深蓝 / 女深粉）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 预置双性别（模拟向导完成时写入）
    await AppLockService(db).saveProfile(
        personName: 'Lukas',
        peerName: 'Alice',
        deviceName: 'Phone',
        myGender: 'male',
        peerGender: 'female');

    final mine = await encryptMessage(
      plaintext: '我的消息',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderDeviceId: 'dev-a',
      messageId: 'msg-me-1',
      keyVersion: 1,
    );
    final peer = await encryptMessage(
      plaintext: '对方的消息',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderDeviceId: 'dev-b',
      messageId: 'msg-peer-1',
      keyVersion: 1,
    );

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
        api: _FakeApi([mine, peer]),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 完成
    await tester.pump(const Duration(milliseconds: 100)); // 渲染消息帧
    expect(find.text('我的消息'), findsOneWidget);
    expect(find.text('对方的消息'), findsOneWidget);

    // 切到渐变风格
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('界面风格'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('渐变粉蓝 / Gradient'));
    await tester.pumpAndSettle();

    // 气泡底色：本人男→深蓝、对方女→深粉（渐变下不再用浅 tint）
    Color? bubbleColorOf(String text) {
      final container = tester.widget<Container>(
        find.ancestor(of: find.text(text), matching: find.byType(Container)).first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    expect(bubbleColorOf('我的消息'), const Color(0xFF2271F7),
        reason: '本人为男：渐变下气泡应为品牌深蓝');
    expect(bubbleColorOf('对方的消息'), const Color(0xFFB83D80),
        reason: '对方为女：渐变下气泡应为深粉');
    // 白字：气泡内文字的生效颜色为白色（DefaultTextStyle.merge）
    expect(DefaultTextStyle.of(tester.element(find.text('我的消息'))).style.color,
        Colors.white, reason: '渐变下气泡文字应为白色');
    expect(DefaultTextStyle.of(tester.element(find.text('对方的消息'))).style.color,
        Colors.white, reason: '渐变下气泡文字应为白色');
  });
}
