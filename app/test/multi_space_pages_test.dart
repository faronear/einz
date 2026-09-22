// 多空间页面测试（M2）：启动门分支 + 空间列表渲染与删除。
//
// 聊天页本身的重活（WS/同步）不在这里拉起——只验证"落点对不对"，
// 交互细节由真机自测（老板 2026-09-13 的 UI 验证分工）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/main.dart';
import 'package:einz/setup_page.dart';
import 'package:einz/space_list_page.dart';

const _payloadA = AppLockPayload(
  spaceKeyB64: 'a2V5LWE=',
  spaceId: 'space-a',
  deviceId: 'dev-a',
  token: 'tok-a',
);
const _payloadB = AppLockPayload(
  spaceKeyB64: 'a2V5LWI=',
  spaceId: 'space-b',
  deviceId: 'dev-b',
  token: 'tok-b',
);

Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 6; round++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: home,
    );

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('启动门：多空间 → 落点是空间列表（不是向导）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall(); // 否则启动门会按"全新安装"清掉安全存储
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);

    await tester.pumpWidget(_app(StartupGate(db: db)));
    await _settle(tester);

    expect(find.byType(SpaceListPage), findsOneWidget, reason: '两个空间 → 先给列表');
    expect(find.byType(SetupPage), findsNothing);
  });

  testWidgets('空间列表：显示两个空间（名字取 Spaces 行），长按删除后只剩一个',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall(); // 否则启动门会按"全新安装"清掉安全存储
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    await lock.saveProfile(spaceId: 'space-a', personName: '我A', peerName: '对方A', deviceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-b', personName: '我B', peerName: '对方B', deviceName: 'iPhone');

    final vault = (await lock.loadVault())!;
    await tester.pumpWidget(_app(SpaceListPage(vault: vault, db: db)));
    await _settle(tester);

    expect(find.text('对方A'), findsOneWidget);
    expect(find.text('对方B'), findsOneWidget);

    // 长按第一个 → 二次确认 → 移除
    await tester.longPress(find.text('对方A'));
    await tester.pumpAndSettle();
    expect(find.text('移除'), findsOneWidget, reason: '应弹出二次确认');
    await tester.tap(find.text('移除'));
    await _settle(tester);

    expect(find.text('对方A'), findsNothing);
    expect(find.text('对方B'), findsOneWidget);
    expect((await lock.loadVault())!.spaces.map((s) => s.spaceId), ['space-b']);
  });
}
