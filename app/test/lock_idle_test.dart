// 回归：设 PIN 后，前台闲置超过默认锁屏时长（无点/滑/打字）必须弹覆盖锁屏。
//
// 实现（chat_page.dart _armIdleLock）：一次性 Timer 每次交互重排到
// "现在+kLockSeconds"，Timer 由测试的 FakeAsync 逻辑时钟驱动，所以这里直接
// tester.pump 推进即可，无需 runAsync 实睡（对比 lock_background_resume_test）。
// 时长全部以 kLockSeconds 表达（默认 60s，2026-10-27 由 30 秒改来），默认值
// 再调也不破测试。
//
// 覆盖三个场景：
// 1. 闲置到阈值 → 弹严格锁屏（canDismiss=false，无返回箭头）；
// 2. 闲置中有交互（pointer 事件）→ 重排，不锁；
// 3. 没设 PIN → 永不锁。
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/lock_timer.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/lock_page.dart';
import 'package:einz_shared/einz_shared.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super('http://fake');
}

Future<LocalDatabase> _pumpChat(WidgetTester tester,
    {required bool withPin}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  final spaceKey = await generateSpaceKey();
  if (withPin) {
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
  }
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
  return db;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    VaultSession.publish(null);
  });

  testWidgets('前台闲置达到默认时长 → 弹严格锁屏', (tester) async {
    final db = await _pumpChat(tester, withPin: true);
    addTearDown(db.close);
    expect(find.byType(LockPage), findsNothing);

    // 闲置到阈值前一瞬：不锁
    await tester.pump(Duration(seconds: kLockSeconds - 1));
    expect(find.byType(LockPage), findsNothing);
    // 跨过阈值：锁
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(LockPage), findsOneWidget);
    expect(find.byType(BackButton), findsNothing); // 严格锁：无返回箭头
  });

  testWidgets('闲置中有交互 → 计时重排，不锁', (tester) async {
    final db = await _pumpChat(tester, withPin: true);
    addTearDown(db.close);

    // 闲置半程时点一下屏幕（任意位置，根 Listener 收到）→ 计时重排
    await tester.pump(Duration(seconds: kLockSeconds ~/ 2));
    await tester.tap(find.byType(ChatPage), warnIfMissed: false);
    await tester.pump();
    // 再过一个整程（距上次交互仅半程 < 阈值）：不锁
    await tester.pump(Duration(seconds: kLockSeconds ~/ 2));
    expect(find.byType(LockPage), findsNothing);
    // 距上次交互阈值+1s：锁
    await tester.pump(const Duration(seconds: kLockSeconds ~/ 2 + 1));
    await tester.pumpAndSettle();
    expect(find.byType(LockPage), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('没设 PIN → 闲置再久也不锁', (tester) async {
    final db = await _pumpChat(tester, withPin: false);
    addTearDown(db.close);

    await tester.pump(const Duration(seconds: 65));
    await tester.pumpAndSettle();
    expect(find.byType(LockPage), findsNothing);
  });
}
