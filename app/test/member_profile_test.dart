// 回归（老板 2026-10-20）：头像点击从「全屏大图」改为「个人资料页」。
//
// 三件事一起钉住：
//  ① 「我的群组」成员弹层：右侧「重新邀请」按钮已删（收进资料页）；
//  ② 点成员卡头像 → 该成员的资料页（标题「群组同伴」+ 名字 + 性别 + 右端
//     「重新邀请」）——**有头像图片也不进全屏**（这正是本次改动的重点）；
//  ③ 消息气泡旁头像：点**别人的**开他的资料页；点**我的**开「我的资料」弹层。
//
// 另跑一遍资料页「重新邀请」→ 口令验证的完整链路，断言全程不闪红屏
// （与 members_reinvite_test 同一类 route 交接回归）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'real_async_settle.dart';

/// 文案断言一律从 l10n 取（改文案不弄红测试）。
final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

/// 1×1 透明 PNG（够 MemoryImage 解码，不引额外依赖）——**刻意给头像**：
/// 要验证"有图也进资料页、不再被全屏抢走点击"。
final Uint8List _kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==');

/// 群空间 fake：我（Lukas/male）+ 两位成员（Alice/female、Bob/male），
/// maxMembers=5（未满 → 成员弹层里还有「邀请新同伴」大按钮）。
class _GroupApi extends ApiClient {
  _GroupApi(this.messages) : super('http://fake');

  final List<MessageEnvelope> messages;

  @override
  Future<SpaceResult> getSpace(String token) async => const SpaceResult(
        spaceId: 'space-demo',
        entrances: [
          SpaceEntrance(
              entranceId: 'dev-me', memberId: 'member-me', status: 'active'),
          SpaceEntrance(
              entranceId: 'dev-a', memberId: 'member-a', status: 'active'),
          SpaceEntrance(
              entranceId: 'dev-b', memberId: 'member-b', status: 'active'),
        ],
        memberNames: {
          'member-me': 'Lukas',
          'member-a': 'Alice',
          'member-b': 'Bob',
        },
        memberGenders: {
          'member-me': 'male',
          'member-a': 'female',
          'member-b': 'male',
        },
        memberSlots: {'member-me': 0, 'member-a': 1, 'member-b': 2},
        mode: 'group',
        maxMembers: 5,
      );

  @override
  Future<Uint8List?> getAvatar(String memberId) async => _kTinyPng;

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async =>
      const [];

  @override
  Future<JoinTokenResult> createJoinToken(
    String spaceId,
    String token, {
    required String purpose,
    String? targetMemberId,
    String? passphrase,
  }) async =>
      const JoinTokenResult(
        joinToken: 'e1_TEST',
        link: 'https://einz.example/join/e1_TEST',
        expiresAt: 0,
      );

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})>
      sync(String token, {int after = 0, int limit = 100}) async {
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
  Future<NotifyEmailStatus> getNotifyEmail(String token) async =>
      NotifyEmailStatus(state: 'none');
}

/// 成员弹层（按标题定位，限定断言范围用）。
Finder get _membersSheet => find.ancestor(
    of: find.text(_zh.chatPageMembersTitle('group')),
    matching: find.byType(SingleChildScrollView));

/// 成员资料页（标题「群组同伴」，老板 2026-10-20 定）。
Finder get _profileSheet => find.ancestor(
    of: find.text(_zh.chatPageMemberProfileTitle),
    matching: find.byType(SingleChildScrollView));

/// 菜单 → 「我的群组」→ 成员弹层。
Future<void> _openMembersSheet(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  await tapDeferred(tester, find.text(_zh.chatPageMembersTitle('group')));
  expect(find.text(_zh.chatPageMembersTitle('group')), findsOneWidget,
      reason: '成员弹层应已打开');
}

/// 点成员弹层里某成员卡的头像 → 等它收完 + 错峰 300ms 再开的资料页。
Future<void> _tapCardAvatar(WidgetTester tester, Finder avatar) async {
  await tester.tap(avatar);
  await tester.pump(const Duration(milliseconds: 400)); // pop 动画 + route 交接
  await tester.pumpAndSettle();
}

