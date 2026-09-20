// LockPage 锁屏语义回归测试：
// 1) 未设置 PIN（无锁包）：锁屏不激活——显示提示，不显示解锁表单，
//    避免"无法解锁、跳不出去"的死锁（老板决策：PIN 锁屏仅当 PIN 非空才激活）。
// 2) 已设 PIN + canDismiss=false（冷启动 / 顶栏手动锁屏 / 切后台超时自动锁三个
//    入口的口径）：返回箭头与返回手势都被挡，只能输对 PIN 出去（老板 2026-09-20
//    实测：此前冷启动与自动锁两条漏了，一点返回箭头就绕过锁屏）。
// 3) canDismiss=false 不挡"输对 PIN 后正常出去"——别把解锁的路一起堵死。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/brand_logo.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/lock_page.dart';
import 'package:einz_shared/einz_shared.dart';

import 'real_async_settle.dart';

/// 覆盖锁屏 push 到一层假主页之上（冷启动以外两个入口的真实栈结构）。
Future<void> _pushLockPage(
  WidgetTester tester,
  LocalDatabase db, {
  required bool canDismiss,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Builder(builder: (context) {
      return Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LockPage(db: db, asOverlay: true, canDismiss: canDismiss))),
            child: const Text('下层页'),
          ),
        ),
      );
    }),
  ));
  await tester.tap(find.text('下层页'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await sodium(); // setPin/unlock 的 Argon2id/XChaCha20 需要 libsodium
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('未设置 PIN（无锁包）：锁屏不激活，显示提示且无解锁表单', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: LockPage(db: db),
    ));
    await tester.pumpAndSettle();

    // 无锁包 → 显示"未设置 PIN 锁屏"提示（不激活锁屏）
    expect(find.text('尚未设置锁屏码（为空时不启用）'), findsOneWidget);
    // 不显示解锁输入框与解锁按钮（避免死锁）
    expect(find.byType(TextField), findsNothing);
    expect(find.text('解锁'), findsNothing);
    // Logo 只在标题栏左侧（与其他页面一致）：页面中间不再放大 Logo
    final logos = tester.widgetList<BrandLogo>(find.byType(BrandLogo)).toList();
    expect(logos.length, 1);
    expect(logos.single.size, 28, reason: '只剩标题栏 28 的小 Logo，中间 72 的大图已移除');
  });

  testWidgets('未设置 PIN + canDismiss=false：兜底提示页不被 PopScope 挡（不死锁）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 生产路径不会走到（无 PIN 就不进锁屏页），但兜底必须仍然能退
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: LockPage(db: db, canDismiss: false),
    ));
    await tester.pumpAndSettle();

    expect(find.text('尚未设置锁屏码（为空时不启用）'), findsOneWidget);
    // 死锁判据：提示页不应套 PopScope（否则返回键/手势全被吞，退不出去也解锁不了）
    expect(find.byType(PopScope), findsNothing);
  });

  testWidgets('已设 PIN + canDismiss=false：无返回箭头、返回被挡', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await AppLockService(db).setPin('123456',
        payload: const AppLockPayload(
          spaceKeyB64: 'dGhlLXNwYWNlLWtleQ==',
          spaceId: 'space-test',
          deviceId: 'dev-a',
          keyVersion: 1,
          token: 'tok-123',
        ));

    await _pushLockPage(tester, db, canDismiss: false);

    // 锁屏已激活：有解锁表单
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('解锁'), findsOneWidget);
    // 严格锁屏：不显示返回箭头（留着点了也被挡，只会误导）
    expect(find.byType(BackButton), findsNothing);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, false);
  });

  testWidgets('已设 PIN + canDismiss=true（对照）：返回箭头可点，能不输 PIN 退出',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await AppLockService(db).setPin('123456',
        payload: const AppLockPayload(
          spaceKeyB64: 'dGhlLXNwYWNlLWtleQ==',
          spaceId: 'space-test',
          deviceId: 'dev-a',
          keyVersion: 1,
          token: 'tok-123',
        ));

    await _pushLockPage(tester, db, canDismiss: true);

    expect(find.byType(BackButton), findsOneWidget, reason: '旧语义：允许手势/返回键退回');
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, true);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('下层页'), findsOneWidget, reason: '旧语义下不输 PIN 就能回聊天');
    expect(find.byType(LockPage), findsNothing);
  });

  testWidgets('已设 PIN + canDismiss=false：输对 PIN 仍可正常解锁回上一层', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await AppLockService(db).setPin('123456',
        payload: const AppLockPayload(
          spaceKeyB64: 'dGhlLXNwYWNlLWtleQ==',
          spaceId: 'space-test',
          deviceId: 'dev-a',
          keyVersion: 1,
          token: 'tok-123',
        ));

    await _pushLockPage(tester, db, canDismiss: false);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('解锁'));
    // 解锁走真实异步（Argon2id 解包），假时钟推不动 → 交替泵帧
    await settleRealAsync(tester);

    expect(find.byType(LockPage), findsNothing, reason: '严格锁屏挡的是返回，不是解锁');
    expect(find.text('下层页'), findsOneWidget);
  });
}
