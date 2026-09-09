// offline 密保信封页回归测试：信封页（步骤 1）的出口行为——
// 1)「下一步」= 回到前面的邀请码页（join 步骤 2），重走登记流程
//    （老板 2026-09-09 决策：信封页不再验证信封推进，由邀请码入口承担登记）；
// 2)「改用线上密保口令」= 回到口令页，口令⇄信封自由互切。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart'; // sodium() 由 einZ_shared re-export

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';

/// 走到信封页：join 身份（自动进邀请码页）→ 邀请码 → 口令页 → 切「改用线下密保信封」。
Future<void> pumpToEnvelope(WidgetTester tester, {required DeviceKeyPair kp}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, const {'personA': 'Lukas'}, const <String, String>{}),
      enrollOverride: (_) async =>
          const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
      authOverride: (kp, id) async =>
          SessionResult(sessionToken: 'tok', spaceId: 'space-test', expiresIn: 3600),
      keyPairOverride: kp,
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Lukas')); // 身份（自动进邀请码页）
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'INVITE-ABC'); // 邀请码
  await tester.tap(find.text('下一步')); // 邀请码验证 → 口令页
  await tester.pumpAndSettle();
  await tester.tap(find.text('改用线下密保信封')); // 口令页 → 信封页
  await tester.pumpAndSettle();
  // enroll 成功的 SnackBar 停留 4 秒：等其消失，避免遮挡底部「下一步」按钮
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  late final DeviceKeyPair kp;

  setUpAll(() async {
    // 真实密钥对：向导 keyPairOverride 需要合法 x25519 密钥
    kp = await DeviceKeyPair.generate(deviceId: 'dev1');
  });

  testWidgets('信封页「下一步」回到邀请码页（不验证信封推进）', (WidgetTester tester) async {
    await pumpToEnvelope(tester, kp: kp);
    // 信封页不管输入什么（甚至为空），「下一步」都应回到邀请码页重走登记
    await tester.enterText(find.byType(TextField), '随便粘贴的内容');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('验证邀请码'), findsOneWidget, reason: '应回到邀请码页（验证邀请码标题）');
    expect(find.byType(TextField), findsOneWidget, reason: '邀请码输入框应可见');
    expect(find.text('密保信封'), findsNothing, reason: '不应停留在信封页');
  });

  testWidgets('信封页「改用线上密保口令」回到口令页（互切保留已填值）', (WidgetTester tester) async {
    await pumpToEnvelope(tester, kp: kp);
    await tester.tap(find.text('改用线上密保口令'));
    await tester.pumpAndSettle();
    expect(find.text('验证密保口令'), findsOneWidget, reason: '应回到口令页（join 验证标题）');
    expect(find.text('改用线下密保信封'), findsOneWidget, reason: '口令页应仍可再切回信封');
  });
}
