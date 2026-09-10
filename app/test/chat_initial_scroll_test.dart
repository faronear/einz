// 回归测试：进入对话页首屏即应滚动到最新消息（列表底部）——
// 老板实测（2026-09-09）：刚进对话页停在最早消息处，要等几秒 ticker 自动刷新
// 才滚到最新；应首次载入时就定位到底部。
// 另含：点击引用卡跳转到原消息并短暂高亮（老板要求 2026-09-10）。

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

/// 固定序号 fake：每次 sync 返回相同消息、相同 server_sequence（模拟真实
/// Server 行为）——重复 sync 不产生新消息，用于「自动 sync 无新消息时不
/// 滚动到底」测试。
class _FixedSeqApi extends ApiClient {
  _FixedSeqApi(this.messages) : super('http://fake');

  final List<MessageEnvelope> messages;

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final withSeq = <MessageEnvelope>[
      for (var i = 0; i < messages.length; i++)
        MessageEnvelope.fromJson({
          ...messages[i].toJson(),
          'server_sequence': i + 1,
        }),
    ];
    final page = withSeq.where((e) => (e.serverSequence ?? 0) > after).toList();
    return (
      messages: page,
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: withSeq.length,
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

  testWidgets('自动 sync 无新消息时不滚动到底；发现新消息时才拉到底部', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 40 条消息（≤ 首屏页 50，全部加载）；固定序号 fake 重复 sync 无新消息
    final msgs = <MessageEnvelope>[];
    for (var i = 1; i <= 40; i++) {
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
        api: _FixedSeqApi(msgs),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1.0), reason: '首屏应在底部');

    // 用户向上翻看历史（离开底部）
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 400));
    await tester.pump();
    expect(position.pixels, lessThan(position.maxScrollExtent - 1),
        reason: '应已离开底部（正在看历史）');

    // 自动 sync 周期触发，但服务端没有新消息 → 不应拉回底部
    await tester.pump(const Duration(seconds: 4)); // ticker 3s 触发 _refresh
    await tester.pump(); // 消化 sync future
    await tester.pump();
    expect(position.pixels, lessThan(position.maxScrollExtent - 1),
        reason: '自动 sync 无新消息时不应把用户拉回底部');

    // 服务端来了新消息 → 应拉到底部
    msgs.add(await encryptMessage(
      plaintext: '新消息 41',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderDeviceId: 'dev-a',
      messageId: 'msg-41',
      keyVersion: 1,
    ));
    await tester.pump(const Duration(seconds: 4)); // 下一个 ticker 周期
    await tester.pump(); // 消化 sync future
    await tester.pump();
    await tester.pumpAndSettle(); // 平滑滚动动画结束
    expect(position.pixels, closeTo(position.maxScrollExtent, 1.0),
        reason: '发现新消息应拉到底部');
  });

  testWidgets('点击引用卡跳转原消息并短暂高亮背景（显眼橘黄，2s 恢复）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 5 条消息（≤ 首屏页 50，全部加载）：msg-5 引用 msg-2（点击目标已在列表）
    final msgs = <MessageEnvelope>[];
    for (var i = 1; i <= 5; i++) {
      final payload = i == 5
          ? jsonEncode({
              'plaintext': '引用回复 5',
              'quote': {'messageId': 'msg-2', 'preview': '预览：原始消息 2'},
            })
          : '原始消息 $i';
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

    // 点击引用卡（msg-5 气泡内的引用块预览）
    await tester.tap(find.text('预览：原始消息 2'));
    // 逐帧推进：帧1=_jumpToMessage setState(jumpTargetId)；帧2=post-frame 回调1
    // （jumpTo + 置高亮 setState）帧末；帧3=渲染高亮起始帧 + 过渡动画帧
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 高亮过渡动画帧

    // 原消息 msg-2 的气泡应高亮（显眼橘黄背景 #FF9800；只换背景色不改尺寸）
    final bubble = find
        .ancestor(
            of: find.text('原始消息 2'), matching: find.byType(AnimatedContainer))
        .first;
    expect(bubble, findsOneWidget, reason: '应能定位到原消息气泡');
    final highlighted =
        tester.widget<AnimatedContainer>(bubble).decoration as BoxDecoration;
    expect(highlighted.color, const Color(0xFFFF9800),
        reason: '跳转目标气泡应短暂高亮（显眼橘黄背景）');

    // 渐变 1.5s 完成（Timer 1500ms，停留 0s）后清除，恢复原气泡色
    // （plain 未登记性别 = indigo.shade100）
    await tester.pump(const Duration(milliseconds: 1600));
    await tester.pump(); // Timer 回调 setState 渲染
    final restored =
        tester.widget<AnimatedContainer>(bubble).decoration as BoxDecoration;
    expect(restored.color, Colors.indigo.shade100,
        reason: '高亮应 2s 后恢复原气泡色');
  });
}
