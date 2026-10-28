// 自愿退群（2026-10-19，aimemo/20261019_groupExitDesign.md）App 侧流程回归：
//  ① **名单/计数口径**：成员弹层只列在册成员（墓碑不列），退出者不占人数；
//  ② **完整退群链**：弹层 →「退出群组」红字项 → 确认闸门（群组名）→
//     leaveSpace 调对空间 → 本地清理 → 导航收尾（仅一个空间 → 回向导）；
//  ③ **失败不清本地**：leaveSpace 抛错 → 顶部报错、留在群里。
//
// 文案断言一律从 l10n 取（改文案不弄红测试）。

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/attachment_store.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';
import 'package:einz_shared/einz_shared.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

/// 媒体缓存/留存明文的临时目录（setUp 里建，tearDown 里删）。
Directory? tempDir;

Finder get _statusBar => find.byKey(const ValueKey('chatPageStatusBar'));

/// 弹窗里的输入框（聊天页底部另有个消息输入框，必须限定在 AlertDialog 内）。
Finder get _dialogField => find.descendant(
    of: find.byType(AlertDialog), matching: find.byType(TextField));

/// 人数是 `Text.rich`（`find.text` 匹配不到），按 textSpan 纯文本匹配。
Finder _countFinder(String plain) =>
    find.byWidgetPredicate((w) => w is Text && w.textSpan?.toPlainText() == plain);

/// 最小 fake：一个 group 空间——我 + 两个在册成员 + 一个**墓碑成员**（Gone，
/// status='left'：退出者。名字仍在表里——历史消息解析用，但名单/计数不该有他）。
class _ExitApi extends ApiClient {
  _ExitApi({this.leaveShouldFail = false}) : super('http://fake');

  final bool leaveShouldFail;

  /// leaveSpace 调用记录（spaceId）——断言"调对了空间、只调了一次"。
  final List<String> leaveCalls = [];

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-demo',
        entrances: const [
          SpaceEntrance(
              entranceId: 'dev-o0', memberId: 'member-o0', status: 'active'),
          SpaceEntrance(
              entranceId: 'dev-o1', memberId: 'member-o1', status: 'active'),
        ],
        memberNames: {
          'member-me': 'Lukas',
          'member-o0': 'Alice',
          'member-o1': 'Bob',
          'member-gone': 'Gone', // 墓碑保名（历史消息"谁说的"不丢）
        },
        memberGenders: const {
          'member-me': 'male',
          'member-o0': 'female',
          'member-o1': 'male',
          'member-gone': 'female',
        },
        memberSlots: const {
          'member-me': 0,
          'member-o0': 1,
          'member-o1': 2,
          'member-gone': 3,
        },
        // 退群配套：active 两个 + 墓碑一个（老服务端不下发 → 空表 = 无墓碑）
        memberStatus: const {
          'member-me': 'active',
          'member-o0': 'active',
          'member-o1': 'active',
          'member-gone': 'left',
        },
        mode: 'group',
        maxMembers: 0,
      );

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => const [
        {'entrance_id': 'dev-o0', 'member_id': 'member-o0', 'connected_at': 1000},
        {'entrance_id': 'dev-o1', 'member_id': 'member-o1', 'connected_at': null},
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

  @override
  Future<void> leaveSpace(String spaceId, String token) async {
    if (leaveShouldFail) {
      throw ApiException('LEAVE_FAILED', 'server said no', 500);
    }
    leaveCalls.add(spaceId);
  }
}

