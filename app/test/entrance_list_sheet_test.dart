// 「更多通道」菜单弹层（老板 2026-09-25）：列出**当前通道（带绿勾、列第一位）+
// 我本人的其他通道**（对方 member 的通道不列；离线时当前通道照列）；列表下方
// 「新建通道」链接 → 生成开通码弹窗。
//
// 数据源 = GET /entrances（fake api 编排）；卡片 = 通道名 + 状态红绿灯 + since。
// 已撤销的本人通道照列（灰灯）。本机那张不用文字标签（英文 "This device" 会吃掉
// 近半张卡宽），改用绿勾 —— 见 `chat_page._showEntranceListSheet`。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// fake api：/entrances 与 /space 都按编排返回（无网络）。
class _FakeEntranceApi extends ApiClient {
  _FakeEntranceApi(this.entranceRows) : super('http://fake');

  /// listEntrances 返回的行（服务端 /entrances 口径）。
  final List<Map<String, dynamic>> entranceRows;

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async =>
      entranceRows;

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-demo',
        entrances: const [
          SpaceEntrance(entranceId: 'dev-a', memberId: 'member-me', status: 'active'),
          SpaceEntrance(entranceId: 'dev-b2', memberId: 'member-me', status: 'active'),
          SpaceEntrance(entranceId: 'dev-peer', memberId: 'member-peer', status: 'active'),
        ],
        memberNames: const {'member-me': 'Lukas', 'member-peer': 'Alice'},
        memberGenders: const {'member-me': 'male', 'member-peer': 'female'},
        memberSlots: const {'member-me': 0, 'member-peer': 1},
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

  @override
  Future<JoinTokenResult> createJoinToken(String spaceId, String token) async =>
      const JoinTokenResult(
        joinToken: 'e1-TESTTOKEN123456789012345678901234567890',
        link: 'https://einz.tic.cc/join/e1-TESTTOKEN12345678901234567890',
        expiresAt: 0,
      );
}

/// 只让 /entrances 抛错的 fake（离线/出错 → 其他通道区显示失败提示，当前通道照列）。
class _BrokenEntranceApi extends ApiClient {
  _BrokenEntranceApi() : super('http://fake');

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async =>
      throw StateError('offline');

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

Future<void> _openEntranceListSheet(
  WidgetTester tester,
  LocalDatabase db,
  ApiClient api,
) async {
  final spaceKey = await generateSpaceKey();
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: ChatPage(
      spaceId: 'space-demo',
      entranceId: 'dev-a',
      spaceKey: spaceKey,
      keyVersion: 1,
      token: 'tok',
      db: db,
      api: api,
      enableWs: false,
      memberId: 'member-me',
      memberName: 'Lukas',
      entranceName: 'iPhone',
      peerName: 'Alice',
    ),
  ));
  // 等 initState 的异步（profile 校正 / 对方在线刷新）落地
  await tester.pump(const Duration(milliseconds: 300));

  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('更多通道'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('更多通道'));
  await tester.pumpAndSettle();
}

/// 作用域限定在底部弹层内的查找（顶栏也有「通道名」，全局 find 会撞车）。
Finder sheetText(String text) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

Finder sheetTextContaining(String text) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.textContaining(text));

/// 弹层内指定颜色的状态灯（Icons.circle）。
Finder sheetDot(Color color) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byWidgetPredicate((w) =>
          w is Icon && w.icon == Icons.circle && w.color == color),
    );

/// 弹层内的**本机绿勾**（Icons.check_circle；与状态灯的实心圆是两个图标，不会撞）。
Finder sheetLocalCheck() => find.descendant(
      of: find.byType(BottomSheet),
      matching:
          find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.check_circle),
    );

