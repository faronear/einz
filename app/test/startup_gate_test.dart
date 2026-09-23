// 启动门（StartupGate）回归测试——锁屏页的**唯一冷启动入口**：
// - 有锁包（设过 PIN）→ 进锁屏页，且是严格锁屏（canDismiss=false：返回被挡）
// - 无锁包 → **不进锁屏页**（老板 2026-09-20：没 PIN 就不该进锁屏页——
//   那页没有 PIN 时只会显示"尚未设置锁屏码"的死胡同，进去了既没意义也像故障）

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/lock_page.dart';
import 'package:einz/main.dart';
import 'package:einz/setup_page.dart';
import 'package:einz_shared/einz_shared.dart';

/// 启动门要等真实异步（drift 查询 + 安全存储）才出结果，且启动屏/检测页有无限
/// 动画 → 不能用 pumpAndSettle，用有限轮次的 pump 推进。
Future<void> _settleGate(WidgetTester tester) async {
  for (var round = 0; round < 6; round++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }
}

Future<void> _pumpGate(WidgetTester tester, LocalDatabase db) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: StartupGate(db: db),
  ));
  await _settleGate(tester);
}

void main() {
  setUpAll(() async {
    await sodium(); // setPin 的 Argon2id/XChaCha20 需要 libsodium
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('无锁包：不进锁屏页（直接去设置页）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await _pumpGate(tester, db);

    expect(find.byType(LockPage), findsNothing,
        reason: '没设过 PIN 就不该进锁屏页——那页只会显示"尚未设置锁屏码"');
    expect(find.text('尚未设置锁屏码（为空时不启用）'), findsNothing);
    expect(find.byType(SetupPage), findsOneWidget, reason: '无锁包且无明文配置 → 走设置向导');
  });

  testWidgets('已设 PIN：进锁屏页且返回被挡（canDismiss=false）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await AppLockService(db).setPin('123456',
        payload: const AppLockPayload(
          spaceKeyB64: 'dGhlLXNwYWNlLWtleQ==',
          spaceId: 'space-test',
          entranceId: 'dev-a',
          keyVersion: 1,
          token: 'tok-123',
        ));

    await _pumpGate(tester, db);

    expect(find.byType(LockPage), findsOneWidget, reason: '有锁包 → 冷启动进锁屏页');
    expect(find.byType(SetupPage), findsNothing);
    // 严格锁屏：无返回箭头 + PopScope 挡返回（冷启动入口与对话页两个入口同口径）
    expect(find.byType(BackButton), findsNothing);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, false);
  });
}
