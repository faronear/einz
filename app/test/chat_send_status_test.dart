// 回归测试（老板 2026-09-12 实测）：自己发的消息，对方已经收到、本端却一直
// 显示「发送中」。
//
// 根因：_refreshLocal 的增量读取 historySince 用的是"本地已加载最大
// server_sequence"这个高水位，只取 seq 更大的行。本机自己发的消息，seq 是
// postMessage 之后才由服务端回填的——若在这之间先并入了 seq 更高的消息（高水位
// 抬到本消息 seq 之上），之后 historySince 就永久漏掉本消息，状态停在 pending。
//
// 修复：按 id 兜底重读仍为 pending/failed 的消息。
// 本测试用 postMessage 返回"低于高水位"的 seq 来确定性复现该状态。

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/message_repository.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// fake：sync 返回编排好的对方消息（带指定 seq）；postMessage 返回一个**低于**
/// 本地高水位的 seq，用来确定性地复现"seq 回填落在高水位之下"的竞态。
class _StatusFakeApi extends ApiClient {
  _StatusFakeApi({required this.peer, required this.postedSeq}) : super('http://fake');

  /// 对方消息（senderDeviceId != 本机），携带指定 server_sequence。
  final List<({MessageEnvelope env, int seq})> peer;
  final int postedSeq;

  /// 已成功上传的 message_id（记录 postMessage 调用，含重发）。
  final List<String> posted = [];

  /// 前 N 次 postMessage **永不返回**（模拟"服务端已收到、但响应在回程丢失"
  /// → 消息一直卡在 pending）。0 = 不挂。
  int hangPostsBefore = 0;
  int _postCalls = 0;

