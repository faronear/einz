// 回归：**群空间**顶部状态条的两处形态（老板 2026-10-05 定）。
//
// 群空间里那一格代表的是"一群人"，所以两处都要跟着变：
//  ① 头像位置不再显示某个人的头像 → 换成创建空间时「群组秘境」那枚图标
//     （`Icons.groups_outlined`，与 setup_page 的类型选择页同一枚）；
//  ② 第二行不再是红绿灯（"某一个人在不在线"没意义）→ 改成
//     「**其他人在线数 / 其他人总数**」，**两个数都不含我自己**。
//
// 本测试同时钉住"按 member 去重"：成员 Alice 挂了**两条**通道，
// 人数必须是 1 而不是 2（在线是"人"的维度）。
//
// l10n：断言只绑 key（`chatPageStatusOthersOnline`），不绑字面文案。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'real_async_settle.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

/// 4 个成员（我 + 3 人）、上限 5 的群空间；通道表里 Alice 有**两条**通道。
class _GroupApi extends ApiClient {
  _GroupApi() : super('http://fake');

  @override
  Future<SpaceResult> getSpace(String token) async => const SpaceResult(
        spaceId: 'space-demo',
        entrances: [],
        memberNames: {
          'member-me': 'Lukas',
          'member-a': 'Alice',
          'member-b': 'Bob',
          'member-c': 'Carol',
        },
        memberGenders: {
          'member-me': 'male',
          'member-a': 'female',
          'member-b': 'male',
          'member-c': 'female',
        },
        memberSlots: {
          'member-me': 0,
          'member-a': 1,
          'member-b': 2,
          'member-c': 3,
        },
        mode: 'group',
        maxMembers: 5,
      );

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => const [
        // 我自己（本机这条）——两个数字都不该把我算进去
        {'entrance_id': 'dev-a', 'member_id': 'member-me', 'connected_at': 1000},
        // 我自己的**另一台设备**（也在线）：按 entrance_id 排除不掉它，
        // 必须靠"排除我自己的 member"那道判断 —— 它同样不该算成"另一个人"。
        {'entrance_id': 'dev-a2', 'member_id': 'member-me', 'connected_at': 1000},
        // Alice：**两条**通道都在线 → 按 member 去重后只算 1 个人
        {'entrance_id': 'dev-b', 'member_id': 'member-a', 'connected_at': 1000},
        {'entrance_id': 'dev-c', 'member_id': 'member-a', 'connected_at': 1000},
        // Bob：在线
        {'entrance_id': 'dev-d', 'member_id': 'member-b', 'connected_at': 1000},
        // Carol：离线（connected_at 为 null = 没有实时连接）
        {
          'entrance_id': 'dev-e',
          'member_id': 'member-c',
          'connected_at': null,
          'last_seen': 0,
        },
      ];

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})>
      sync(String token, {int after = 0, int limit = 100}) async => (
            messages: <MessageEnvelope>[],
            attachmentsMeta: <Map<String, dynamic>>[],
            lastSequence: after,
            hasMore: false,
          );

  @override
  Future<NotifyEmailStatus> getNotifyEmail(String token) async =>
      NotifyEmailStatus(state: 'none');
}

Future<void> _pumpGroupChat(WidgetTester tester, LocalDatabase db) async {
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
      api: _GroupApi(),
      enableWs: false,
      memberId: 'member-me',
      memberName: 'Lukas',
      entranceName: 'iPhone',
      peerName: '',
    ),
  ));
  // /space（成员表）+ /entrances（人数）都是 initState 里发起的异步
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  disableAnimationsInTests();

  testWidgets('群空间状态条：群组图标 + 「其他人在线数/总数」（都不含我自己）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pumpGroupChat(tester, db);

    // ① 左侧头像位置换成了「群组秘境」那枚图标（不是单人形）
    expect(find.byIcon(Icons.groups_outlined), findsOneWidget,
        reason: '群空间左侧应显示群组图标（与创建空间时选类型那页同一枚）');
    // 单人图标只剩**我自己**那半格（我还没设头像，空头像就是单人形）
    expect(find.byIcon(Icons.person), findsOneWidget,
        reason: '单人图标只应剩"我自己"那一个（左侧已换成群组图标）');

    // ② 第一行仍是名单（按加入顺序，不含我自己）
    expect(find.text('Alice、Bob、Carol'), findsOneWidget,
        reason: '第一行是其他成员名单');

    // ③ 第二行是人数：Alice/Bob 在线、Carol 离线 → 2/3；
    //    Alice 的两条通道按 member 去重后只算 1 个人
    expect(find.text(_zh.chatPageStatusOthersOnline(2, 3)), findsOneWidget,
        reason: '第二行应为「其他人在线数/其他人总数」，且不含我自己');

    // ④ 红绿灯只在**我自己那一侧**（左侧群空间不摆灯）
    expect(find.byIcon(Icons.circle), findsOneWidget,
        reason: '群空间左侧不该有红绿灯（只剩我自己那半格的灯）');
  });
}
