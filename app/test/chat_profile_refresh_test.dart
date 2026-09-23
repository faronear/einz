// 启动校正回归：本机 profile 只是入网时的快照，对方改名后（或没收到广播时）
// App 重启必须按服务端（GET /space）的名字/性别校正——否则一直显示旧的对方名字。
//
// 重点覆盖重启路径：main.dart 用明文 payload 构造 ChatPage 时**不传 partnerId**，
// 校正必须能从 /space 的设备表按 entranceId 反查"我是谁"。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// fake ApiClient：不发网络，返回编排的 /space 名称表（服务端为准的新名字）。
class _FakeSpaceApi extends ApiClient {
  _FakeSpaceApi() : super('http://fake');

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-demo',
        entrances: const [
          SpaceEntrance(entranceId: 'dev-a', partnerId: 'partner-a', status: 'active'),
          SpaceEntrance(entranceId: 'dev-b', partnerId: 'partner-b', status: 'active'),
        ],
        partnerNames: const {'partner-a': 'Alice-新名字', 'partner-b': 'Bob'},
        partnerGenders: const {'partner-a': 'female', 'partner-b': 'male'},
      );

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async =>
      (
        messages: <MessageEnvelope>[],
        attachmentsMeta: <Map<String, dynamic>>[],
        lastSequence: after,
        hasMore: false,
      );
}

/// fake：对方"稍后加入"——[peerJoined] 置真后 /space 与 /entrances 才带上对方。
/// 用于验证"对方刚加入 → 我方补拉身份（名字/性别/槽位）"。
class _JoiningPeerApi extends ApiClient {
  _JoiningPeerApi() : super('http://fake');

  bool peerJoined = false;

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-late',
        entrances: [
          const SpaceEntrance(entranceId: 'dev-me', partnerId: 'partner-me', status: 'active'),
          if (peerJoined)
            const SpaceEntrance(entranceId: 'dev-peer', partnerId: 'partner-peer', status: 'active'),
        ],
        partnerNames: {
          'partner-me': '我',
          if (peerJoined) 'partner-peer': '新来的对方',
        },
        partnerGenders: {
          'partner-me': 'male',
          if (peerJoined) 'partner-peer': 'male',
        },
        partnerSlots: {
          'partner-me': 0,
          if (peerJoined) 'partner-peer': 1,
        },
      );

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => [
        {'entrance_id': 'dev-me', 'partner_id': 'partner-me', 'connected_at': 1},
        if (peerJoined)
          {'entrance_id': 'dev-peer', 'partner_id': 'partner-peer', 'connected_at': 1},
      ];

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async =>
      (
        messages: <MessageEnvelope>[],
        attachmentsMeta: <Map<String, dynamic>>[],
        lastSequence: after,
        hasMore: false,
      );
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  testWidgets('重启（无 partnerId）：按服务端名称表校正旧的本地快照', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // 本地快照：入网时写入的旧名字 + 空的对方性别（v2 早期的实际数据形态）
    await AppLockService(db).saveProfile(
      partnerName: 'Bob',
      peerName: 'Alice-老名字',
      entranceName: 'dev-b',
    );

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-demo',
        entranceId: 'dev-b',
        spaceKey: await generateSpaceKey(),
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeSpaceApi(),
        enableWs: false,
        // 模拟重启路径：不传 partnerId / peerName（main.dart 即如此）
      ),
    ));
    // 等 profile 读取 + /space 校正两轮异步完成
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Alice-新名字'), findsOneWidget,
        reason: '顶部条应显示服务端的最新对方名字，而非本地旧快照');
    expect(find.text('Alice-老名字'), findsNothing);

    // 校正结果回写本地快照（按当前空间）：下次（离线）启动也正确
    final profile = await AppLockService(db).loadProfile(spaceId: 'space-demo');
    expect(profile['peerName'], 'Alice-新名字');
    expect(profile['peerGender'], 'female', reason: '性别一并校正（气泡配色）');
  });

  testWidgets('对方加入后（先离线→在线）补拉身份：名字与槽位补齐', (tester) async {
    // 回归（老板 2026-09-22）：建空间时对方还没加入 → initState 那次 /space 只有
    // 我一人，对方名字/性别/槽位全空 → 同性别两人气泡同色。对方上线时应补拉一次。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await AppLockService(db).saveProfile(
      spaceId: 'space-late',
      partnerName: '我',
      peerName: '待加入',
      entranceName: 'dev-me',
      myGender: 'male',
      peerGender: 'male', // 同性别：必须靠 slot 才能区分气泡颜色
    );

    final api = _JoiningPeerApi();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-late',
        entranceId: 'dev-me',
        spaceKey: await generateSpaceKey(),
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
        partnerId: 'partner-me',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('待加入'), findsOneWidget, reason: '对方未加入时先用 profile 里的占位名');

    // 对方加入并上线（WS 关闭 → 靠 30s 对端在线轮询发现）
    api.peerJoined = true;
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('新来的对方'), findsOneWidget, reason: '对方上线后应补拉 /space 换成真名');
    // 槽位一并补齐（同性别第二人气泡取青色）：回写 profile 供下次离线启动
    final profile = await AppLockService(db).loadProfile(spaceId: 'space-late');
    expect(profile['peerSlot'], 1, reason: '对方槽位应补齐（同性别气泡青色判定）');
    expect(profile['peerName'], '新来的对方');
  });
}
