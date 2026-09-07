// offline 密钥信封验证回归测试：信封页（步骤 1）必须即时验证信封——
// 用本设备私钥解封成功（得到合法 Space Key）才放行进 PIN 步骤；
// 无效信封提示并停留信封页（不得"随便输入都能过"）。

import 'dart:convert'; // base64Encode
import 'dart:typed_data'; // Uint8List

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart'; // sodium() 由 einZ_shared re-export

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';

/// 走到信封页：join 身份（自动进邀请码页）→ 邀请码 → 口令页 → 切「改用密封密钥信封导入」。
Future<void> pumpToEnvelope(WidgetTester tester, {required DeviceKeyPair kp}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, const {'personA': 'Lukas'}),
      enrollOverride: (_) async =>
          const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
      authOverride: (kp, id) async =>
          SessionResult(sessionToken: 'tok', spaceId: 'space-test', expiresIn: 3600),
      keyPairOverride: kp,
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('第一个用户（创建者）')); // 身份（自动进邀请码页）
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'INVITE-ABC'); // 邀请码
  await tester.tap(find.text('下一步')); // 邀请码验证 → 口令页
  await tester.pumpAndSettle();
  await tester.tap(find.text('改用密封密钥信封导入（离线）')); // 口令页 → 信封页
  await tester.pumpAndSettle();
}

void main() {
  late final DeviceKeyPair kp;

  setUpAll(() async {
    // 真实密钥对：sealFor/sealOpen 需要合法 x25519 密钥（全零 32B 仅可渲染不可加解密）
    kp = await DeviceKeyPair.generate(deviceId: 'dev1');
  });

  testWidgets('无效密钥信封：提示无效并停留信封页（不进入 PIN 页）', (WidgetTester tester) async {
    await pumpToEnvelope(tester, kp: kp);
    await tester.enterText(find.byType(TextField), '不是合法信封');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('密钥信封无效'), findsOneWidget, reason: '无效信封必须被拦截并提示');
    expect(find.text('导入密钥信封'), findsWidgets, reason: '应停留在信封页');
    expect(find.text('设置启动锁'), findsNothing, reason: '不应进入 PIN 页');
  });

  testWidgets('有效密钥信封：解封成功放行到 PIN 页', (WidgetTester tester) async {
    final s = await sodium();
    final envelope = await sealFor(s, kp.publicKey, Uint8List(32)); // Space Key 32B
    await pumpToEnvelope(tester, kp: kp);
    await tester.enterText(find.byType(TextField), base64Encode(envelope));
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('设置启动锁'), findsWidgets, reason: '有效信封应放行到 PIN 步骤');
  });
}
