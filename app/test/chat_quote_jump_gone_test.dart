// 回归测试（老板 2026-10-14）：点击引用卡跳转失败时，弹顶部通知
// 「被引用消息已不存在」——此前三种失败路径都是**静默无操作**，用户点了
// 引用卡什么都不会发生，不知道原消息已经没了。
//
// 背景：墓碑消息保持显示的最初动因就是"点击被引用消息要有东西可落"
// （见 aimemo/worklog 2026-09 系列决策）；当真落不了时（原消息行不存在），
// 至少要把结果说清楚。覆盖 _jumpToMessage 的两条失败路径 + 一条成功路径
// （防误报：原消息在列表里时不该弹通知）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'real_async_settle.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/message_repository.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// fake：不发真实网络。sync 空（消息由 seedRepo 直接落库），postMessage 成功。
class _JumpFakeApi extends ApiClient {
  _JumpFakeApi() : super('http://fake');

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async =>
      (
        messages: const <MessageEnvelope>[],
        attachmentsMeta: const <Map<String, dynamic>>[],
        lastSequence: 0,
        hasMore: false,
      );

  @override
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async =>
      PostMessageResult(
          messageId: env.messageId, serverSequence: 1, createdAt: 1000);

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-test',
        entrances: const [
          SpaceEntrance(entranceId: 'dev-a', memberId: 'member-a', status: 'active'),
        ],
      );

  @override
  Future<List<ReceiptRow>> getReceipts(String token) async => const [];

  @override
  Future<({int deliveredUptoSeq, int readUptoSeq})> postReceipts(
    String token, {
    int? deliveredUptoSeq,
    int? readUptoSeq,
  }) async =>
      (deliveredUptoSeq: deliveredUptoSeq ?? 0, readUptoSeq: 0);
}

void main() {
  setUpAll(() async {
    await sodium(); // 发送要走加密（libsodium）
  });

  /// 按 [seed] 种消息 + 打开聊天页（zh），返回 tester。
  Future<WidgetTester> pumpWithSeed(
    WidgetTester tester,
    Future<void> Function(MessageRepository repo) seed,
  ) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _JumpFakeApi();
    // token: null → 只落库不上传（测试不需要真实上传）
    final seedRepo = MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      entranceId: 'dev-a',
      keyVersion: 1,
      token: null,
    );
    await seed(seedRepo);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-test',
        entranceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等本地历史载入
    await settleRealAsync(tester);
    return tester;
  }

  testWidgets('引用不存在的 messageId（原消息已清屏/非本空间）→ 弹通知',
      (WidgetTester tester) async {
    await pumpWithSeed(tester, (repo) async {
      await repo.send(
        '回复一条',
        quote: const {
          'messageId': 'no-such-message',
          'preview': '原消息一',
          'type': 'text',
        },
      );
    });

    expect(find.text('原消息一'), findsOneWidget, reason: '引用块应显示预览文字');
    await tester.tap(find.text('原消息一'));
    await settleRealAsync(tester);

    expect(
      find.text('被引用消息已不存在'),
      findsOneWidget,
      reason: '原消息不存在时应弹通知告知，而不是静默无操作',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('引用快照缺 messageId（坏数据）→ 同样弹通知', (WidgetTester tester) async {
    await pumpWithSeed(tester, (repo) async {
      await repo.send(
        '回复二条',
        quote: const {'preview': '原消息二', 'type': 'text'},
      );
    });

    await tester.tap(find.text('原消息二'));
    await settleRealAsync(tester);

    expect(
      find.text('被引用消息已不存在'),
      findsOneWidget,
      reason: '缺 messageId 也无法定位，点引用卡必须有回响',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('原消息在列表里 → 正常跳转，不弹通知（防误报）',
      (WidgetTester tester) async {
    await pumpWithSeed(tester, (repo) async {
      // 第一条 = 被引用的原消息；send 返回 messageId，第二条引用它
      final originalId = await repo.send('第一条消息');
      await repo.send(
        '回复三条',
        quote: {
          'messageId': originalId,
          'preview': '引用预览',
          'type': 'text',
        },
      );
    });

    await tester.tap(find.text('引用预览'));
    await settleRealAsync(tester);

    expect(
      find.text('被引用消息已不存在'),
      findsNothing,
      reason: '原消息就在列表里，跳转应正常完成，不该弹「不存在」通知',
    );
    expect(tester.takeException(), isNull);
  });
}