/// [spaceKey] 由调用方生成并先用于加密消息——必须与页面拿到的是同一把，
/// 否则解密失败、消息根本不渲染（气泡旁头像就无从点起）。
Future<void> _pumpChat(WidgetTester tester, LocalDatabase db,
    Uint8List spaceKey, List<MessageEnvelope> messages) async {
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
      api: _GroupApi(messages),
      enableWs: false,
      memberId: 'member-me',
      memberName: 'Lukas',
      entranceName: 'iPhone',
      peerName: '',
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300)); // 等 initState 的 getSpace 回来
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  // 菜单里的翻转沙漏是常驻动画，关掉免得 pumpAndSettle 超时。
  disableAnimationsInTests();

  testWidgets('成员弹层无「重新邀请」按钮；点头像开资料页（有图也不进全屏）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpChat(tester, db, await generateSpaceKey(), const []);
    await _openMembersSheet(tester);

    // ① 「重新邀请」按钮已从成员卡上删掉（功能收进资料页）
    expect(find.text(_zh.chatPageMembersReinvite), findsNothing,
        reason: '老板 2026-10-20：成员卡右侧不再放「重新邀请」');
    // 卡片仍在：两位成员的名字都列着
    expect(find.descendant(of: _membersSheet, matching: find.text('Alice')),
        findsOneWidget);
    expect(find.descendant(of: _membersSheet, matching: find.text('Bob')),
        findsOneWidget);

    // ② 点头像（Alice 的卡，槽位 1 = 第一张）→ 她的资料页
    final cardAvatar = find
        .descendant(of: _membersSheet, matching: find.byType(CircleAvatar))
        .first;
    await _tapCardAvatar(tester, cardAvatar);

    expect(find.text(_zh.chatPageMemberProfileTitle), findsOneWidget,
        reason: '应弹出该成员的资料页（标题「群组同伴」）');
    expect(find.descendant(of: _profileSheet, matching: find.text('Alice')),
        findsOneWidget, reason: '资料页应显示该成员的名字');
    final genderIcon =
        find.descendant(of: _profileSheet, matching: find.byIcon(Icons.female));
    expect(genderIcon, findsOneWidget, reason: '资料页应显示性别图标');
    // 「重新邀请」收在这里：性别行右端
    expect(
        find.descendant(
            of: _profileSheet, matching: find.text(_zh.chatPageMembersReinvite)),
        findsOneWidget,
        reason: '资料页里应有「重新邀请」（成员卡上已删）');
    // 有头像图片也**不开全屏**——这是本次改动的重点
    expect(find.byType(InteractiveViewer), findsNothing,
        reason: '点头像应进资料页，不再开头像全屏大图');
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料页「重新邀请」→ 口令验证：全程不闪红屏',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpChat(tester, db, await generateSpaceKey(), const []);
    await _openMembersSheet(tester);

    final cardAvatar = find
        .descendant(of: _membersSheet, matching: find.byType(CircleAvatar))
        .first;
    await _tapCardAvatar(tester, cardAvatar);
    expect(find.text(_zh.chatPageMemberProfileTitle), findsOneWidget);

    // 点性别行右端的「重新邀请」→ 先收资料页、错峰后再弹口令框
    await tester.tap(find.byKey(const ValueKey('duoPeerSheetActionButton')));
    expect(find.text(_zh.chatPageReinvitePassphraseTitle), findsNothing,
        reason: '口令框要等 route 交接（300ms）后才出现');
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull,
          reason: '资料页退出/衔接期间不应报错（真机上表现为闪一下红屏）');
    }
    expect(find.text(_zh.chatPageReinvitePassphraseTitle), findsOneWidget,
        reason: '应弹出共享口令验证框');

    // 输口令 → 确定（FilledButton = 弹窗的确认键，用类型定位免得绑死文案）
    await tester.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'secret-passphrase',
    );
    await tester.pump();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(FilledButton)));

    // 口令弹窗退出动画 → 错峰 300ms → 通道码弹窗，全程不应报错
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull,
          reason: '口令弹窗退出/衔接期间不应报错（真机上表现为闪一下红屏）');
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 最终应停在「重新邀请」的通道码弹窗上
    expect(find.text(_zh.chatPageInviteDialogTitleReinvite), findsOneWidget,
        reason: '验证口令后应弹出通道码弹窗');
    expect(tester.takeException(), isNull);
  });

  testWidgets('气泡旁头像：点别人的开他的资料页，点我的开「我的资料」',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    // 两条消息：Alice 发的一条 + 我发的一条（气泡旁两侧都有头像）
    final fromPeer = await encryptMessage(
      plaintext: 'hello',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderEntranceId: 'dev-a',
      messageId: 'msg-peer-1',
      keyVersion: 1,
    );
    final fromMe = await encryptMessage(
      plaintext: 'hi',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderEntranceId: 'dev-me',
      messageId: 'msg-me-1',
      keyVersion: 1,
    );

    await _pumpChat(tester, db, spaceKey, [fromPeer, fromMe]);

    // 一切都要**限定在消息列表里**：顶部状态条的头像条也有 CircleAvatar
    Finder inMessages(Finder f) =>
        find.descendant(of: find.byType(ListView), matching: f);
    final avatars = inMessages(find.byType(CircleAvatar));
    expect(avatars, findsNWidgets(2), reason: '两条消息旁各有一枚头像');
    // 第一条（Alice 的）在列表最上；她的头像靠左，我的靠右
    final peerAvatar = avatars.first;
    final myAvatar = avatars.last;
    expect(tester.getRect(peerAvatar).center.dx,
        lessThan(tester.getRect(myAvatar).center.dx),
        reason: '对方的头像应在左侧、我的在右侧');

    // ① 点别人的头像 → 他的资料页
    await tester.tap(peerAvatar);
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageMemberProfileTitle), findsOneWidget,
        reason: '点气泡旁别人的头像应开他的资料页');
    expect(find.descendant(of: _profileSheet, matching: find.text('Alice')),
        findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing,
        reason: '不再开头像全屏大图');
    expect(tester.takeException(), isNull);

    // 关掉资料页（点顶部空白处的屏障）
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // ② 点我的头像 → 「我的资料」弹层
    await tester.tap(myAvatar);
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageMenuMyProfile), findsOneWidget,
        reason: '点气泡旁我的头像应开「我的资料」弹层');
    expect(tester.takeException(), isNull);
  });
}
