// 回归：**群空间**顶部状态条**左侧**的形态（老板 2026-10-05 定）。
//
// 左侧 = **一排其他成员的头像**，其后紧跟 **「在线人数/总人数」**（两个数都不含我）：
//  ① 头像不含我自己（我在右侧那一块）；
//  ② **没有人名**（原先那行 "Member0、Member1、Member2" 已去掉）；
//  ③ 人数在头像**右侧**，且**整块不越过胶囊中线**（老板：最多顶到一半宽的最右侧）；
//  ④ 头像装不下时**末尾渐隐**（`ShaderMask`），且**只构建装得下的那几个**
//     ——群大了不该为看不见的头像去拉图；**人数不参与截断**（它是信息）。
//
// 本文件只绑 l10n 键（`chatPageStatusOthersOnline`），不绑字面文案。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'real_async_settle.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

/// [others] = 除我之外的成员数；名单与通道表按它生成。
///
/// 通道表刻意编排成三种边角：
/// - 每个其他成员一条通道；
/// - **最后一个**离线（`connected_at: null`）→ 让"在线数"与"总数"不同；
/// - **第一个**多一条通道且在线 → 按 member 去重后仍只算 1 个人。
class _GroupApi extends ApiClient {
  _GroupApi(this.others) : super('http://fake');

  final int others;

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-demo',
        entrances: [
          for (var i = 0; i < others; i++)
            SpaceEntrance(
                entranceId: 'dev-o$i', memberId: 'member-o$i', status: 'active'),
        ],
        memberNames: {
          'member-me': 'Lukas',
          for (var i = 0; i < others; i++) 'member-o$i': 'Member$i',
        },
        memberGenders: {
          'member-me': 'male',
          for (var i = 0; i < others; i++) 'member-o$i': 'female',
        },
        // 槽位即入群顺序（左侧头像条按它排）
        memberSlots: {
          'member-me': 0,
          for (var i = 0; i < others; i++) 'member-o$i': i + 1,
        },
        mode: 'group',
        maxMembers: 0,
      );

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => [
        for (var i = 0; i < others; i++)
          if (i == others - 1)
            // 最后一个：离线
            {
              'entrance_id': 'dev-o$i',
              'member_id': 'member-o$i',
              'connected_at': null,
              'last_seen': 0,
            }
          else
            {
              'entrance_id': 'dev-o$i',
              'member_id': 'member-o$i',
              'connected_at': 1000,
            },
        // 第一个成员的**第二条**通道（也在线）→ 去重后仍算 1 人
        if (others > 0)
          {
            'entrance_id': 'dev-o0-2nd',
            'member_id': 'member-o0',
            'connected_at': 1000,
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

Future<void> _pump(WidgetTester tester, LocalDatabase db, int others) async {
  final spaceKey = await generateSpaceKey();
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: ChatPage(
      spaceId: 'space-demo',
      entranceId: 'dev-me',
      spaceKey: spaceKey,
      keyVersion: 1,
      token: 'tok',
      db: db,
      api: _GroupApi(others),
      enableWs: false,
      memberId: 'member-me',
      memberName: 'Lukas',
      entranceName: 'iPhone',
      peerName: '',
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300)); // /space + /entrances
  await tester.pumpAndSettle();
}

Finder get _statusBar => find.byKey(const ValueKey('chatPageStatusBar'));

/// 状态条里的头像数（含**我自己**那一个——它在右侧）。
int _statusAvatars(WidgetTester tester) => tester
    .widgetList(find.descendant(of: _statusBar, matching: find.byType(CircleAvatar)))
    .length;

void main() {
  disableAnimationsInTests();

  testWidgets('群空间状态条左侧：成员头像条 + 「在线/总数」，没有人名',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);

    expect(_statusBar, findsOneWidget);

    // ① 三个其他成员的头像 + 我自己那一个 = 4
    expect(_statusAvatars(tester), 4,
        reason: '左侧应摆其他成员的头像（3 个），加我自己共 4 个');

    // ② 左侧**没有人名**（原来的 "Member0、Member1、Member2" 已去掉）
    for (var i = 0; i < 3; i++) {
      expect(find.descendant(of: _statusBar, matching: find.text('Member$i')),
          findsNothing,
          reason: '群空间状态条左侧不该再写人名');
    }

    // ③ 没有人形图标以外的旧元素（上一版那个 Icons.groups_outlined 已被头像条取代）
    expect(
        find.descendant(
            of: _statusBar, matching: find.byIcon(Icons.groups_outlined)),
        findsNothing);

    // ④ 人数：o0 两条通道去重后算 1、o1 在线、o2 离线 → 2/3（都不含我自己）
    final countFinder = find.descendant(
        of: _statusBar,
        matching: find.text(_zh.chatPageStatusOthersOnline(2, 3)));
    expect(countFinder, findsOneWidget,
        reason: '头像右侧应显示「其他人在线数/其他人总数」（2/3）');

    // ⑤ 人数在头像**右侧**
    final countRect = tester.getRect(countFinder);
    final firstAvatar = tester.getRect(
        find.descendant(of: _statusBar, matching: find.byType(CircleAvatar)).first);
    final avatarsRect = tester
        .getRect(find
            .descendant(of: _statusBar, matching: find.byType(CircleAvatar))
            .at(2)) // 第 3 个头像 = 左侧头像条最右那个
        ;
    expect(countRect.left, greaterThanOrEqualTo(avatarsRect.right),
        reason: '人数应在头像条右侧');
    expect(firstAvatar.left, lessThan(countRect.left),
        reason: '头像条在最左（先头像、后人数）');

    // ⑥ **整块不越过胶囊中线**（老板：最多顶到一半宽的最右侧）
    final capsule = tester.getRect(_statusBar);
    expect(countRect.right, lessThanOrEqualTo(capsule.left + capsule.width / 2 + 0.5),
        reason: '左侧整块（头像 + 人数）最远只能到胶囊中线');

    // ⑦ 3 个装得下 → 不该有渐隐
    expect(find.descendant(of: _statusBar, matching: find.byType(ShaderMask)),
        findsNothing,
        reason: '头像条没超上限时不需要渐隐');
  });

  testWidgets('成员多到超过一半宽：只摆装得下的那几个、末尾渐隐，人数照常显示',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const others = 15;
    await _pump(tester, db, others);

    // 渐隐出现（说明头像确实截断了）
    expect(find.descendant(of: _statusBar, matching: find.byType(ShaderMask)),
        findsWidgets,
        reason: '头像条超出上限时应在末尾渐隐');

    // 没有把 15 个都建出来：只摆装得下的（+1 是我自己）
    final avatars = _statusAvatars(tester);
    expect(avatars, greaterThan(1), reason: '至少要有头像');
    expect(avatars, lessThan(1 + others),
        reason: '超过上限的部分不该被构建（更不该为看不见的头像去拉图）');

    // 人数**不参与截断**：14/15（最后一个离线）照常完整显示
    expect(
        find.descendant(
            of: _statusBar,
            matching: find.text(_zh.chatPageStatusOthersOnline(14, 15))),
        findsOneWidget,
        reason: '人数是信息，无论头像截不截断都要显示');

    // 整块仍然不越过胶囊中线
    final capsule = tester.getRect(_statusBar);
    final countRect = tester.getRect(find.descendant(
        of: _statusBar,
        matching: find.text(_zh.chatPageStatusOthersOnline(14, 15))));
    expect(countRect.right, lessThanOrEqualTo(capsule.left + capsule.width / 2 + 0.5),
        reason: '头像再多，整块也只能顶到胶囊中线');
  });
}
