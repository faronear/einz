// 回归：本机**已经有这个秘境**时，不允许再走一遍加入向导。
//
// 背景（老板 2026-09-23 报的 bug）：同一个 spaceId 再走一遍向导不是"加第二条通道"，而是把
// 原有那条 upsert **顶替**掉——旧通道的凭证消失、本地消息却被新通道继承，而服务端并不
// 知情、旧通道也没退役（既丢数据又在服务端留孤儿）。一台设备对一个秘境只存一条通道
// （Vault 按 spaceId 存一份凭证），所以重复添加必须拦。
//
// 拦点在 `_verifyJoinToken`：preflight 之后（此时才知道目标 spaceId）、**消费一次性
// 之前**（被拒绝的开通码还能发给别的设备用，且没有任何服务端副作用）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart';

import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';

const _dupMessage = '这个秘境已经添加过了（一台设备只能有一条通道到同一个秘境）';

/// 打开 join 向导并停在「验证开通码」页（入口页 → 加入）。
Future<void> _pumpToJoinToken(WidgetTester tester, LocalDatabase db) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, 'v2-multiverse', const <String>[]),
      preflightOverride: (token) async => const SpaceJoinPreflight(
          spaceId: 'space-test',
          status: 'waiting',
          memberCount: 1,
          slots: [
            SpaceMemberSlot(slot: 0, displayName: 'Lukas', gender: 'male', status: 'active'),
            SpaceMemberSlot(slot: 1, displayName: 'Alice', gender: 'female', status: 'pending'),
          ]),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('加入秘境'));
  await tester.pumpAndSettle();
}

Future<void> _submitToken(WidgetTester tester, String token) async {
  await tester.enterText(find.byType(TextField), token);
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle();
}

LocalDatabase _newDb() {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  setUpAll(() async {
    await sodium(); // 向导会自动建钥，需要 libsodium
  });

  // 解锁态是**进程级静态**，逐用例复位，免得串味
  setUp(() => VaultSession.publish(null));

  testWidgets('Spaces 表里已有该 spaceId → 拦下并提示，不进身份选择页', (WidgetTester tester) async {
    final db = _newDb();
    await db.into(db.spaces).insert(SpacesCompanion.insert(spaceId: 'space-test'));

    await _pumpToJoinToken(tester, db);
    await _submitToken(tester, 'TOKEN-DUP');

    expect(find.text(_dupMessage), findsOneWidget, reason: '必须给出「已添加过」的红字');
    expect(find.text('验证开通码'), findsWidgets, reason: '应停留在开通码页');
    expect(find.text('选择身份'), findsNothing, reason: '不得放行进下一步');
  });

  testWidgets('内存 Vault 里已有该 spaceId → 同样拦下（权威来源）', (WidgetTester tester) async {
    final db = _newDb();
    VaultSession.publish(const VaultPayload(spaces: [
      AppLockPayload(
        spaceKeyB64: 'a2V5',
        spaceId: 'space-test',
        entranceId: 'dev-a',
        keyVersion: 1,
        token: 'tok-a',
      ),
    ]));

    await _pumpToJoinToken(tester, db);
    await _submitToken(tester, 'TOKEN-DUP');

    expect(find.text(_dupMessage), findsOneWidget);
    expect(find.text('选择身份'), findsNothing);
  });

  testWidgets('本机没有该秘境 → 照常放行（别误伤正常加入）', (WidgetTester tester) async {
    final db = _newDb();

    await _pumpToJoinToken(tester, db);
    await _submitToken(tester, 'TOKEN-OK');

    expect(find.text(_dupMessage), findsNothing, reason: '没添加过就不该报错');
    expect(find.text('选择身份'), findsOneWidget, reason: '没添加过就该照常放行');
  });
}
