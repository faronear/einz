// 消息气泡按发言人性别配色回归测试：本人消息 = 我方性别色浅 tint
// （男天蓝 / 女品牌粉），对方消息 = 对方性别色；性别未登记回退默认色
// （本人 indigo.shade100 / 对方 grey.shade200）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/ui_style_settings.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回编排好的加密消息（并模拟 Server 分配
/// server_sequence）；getSpace 返回设备表（dev-a=本人 / dev-b=对方）供 sender 判定。
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
      entrances: const [
        SpaceEntrance(entranceId: 'dev-a', partnerId: 'partner-a', status: 'active'),
        SpaceEntrance(entranceId: 'dev-b', partnerId: 'partner-b', status: 'active'),
      ],
    );
  }
}

/// 取指定文本所在气泡（最近的 Container 祖先）的底色。
Color? _bubbleColor(WidgetTester tester, String text) {
  final container = tester.widget<Container>(
    find.ancestor(of: find.text(text), matching: find.byType(Container)).first,
  );
  return (container.decoration as BoxDecoration?)?.color;
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  testWidgets('气泡底色按发言人性别：本人男→天蓝、对方女→品牌粉', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 气泡配色随界面主题（plain 半透明 tint / gradient 不透明）而不同，本测试断言的是
    // 「性别 → 颜色」映射，所以钉住素雅纯色风格（默认风格已于 2026-09-17 改为渐变）
    await UiStyleSettings(db).save('plain');
    // 预置 profile 双性别（模拟向导完成时写入）
    await AppLockService(db).saveProfile(
        partnerName: 'Lukas',
        peerName: 'Alice',
        entranceName: 'Phone',
        myGender: 'male',
        peerGender: 'female');

    final mine = await encryptMessage(
      plaintext: '我的消息',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderEntranceId: 'dev-a',
      messageId: 'msg-me-1',
      keyVersion: 1,
    );
    final peer = await encryptMessage(
      plaintext: '对方的消息',
      spaceKey: spaceKey,
      spaceId: 'space-test',
      senderEntranceId: 'dev-b',
      messageId: 'msg-peer-1',
      keyVersion: 1,
    );

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
        api: _FakeApi([mine, peer]),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成
    await tester.pump(const Duration(milliseconds: 100)); // 渲染消息帧

    expect(find.text('我的消息'), findsOneWidget, reason: '本人消息应渲染');
    expect(find.text('对方的消息'), findsOneWidget, reason: '对方消息应渲染');
    // 本人男 → 天蓝浅 tint；对方女 → 品牌粉浅 tint（与 _bubbleColor 同源表达式）
    expect(_bubbleColor(tester, '我的消息'),
        const Color(0xFF3BAFFD).withValues(alpha: 0.18),
        reason: '本人为男：气泡应为天蓝浅色');
    expect(_bubbleColor(tester, '对方的消息'),
        const Color(0xFFD6529C).withValues(alpha: 0.18),
        reason: '对方为女：气泡应为品牌粉浅色');
  });
}
