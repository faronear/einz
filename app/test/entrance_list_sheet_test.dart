// 「更多通道」菜单弹层（老板 2026-09-25）：列出**当前通道（带绿勾、列第一位）+
// 我本人的其他通道**（对方 member 的通道不列；离线时当前通道照列）；列表下方
// 「新建通道」链接 → 生成开通码弹窗。
//
// 数据源 = GET /entrances（fake api 编排）；卡片 = 通道名 + 状态红绿灯 + 时间。
// 时间**不带 "since" 前缀**（老板 2026-09-26：太占地方），且所有卡片等高
// （第二行恒占一行高度——离线卡原先没有文字，会矮一截）。
// 右上角固定角标（老板 2026-09-26）：本机 = 绿勾（原先紧贴名称，位置随名字跑）、
// 已撤销 = 阻止图标 + 整卡蒙版；两者互斥，共用一个角标位。
// 离线时刻 = max(last_seen, offline_since)：服务端干净断开时 last_seen 归零，
// 断线时刻只落在 offline_since —— 见 `chat_page._showEntranceListSheet`。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/space_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// fake api：/entrances 与 /space 都按编排返回（无网络）。
class _FakeEntranceApi extends ApiClient {
  _FakeEntranceApi(this.entranceRows) : super('http://fake');

  /// listEntrances 返回的行（服务端 /entrances 口径）。测试可在两次调用之间**改写**它，
  /// 模拟"点刷新时服务端的状态变了"。
  List<Map<String, dynamic>> entranceRows;

  /// listEntrances 被调用的次数（刷新断言用；注意 ChatPage 自己也会轮询对方在线状态，
  /// 所以测试里比的是**增量**，不是绝对值）。
  int listCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async {
    listCalls++;
    return entranceRows;
  }

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
  ApiClient api, {
  String token = 'tok',
  Future<String> Function()? reauth,
}) async {
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
      token: token,
      reauth: reauth,
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

/// 弹层内的**已撤销角标**（Icons.block）。
Finder sheetRevokedMark() => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byWidgetPredicate((w) => w is Icon && w.icon == Icons.block),
    );

/// 弹层内的**时间文本**（卡片第二行；无 "since" 前缀，故按时间格式匹配）：
/// 当天 `HH:MM` / 当年 `MM-DD HH:MM` / 跨年 `YYYY-MM-DD HH:MM`。
Finder sheetTimeText() => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byWidgetPredicate((w) =>
          w is Text &&
          w.data != null &&
          RegExp(r'^(\d{2}-\d{2} |\d{4}-\d{2}-\d{2} )?\d{2}:\d{2}$')
              .hasMatch(w.data!)),
    );

/// 弹层标题右端的**刷新**按钮。
Finder sheetRefresh() => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byIcon(Icons.refresh),
    );

/// 某张卡片（名称文字最近的 Container 祖先）的矩形——角标/等高断言用。
Rect cardOf(WidgetTester tester, String name) => tester.getRect(
      find
          .ancestor(of: sheetText(name), matching: find.byType(Container))
          .first,
    );

/// 已撤销卡的蒙版（整卡降透明度的 Opacity 祖先）。
Finder dimmedCardOf(String name) => find.ancestor(
      of: sheetText(name),
      matching:
          find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
    );

/// 「旧 token 一律 401 invalid session、续期后的新 token 才正常」的 fake：
/// 复现老板 2026-09-26 的线上场景（会话过期后，页面的直接请求全挂）。
class _StaleTokenApi extends _FakeEntranceApi {
  _StaleTokenApi(super.rows, {required this.staleToken});

  final String staleToken;

