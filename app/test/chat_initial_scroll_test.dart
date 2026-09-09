// 回归测试：进入对话页首屏即应滚动到最新消息（列表底部）——
// 老板实测（2026-09-09）：刚进对话页停在最早消息处，要等几秒 ticker 自动刷新
// 才滚到最新；应首次载入时就定位到底部。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回编排好的加密消息（模拟 Server 分配
/// server_sequence）；getSpace 返回设备表（dev-a=本人）供 sender 判定。
class _FakeApi extends ApiClient {
  _FakeApi(this.messages) : super('http://fake');

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
      spaceId: 'space-test',
      devices: const [
        SpaceDevice(deviceId: 'dev-a', personId: 'person-a', status: 'active'),
      ],
    );
  }
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  testWidgets('进入对话页首屏即滚动到最新消息（列表底部）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 60 条消息：首屏只加载最近一页 50 条；若停在顶部会看到最早消息、看不到最新
    final msgs = <MessageEnvelope>[];
    for (var i = 1; i <= 60; i++) {
      msgs.add(await encryptMessage(
        plaintext: '消息 $i',
        spaceKey: spaceKey,
        spaceId: 'space-test',
        senderDeviceId: 'dev-a',
        messageId: 'msg-$i',
        keyVersion: 1,
      ));
    }

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
        api: _FakeApi(msgs),
        enableWs: false,
      ),
    ));
    // 等初始同步完成 + 首帧渲染 + 初始滚动定位（post-frame）生效
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 列表滚动位置应在底部（最新消息处）
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1.0),
        reason: '首屏应滚动到列表底部（最新消息处），而不是停在最早消息处');
    // 最新消息应可见
    expect(find.text('消息 60'), findsOneWidget, reason: '最新消息应显示在首屏');
  });

  testWidgets('首屏滚动到底部：末尾有引用消息（更高气泡）时仍定位最新', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 55 条普通 + 末尾 5 条引用消息（引用块使气泡更高）——老板场景：发了几条引用后重启
    final msgs = <MessageEnvelope>[];
    for (var i = 1; i <= 60; i++) {
      final payload = i > 55
          ? jsonEncode({
              'plaintext': '引用回复 $i',
              'quote': {'messageId': 'q-$i', 'preview': '被引用的原文内容'},
            })
          : '消息 $i';
      msgs.add(await encryptMessage(
        plaintext: payload,
        spaceKey: spaceKey,
        spaceId: 'space-test',
        senderDeviceId: 'dev-a',
        messageId: 'msg-$i',
        keyVersion: 1,
      ));
    }

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
        api: _FakeApi(msgs),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1.0),
        reason: '末尾有引用消息时首屏仍应滚动到列表底部');
    expect(find.text('引用回复 60'), findsOneWidget, reason: '最新引用消息应显示在首屏');
  });
}