void main() {
  setUpAll(() async {
    await sodium();
  });

  testWidgets('只列本人其他通道：对方的通道不列、当前通道不列', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.now().millisecondsSinceEpoch;
    final api = _FakeEntranceApi([
      // 当前通道（dev-a）——必须被排除
      {
        'entrance_id': 'dev-a',
        'entrance_name': 'iPhone',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
      // 我本人的另一条通道（在线）——应列出
      {
        'entrance_id': 'dev-b2',
        'entrance_name': 'iPad',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
      // 我本人一条已撤销的旧通道——照列并标注
      {
        'entrance_id': 'dev-old',
        'entrance_name': '旧手机',
        'member_id': 'member-me',
        'connected_at': null,
        'last_seen': now - 3600 * 1000,
        'status': 'revoked',
      },
      // 对方的通道（在线）——不列（老板要求：只列**我本人**的）
      {
        'entrance_id': 'dev-peer',
        'entrance_name': 'Alice的iPad',
        'member_id': 'member-peer',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
    ]);

    await _openEntranceListSheet(tester, db, api);

    // 弹层标题（菜单已关，文本只在弹层里）
    expect(sheetText('更多通道'), findsOneWidget);
    // 三张卡片：iPhone（本机·在线）/ iPad（在线）/ 旧手机（已撤销）
    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetText('iPad'), findsOneWidget);
    expect(sheetText('旧手机'), findsOneWidget);
    // 本机绿勾只在当前通道那张卡上（恒列第一位）
    expect(sheetLocalCheck(), findsOneWidget);
    // 第一张卡就是本机那张（老板 2026-09-25：恒列首位，作为区分依据之一）
    expect(
      tester.getTopLeft(sheetText('iPhone')).dx,
      lessThan(tester.getTopLeft(sheetText('iPad')).dx),
      reason: '本机通道应排在我本人的其他通道之前',
    );
    // 红绿灯：2 绿（本机+iPad 在线）+ 1 灰（已撤销），无红
    expect(sheetDot(Colors.green), findsNWidgets(2));
    expect(sheetDot(Colors.red), findsNothing);
    // since 时间：三张卡都有（在线→上线时刻；已撤销→撤销前最后活跃）
    expect(sheetTextContaining('since'), findsNWidgets(3));
    // 对方通道不出现
    expect(sheetText('Alice的iPad'), findsNothing);
    // 「新建通道」按钮（图标+文字居中、有背景）：点击后通道列表弹层收起，
    // 再弹出生成开通码弹窗（老板 2026-09-25）
    expect(sheetText('新建通道'), findsOneWidget);
    await tester.tap(sheetText('新建通道'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('开通码已生成'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing,
        reason: '点「新建通道」后通道列表弹层应已收起');
  });

  testWidgets('只有自己一条通道时也要显示自己（带绿勾）', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.now().millisecondsSinceEpoch;
    final api = _FakeEntranceApi([
      {
        'entrance_id': 'dev-a',
        'entrance_name': 'iPhone',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
    ]);

    await _openEntranceListSheet(tester, db, api);

    // 只有一张卡：当前通道 + 绿勾 + 绿灯 + since
    expect(sheetText('更多通道'), findsOneWidget);
    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetLocalCheck(), findsOneWidget);
    expect(sheetDot(Colors.green), findsOneWidget);
    expect(sheetDot(Colors.red), findsNothing);
    expect(sheetTextContaining('since'), findsOneWidget);
    // 「新建通道」按钮在
    expect(sheetText('新建通道'), findsOneWidget);
  });

  testWidgets('离线时当前通道照列，其他通道区显示失败提示', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _openEntranceListSheet(tester, db, _BrokenEntranceApi());

    // 当前通道（本机）照常显示（绿勾 + 绿灯；拉不到服务端时间 → 不显示 since）
    expect(sheetText('更多通道'), findsOneWidget);
    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetLocalCheck(), findsOneWidget);
    expect(sheetDot(Colors.green), findsOneWidget);
    expect(sheetTextContaining('since'), findsNothing);
    // 其他通道区失败提示 + 「新建通道」仍在
    expect(sheetTextContaining('无法获取其他通道'), findsOneWidget);
    expect(sheetText('新建通道'), findsOneWidget);
  });
}
