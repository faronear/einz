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

/// 走到信封页：入口页 → 加入 → token（preflight）→ 名字 → 口令页 → 切「改用线下密保信封」。
Future<void> pumpToEnvelope(WidgetTester tester, {required DeviceKeyPair kp}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, 'v2-multiverse', const <String>[]),
      // Multiverse join：token 校验（preflight）用 fake
      preflightOverride: (token) async => const SpaceJoinPreflight(
          spaceId: 'space-test', displayName: 'Lukas', status: 'waiting', memberCount: 1,
          slots: [
            SpaceMemberSlot(slot: 0, displayName: 'Lukas', gender: 'male', status: 'active'),
            SpaceMemberSlot(slot: 1, displayName: 'Alice', gender: 'female', status: 'pending'),
          ]),
      enrollOverride: (_) async =>
          const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
      authOverride: (kp, id) async =>
          SessionResult(sessionToken: 'tok', spaceId: 'space-test', expiresIn: 3600),
      keyPairOverride: kp,
    ),
  ));
  await tester.pumpAndSettle();
  // Multiverse join：入口页 → 加入 → token（preflight 通过）→ 身份选择 → 口令页
  await tester.tap(find.text('加入秘境'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'TOKEN-1'); // token
  await tester.tap(find.text('下一步')); // 首次：preflight 校验 → 空间确认卡片（停留）
  await tester.pumpAndSettle();
  await tester.tap(find.text('下一步')); // 再次：放行到身份选择页
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('Alice')); // 选第二人（伴侣）
  await tester.pumpAndSettle();
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle(); // → 口令页
  await tester.tap(find.byIcon(Icons.mail_outline)); // 口令页 → 信封页（标题行右上角切换图标）
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

  testWidgets('信封页「下一步」回到 join 口令页（不验证信封推进）', (WidgetTester tester) async {
    await pumpToEnvelope(tester, kp: kp);
    // 信封页不管输入什么（甚至为空），「下一步」都应回到 join 口令页
    await tester.enterText(find.byType(TextField), '随便粘贴的内容');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('验证密保口令'), findsOneWidget, reason: '应回到 join 口令页');
    expect(find.text('解析密保信封'), findsNothing, reason: '不应停留在信封页');
  });

  testWidgets('信封页「改用线上密保口令」回到口令页（互切保留已填值）', (WidgetTester tester) async {
    await pumpToEnvelope(tester, kp: kp);
    await tester.tap(find.byIcon(Icons.password)); // 信封页 → 口令页（右上角切换图标）
    await tester.pumpAndSettle();
    expect(find.text('验证密保口令'), findsOneWidget, reason: '应回到口令页（join 验证标题）');
    expect(find.byIcon(Icons.mail_outline), findsOneWidget, reason: '口令页应仍可再切回信封');
  });

  testWidgets('信封页「上一步」可点：回到 join 口令页', (WidgetTester tester) async {
    await pumpToEnvelope(tester, kp: kp);
    // 信封页「上一步」不应禁用：点击回到 join 口令页（步骤 3，信封入口所在位置）
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('验证密保口令'), findsOneWidget, reason: '上一步应回到 join 口令页（验证密保口令标题）');
    expect(find.byType(TextField), findsOneWidget, reason: '口令输入框应可见');
    expect(find.text('解析密保信封'), findsNothing, reason: '不应停留在信封页');
  });
}
