// 启动校正回归：本机 profile 只是入网时的快照，对方改名后（或没收到广播时）
// App 重启必须按服务端（GET /space）的名字/性别校正——否则一直显示旧的对方名字。
//
// 重点覆盖重启路径：main.dart 用明文 payload 构造 ChatPage 时**不传 personId**，
// 校正必须能从 /space 的设备表按 deviceId 反查"我是谁"。

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
        devices: const [
          SpaceDevice(deviceId: 'dev-a', personId: 'person-a', status: 'active'),
          SpaceDevice(deviceId: 'dev-b', personId: 'person-b', status: 'active'),
        ],
        personNames: const {'person-a': 'Alice-新名字', 'person-b': 'Bob'},
        personGenders: const {'person-a': 'female', 'person-b': 'male'},
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

void main() {
  setUpAll(() async {
    await sodium();
  });

  testWidgets('重启（无 personId）：按服务端名称表校正旧的本地快照', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    // 本地快照：入网时写入的旧名字 + 空的对方性别（v2 早期的实际数据形态）
    await AppLockService(db).saveProfile(
      personName: 'Bob',
      peerName: 'Alice-老名字',
      deviceName: 'dev-b',
    );

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-demo',
        deviceId: 'dev-b',
        spaceKey: await generateSpaceKey(),
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeSpaceApi(),
        enableWs: false,
        // 模拟重启路径：不传 personId / peerName（main.dart 即如此）
      ),
    ));
    // 等 profile 读取 + /space 校正两轮异步完成
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Alice-新名字'), findsOneWidget,
        reason: '顶部条应显示服务端的最新对方名字，而非本地旧快照');
    expect(find.text('Alice-老名字'), findsNothing);

    // 校正结果回写本地快照：下次（离线）启动也正确
    final profile = await AppLockService(db).loadProfile();
    expect(profile['peerName'], 'Alice-新名字');
    expect(profile['peerGender'], 'female', reason: '性别一并校正（气泡配色）');
  });
}
