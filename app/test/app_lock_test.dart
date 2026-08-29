// AppLockService 单测：drift 内存库，验证 PIN 设置/解锁、错误计数锁定、恢复码兑底。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 shared 单测一致）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onlyspace/data/app_lock.dart';
import 'package:onlyspace/data/local_database.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

void main() {
  setUpAll(() async {
    await sodium();
  });

  late LocalDatabase db;
  late AppLockService lock;

  const payload = AppLockPayload(
    server: 'https://only.tic.cc',
    spaceKeyB64: 'dGhlLXNwYWNlLWtleQ==',
    spaceId: 'space-test',
    deviceId: 'dev-a',
    keyVersion: 1,
    token: 'tok-123',
  );

  setUp(() async {
    db = LocalDatabase.forTesting(NativeDatabase.memory());
    lock = AppLockService(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('设置 PIN 后 isSetup=true，正确 PIN 解锁返回原 payload', () async {
    expect(await lock.isSetup, false);
    final recovery = await lock.setPin('1234', payload: payload);
    expect(recovery.split(' ').length, 12, reason: '恢复码应为 12 词');

    expect(await lock.isSetup, true);
    final unlocked = await lock.unlock('1234');
    expect(unlocked.server, 'https://only.tic.cc');
    expect(unlocked.spaceKeyB64, 'dGhlLXNwYWNlLWtleQ==');
    expect(unlocked.spaceId, 'space-test');
    expect(unlocked.deviceId, 'dev-a');
    expect(unlocked.keyVersion, 1);
    expect(unlocked.token, 'tok-123');
  });

  test('错误 PIN 抛 AppLockException，且不影响后续正确 PIN', () async {
    await lock.setPin('1234', payload: payload);
    await expectLater(lock.unlock('9999'), throwsA(isA<AppLockException>()));
    final unlocked = await lock.unlock('1234');
    expect(unlocked.spaceId, 'space-test');
  });

  test('连续 5 次错误触发锁定：锁定期间正确 PIN 也被拒', () async {
    await lock.setPin('1234', payload: payload);
    for (var i = 0; i < 5; i++) {
      await expectLater(lock.unlock('0000'), throwsA(isA<AppLockException>()));
    }
    // 第 6 次（即使 PIN 正确）应被锁定拒绝
    await expectLater(lock.unlock('1234'), throwsA(isA<AppLockLockedException>()));
    expect(await lock.remainingLockSeconds, greaterThan(0));
  });

  test('恢复码兑底：PIN 丢失时用恢复码解锁成功，错误恢复码被拒', () async {
    final recovery = await lock.setPin('1234', payload: payload);
    // 用错误 PIN 触发锁定也无妨：恢复码不受锁定限制
    for (var i = 0; i < 5; i++) {
      await expectLater(lock.unlock('0000'), throwsA(isA<AppLockException>()));
    }
    await expectLater(
      lock.unlockWithRecovery('abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon'),
      throwsA(isA<AppLockException>()),
    );
    final unlocked = await lock.unlockWithRecovery(recovery);
    expect(unlocked.spaceKeyB64, 'dGhlLXNwYWNlLWtleQ==');
    // 解锁成功后锁定应被清除
    expect(await lock.remainingLockSeconds, 0);
  });
}
