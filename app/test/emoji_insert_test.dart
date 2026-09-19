// 回归测试：输入栏「+」→ 表情符 → 表情面板点选插入光标处；面板退格按字删
// （emoji 是 UTF-16 代理对，不能只删半个）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回空消息页（只测输入栏交互，不涉网络）。
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
    await sodium(); // 本地库初始化（spaceKey/消息加解密需要 libsodium）
  });

  testWidgets('「+」→表情符→点选 emoji 插到光标处；退格整字删除', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // 手机尺寸（390x844）：默认 800x600 测试画布装不下「输入栏 + 表情面板」
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final spaceKey = await generateSpaceKey();

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-demo',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeApi(),
        enableWs: false, // 测试环境不连真实 WS
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等首屏 sync 完成

    // 打开附件弹层 → 应含「表情符」
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('表情符'), findsOneWidget);

    // 点「表情符」→ 弹层关闭、输入栏内表情面板展开
    await tester.tap(find.text('表情符'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.backspace_outlined), findsOneWidget); // 面板底栏
    final field = find.byType(TextField);
    final controller = tester.widget<TextField>(field).controller!;

    // 面板常驻：不随点选关闭（先点一个）
    await tester.tap(find.text('😄'));
    await tester.pumpAndSettle();
    expect(controller.text, '😄');
    expect(find.byIcon(Icons.backspace_outlined), findsOneWidget); // 面板仍在

    // 光标移到 'ab' 中间 → 插入应落在中间，而不是末尾
    controller.value = const TextEditingValue(
      text: 'ab',
      selection: TextSelection.collapsed(offset: 1),
    );
    await tester.pump();
    await tester.tap(find.text('😄'));
    await tester.pumpAndSettle();
    expect(controller.text, 'a😄b');
    expect(controller.selection.baseOffset, 3); // 光标停在插入的 emoji 之后

    // 退格：代理对整字删除（只删 1 个 code unit 会留下乱码）
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await tester.pumpAndSettle();
    expect(controller.text, 'ab');

    // 面板上的键盘键：收起面板并回到输入框
    await tester.tap(find.byIcon(Icons.keyboard_alt_outlined));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.backspace_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