  /// 每次 listEntrances 收到的 token（断言"确实用新 token 重发过"）。
  final List<String> tokensSeen = [];

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async {
    tokensSeen.add(token);
    if (token == staleToken) {
      throw ApiException('UNAUTHORIZED', 'invalid session', 401);
    }
    return super.listEntrances(token);
  }
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  // 会话注册表是进程级静态的：逐用例复位，别让上一个用例的会话（含旧 token）串进来
  setUp(() => SpaceSessions.clear());

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
      // 我本人一条**离线**的通道——服务端干净断开时 last_seen 归零，
      // 断线时刻落在 offline_since（老板 2026-09-26：离线卡也要有时间，否则矮一截）
      {
        'entrance_id': 'dev-off',
        'entrance_name': 'MacBook',
        'member_id': 'member-me',
        'connected_at': null,
        'last_seen': 0,
        'offline_since': now - 2 * 3600 * 1000,
        'status': 'active',
      },
      // 我本人一条已撤销的旧通道——照列并标注
      {
        'entrance_id': 'dev-old',
        'entrance_name': '旧手机',
        'member_id': 'member-me',
        'connected_at': null,
        'last_seen': now - 3600 * 1000,
        'offline_since': now - 3600 * 1000,
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
    // 四张卡片：iPhone（本机·在线）/ iPad（在线）/ MacBook（离线）/ 旧手机（已撤销）
    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetText('iPad'), findsOneWidget);
    expect(sheetText('MacBook'), findsOneWidget);
    expect(sheetText('旧手机'), findsOneWidget);
    // 本机绿勾只在当前通道那张卡上（恒列第一位）
    expect(sheetLocalCheck(), findsOneWidget);
    // 第一张卡就是本机那张（老板 2026-09-25：恒列首位，作为区分依据之一）
    expect(
      tester.getTopLeft(sheetText('iPhone')).dx,
      lessThan(tester.getTopLeft(sheetText('iPad')).dx),
      reason: '本机通道应排在我本人的其他通道之前',
    );
    // 红绿灯：2 绿（本机+iPad 在线）+ 1 红（MacBook 离线）+ 1 灰（已撤销）
    expect(sheetDot(Colors.green), findsNWidgets(2));
    expect(sheetDot(Colors.red), findsOneWidget);
    expect(sheetDot(Colors.black.withValues(alpha: 0.30)), findsOneWidget);
    // 时间行：四张卡都有（在线→上线时刻；离线/已撤销→下线时刻），且**不带 since**
    expect(sheetTimeText(), findsNWidgets(4));
    expect(sheetTextContaining('since'), findsNothing);
    // 四张卡等高（老板 2026-09-26：离线卡原先没有文字，会比别的矮一截）
    final heights = <double>{
      for (final n in ['iPhone', 'iPad', 'MacBook', '旧手机']) cardOf(tester, n).height,
    };
    expect(heights.length, 1, reason: '所有通道卡片应等高（时间行恒占一行）');
    // 卡片边长上限 = 弹层最大宽度下"一行 3 张"的边长（老板 2026-09-26）：
    // 弹层内容限在 640、减左右各 16 = 608 可用 → (608 − 2×12) / 3 = 194.67 → 取整 194。
    // 原来硬写 160 时，三张卡只铺到 504，宽窗口里右边空一大截。
    expect(cardOf(tester, 'iPhone').width, 194,
        reason: '卡片上限应跟着弹层最大宽度走，不再卡在 160');
    // 第一行三张（iPhone / iPad / MacBook）铺满内容宽度：右缘应对齐刷新按钮的右缘
    // （刷新按钮与卡片是同层 Padding 的两个兄弟 → 它的右缘 = 内容区右缘）
    final contentRight = tester
        .getRect(find.ancestor(of: sheetRefresh(), matching: find.byType(IconButton)))
        .right;
    expect(cardOf(tester, 'MacBook').right, closeTo(contentRight, 3),
        reason: '一行 3 张应铺满弹层内容宽度（最多差向下取整的那 2px）');
    // 已撤销卡：右上角阻止图标 + 整卡蒙版；本机卡：右上角绿勾、不蒙版
    expect(sheetRevokedMark(), findsOneWidget);
    expect(dimmedCardOf('旧手机'), findsOneWidget, reason: '已撤销卡应有蒙版（整卡降透明度）');
    expect(dimmedCardOf('iPad'), findsNothing, reason: '正常卡不该蒙版');
    // 角标**固定在卡片右上角**（与名称长短无关）：两种角标到各自卡片右上角的
    // 内缩量应一致（老板 2026-09-26：绿勾原先紧贴名称，位置随名字跑）
    final checkRect = tester.getRect(sheetLocalCheck());
    final markRect = tester.getRect(sheetRevokedMark());
    final phoneCard = cardOf(tester, 'iPhone');
    final oldCard = cardOf(tester, '旧手机');
    double insetRight(double cardRight, Rect badge) => cardRight - badge.right;
    double insetTop(double cardTop, Rect badge) => badge.top - cardTop;
    expect(
      insetRight(phoneCard.right, checkRect),
      closeTo(insetRight(oldCard.right, markRect), 1),
      reason: '两种角标距卡片右边缘的距离应一致（固定位，不随名称长短跑）',
    );
    expect(
      insetTop(phoneCard.top, checkRect),
      closeTo(insetTop(oldCard.top, markRect), 1),
      reason: '两种角标距卡片上边缘的距离应一致',
    );
    // 角标该在右上角：位于卡片右上象限，且在名称右侧
    expect(checkRect.right, greaterThan(phoneCard.center.dx));
    expect(checkRect.top, lessThan(phoneCard.center.dy));
    expect(checkRect.right, greaterThan(tester.getRect(sheetText('iPhone')).right),
        reason: '绿勾不该再贴名称右缘');
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

