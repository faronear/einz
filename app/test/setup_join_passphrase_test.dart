// join 接入口令验证回归测试：口令页必须是「验证」语义——
// 输入口令必须与首台设备创建时一致（解密 escrow 托管包成功）才放行进 PIN 步骤；
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

/// 打开 join 向导并走到口令页（身份卡片自动进邀请码页 → 填邀请码 → 口令页）。
Future<void> pumpToJoinPassphrase(
  WidgetTester tester, {
  required String correctPass,
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
      enrollOverride: (_) async =>
          const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
      authOverride: (kp, id) async =>
          SessionResult(sessionToken: 'tok', spaceId: 'space-test', expiresIn: 3600),
      escrowOverride: (server) => _FakeEscrow(correctPass, payload),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining('第一个用户（创建者）')); // 身份（自动进邀请码页）
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'INVITE-ABC'); // 邀请码
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle();
  // 口令页应为「验证」语义
  expect(find.text('验证接入口令：输入首台设备创建时设置的口令，必须完全一致才能加入'),
      findsOneWidget);
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
    expect(find.text('验证接入口令：输入首台设备创建时设置的口令，必须完全一致才能加入'),
        findsOneWidget, reason: '应停留在口令页');
    expect(find.text('设置启动锁'), findsNothing, reason: '不应进入 PIN 页');
  });

  testWidgets('正确口令：通过验证进入 PIN 页', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: payload);
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('设置启动锁'), findsWidgets, reason: '口令一致应放行进 PIN 步骤');
  });

  testWidgets('未托管口令（服务器无 escrow 包）：提示并停留', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: null);
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('验证接入口令：输入首台设备创建时设置的口令，必须完全一致才能加入'),
        findsOneWidget, reason: '未托管时停留口令页');
  });
}
