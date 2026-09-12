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

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// fake：sync 返回编排好的对方消息（带指定 seq）；postMessage 返回一个**低于**
/// 本地高水位的 seq，用来确定性地复现"seq 回填落在高水位之下"的竞态。
class _StatusFakeApi extends ApiClient {
  _StatusFakeApi({required this.peer, required this.postedSeq}) : super('http://fake');

  /// 对方消息（senderDeviceId != 本机），携带指定 server_sequence。
  final List<({MessageEnvelope env, int seq})> peer;
  final int postedSeq;

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
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async =>
      PostMessageResult(
          messageId: env.messageId, serverSequence: postedSeq, createdAt: 1000);

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-test',
        devices: const [
          SpaceDevice(deviceId: 'dev-a', personId: 'person-a', status: 'active'),
        ],
      );
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
}
