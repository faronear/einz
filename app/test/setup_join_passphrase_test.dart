// join 接入口令验证回归测试：口令页必须是「验证」语义——
// 输入口令必须与首台设备创建时一致（解密 escrow 口令密保箱成功）才放行进 PIN 步骤；
// 错误口令提示并停留口令页（不得"随便输都能过"）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart';

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';

/// 假 escrow：口令匹配返回 payload，不匹配抛 FormatException（模拟 decryptBackup 失败），
/// payload 为 null 表示未托管。
class _FakeEscrow extends KeyEscrowService {
  _FakeEscrow(this.correctPass, this.payload) : super(ApiClient('http://fake'));

  final String correctPass;
  final EscrowPayload? payload;

  @override
  Future<EscrowPayload?> fetch({required String passphrase, required String token}) async {
    if (payload == null) return null;
    if (passphrase != correctPass) throw const FormatException('口令错误');
    return payload;
  }
}

/// 打开 join 向导并走到邀请码页（身份卡片自动进邀请码页）。
/// enroll 可注入错误 fake（模拟无效邀请码）；默认成功登记。
Future<void> pumpToJoinInvite(
  WidgetTester tester, {
  Future<EnrollResult> Function(String? inviteCode)? enroll,
  String correctPass = '正确口令-abc',
  EscrowPayload? payload,
}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, const {'personA': 'Lukas'}),
      enrollOverride: enroll ??
          (_) async =>
              const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
      authOverride: (kp, id) async =>
          SessionResult(sessionToken: 'tok', spaceId: 'space-test', expiresIn: 3600),
      escrowOverride: (server) => _FakeEscrow(correctPass, payload),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Lukas')); // 身份（自动进邀请码页）
  await tester.pumpAndSettle();
}

/// 走到口令页：邀请码页填码 → 下一步（验证邀请码）→ 口令页。
Future<void> pumpToJoinPassphrase(
  WidgetTester tester, {
  required String correctPass,
  EscrowPayload? payload,
}) async {
  await pumpToJoinInvite(tester, correctPass: correctPass, payload: payload);
  await tester.enterText(find.byType(TextField), 'INVITE-ABC'); // 邀请码
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle();
  // 口令页应为「验证」语义：标题与提示都是验证措辞
  expect(find.text('设置密保口令'), findsOneWidget); // 标题
  expect(find.text('对所有消息进行加密、解密。如还不知道口令，询问秘境伴侣。'),
      findsOneWidget); // hint
  // enroll 成功的 SnackBar 停留 4 秒：等其消失，避免遮挡底部「下一步」按钮
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  final payload =
      const EscrowPayload(spaceKeyB64: 'a2V5', spaceId: 'space-test', keyVersion: 1);

  testWidgets('错误口令：提示口令错误并停留口令页（不进入 PIN 页）', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: payload);
    await tester.enterText(find.byType(TextField), '随便输入的口令');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('口令错误：请确认首台设备创建时设置的口令'), findsOneWidget,
        reason: '错误口令必须被拦截并提示');
    expect(find.text('对所有消息进行加密、解密。如还不知道口令，询问秘境伴侣。'),
        findsOneWidget, reason: '应停留在口令页');
    expect(find.text('设置锁屏码'), findsNothing, reason: '不应进入 PIN 页');
  });

  testWidgets('正确口令：通过验证进入 PIN 页', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: payload);
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsWidgets, reason: '口令一致应放行进 PIN 步骤');
  });

  testWidgets('未托管口令（服务器无 escrow 包）：提示并停留', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: null);
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('对所有消息进行加密、解密。如还不知道口令，询问秘境伴侣。'),
        findsOneWidget, reason: '未托管时停留口令页');
  });

  testWidgets('错误邀请码：提示无效并停留邀请码页（不进口令页）', (WidgetTester tester) async {
    await pumpToJoinInvite(tester, enroll: (_) async => throw Exception('invite invalid'));
    await tester.enterText(find.byType(TextField), '错误邀请码');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('邀请码无效'), findsOneWidget, reason: '无效码必须被拦截并提示');
    expect(find.text('邀请码'), findsWidgets, reason: '应停留在邀请码页');
    expect(find.text('设置密保口令'), findsNothing, reason: '不应进入口令页');
  });

  testWidgets('正确邀请码：放行到「验证接入口令」页', (WidgetTester tester) async {
    await pumpToJoinInvite(tester); // 默认成功登记
    await tester.enterText(find.byType(TextField), '正确邀请码');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('设置密保口令'), findsOneWidget, reason: '有效码应放行进口令页');
  });
}