  /// 是否让 postMessage 被**服务端明确拒绝**（4xx → 应标 failed）。
  bool rejectPostMessage = false;

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final all = [
      for (final p in peer)
        MessageEnvelope.fromJson({...p.env.toJson(), 'server_sequence': p.seq}),
    ];
    final page = all.where((e) => (e.serverSequence ?? 0) > after).toList();
    final last = all.isEmpty
        ? after
        : all.map((e) => e.serverSequence!).reduce((a, b) => a > b ? a : b);
    return (
      messages: page,
      attachmentsMeta: const <Map<String, dynamic>>[],
      lastSequence: last,
      hasMore: false,
    );
  }

  @override
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) {
    _postCalls++;
    if (rejectPostMessage) {
      throw ApiException('INVALID_REQUEST', 'invalid envelope', 400);
    }
    if (_postCalls <= hangPostsBefore) {
      // 永不完成：模拟响应丢失（HTTP 层面没有超时的老行为）
      return Completer<PostMessageResult>().future;
    }
    posted.add(env.messageId);
    return Future.value(PostMessageResult(
        messageId: env.messageId, serverSequence: postedSeq, createdAt: 1000));
  }

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-test',
        devices: const [
          SpaceDevice(deviceId: 'dev-a', personId: 'person-a', status: 'active'),
        ],
      );

  /// 回执：测试内不需要真网络（回执数据由测试直接种进库）。
  @override
  Future<List<ReceiptRow>> getReceipts(String token) async => const [];

  @override
  Future<({int deliveredUptoSeq, int readUptoSeq})> postReceipts(
    String token, {
    int? deliveredUptoSeq,
    int? readUptoSeq,
  }) async =>
      (deliveredUptoSeq: deliveredUptoSeq ?? 0, readUptoSeq: readUptoSeq ?? 0);
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  testWidgets('发送后即使 seq 低于本地高水位，气泡也应从「发送中」更新为「已发送」',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    // 对方一条消息 seq=10 → 初始载入后本地高水位 = 10
    final peerEnv = await encryptMessage(
      plaintext: '对方消息',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderDeviceId: 'dev-b',
      messageId: 'peer-1',
      keyVersion: 1,
    );
    // 本机发送时服务端回填 seq=5（< 高水位 10）→ 复现竞态
    final api = _StatusFakeApi(peer: [(env: peerEnv, seq: 10)], postedSeq: 5);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-test',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 发送一条
    await tester.enterText(find.byType(TextField), '你好');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('你好'), findsOneWidget, reason: '乐观回显：消息应立即出现');
    expect(find.byIcon(Icons.check), findsOneWidget,
        reason: '应显示「已发送」对勾；漏读本消息时会停在 pending（无对勾）');
  });

  testWidgets('自己消息：对方已送达 → 显示双勾（read 暂不单独区分）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    // 我发的一条（senderDeviceId == 本机 → 渲染为"我的消息"），seq=1
    final mine = await encryptMessage(
      plaintext: '我发的',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderDeviceId: 'dev-a',
      messageId: 'mine-1',
      keyVersion: 1,
    );
    final api = _StatusFakeApi(peer: [(env: mine, seq: 1)], postedSeq: 1);

    // 种入对方回执：delivered=1（对方设备已收到）、read=0
    await db.into(db.peerReceipts).insert(PeerReceiptsCompanion.insert(
          spaceId: 'space-test',
          personId: 'person-b',
          deliveredUptoSeq: const Value(1),
          readUptoSeq: const Value(0),
          updatedAt: const Value(1),
        ));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-test',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('我发的'), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsOneWidget,
        reason: 'delivered（对方已收到）应显示双勾');
    expect(find.byIcon(Icons.check), findsNothing,
        reason: '有回执时不应再显示单勾');
  });

  testWidgets('点按「发送中」小飞机：重发并收敛为已发送单勾', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _StatusFakeApi(peer: const [], postedSeq: 1)
      ..hangPostsBefore = 1; // 第一次请求永不返回（响应丢失）→ 一直显示发送中

    // 先造一条 pending：无 token 的离线入队（只入本地队列，不上传）
    final seedRepo = MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      deviceId: 'dev-a',
      keyVersion: 1,
      token: null, // 无 token → 保持 pending
    );
    await seedRepo.send('待确认的一条');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-test',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok', // 有 token → 点按后能重发
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('待确认的一条'), findsOneWidget);
    final plane = find.byTooltip('发送中，点击验证是否已送达并重发');
    expect(plane, findsOneWidget, reason: 'pending 应显示可点按的小飞机');
    expect(api.posted, isEmpty, reason: '尚未点按前不该上传');

    // 点按小飞机 → 用同一封消息重发（服务端幂等）→ 变单勾
    await tester.tap(plane);
    await tester.pumpAndSettle();

    expect(api.posted.length, 1, reason: '点按应触发一次重发');
    expect(find.byIcon(Icons.check), findsOneWidget,
        reason: '重发成功后应显示单勾（已发送）');
    expect(find.byTooltip('发送中，点击验证是否已送达并重发'), findsNothing,
        reason: '不应再停留在发送中');
  });

  testWidgets('发送失败：气泡里带「点击重发」文字标签 + ⚠️ 图标', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _StatusFakeApi(peer: const [], postedSeq: 1)..rejectPostMessage = true;

    // 服务端明确拒绝（4xx）→ failed
    final seedRepo = MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      deviceId: 'dev-a',
      keyVersion: 1,
      token: 'tok',
    );
    await seedRepo.send('会被服务端拒绝的');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-test',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('点击重发'), findsOneWidget, reason: '失败气泡应有显式文字标签');
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('墓碑消息（删除/焚毁）仍显示发送状态图标（删除只是本设备隐藏正文）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _StatusFakeApi(peer: const [], postedSeq: 1);

    final seedRepo = MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      deviceId: 'dev-a',
      keyVersion: 1,
      token: 'tok',
    );
    final id = await seedRepo.send('会被删除的消息'); // 正常发出 → sent
    await seedRepo.tombstoneMessage(id); // 本地墓碑

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-test',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('会被删除的消息'), findsNothing, reason: '墓碑应隐藏正文');
    expect(find.byIcon(Icons.check), findsOneWidget,
        reason: '墓碑不影响在途路径，状态图标仍应显示');
  });
}
