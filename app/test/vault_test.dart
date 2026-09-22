// Vault（多空间凭证集合）单测：drift 内存库 + SecureStore 测试替身。
//
// 覆盖 aimemo/multiSpaceDesign.zhcn.md §7 的 1–4：
// 单→多→删除→activeSpace 切换、旧单 payload 归一、PIN 错误/锁定、Spaces 行同步。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 app_lock_test 一致）。

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/secure_store.dart';
import 'package:einz_shared/einz_shared.dart';

void main() {
  setUpAll(() async {
    await sodium();
  });

  late LocalDatabase db;
  late AppLockService lock;

  const payloadA = AppLockPayload(
    spaceKeyB64: 'a2V5LWE=',
    spaceId: 'space-a',
    deviceId: 'dev-a',
    keyVersion: 1,
    token: 'tok-a',
  );
  const payloadB = AppLockPayload(
    spaceKeyB64: 'a2V5LWI=',
    spaceId: 'space-b',
    deviceId: 'dev-b',
    keyVersion: 2,
    token: 'tok-b',
  );
  const payloadB2 = AppLockPayload(
    spaceKeyB64: 'a2V5LWI=',
    spaceId: 'space-b',
    deviceId: 'dev-b',
    keyVersion: 2,
    token: 'tok-b2',
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({}); // SecureStore（Keychain/Keystore）测试替身
    db = LocalDatabase.forTesting(NativeDatabase.memory());
    lock = AppLockService(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<String>> spaceIds() async =>
      (await db.select(db.spaces).get()).map((r) => r.spaceId).toList();

  group('旧单包归一', () {
    test('旧明文包（单个 payload JSON）读成单元素 Vault，active 指向它', () async {
      // 模拟 v7 之前写入的明文包：SecureStore 里是单独一个 AppLockPayload
      await SecureStore.write('app_lock.plain', '{"space_key":"a2V5LWE=","space_id":"space-a","device_id":"dev-a","key_version":1,"token":"tok-a"}');

      final vault = await lock.loadVault();
      expect(vault, isNotNull);
      expect(vault!.spaces.length, 1);
      expect(vault.activeSpaceId, 'space-a');
      expect(await lock.loadPlain(), isNotNull);
      expect((await lock.loadPlain())!.spaceId, 'space-a');
    });

    test('旧 PIN 密文包（单个 payload）解锁后归一为单元素 Vault', () async {
      await lock.setPin('123456', payload: payloadA);
      final vault = await lock.unlockVault('123456');
      expect(vault.spaces.map((s) => s.spaceId), ['space-a']);
      expect(vault.active!.token, 'tok-a');
    });

    test('VaultPayload.fromJson：结构不对抛 FormatException', () {
      expect(() => VaultPayload.fromJson({'foo': 1}), throwsA(isA<FormatException>()));
      expect(() => VaultPayload.fromJson('not a map'), throwsA(isA<FormatException>()));
    });
  });

  group('多空间增删与切换（明文 Vault）', () {
    test('addSpace 追加并置为 active；两个空间互不干扰', () async {
      await lock.savePlain(payloadA);
      await lock.addSpace(payloadB);

      final vault = (await lock.loadVault())!;
      expect(vault.spaces.map((s) => s.spaceId), ['space-a', 'space-b']);
      expect(vault.activeSpaceId, 'space-b');
      expect((await lock.loadPlain())!.spaceKeyB64, 'a2V5LWI=');

      await lock.setActiveSpace('space-a');
      expect((await lock.loadPlain())!.spaceKeyB64, 'a2V5LWE=');
    });

    test('同 spaceId 再次 addSpace 是覆盖，不产生重复项', () async {
      await lock.savePlain(payloadA);
      await lock.addSpace(payloadB);
      await lock.addSpace(payloadB2);

      final vault = (await lock.loadVault())!;
      expect(vault.spaces.length, 2);
      expect(vault.spaces.last.token, 'tok-b2');
    });

    test('removeSpace：只摘目标空间，其他空间与 active 仍可用', () async {
      await lock.savePlain(payloadA);
      await lock.addSpace(payloadB);
      await lock.removeSpace('space-b');

      final vault = (await lock.loadVault())!;
      expect(vault.spaces.map((s) => s.spaceId), ['space-a']);
      expect(vault.activeSpaceId, 'space-a');
    });

    test('removeSpace 删掉的是 active 时，active 让给剩下的第一个', () async {
      await lock.savePlain(payloadA);
      await lock.addSpace(payloadB);
      await lock.removeSpace('space-b'); // b 是 active
      await lock.addSpace(payloadB);
      await lock.removeSpace('space-b');

      final vault = (await lock.loadVault())!;
      expect(vault.activeSpaceId, 'space-a');
    });
  });

  group('PIN 模式', () {
    test('addSpace/removeSpace/setActiveSpace 带 pin 走加密包，明文不留副本', () async {
      await lock.setPin('123456', payload: payloadA);
      await lock.addSpace(payloadB, pin: '123456');

      expect(await lock.loadPlainVault(), isNull, reason: 'PIN 模式下不应有明文 Vault');
      final vault = await lock.unlockVault('123456');
      expect(vault.spaces.map((s) => s.spaceId), ['space-a', 'space-b']);

      await lock.removeSpace('space-a', pin: '123456');
      final after = await lock.unlockVault('123456');
      expect(after.spaces.map((s) => s.spaceId), ['space-b']);
      expect(after.activeSpaceId, 'space-b');
    });

    test('PIN 模式下不传 pin 读写 Vault 直接抛错（防静默降级为明文）', () async {
      await lock.setPin('123456', payload: payloadA);
      await expectLater(lock.loadVault(), throwsA(isA<StateError>()));
      await expectLater(
        lock.addSpace(payloadB),
        throwsA(isA<StateError>()),
      );
    });

    test('错误 PIN 仍计入 attempts/lock（Vault 粒度与旧行为一致）', () async {
      await lock.setPin('123456', payload: payloadA);
      await expectLater(
        lock.unlockVault('000000'),
        throwsA(isA<AppLockException>()),
      );
      for (var i = 0; i < 4; i++) {
        await expectLater(lock.unlockVault('000000'), throwsA(isA<AppLockException>()));
      }
      await expectLater(
        lock.unlockVault('123456'),
        throwsA(isA<AppLockLockedException>()),
      );
    });
  });

  group('Spaces 表同步', () {
    test('读凭证即补写 Spaces 行（v7 迁移不灌数据，靠这里补）', () async {
      await lock.savePlain(payloadA);
      await lock.loadPlain();
      expect(await spaceIds(), ['space-a']);

      await lock.addSpace(payloadB);
      expect(await spaceIds(), containsAll(['space-a', 'space-b']));

      final rowB = await (db.select(db.spaces)
            ..where((s) => s.spaceId.equals('space-b')))
          .getSingle();
      expect(rowB.deviceId, 'dev-b');
      expect(rowB.keyVersion, 2);
    });

    test('removeSpace 同时删 Spaces 行；clear() 全清', () async {
      await lock.savePlain(payloadA);
      await lock.addSpace(payloadB);
      await lock.removeSpace('space-a');
      expect(await spaceIds(), ['space-b']);

      await lock.clear();
      expect(await spaceIds(), isEmpty);
      expect(await lock.hasConfig, false);
    });

    test('saveProfile(spaceId:) 写 per-space 键并同步 Spaces 行的名字', () async {
      await lock.savePlain(payloadA);
      await lock.addSpace(payloadB);

      await lock.saveProfile(spaceId: 'space-b', personName: 'Lukas', peerName: 'Alice', deviceName: 'iPhone');
      final rowB = await (db.select(db.spaces)
            ..where((s) => s.spaceId.equals('space-b')))
          .getSingle();
      expect(rowB.name, 'Lukas');
      expect(rowB.peerName, 'Alice');

      final pB = await lock.loadProfile(spaceId: 'space-b');
      expect(pB['personName'], 'Lukas');
      await lock.saveProfile(spaceId: 'space-a', personName: 'Me', peerName: 'Bob', deviceName: 'iPhone');
      expect((await lock.loadProfile(spaceId: 'space-a'))['peerName'], 'Bob');
      expect((await lock.loadProfile(spaceId: 'space-b'))['peerName'], 'Alice',
          reason: '两个空间的资料互不覆盖');
    });
  });
}
