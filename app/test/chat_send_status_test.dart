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

  /// 对方消息（senderEntranceId != 本机），携带指定 server_sequence。
  final List<({MessageEnvelope env, int seq})> peer;
  final int postedSeq;

  /// 已成功上传的 message_id（记录 postMessage 调用，含重发）。
  final List<String> posted = [];

  /// 前 N 次 postMessage **永不返回**（模拟"服务端已收到、但响应在回程丢失"
  /// → 消息一直卡在 pending）。0 = 不挂。
  int hangPostsBefore = 0;
  int _postCalls = 0;

  /// 是否让 postMessage 抛**网络类**异常（→ 保持 pending，不标 failed）。
  bool failPostMessage = false;

  /// 是否让 sync 抛异常（模拟服务端不可达 → 连续失败计数/离线提示）。
  bool failSync = false;

  /// 是否让 postMessage 被**服务端明确拒绝**（4xx → 应标 failed）。
  bool rejectPostMessage = false;

  /// postMessage 的响应延迟（观察「加速中…/重发中…」这类进行中文案用）。
  Duration? postMessageDelay;

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    if (failSync) throw Exception('server unreachable');
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
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async {
    if (postMessageDelay != null) await Future<void>.delayed(postMessageDelay!);
    _postCalls++;
    if (rejectPostMessage) {
      throw ApiException('INVALID_REQUEST', 'invalid envelope', 400);
    }
    if (failPostMessage) throw Exception('network down');
    if (_postCalls <= hangPostsBefore) {
      // 永不完成：模拟响应丢失（HTTP 层面没有超时的老行为）
      return Completer<PostMessageResult>().future;
    }
    posted.add(env.messageId);
    return Future.value(PostMessageResult(
        messageId: env.messageId, serverSequence: postedSeq, createdAt: 1000));
  }

  /// GET /space 返回的通道表：决定 entrance→member 映射（"是否我的消息"）。
  /// 需要模拟"同一身份的另一条通道"时替换它。
  List<SpaceEntrance> entrances = const [
    SpaceEntrance(entranceId: 'dev-a', memberId: 'member-a', status: 'active'),
  ];

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-test',
        entrances: entrances,
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

  // 关掉动画：pending 的小飞机是**常驻动画**，会让 pumpAndSettle 一直等到超时。
  // 用系统的「减少动态效果」偏好关掉它（生产代码在 disableAnimations 时退化为
  // 静态图标——顺带覆盖了这条无障碍路径）。
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
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
      senderEntranceId: 'dev-b',
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

    // 我发的一条（senderEntranceId == 本机 → 渲染为"我的消息"），seq=1
    final mine = await encryptMessage(
      plaintext: '我发的',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderEntranceId: 'dev-a',
      messageId: 'mine-1',
      keyVersion: 1,
    );
    final api = _StatusFakeApi(peer: [(env: mine, seq: 1)], postedSeq: 1);

    // 种入对方回执：delivered=1（对方通道已收到）、read=0
    await db.into(db.peerReceipts).insert(PeerReceiptsCompanion.insert(
          spaceId: 'space-test',
          memberId: 'member-b',
          deliveredUptoSeq: const Value(1),
          readUptoSeq: const Value(0),
          updatedAt: const Value(1),
        ));

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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('我发的'), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsOneWidget,
        reason: 'delivered（对方已收到）应显示双勾');
    expect(find.byIcon(Icons.check), findsNothing,
        reason: '有回执时不应再显示单勾');
  });

  testWidgets('另一条通道发的历史消息：无对方回执 → 单勾（不再假装「发送中」）',
      (WidgetTester tester) async {
    // 老板 2026-09-22 线上实测：换通道后同步回来的历史消息，seq 有值（=服务端已收下），
    // 但对方通道那几天是死的 → 没有回执。旧逻辑走完 failed → receipt → sent 三个分支
    // 后掉进末尾的 pending 分支，渲染成"发送中"蓝飞机 → 用户以为没发出去、去点重发
    // → 撞上服务端 403 → 变成永久红色「点击重发」。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    // 同一身份的另一条通道（dev-a2）发的；**不种**任何对方回执
    final fromMyOtherEntrance = await encryptMessage(
      plaintext: '旧设备发的',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderEntranceId: 'dev-a2',
      messageId: 'old-1',
      keyVersion: 1,
    );
    final api = _StatusFakeApi(peer: [(env: fromMyOtherEntrance, seq: 1)], postedSeq: 1)
      ..entrances = const [
        SpaceEntrance(entranceId: 'dev-a', memberId: 'member-a', status: 'active'),
        SpaceEntrance(entranceId: 'dev-a2', memberId: 'member-a', status: 'active'),
      ];

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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('旧设备发的'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget,
        reason: '服务端已收下（seq 有值）→ 单勾');
    expect(find.byTooltip('发送中，点击验证是否已送达并重发'), findsNothing,
        reason: '不该显示成「发送中」——那会诱导用户点重发，进而撞 403 变永久失败');
    expect(find.byIcon(Icons.done_all), findsNothing,
        reason: '还没有对方回执 → 不该显示双勾');
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
      entranceId: 'dev-a',
      keyVersion: 1,
      token: null, // 无 token → 保持 pending
    );
    await seedRepo.send('待确认的一条');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-test',
        entranceId: 'dev-a',
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
      entranceId: 'dev-a',
      keyVersion: 1,
      token: 'tok',
    );
    await seedRepo.send('会被服务端拒绝的');

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
      entranceId: 'dev-a',
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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('会被删除的消息'), findsNothing, reason: '墓碑应隐藏正文');
    expect(find.byIcon(Icons.check), findsOneWidget,
        reason: '墓碑不影响在途路径，状态图标仍应显示');
  });

  testWidgets('服务端不可达且有未确认消息：显示「离线 · N 条待发送」提示',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _StatusFakeApi(peer: const [], postedSeq: 1)
      ..failPostMessage = true // 造出 pending（网络类失败保持待确认）
      ..failSync = true; // 造出"服务端不可达"
    await MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      entranceId: 'dev-a',
      keyVersion: 1,
      token: 'tok',
    ).send('离线时写的消息');

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
    await tester.pump(const Duration(milliseconds: 300)); // 首屏
    expect(find.textContaining('待发送'), findsNothing,
        reason: '刚开始还没失败过，不该立刻提示');

    // 触发一次 ticker 轮询（3s）→ sync 失败 → 记为连接异常 → 出现提示
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('离线 · 1 条待发送'), findsOneWidget,
        reason: '有未确认消息 + 连接异常 → 应给出明确提示');
  });

  testWidgets('点按小飞机：重发期间显示「加速中…」，成功后回到单勾', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 用"网络异常"造出 pending（这样 ChatPage 的 _flushPending 不会把它抢先发走，
    // 仍是待确认状态）；点按前再切成"慢 + 成功"，便于观察「加速中…」。
    final api = _StatusFakeApi(peer: const [], postedSeq: 1)..failPostMessage = true;
    await MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      entranceId: 'dev-a',
      keyVersion: 1,
      token: 'tok',
    ).send('待加速的消息');

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
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('发送中，点击验证是否已送达并重发'), findsOneWidget,
        reason: '网络异常后应停在待确认的小飞机');

    // 网络恢复且响应变慢 → 点按后能观察到「加速中…」
    api.failPostMessage = false;
    api.postMessageDelay = const Duration(milliseconds: 60);
    await tester.tap(find.byTooltip('发送中，点击验证是否已送达并重发'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('加速中…'), findsOneWidget, reason: '重发期间应显示进行中文案');

    // 完成后 → 单勾，「加速中…」消失
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('加速中…'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('点按「点击重发」：期间显示「重发中…」，再次失败回到「点击重发」',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 注意：delay 不能在建 failed 阶段就设上——测试体内 await 到的 Future.delayed
    // 在 FakeAsync 下不会被推进，会直接挂死。故点按前再设。
    final api = _StatusFakeApi(peer: const [], postedSeq: 1)..rejectPostMessage = true;

    // 服务端明确拒绝 → failed（气泡显示「点击重发」）
    await MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      entranceId: 'dev-a',
      keyVersion: 1,
      token: 'tok',
    ).send('会被再次拒绝的');

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
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('点击重发'), findsOneWidget);

    // 让重发慢下来（仍会被拒绝）→ 点按后能观察到「重发中…」
    api.postMessageDelay = const Duration(milliseconds: 60);
    await tester.tap(find.text('点击重发'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('重发中…'), findsOneWidget, reason: '重发期间应显示进行中文案');

    // 再次被拒绝 → 回到 failed → 文案换回「点击重发」
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('重发中…'), findsNothing);
    expect(find.text('点击重发'), findsOneWidget, reason: '再次失败应换回「点击重发」');
  });
}
