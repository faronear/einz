// 回归：成员弹层「重新邀请」→ 口令验证之后**不应闪红屏**。
//
// 2026-10-05 老板 iOS 真机实测（两个坑叠在一起，修完第一个才露出第二个）：
//  ① 弹层 pop 之后**紧接着** showDialog → 两条 route 在 Overlay 里交叉卸载
//     （InheritedElement 断言 "check that it really is our descendant"）→ 整屏红屏，
//     不恢复。修法：错峰 300ms（`_waitRouteHandoff` / `_menuAction`）。
//  ② 口令弹窗的 TextEditingController **立即 dispose** → TextField 在**退出动画**
//     那几帧里向已销毁 controller 加 listener → 闪一下红屏**又自己恢复**。
//     修法：延迟 400ms dispose（与改名弹窗/设锁屏码弹窗同一手法）。
//
// 本测试跑完整流程（成员弹层 → 重新邀请 → 输口令 → 确认 → 通道码弹窗），
// 全程断言 `takeException()` 为 null——尤其是口令弹窗退出动画那几帧。

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

/// 最小 fake：只需把「本空间有两个成员」喂给页面，其余走空实现。
class _Api extends ApiClient {
  _Api() : super('http://fake');

  @override
  Future<SpaceResult> getSpace(String token) async => const SpaceResult(
        spaceId: 'space-demo',
        entrances: [],
        memberNames: {'member-me': 'Lukas', 'member-peer': 'Alice'},
        memberGenders: {'member-me': 'male', 'member-peer': 'female'},
        memberSlots: {'member-me': 0, 'member-peer': 1}, // 含未命名成员
        mode: 'duo',
        maxMembers: 0,
      );

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

void main() {
  // 菜单里的翻转沙漏是常驻动画，关掉免得 pumpAndSettle 超时。
  disableAnimationsInTests();

  testWidgets('成员弹层「重新邀请」→ 口令验证：全程不闪红屏', (WidgetTester tester) async {
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

    // 菜单 → 空间成员 → 卡片上的「重新邀请」
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tapDeferred(tester, find.text(_zh.chatPageMenuMembers('duo')));
    expect(find.text(_zh.chatPageMembersTitle('duo')), findsOneWidget, reason: '成员弹层应已打开');
    await tapDeferred(tester, find.text(_zh.chatPageMembersReinvite));

    // 口令弹窗
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

    // ① + ② 都在这一段里：口令弹窗退出动画 → 错峰 300ms → 通道码弹窗
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull,
          reason: '口令弹窗退出/衔接期间不应报错（真机上表现为闪一下红屏）');
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 最终应停在「重新邀请」的通道码弹窗上，且全程无异常
    expect(find.text(_zh.chatPageInviteDialogTitleReinvite), findsOneWidget,
        reason: '验证口令后应弹出通道码弹窗');
    expect(tester.takeException(), isNull);
  });
}