    // 只有一张卡：当前通道 + 绿勾 + 绿灯 + 时间
    expect(sheetText('更多通道'), findsOneWidget);
    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetLocalCheck(), findsOneWidget);
    expect(sheetDot(Colors.green), findsOneWidget);
    expect(sheetDot(Colors.red), findsNothing);
    expect(sheetTimeText(), findsOneWidget);
    // 「新建通道」按钮在
    expect(sheetText('新建通道'), findsOneWidget);
  });

  testWidgets('没有时间可显示的卡片也与别的等高（时间行恒占一行，老板 2026-09-26）',
      (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.now().millisecondsSinceEpoch;
    final api = _FakeEntranceApi([
      // 当前通道（有上线时刻 → 有时间可显示）
      {
        'entrance_id': 'dev-a',
        'entrance_name': 'iPhone',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
      // 我本人的另一条通道：**两个时间字段都空**（存量行——last_seen 早已被服务端
      // 归零，offline_since 还没落过）→ 时间行为空。它必须和上面那张一样高
      {
        'entrance_id': 'dev-ghost',
        'entrance_name': 'Ghost',
        'member_id': 'member-me',
        'connected_at': null,
        'last_seen': 0,
        'offline_since': null,
        'status': 'active',
      },
    ]);

    await _openEntranceListSheet(tester, db, api);

    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetText('Ghost'), findsOneWidget);
    // 只有一张卡有时间
    expect(sheetTimeText(), findsOneWidget);
    expect(
      cardOf(tester, 'iPhone').height,
      cardOf(tester, 'Ghost').height,
      reason: '没有时间可显示的卡片也要占住时间行的高度，否则会矮一截',
    );
  });

  testWidgets('离线时当前通道照列，其他通道区显示失败提示', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _openEntranceListSheet(tester, db, _BrokenEntranceApi());

    // 当前通道（本机）照常显示（绿勾 + 绿灯；拉不到服务端时间 → 不显示时间）
    expect(sheetText('更多通道'), findsOneWidget);
    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetLocalCheck(), findsOneWidget);
    expect(sheetDot(Colors.green), findsOneWidget);
    expect(sheetTimeText(), findsNothing);
    // 其他通道区失败提示 + 「新建通道」仍在
    expect(sheetTextContaining('无法获取其他通道'), findsOneWidget);
    expect(sheetText('新建通道'), findsOneWidget);
  });

  testWidgets('点标题右端的刷新：就地重拉 /entrances，卡片在线状况跟着变', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.now().millisecondsSinceEpoch;
    // 当前通道（本机）+ 我本人的另一条通道：此刻都在线
    final api = _FakeEntranceApi([
      {
        'entrance_id': 'dev-a',
        'entrance_name': 'iPhone',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
      {
        'entrance_id': 'dev-b2',
        'entrance_name': 'iPad',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
    ]);

    await _openEntranceListSheet(tester, db, api);

    expect(sheetRefresh(), findsOneWidget, reason: '弹层标题右端应有刷新按钮');
    expect(sheetDot(Colors.green), findsNWidgets(2));
    expect(sheetDot(Colors.red), findsNothing);

    // 那台下线了：下一次拉取时 connected_at 为 null、last_seen 归零、
    // 断线时刻落在 offline_since
    api.entranceRows = [
      {
        'entrance_id': 'dev-a',
        'entrance_name': 'iPhone',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
      {
        'entrance_id': 'dev-b2',
        'entrance_name': 'iPad',
        'member_id': 'member-me',
        'connected_at': null,
        'last_seen': 0,
        'offline_since': now - 60 * 1000,
        'status': 'active',
      },
    ];
    final callsBefore = api.listCalls;
    await tester.tap(sheetRefresh());
    await tester.pumpAndSettle();

    expect(api.listCalls, callsBefore + 1, reason: '点刷新应重新拉一次 /entrances');
    expect(find.byType(BottomSheet), findsOneWidget,
        reason: '刷新是就地重建，不该把弹层关掉再开');
    // 灯变色：iPad 在线 → 离线（本机卡恒绿）
    expect(sheetDot(Colors.green), findsOneWidget);
    expect(sheetDot(Colors.red), findsOneWidget);
    // 时间行两张都在（离线那张显示下线时刻）
    expect(sheetTimeText(), findsNWidgets(2));
    // 转圈收起、刷新按钮回到常态
    expect(sheetRefresh(), findsOneWidget);
  });

  testWidgets('旧 token 已过期（401 invalid session）→ 自动续期 + 重试，卡片照常列出',
      (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.now().millisecondsSinceEpoch;
    final api = _StaleTokenApi([
      {
        'entrance_id': 'dev-a',
        'entrance_name': 'iPhone',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
      {
        'entrance_id': 'dev-b2',
        'entrance_name': 'iPad',
        'member_id': 'member-me',
        'connected_at': now,
        'last_seen': now,
        'status': 'active',
      },
    ], staleToken: 'tok');
    var reauthCalls = 0;

    // 老板 2026-09-26 实测的场景：Vault 里那份 token 已过 24h（服务端 session TTL）
    await _openEntranceListSheet(tester, db, api,
        reauth: () async {
          reauthCalls++;
          return 'fresh';
        });

    // 续期后重试成功：其他通道照常列出，而不是"无法获取其他通道（当前离线？）"
    expect(sheetText('iPhone'), findsOneWidget);
    expect(sheetText('iPad'), findsOneWidget,
        reason: '401 的直接请求应被续期后重试，而不是把失败亮给用户');
    expect(sheetTextContaining('无法获取其他通道'), findsNothing);
    expect(reauthCalls, 1, reason: '一处过期只该续期一次');
    expect(api.tokensSeen, contains('tok'), reason: '第一次确实用旧 token 发了（才 401）');
    expect(api.tokensSeen, contains('fresh'), reason: '重试用的是续期后的新 token');
  });
}
