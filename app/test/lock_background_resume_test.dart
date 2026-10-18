// 回归：设 PIN 后「切后台超 30s → 回前台」必须弹覆盖锁屏。
//
// 背景（老板 2026-10-17 实测 bug）：原实现 `inactive` 也会 `recordBackgrounded`，
// 而 iOS 回前台序列 `paused → inactive → resumed` 里 `inactive` 会触发一次，
// 把后台开始时刻覆写成"刚回来" → `shouldRelock` 差值不足阈值 → 永不锁。
// 修复后只认 `paused`。
//
// 注意：`LockTimer` 读真实 `DateTime.now()`，widget 测试的假时钟推不动它，
// 所以这条用例必须 `runAsync` 真睡 31s 才能复现（约 +31s 测试耗时）。
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/lock_page.dart';
import 'package:einz_shared/einz_shared.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super('http://fake');
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    VaultSession.publish(null);
  });

  testWidgets(
      '设 PIN + 切后台超 30s 回前台 → 弹覆盖锁屏（inactive 覆写计时 bug 回归）',
      (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 老板的真实路径：向导跳过 PIN（明文包），后来在菜单里补设了 PIN
    final lock = AppLockService(db);
    final plain = AppLockPayload(
      spaceKeyB64: base64Encode(spaceKey),
      spaceId: 'space-demo',
      entranceId: 'dev-a',
      token: 'tok',
    );
    await lock.savePlain(plain);
    await lock.setPin('123456', payload: plain);
    expect(await lock.isSetup, true); // 确认锁包已就位（_hasPin 的来源）

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
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 _hasPin 刷新
    expect(find.byType(LockPage), findsNothing);

    // 真实生命周期序列：进后台（inactive→hidden→paused，Flutter 3.13 起出向
    // 是这个顺序）→ 真睡 31s 跨阈值 → 回前台（inactive→resumed）。关键：
    // 回程的 `inactive` 不可再把后台时刻覆写成"刚回来" → 否则不锁。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 31)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    // 必须弹覆盖锁屏，且严格锁（canDismiss=false，返回手势挡掉）
    expect(find.byType(LockPage), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets(
      'app 切换器路径（只到 inactive 不到 paused）超 30s → 回来也要锁',
      (tester) async {
    // 覆盖路径：iOS app 切换器/通知下拉只发 inactive，永远不会到 paused。
    // 只认 paused 的实现会漏掉这条路径（评审 2026-10-17）。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final lock = AppLockService(db);
    final plain = AppLockPayload(
      spaceKeyB64: base64Encode(spaceKey),
      spaceId: 'space-demo',
      entranceId: 'dev-a',
      token: 'tok',
    );
    await lock.savePlain(plain);
    await lock.setPin('123456', payload: plain);

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
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 进 app 切换器：只发 inactive → 真睡 31s → 直接回 resumed
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 31)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.byType(LockPage), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets(
      '回程 inactive（后台→inactive→resumed，中间隔 5s）→ 不锁（覆写 bug 不复发）',
      (tester) async {
    // 正常切后台几秒就回来（未超阈值）：inactive 回程覆写曾导致 shouldRelock
    // 差值不足 → 这里验证"短暂后台回来不锁"且后续不被误锁。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final lock = AppLockService(db);
    final plain = AppLockPayload(
      spaceKeyB64: base64Encode(spaceKey),
      spaceId: 'space-demo',
      entranceId: 'dev-a',
      token: 'tok',
    );
    await lock.savePlain(plain);
    await lock.setPin('123456', payload: plain);

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
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 完整出向序列 + 只离开 5s 回来（<30s）→ 不应锁
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 5)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.byType(LockPage), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
