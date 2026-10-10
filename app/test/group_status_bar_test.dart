// 回归：**群空间**顶部状态条**左侧**的形态（老板 2026-10-05 定；2026-10-09 改两行）。
//
// 左侧 = **一排其他成员的头像** + **两行文字**（第一行**群组名字**、第二行
// 「在线人数/总人数」，其中在线人数绿色）：
//  ① 头像不含我自己（我在右侧那一块）；
//  ② **没有逐成员人名**（原先那行 "Member0、Member1、Member2" 已去掉）；
//  ③ 人数在名字列**第二行**，且**整块不越过胶囊中线**（老板：最多顶到一半宽的最右侧）；
//  ④ 头像装不下时**末尾渐隐**（`ShaderMask`），且**只构建装得下的那几个**
//     ——群大了不该为看不见的头像去拉图；**名字/人数不参与截断**（它是信息）；
//  ⑤ **至少有一条通道在线**的成员，头像上叠一圈**绿环**（离线的不叠）；
//  ⑥ 群组名字**仅本机**存（per-space 资料 `groupName`）：无名字时第一行只显示
//     编辑图标，点击进编辑弹窗；有名字时显示名字，重启后从资料恢复。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
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

/// 人数现在是 `Text.rich`（在线数绿 + `/总数`灰两段 span）。`find.text` 匹配的是
/// `Text.data`（Text.rich 的 data 为 null），故按 `textSpan` 的纯文本匹配。
Finder _countFinder(String plain) =>
    find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == plain);

/// 弹窗里的输入框（聊天页底部另有个消息输入框，必须限定在 AlertDialog 内）。
Finder get _dialogField => find.descendant(
    of: find.byType(AlertDialog), matching: find.byType(TextField));

/// 状态条里的头像数（含**我自己**那一个——它在右侧）。
int _statusAvatars(WidgetTester tester) => tester
    .widgetList(find.descendant(of: _statusBar, matching: find.byType(CircleAvatar)))
    .length;

