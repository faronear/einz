// AppLockService 单测：drift 内存库，验证 PIN 设置/解锁、错误计数锁定。
// 恢复码功能已按老板决策删除（不再生成/兑底）。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 shared 单测一致）。

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

  const payload = AppLockPayload(
    spaceKeyB64: 'dGhlLXNwYWNlLWtleQ==',
    spaceId: 'space-test',
    entranceId: 'dev-a',
    keyVersion: 1,
    token: 'tok-123',
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({}); // SecureStore（Keychain/Keystore）测试替身
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
    expect(unlocked.spaceKeyB64, 'dGhlLXNwYWNlLWtleQ==');
    expect(unlocked.spaceId, 'space-test');
    expect(unlocked.entranceId, 'dev-a');
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

  test('clearPackage：删除锁包后 isSetup=false，原 PIN 无法再解锁', () async {
    await lock.setPin('1234', payload: payload);
    expect(await lock.isSetup, true);

    await lock.clearPackage();
    expect(await lock.isSetup, false, reason: '锁包已删 → 回到未配置状态');
    await expectLater(lock.unlock('1234'), throwsA(isA<AppLockException>()),
        reason: '锁包已删，原 PIN 不应再能解锁');
  });

  test('跳过 PIN：savePlain 后 hasConfig=true、loadPlain 返回 payload，明文不算设锁', () async {
    expect(await lock.hasConfig, false);
    await lock.savePlain(payload);
    expect(await lock.hasConfig, true, reason: '跳过 PIN 也算已配置（下次直接进聊天）');
    expect(await lock.isSetup, false, reason: '明文不算设锁（仍需走免打扰路径）');

    final loaded = await lock.loadPlain();
    expect(loaded, isNotNull);
    expect(loaded!.spaceId, 'space-test');
    expect(loaded.spaceKeyB64, 'dGhlLXNwYWNlLWtleQ==');
  });

  test('补设 PIN 后明文副本清除：setPin 覆盖 savePlain', () async {
    await lock.savePlain(payload);
    expect(await lock.loadPlain(), isNotNull);

    await lock.setPin('1234', payload: payload);
    expect(await lock.isSetup, true);
    expect(await lock.loadPlain(), isNull, reason: 'setPin 后不应再保留明文副本');
    // 之后只能 PIN 解锁（无锁路径不再可用）
    final unlocked = await lock.unlock('1234');
    expect(unlocked.spaceId, 'space-test');
  });

  test('clearPlain：清除明文配置后 hasConfig=false', () async {
    await lock.savePlain(payload);
    expect(await lock.hasConfig, true);
    await lock.clearPlain();
    expect(await lock.hasConfig, false, reason: 'clearPlain 清无锁配置');
    expect(await lock.loadPlain(), isNull, reason: '明文包已删');
  });

  test('installUid：惰性生成并持久化（安装级）；app_state 被清后轮换', () async {
    final first = await lock.installUid();
    expect(first.length, 32, reason: '16 字节 hex，与服务端形状约束一致');
    expect(await lock.installUid(), first, reason: '同一安装内稳定（每个空间读到同一个）');

    // 整机清空 = 清空 app_state 整表 → 下次生成新的：不该再被认成同一台设备
    await db.delete(db.appState).go();
    expect(await lock.installUid(), isNot(first), reason: '重置后应轮换');
  });

  test('saveProfile/loadProfile：资料（名字）持久化存取', () async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    expect(await lock.loadProfile(), isEmpty, reason: '未保存时返回空');
    await lock.saveProfile(memberName: 'Lukas', peerName: 'Alice', entranceName: 'iPhone');
    final p = await lock.loadProfile();
    expect(p['memberName'], 'Lukas');
    expect(p['peerName'], 'Alice');
    expect(p['entranceName'], 'iPhone');
  });

  // ---- 卸载即重置（老板 2026-09-14 决策）：安全存储条目活过 App 卸载，drift 不会 ----

  test('全新安装（沙盒无安装标记）→ 清掉上一次安装残留的安全存储条目', () async {
    // 模拟：上一次安装在 Keychain 里留下的明文包（沙盒已随卸载清空 → 无安装标记）
    FlutterSecureStorage.setMockInitialValues({
      'einz.secure.app_lock.plain': '{"space_id":"previous-install"}',
    });
    await lock.ensureFreshInstall();
    expect(await SecureStore.read('app_lock.plain'), isNull,
        reason: '残留包必须被清掉，否则重装会被直接拖进聊天');
  });

  test('同一安装内重复调用不会误清本次写入的包（标记已落）', () async {
    await lock.ensureFreshInstall(); // 本次安装首次启动：落标记
    await lock.savePlain(payload); // 用户跳过 PIN → 明文包入安全存储
    await lock.ensureFreshInstall(); // 再次启动（同一安装，沙盒标记还在）
    final p = await lock.loadPlain();
    expect(p, isNotNull, reason: '同一安装不得误清');
    expect(p!.spaceId, 'space-test');
  });

  test('安装标记不影响配置清除：同一安装内清掉明文包后不再算已配置', () async {
    await lock.ensureFreshInstall();
    await lock.savePlain(payload);
    await lock.clearPlain();
    expect(await SecureStore.read('app_lock.plain'), isNull);
    expect(await lock.hasConfig, false);
    // 清完之后同一安装内再启动：标记仍在 → 不会重复清理（也无残留可清）
    await lock.ensureFreshInstall();
    expect(await lock.hasConfig, false);
  });

  // ---- 对方的身份状态（空间卡片「待加入」用）----

  test('savePeerPresence：对方的 member_id 与「是否已加入」一起落盘', () async {
    await lock.savePeerPresence(spaceId: 'space-a', peerMemberId: 'peer-1');
    var p = await lock.loadProfile(spaceId: 'space-a');
    expect(p['peerMemberId'], 'peer-1');
    expect(p['peerJoined'], true);

    // 对方尚未加入：清掉 id，并明确落 false（卡片据此显示「待加入」）
    await lock.savePeerPresence(spaceId: 'space-a');
    p = await lock.loadProfile(spaceId: 'space-a');
    expect(p['peerMemberId'], '');
    expect(p['peerJoined'], false, reason: '确定的"没加入"要能落下来');

    // 状态未知（资料里没这键）→ null，卡片什么都不显示（不误报「待加入」）
    await lock.saveProfile(
        spaceId: 'space-b', memberName: '我', peerName: '对方', entranceName: 'iMac');
    expect((await lock.loadProfile(spaceId: 'space-b'))['peerJoined'], isNull);
  });

  // ---- Spaces 行自愈（老板 2026-09-25 本机实测的死锁）----
  //
  // 残档 = 库里有一行、Vault 里没有凭证：空间卡片只认 Vault（看不见），
  // 加入向导的重复闸门却认这行（加不进来）→ 自愈必须在读到 Vault 时清掉它。

  test('读到 Vault 时清掉没有凭证的 Spaces 残档行', () async {
    await lock.savePlain(payload); // Vault 里只有 space-test
    // 残档：模拟凭证在别处丢失（换 build 命名空间 / Keychain 被清）后留下的那一行
    await db.into(db.spaces).insert(SpacesCompanion.insert(spaceId: 'space-zombie'));
    expect(await db.select(db.spaces).get(), hasLength(2), reason: '此刻两行都在');

    final loaded = await lock.loadPlain(); // 冷启动读 Vault
    expect(loaded, isNotNull);
    final ids = [for (final r in await db.select(db.spaces).get()) r.spaceId];
    expect(ids, ['space-test'], reason: '残档行被清掉，真·已添加的那个不动');
  });

  test('Vault 为空时不删 Spaces 行（无法区分"没空间"与"Vault 不完整"）', () async {
    await db.into(db.spaces).insert(SpacesCompanion.insert(spaceId: 'space-zombie'));
    await SecureStore.write('app_lock.plain',
        '{"version":1,"active_space_id":null,"spaces":[]}');
    expect(await lock.loadPlain(), isNull);
    expect(await db.select(db.spaces).get(), hasLength(1), reason: '空 Vault 不动表');
  });
}
