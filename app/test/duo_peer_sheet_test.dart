// 回归测试（老板 2026-10-18 改版）：duo 的「我的同伴」弹层从成员卡列表改成
// 与「我的资料」同款的**单张只读身份卡**：
//  ① 布局 = 左头像 + 右两行（名字在上、性别在下），全部只读（无编辑入口）；
//  ② **点头像打开头像全屏**——与对方头像既有全屏同一份实现：底部「保存」
//     可下载，没有「更换头像」（不给改别人的图）；
//  ③ **邀请 / 重新邀请按钮放在性别那一行、右端对齐**——已加入 = 「重新邀请」，
//     还没加入 = 「邀请」。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'real_async_settle.dart';

/// 文案断言一律从 l10n 取（改文案不弄红测试）。
final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

/// 1×1 透明 PNG（够 MemoryImage 解码，不引额外依赖）。
final Uint8List _kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==');

/// 最小 fake：把「本空间成员表」喂给页面，其余走空实现。
/// [peerInSpace] = false 时对方还没加入（槽位表里只有我）。
class _Api extends ApiClient {
  _Api({this.peerInSpace = true}) : super('http://fake');

  final bool peerInSpace;

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-demo',
        entrances: const [],
        memberNames: {
          'member-me': 'Lukas',
          if (peerInSpace) 'member-peer': 'Alice',
        },
        memberGenders: {
          'member-me': 'male',
          if (peerInSpace) 'member-peer': 'female',
        },
        memberSlots: {
          'member-me': 0,
          if (peerInSpace) 'member-peer': 1, // 含未命名成员
        },
        mode: 'duo',
        maxMembers: 0,
      );

  @override
  Future<Uint8List?> getAvatar(String memberId) async => _kTinyPng;

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => const [];

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

Finder get _actionButton =>
    find.byKey(const ValueKey('duoPeerSheetActionButton'));
Finder get _avatarHotZone => find.byKey(const ValueKey('duoPeerSheetAvatar'));
Finder get _sheet => find.ancestor(
    of: find.text(_zh.chatPageMembersTitle('duo')),
    matching: find.byType(SingleChildScrollView));

/// 点状态条上的对方胶囊（整块可点 = 打开「我的同伴」弹层）。
Future<void> _openPeerSheet(WidgetTester tester, {required String peerName}) async {
  await tester.tap(find.text(peerName));
  await tester.pumpAndSettle();
  expect(find.text(_zh.chatPageMembersTitle('duo')), findsOneWidget,
      reason: '点对方状态胶囊应打开「我的同伴」弹层');
}