/// 让**真实异步**在 widget 测试里跑完（同 real_async_settle.dart 的手法）：
/// 退群链的 removeSpace 要清媒体缓存/留存明文——path_provider / 'einz/store'
/// 两条 mock 通道 + dart:io 目录操作全是真实异步，且 `runAsync` 期间不能 pump，
/// 必须交替多轮。以「回向导」为完成条件（没导航成功就推满 40 轮）。
/// SetupPage 出现后再推几帧：pushAndRemoveUntil 的旧路由退场动画（约 300ms）
/// 期间 ChatPage 仍在树里，不推完断言"已退场"会闪。
/// **不 pumpAndSettle**：SetupPage 带常驻动画，settle 不了一样超时。
Future<void> _settleUntilWizard(WidgetTester tester) async {
  for (var round = 0; round < 40; round++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    if (find.byType(SetupPage).evaluate().isNotEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<({LocalDatabase db, _ExitApi api})> _pump(
  WidgetTester tester, {
  bool leaveShouldFail = false,
  String groupName = '测试群',
}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  // 群组名是退出确认的因子（仅本机存储）——预置一份
  await AppLockService(db).saveProfile(
    spaceId: 'space-demo',
    memberName: 'Lukas',
    peerName: '',
    entranceName: 'iPhone',
    groupName: groupName,
  );
  final api = _ExitApi(leaveShouldFail: leaveShouldFail);
  final spaceKey = await generateSpaceKey();
  // 单空间 Vault：退出后 resolveActivePayload 取不到下一个 → 回向导
  VaultSession.publish(VaultPayload(
    spaces: [
      AppLockPayload(
        spaceKeyB64: base64Encode(spaceKey),
        spaceId: 'space-demo',
        entranceId: 'dev-me',
        token: 'tok',
      ),
    ],
    activeSpaceId: 'space-demo',
  ));
  addTearDown(() => VaultSession.publish(null));
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
      api: api,
      enableWs: false,
      memberId: 'member-me',
      memberName: 'Lukas',
      entranceName: 'iPhone',
      peerName: '',
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300)); // /space + /entrances
  await tester.pumpAndSettle();
  return (db: db, api: api);
}

/// 点状态条胶囊（群名）打开「我的群组」弹层。群名未设置时胶囊里只有编辑图标，
/// 点它同样打开（与 group_status_bar_test 的走位一致）。
Future<void> _openMembersSheet(WidgetTester tester, {String groupName = '测试群'}) async {
  if (groupName.isEmpty) {
    await tester.tap(find.descendant(of: _statusBar, matching: find.byIcon(Icons.edit)));
  } else {
    await tester.tap(find.descendant(of: _statusBar, matching: find.text(groupName)));
  }
  await tester.pumpAndSettle();
  expect(find.text(_zh.chatPageMembersTitle('group')), findsOneWidget,
      reason: '点群名胶囊应打开「我的群组」弹层');
}

/// 弹层 →「退出群组」→ 确认闸门（输入群组名 / 未命名时输确认词）→ 点确认。
/// 之后按 [expectSuccess] 分流 settle：成功链要清本地（十几次真实异步跳转，
/// 见 [_settleUntilWizard]）；失败链只弹顶部通知，几轮就够。
Future<void> _tapExitAndConfirm(WidgetTester tester,
    {required bool expectSuccess, String confirmWord = '测试群'}) async {
  await tester.tap(find.text(_zh.exitGroupMenuItem));
  await tester.pumpAndSettle();
  // 红字项 onTap = 收弹层 + _menuAction（300ms route 交接）
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  expect(find.text(_zh.exitGroupTitle), findsOneWidget,
      reason: '应弹出退出确认闸门（群组名 + 禁误触关闭）');
  await tester.enterText(_dialogField, confirmWord);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, _zh.exitGroupConfirm));
  if (expectSuccess) {
    await _settleUntilWizard(tester);
  } else {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pumpAndSettle();
  }
}

