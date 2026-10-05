// 回归：**群空间**顶部状态条**左侧**的形态（老板 2026-10-05 定）。
//
// 左侧 = **一排其他成员的头像**：
//  ① 不含我自己（我在右侧那一块）；
//  ② **没有人名**（原先那行 "Member0、Member1、Member2" 已去掉）；
//  ③ **没有在线状态**（红绿灯 / 人数都没有）；
//  ④ 装不下时**末尾渐隐**（`ShaderMask`），且**只构建装得下的那几个**
//     ——群大了不该为看不见的头像去拉图。
//
// 本文件不依赖文案（新设计里左侧没有文字），所以不引 l10n 取词。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'real_async_settle.dart';

/// [others] = 除我之外的成员数；名单与通道表按它生成。
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
        // 每个其他成员都有一条在用通道 → `_peerJoined == true` → 不显示「邀请」入口，
        // 断言里就只剩头像条本身，干净。
        for (var i = 0; i < others; i++)
          {'entrance_id': 'dev-o$i', 'member_id': 'member-o$i', 'connected_at': 1000},
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

/// 状态条里的头像数（含**我自己**那一个——它在右侧）。
int _statusAvatars(WidgetTester tester) => tester
    .widgetList(find.descendant(
        of: find.byKey(const ValueKey('chatPageStatusBar')),
        matching: find.byType(CircleAvatar)))
    .length;

void main() {
  disableAnimationsInTests();

  testWidgets('群空间状态条左侧：只有其他成员的头像，没有人名与在线状态',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);

    final statusBar = find.byKey(const ValueKey('chatPageStatusBar'));
    expect(statusBar, findsOneWidget);

    // ① 三个其他成员的头像 + 我自己那一个 = 4
    expect(_statusAvatars(tester), 4,
        reason: '左侧应摆其他成员的头像（3 个），加我自己共 4 个');

    // ② 左侧**没有人名**（原来的 "Member0、Member1、Member2" 已去掉）
    for (var i = 0; i < 3; i++) {
      expect(find.descendant(of: statusBar, matching: find.text('Member$i')),
          findsNothing,
          reason: '群空间状态条左侧不该再写人名');
    }

    // ③ 没有群组图标（上一版那个 Icons.groups_outlined 已被头像条取代）
    expect(
        find.descendant(
            of: statusBar, matching: find.byIcon(Icons.groups_outlined)),
        findsNothing);

    // ④ 没超上限 → 不该有渐隐
    expect(find.descendant(of: statusBar, matching: find.byType(ShaderMask)),
        findsNothing,
        reason: '头像条没超过一半宽时不需要渐隐');
  });

  testWidgets('成员多到超过一半宽：只摆装得下的那几个，且末尾渐隐',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const others = 15;
    await _pump(tester, db, others);

    final statusBar = find.byKey(const ValueKey('chatPageStatusBar'));
    final avatars = _statusAvatars(tester);

    // 渐隐出现（说明确实截断了）
    expect(find.descendant(of: statusBar, matching: find.byType(ShaderMask)),
        findsWidgets,
        reason: '头像条超出上限时应在末尾渐隐');

    // 没有把 15 个都建出来：只摆装得下的（+1 是我自己）
    expect(avatars, greaterThan(1), reason: '至少要有头像');
    expect(avatars, lessThan(1 + others),
        reason: '超过上限的部分不该被构建（更不该为看不见的头像去拉图）');
  });
}