void main() {
  setUpAll(() {
    // withImmersiveFullscreen 里的 SystemChrome.setEnabledSystemUIMode 走
    // flutter/platform 通道，测试环境没有引擎、调用永不回调——不 mock 的话
    // await 挂住，头像全屏根本打不开（与 chat_fullscreen_tap_close_test 同因）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SystemChannels.platform, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  // 菜单里的翻转沙漏是常驻动画，关掉免得 pumpAndSettle 超时。
  disableAnimationsInTests();

  testWidgets('对方已加入：资料卡布局 + 点头像开全屏 + 重新邀请在性别行右端',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
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
        api: _Api(),
        enableWs: false,
        memberId: 'member-me',
        memberName: 'Lukas',
        entranceName: 'iPhone',
        peerName: 'Alice',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 initState 的 getSpace 回来
    await tester.pumpAndSettle();

    await _openPeerSheet(tester, peerName: 'Alice');

    // ① 资料卡布局：名字 + 性别（只读，没有编辑图标/改名胶囊）
    // （页面被弹层盖着，文本仍在树里——断言一律限定在弹层内）
    expect(find.descendant(of: _sheet, matching: find.text('Alice')), findsOneWidget,
        reason: '名字应显示对方名字');
    final genderText =
        find.descendant(of: _sheet, matching: find.text(_zh.wizardGenderFemale));
    expect(genderText, findsOneWidget, reason: '性别行应显示「女」');
    expect(find.descendant(of: _sheet, matching: find.byIcon(Icons.edit)),
        findsNothing, reason: '对方的资料不能编辑：不应出现任何编辑图标');

    // ② 邀请/重新邀请按钮 = 「重新邀请」，放在性别那一行、右端对齐
    expect(find.descendant(of: _sheet, matching: find.text(_zh.chatPageMembersReinvite)),
        findsOneWidget, reason: '对方已加入 → 按钮应为「重新邀请」');
    final genderRect = tester.getRect(genderText);
    final buttonRect = tester.getRect(_actionButton);
    expect((buttonRect.center.dy - genderRect.center.dy).abs(), lessThan(4),
        reason: '按钮应与性别文字同一行（按钮 dy=${buttonRect.center.dy} 性别 dy=${genderRect.center.dy}）');
    final sheetRect = tester.getRect(_sheet);
    expect(buttonRect.right, closeTo(sheetRect.right - 22, 1),
        reason: '按钮应右端对齐到弹层内容右缘（22 是弹层水平内边距）');
    expect(buttonRect.left, greaterThan(genderRect.right),
        reason: '按钮应排在性别文字右侧');

    // ③ 点头像 → 头像全屏（与对方头像既有全屏同一份实现）
    await tester.tap(_avatarHotZone);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget, reason: '点头像应打开全屏大图');
    expect(find.text(_zh.chatPageActionSave), findsOneWidget,
        reason: '对方头像全屏底部应有「保存」（可下载）');
    expect(find.text(_zh.chatPageAvatarChange), findsNothing,
        reason: '对方的头像不给「更换头像」');
    expect(tester.takeException(), isNull);

    // 关全屏 → 回到弹层
    await tester.tap(find.descendant(
        of: find.byType(Dialog), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageMembersTitle('duo')), findsOneWidget);
  });

  testWidgets('对方还没加入：显示「待加入」+ 性别行的「邀请」按钮（右端对齐）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
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
        api: _Api(peerInSpace: false),
        enableWs: false,
        memberId: 'member-me',
        memberName: 'Lukas',
        entranceName: 'iPhone',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 对方没名字 → 胶囊里没有名字可点，从菜单进（与 members_reinvite_test 同路径；
    // 菜单项走 _menuAction 的 300ms 错峰，用 tapDeferred 推过它）
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tapDeferred(tester, find.text(_zh.chatPageMembersTitle('duo')));
    expect(find.text(_zh.chatPageMembersTitle('duo')), findsOneWidget,
        reason: '「我的同伴」弹层应已打开');

    // ① 名字占位词 = 「待加入」（与状态条同一口径；限定在弹层内——
    // 状态条未加入时也显示「待加入」）
    expect(find.descendant(of: _sheet, matching: find.text(_zh.memberPending)),
        findsOneWidget, reason: '对方还没加入 → 名字位应显示「待加入」');

    // ② 性别未知 → 不显示性别图标/文字，但邀请按钮仍在性别行右端
    expect(find.descendant(of: _sheet, matching: find.byIcon(Icons.male)),
        findsNothing, reason: '性别未知不应显示性别图标');
    expect(find.descendant(of: _sheet, matching: find.byIcon(Icons.female)),
        findsNothing);
    expect(find.descendant(of: _sheet, matching: find.text(_zh.chatPageMembersInvite)),
        findsOneWidget, reason: '对方还没加入 → 按钮应为「邀请」');
    final sheetRect = tester.getRect(_sheet);
    final buttonRect = tester.getRect(_actionButton);
    expect(buttonRect.right, closeTo(sheetRect.right - 22, 1),
        reason: '邀请按钮应右端对齐到弹层内容右缘');

    // ③ 点「邀请」→ 先收弹层、错峰后再开通道码弹窗（route 交接）。
    // 用弹窗里的邀请链接断言（标题「邀请」与状态条上的邀请链接同文案，
    // 未加入时它在页面背后，直接按文本找会撞两个）。
    await tester.tap(_actionButton);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400)); // 冲掉 _menuAction 的 300ms
    await tester.pumpAndSettle();
    expect(find.text('https://einz.example/join/e1_TEST'), findsOneWidget,
        reason: '点邀请应打开邀请通道码弹窗');
    expect(tester.takeException(), isNull);
  });
}
