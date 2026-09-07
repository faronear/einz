// 回归测试：顶栏菜单 → PIN 菜单项 → 返回 不应触发
// `InheritedElement.debugDeactivated` 的 `_dependents.isEmpty` 断言崩溃
// （MenuRoute 与 DialogRoute 在 Overlay 中交叉卸载导致，见 git 记录）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回空消息页（只测菜单交互，不涉网络）。
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
    await sodium(); // setPin 的 Argon2id/XChaCha20 需要 libsodium
  });

  testWidgets('顶栏菜单→本机PIN→返回 不崩溃（_dependents.isEmpty 回归）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        api: api,
        enableWs: false, // 测试环境不连真实 WS
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 抬头为品牌名+slogan（不显示空间 ID）；enableWs:false → 红绿灯显示离线
    expect(find.text('EINZ 私密领地'), findsOneWidget);
    expect(find.text('离线'), findsOneWidget);

    // 打开顶栏菜单
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // 菜单应包含各功能项（含「导出完整备份」与「修改口令」）
    expect(find.text('导出完整备份'), findsOneWidget);
    expect(find.text('修改口令'), findsOneWidget);
    expect(find.text('PIN: 未设置'), findsOneWidget);
    // 点"PIN: 未设置"菜单项
    await tester.tap(find.text('PIN: 未设置'));
    await tester.pumpAndSettle();
    // 弹窗应出现（设置启动锁）
    expect(find.text('设置启动锁'), findsOneWidget);
    // 返回：模拟系统返回键（与真机"返回"一致；barrier/取消按钮均走 Navigator.pop）
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // 不应有任何异常（复现 _dependents.isEmpty 崩溃则此处失败）
    expect(tester.takeException(), isNull);
  });

  testWidgets('本机PIN→输入有效PIN→点设置 不崩溃且锁已落盘', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 打开菜单 → PIN 菜单项
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PIN: 未设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置启动锁'), findsOneWidget);

    // 输入有效 PIN（两次一致）——限定在弹窗内查找，避免匹配聊天页消息输入框
    final pinFields =
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(pinFields.at(0), '123456');
    await tester.enterText(pinFields.at(1), '123456');
    // 点"设置 PIN"
    await tester.tap(find.text('设置 PIN'));
    await tester.pumpAndSettle();

    // 不应有任何异常（若 setPin/async UI 竞态触发 _dependents.isEmpty 则此处失败）
    expect(tester.takeException(), isNull);
    // 弹窗应已关闭，锁已落盘
    expect(find.text('设置启动锁'), findsNothing);
    expect(await AppLockService(db).isSetup, true);
  });
}