void main() {
  disableAnimationsInTests();

  testWidgets('群空间状态条左侧：成员头像条 + 群名/「在线/总数」，没有逐成员人名',
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
        of: _statusBar, matching: _countFinder('2/3'));
    expect(countFinder, findsOneWidget,
        reason: '名字列第二行应显示「其他人在线数/其他人总数」（2/3）');

    // ④a「在线人数」用绿色（与在线灯同色），「/总数」保持原灰
    final countText = tester.widget<Text>(countFinder);
    final spans = (countText.textSpan as TextSpan).children!.cast<TextSpan>();
    expect(spans.first.text, '2');
    expect(spans.first.style?.color, Colors.green,
        reason: '在线人数应为绿色');
    expect(spans.last.text, '/3');
    expect(spans.last.style?.color, isNot(Colors.green),
        reason: '总人数保持原灰，不跟着变绿');

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

    // ⑧ 在线与否一眼可辨：o0、o1 在线（套绿环），o2 离线（不套）
    expect(find.byKey(const ValueKey('statusAvatarOnline-member-o0')),
        findsOneWidget,
        reason: '有通道在线的成员，头像应套绿环');
    expect(find.byKey(const ValueKey('statusAvatarOnline-member-o1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('statusAvatarOnline-member-o2')),
        findsNothing,
        reason: '没有通道在线的成员不该套环');
    expect(find.byKey(const ValueKey('statusAvatarOnline-member-me')),
        findsNothing,
        reason: '"其他成员"不含我自己，我自己那一格不套环');
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

    // 名字/人数**不参与截断**：14/15（最后一个离线）照常完整显示
    expect(
        find.descendant(of: _statusBar, matching: _countFinder('14/15')),
        findsOneWidget,
        reason: '人数是信息，无论头像截不截断都要显示');

    // 截断归截断，在线的环照常画（o0 在线）
    expect(find.byKey(const ValueKey('statusAvatarOnline-member-o0')),
        findsOneWidget,
        reason: '头像条被截断也照样标出谁在线');

    // 整块仍然不越过胶囊中线
    final capsule = tester.getRect(_statusBar);
    final countRect = tester.getRect(find.descendant(
        of: _statusBar, matching: _countFinder('14/15')));
    expect(countRect.right, lessThanOrEqualTo(capsule.left + capsule.width / 2 + 0.5),
        reason: '头像再多，整块也只能顶到胶囊中线');
  });

  testWidgets('群组名字：无名字时第一行只显示编辑图标，点击起名并落本机资料',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);

    // ① 一开始没有名字：第一行是灰字「设置群名」+ 编辑图标
    expect(find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)),
        findsOneWidget,
        reason: '没有群名时第一行应显示编辑图标');
    expect(find.descendant(of: _statusBar, matching: find.text('Crew')),
        findsNothing);

    // ② 点编辑图标 → 打开群组名字编辑弹窗
    await tester.tap(
        find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)));
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageGroupNameTitle), findsOneWidget);

    // ③ 输入并保存 → 第一行显示名字，编辑图标消失
    await tester.enterText(_dialogField, 'Crew');
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _statusBar, matching: find.text('Crew')),
        findsOneWidget,
        reason: '保存后第一行应显示群组名字');
    expect(find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)),
        findsNothing);

    // ④ 落进 per-space 资料（仅本机）
    final profile = await AppLockService(db).loadProfile(spaceId: 'space-demo');
    expect(profile['groupName'], 'Crew');

    // ⑤ 点名字可再次编辑；清空保存 → 回到"没有名字"（编辑图标回来）
    await tester.tap(find.descendant(of: _statusBar, matching: find.text('Crew')));
    await tester.pumpAndSettle();
    await tester.enterText(_dialogField, '');
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)),
        findsOneWidget,
        reason: '清空后可回到没有名字的状态');
    final cleared = await AppLockService(db).loadProfile(spaceId: 'space-demo');
    expect(cleared['groupName'], '');
    // 冲掉弹窗 controller 延迟 dispose 的 400ms 计时器（避免测试结束报 pending timer）
    await tester.pump(const Duration(milliseconds: 450));
  });

  testWidgets('群组名字：重启（同库重新进入）后从资料恢复',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);

    await tester.tap(
        find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)));
    await tester.pumpAndSettle();
    await tester.enterText(_dialogField, 'Crew');
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();

    // 重新挂载聊天页（模拟重启；同一本地库）
    await _pump(tester, db, 3);
    expect(find.descendant(of: _statusBar, matching: find.text('Crew')),
        findsOneWidget,
        reason: '重启后应从 per-space 资料恢复群组名字');
    expect(find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)),
        findsNothing);
  });

  testWidgets('群名输入校验与人名同一套：白名单拦截 + 最长 32 字',
      (WidgetTester tester) async {
    // 老板 2026-10-09：群名采用和人名一样的字符、长度规则（同一 policy 收口）。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);

    await tester.tap(
        find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)));
    await tester.pumpAndSettle();

    // ① 人名白名单外的字符（空格）→ 拦下，弹窗不开
    await tester.enterText(_dialogField, 'Mr Lukas');
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageRenameNameInvalidError), findsOneWidget,
        reason: '人名白名单外的字符应被拦截（与人名同一套规则）');

    // ② 最长 32 字：第 33 个字符敲不进去（同改名输入框）
    await tester.enterText(_dialogField, 'a' * 33);
    final field = tester.widget<TextField>(_dialogField);
    expect(field.maxLength, kMemberNameMaxLength,
        reason: '输入框上限应同人名（kMemberNameMaxLength）');
    expect(field.controller!.text.length, kMemberNameMaxLength,
        reason: '第 33 个字符应敲不进去');

    // ③ 合法名字 → 保存成功
    await tester.enterText(_dialogField, 'Crew');
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();
    expect(find.descendant(of: _statusBar, matching: find.text('Crew')),
        findsOneWidget);
    // 冲掉弹窗 controller 延迟 dispose 的 400ms 计时器（同上）
    await tester.pump(const Duration(milliseconds: 450));
  });

  testWidgets('「我的同伴」胶囊只包头像条：点人数/群名不开成员弹层',
      (WidgetTester tester) async {
    // 老板 2026-10-09：群名已可单独单击改名，人数/群名不该再落进"我的同伴"可点区。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);
    final membersSheet = find.text(_zh.chatPageMembersTitle('group'));

    // 先起个群名，第一行才有名字可点
    await tester.tap(
        find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)));
    await tester.pumpAndSettle();
    await tester.enterText(_dialogField, 'Crew');
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();

    // ① 点人数（第二行「2/3」）→ 不开成员弹层
    await tester.tap(
        find.descendant(of: _statusBar, matching: _countFinder('2/3')));
    await tester.pumpAndSettle();
    expect(membersSheet, findsNothing, reason: '人数不属于「我的同伴」可点区');

    // ② 点群名 → 开的是**群名编辑**弹窗，不是成员弹层
    await tester.tap(find.descendant(of: _statusBar, matching: find.text('Crew')));
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageGroupNameTitle), findsOneWidget,
        reason: '点群名应开改名弹窗');
    expect(membersSheet, findsNothing, reason: '群名可点区属于「改名」而非成员弹层');
    await tester.tap(find.text(_zh.cancel));
    await tester.pumpAndSettle();

    // ③ 点头像条 → 开「我的同伴」
    await tester.tap(find.descendant(
        of: _statusBar,
        matching: find.byType(CircleAvatar).first));
    await tester.pumpAndSettle();
    expect(membersSheet, findsOneWidget, reason: '头像条才是「我的同伴」入口');
    // 冲掉弹窗 controller 延迟 dispose 的 400ms 计时器（同上）
    await tester.pump(const Duration(milliseconds: 450));
  });

  testWidgets('点我的名字 → 打开「我的身份」弹窗', (WidgetTester tester) async {
    // 老板 2026-10-09：状态条里我的名字也做成可点（与菜单「我的身份」同入口）。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
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
        api: _GroupApi(3),
        enableWs: false,
        memberId: 'member-me',
        memberName: 'Lukas',
        entranceName: 'iPhone',
        peerName: '',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: _statusBar, matching: find.text('Lukas')));
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageRenameNameTitle), findsOneWidget,
        reason: '点我的名字应打开「我的身份」弹窗');
    await tester.tap(find.text(_zh.cancel));
    await tester.pumpAndSettle();
    // 冲掉弹窗 controller 延迟 dispose 的 400ms 计时器（同上）
    await tester.pump(const Duration(milliseconds: 450));
  });

  testWidgets('头像条↔群名的间距 = 我的名字↔我的头像的间距（老板 2026-10-09）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);

    // 先起个群名，第一行才有名字可量
    await tester.tap(
        find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)));
    await tester.pumpAndSettle();
    await tester.enterText(_dialogField, 'Crew');
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();

    final avatars = find.descendant(of: _statusBar, matching: find.byType(CircleAvatar));
    final stripRight = tester.getRect(avatars.at(2)).right; // 头像条最右那个
    final groupNameLeft = tester.getRect(
        find.descendant(of: _statusBar, matching: find.text('Crew'))).left;
    final myNameRight = tester.getRect(
        find.descendant(of: _statusBar, matching: find.text('Lukas'))).right;
    final myAvatarLeft = tester.getRect(avatars.last).left; // 我自己的头像（最右）

    final gapGroup = groupNameLeft - stripRight;
    final gapMine = myAvatarLeft - myNameRight;
    expect(gapGroup, closeTo(gapMine, 2),
        reason: '头像条↔群名的视觉间距应与"我的名字↔我的头像"一致'
            '（实测 gapGroup=$gapGroup gapMine=$gapMine）');
    // 冲掉弹窗 controller 延迟 dispose 的 400ms 计时器（同上）
    await tester.pump(const Duration(milliseconds: 450));
  });

  testWidgets('还没人加入：最左侧显示群组头像占位（可点开「我的同伴」），编辑图标不顶边',
      (WidgetTester tester) async {
    // 老板 2026-10-09：没人加入时编辑图标/人数直接顶到状态条左缘之外；
    // 应在最左摆一个群组头像（与菜单「我的同伴」图标同款），且可点开成员弹层。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 0);

    final capsule = tester.getRect(_statusBar);

    // ① 群组头像占位在场（groups_outlined，与菜单「我的同伴」同款）
    final placeholder = find.descendant(
        of: _statusBar, matching: find.byIcon(Icons.groups_outlined));
    expect(placeholder, findsOneWidget);

    // ② 占位占满一个头像位（40）→ 编辑图标不再顶到胶囊左缘
    final editRect = tester.getRect(find.descendant(
        of: _statusBar, matching: find.byIcon(Icons.edit)));
    expect(editRect.left,
        greaterThanOrEqualTo(capsule.left + kStatusMemberAvatarSize - 1),
        reason: '编辑图标应排在头像占位右侧，不顶到胶囊边缘');

    // ③ 点占位 → 开「我的同伴」弹层
    await tester.tap(placeholder);
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageMembersTitle('group')), findsOneWidget,
        reason: '群组头像占位也应可点开「我的同伴」');
    await tester.pump(const Duration(milliseconds: 450)); // 冲掉弹层计时器
  });

  testWidgets('长群名用到接近中线才省略，整块不溢出（macOS 截图回归）',
      (WidgetTester tester) async {
    // 老板 2026-10-09：群名离状态条一半还很远就被截断。根因是名字列被
    // TextPainter 量出的宽**钉死**（量宽偏小 → 提前省略）。现在量宽只用于
    // 分头像预算，名字列拿"去掉头像条后剩下的全部宽度"。
    tester.view.physicalSize = const Size(960, 652);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _pump(tester, db, 3);

    const longName = '群群群群群群群群群群群群群群群群群群群群群群群群群群群群群群群群';
    await tester.tap(
        find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)));
    await tester.pumpAndSettle();
    await tester.enterText(_dialogField, longName);
    await tester.tap(find.text(_zh.chatPageRenamingSubmit));
    await tester.pumpAndSettle();

    final capsule = tester.getRect(_statusBar);
    final nameRect = tester.getRect(find.descendant(
        of: _statusBar, matching: find.textContaining('群')));
    final midline = capsule.left + capsule.width / 2;
    expect(nameRect.right, greaterThan(midline - 60),
        reason: '长群名应一直用到接近中线才省略（不再提前截断）');
    expect(nameRect.right, lessThanOrEqualTo(midline + 0.5),
        reason: '但也不该越过中线');
    // 冲掉弹窗 controller 延迟 dispose 的 400ms 计时器（同上）
    await tester.pump(const Duration(milliseconds: 450));
  });
}