void main() {
  setUpAll(() async {
    await sodium(); // generateSpaceKey 需要 libsodium
  });

  // removeSpace 的本地清理要删媒体缓存/留存明文目录（MediaCache 走
  // path_provider、AttachmentStore 走自定义 'einz/store'）——测试环境没有原生
  // 实现，不 mock 这两条通道清理链会永远挂住（同 attachment_store_test 手法）。
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('einz_exit_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('einz/store'),
      (call) async =>
          call.method == 'getStoredDir' ? tempDir!.path : null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getTemporaryDirectory' ? tempDir!.path : null,
    );
    AttachmentStore.resetForTest();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('einz/store'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), null);
    AttachmentStore.resetForTest();
    if (tempDir != null && tempDir!.existsSync()) {
      tempDir!.deleteSync(recursive: true);
    }
    tempDir = null;
  });

  testWidgets('成员弹层只列在册成员：墓碑（Gone）不列、不占人数', (tester) async {
    await _pump(tester);

    await _openMembersSheet(tester);

    // 在册成员在列（**限定在成员弹层内**：状态条头像条 2026-10-20 起也显示
    // 成员名字标签，全局 find.text 会撞成两个——同 group_status_bar_test 口径）
    // 弹层内容根（2026-10-25 起「只滚成员列表」，外层无
    // SingleChildScrollView，改用定位 key）
    final sheet = find.byKey(const ValueKey('membersSheet'));
    expect(find.descendant(of: sheet, matching: find.text('Alice')),
        findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Bob')),
        findsOneWidget);
    // 墓碑成员不在列（名字保住了，但人已经退出——服务端 member_status='left'）
    expect(find.text('Gone'), findsNothing,
        reason: '退出者不该再出现在成员名单里');
    // 「其他人在线/总数」= 1/2（不含我、不含墓碑）
    expect(_countFinder('1/2'), findsOneWidget,
        reason: '退出者不占名额：两个在册成员，一个在线');
    // 退出入口在（仅 group）
    expect(find.text(_zh.exitGroupMenuItem), findsOneWidget);
  });

  testWidgets('完整退群链：确认后 leaveSpace 调对空间、本地清理、回向导', (tester) async {
    final ctx = await _pump(tester);

    await _openMembersSheet(tester);
    await _tapExitAndConfirm(tester, expectSuccess: true);

    // ① 服务端退出：调了一次、空间 id 正确
    expect(ctx.api.leaveCalls, ['space-demo']);
    // ② 本地清理 + 导航收尾：只剩一个空间 → 回向导（ChatPage 已退场）
    expect(find.byType(ChatPage), findsNothing);
    expect(find.byType(SetupPage), findsOneWidget);
  });

  testWidgets('leaveSpace 失败 → 不清本地：顶部报错、留在群里', (tester) async {
    final ctx = await _pump(tester, leaveShouldFail: true);

    await _openMembersSheet(tester);
    await _tapExitAndConfirm(tester, expectSuccess: false);

    // 调过了（失败了），但本地数据不动、人还在群里
    expect(ctx.api.leaveCalls, isEmpty, reason: '失败的调用不应记录成功');
    expect(find.byType(ChatPage), findsOneWidget,
        reason: '失败必须留在群里（设计 §6.3：失败不清本地）');
    expect(find.text(_zh.exitGroupFailed), findsOneWidget,
        reason: '顶部通知如实告知退出失败');
  });

  testWidgets('群名未设置：闸门改要固定确认词（输错有确认词口径红字，输对方能通过）', (tester) async {
    final ctx = await _pump(tester, groupName: '');

    await _openMembersSheet(tester, groupName: '');
    await tester.tap(find.text(_zh.exitGroupMenuItem));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 提示必须是"确认词"口径，且 expected 与提示一致——否则用户无法通过
    // （老板 2026-10-19 实测：原来写"请输入群组名称「重置」"，而重置不是群名）
    expect(
        find.text(_zh.exitGroupConfirmWordHint(_zh.exitGroupConfirmWord)),
        findsOneWidget);
    // 输错 → 确认词口径的红字（不是"请输入正确的群组名称"）
    await tester.enterText(_dialogField, '测试群');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, _zh.exitGroupConfirm));
    await tester.pumpAndSettle();
    expect(find.text(_zh.exitGroupConfirmWordMismatch), findsOneWidget,
        reason: '输错时报确认词口径的红字');
    expect(find.byType(ChatPage), findsOneWidget, reason: '闸门没过 → 留在群里');
    // 输对（固定确认词）→ 通过，走完整退群链
    await tester.enterText(_dialogField, _zh.exitGroupConfirmWord);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, _zh.exitGroupConfirm));
    await _settleUntilWizard(tester);

    expect(ctx.api.leaveCalls, ['space-demo']);
    expect(find.byType(ChatPage), findsNothing);
    expect(find.byType(SetupPage), findsOneWidget);
  });
}
