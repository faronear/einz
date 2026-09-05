// AppLockService 单测：drift 内存库，验证 PIN 设置/解锁、错误计数锁定。
// 恢复码功能已按老板决策删除（不再生成/兑底）。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 shared 单测一致）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz_shared/einz_shared.dart';

void main() {
  setUpAll(() async {
    await sodium();
  });

  late LocalDatabase db;
  late AppLockService lock;

  const payload = AppLockPayload(
    server: 'https://einz.tic.cc',
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
    await lock.setPin('1234', payload: payload);

    expect(await lock.isSetup, true);
    final unlocked = await lock.unlock('1234');
    expect(unlocked.server, 'https://einz.tic.cc');
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

  test('clear：删除锁包后 isSetup=false，原 PIN 无法再解锁（设备撤销清理）', () async {
    await lock.setPin('1234', payload: payload);
    expect(await lock.isSetup, true);

    await lock.clear();
    expect(await lock.isSetup, false, reason: 'clear 后应回到未配置状态');
    await expectLater(lock.unlock('1234'), throwsA(isA<AppLockException>()),
        reason: '锁包已删，原 PIN 不应再能解锁');
  });
}
