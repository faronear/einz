// 界面渲染截图（golden）：用 flutter test 渲染三页界面生成 PNG，
// 供无真机时查看 UI 效果（模拟器 screencap 的替代方案）。
//
// 运行：flutter test --update-goldens test/golden_render_test.dart
// 产物：test/goldens/{setup_page,lock_page,chat_page}.png
//
// 说明：golden 测试默认 Ahem 字体（中文显示为方块），此处加载系统中文字体
// （Windows 的 simhei.ttf）覆盖默认 'Roboto' family 使文字可读。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onlyspace/chat_page.dart';
import 'package:onlyspace/data/local_database.dart';
import 'package:onlyspace/l10n/app_localizations.dart';
import 'package:onlyspace/lock_page.dart';
import 'package:onlyspace/setup_page.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

/// 最小 fake ApiClient：sync 返回编排好的消息页（渲染聊天界面用）。
class _FakeApi extends ApiClient {
  _FakeApi(this.page) : super('http://fake');
  final ({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore}) page;

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    return page;
  }
}

Future<void> _loadChineseFont() async {
  final bytes = File(r'C:\Windows\Fonts\simhei.ttf').readAsBytesSync();
  final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// 手机尺寸（390x844）下渲染，截图更接近真机观感。
void _usePhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    await _loadChineseFont();
    await sodium();
  });

  testWidgets('golden: 设置页 SetupPage', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(),
    ));
    await tester.pump();
    await expectLater(find.byType(SetupPage), matchesGoldenFile('goldens/setup_page.png'));
  });

  testWidgets('golden: 锁屏页 LockPage', (WidgetTester tester) async {
    _usePhoneSize(tester);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: LockPage(db: db),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(find.byType(LockPage), matchesGoldenFile('goldens/lock_page.png'));
  });

  testWidgets('golden: 聊天页 ChatPage（含两条消息）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    final peer = await encryptMessage(
      plaintext: '你好，这是我加密发送的第一条消息',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderDeviceId: 'dev-b',
      messageId: 'msg-0001',
      keyVersion: 1,
    );
    final mine = await encryptMessage(
      plaintext: '收到！第二条消息（我发送的）',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderDeviceId: 'dev-a',
      messageId: 'msg-0002',
      keyVersion: 1,
    );
    final api = _FakeApi((
      messages: [peer, mine],
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: 2,
      hasMore: false,
    ));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://only.tic.cc',
        spaceId: 'space-demo',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false, // 测试环境不连真实 WS（避免重连 Timer 挂起）
      ),
    ));
    // 等 sync + history 异步完成（fake api 返回 2 条消息，落库后解密显示）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(ChatPage), matchesGoldenFile('goldens/chat_page.png'));
  });
}
