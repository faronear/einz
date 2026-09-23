// 多空间数据隔离单测（M1）：drift 内存库 + SecureStore 替身。
//
// 覆盖 aimemo/multiSpaceDesign.zhcn.md §7 的 4–6：
// removeSpace 只清本空间、PIN 模式挂 pending 后解锁再摘凭证、per-space 设置互不干扰、
// 媒体缓存保留名单跨空间。
//
// 需要 LIBSODIUM_PATH 指向 libsodium.dll（与 app_lock_test 一致）。

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/attachment_storage_settings.dart';
import 'package:einz/data/burn_after_settings.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/message_repository.dart';
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
    token: 'tok-a',
  );
  const payloadB = AppLockPayload(
    spaceKeyB64: 'a2V5LWI=',
    spaceId: 'space-b',
    deviceId: 'dev-b',
    token: 'tok-b',
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = LocalDatabase.forTesting(NativeDatabase.memory());
    lock = AppLockService(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// 在两个空间各放一条消息 + 一条附件 + 一个同步锚点。
  Future<void> seedTwoSpaces() async {
    for (final sid in ['space-a', 'space-b']) {
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            messageId: 'msg-$sid',
            spaceId: sid,
            senderDeviceId: 'dev',
            type: 'text',
            keyVersion: 1,
            nonce: 'n',
            ciphertext: 'c',
            createdAt: 1,
            localCreatedAt: 1,
          ));
      await db.into(db.localAttachments).insert(LocalAttachmentsCompanion.insert(
            attachmentId: 'att-$sid',
            messageId: 'msg-$sid',
            spaceId: Value(sid),
            keyVersion: 1,
            size: 1,
            sha256: 's',
            nonce: 'n',
          ));
      await db.into(db.syncState).insert(SyncStateCompanion.insert(spaceId: sid, lastServerSequence: const Value(7)));
    }
  }

  Future<int> count(String table) async {
    final rows = await db.customSelect('SELECT COUNT(*) AS n FROM $table').get();
    return rows.single.read<int>('n');
  }

  test('removeSpace 只清本空间：另一个空间的消息/附件/锚点/Spaces 行全部存活', () async {
    await lock.savePlain(payloadA);
    await lock.addSpace(payloadB);
    await seedTwoSpaces();
    expect(await count('local_messages'), 2);

    await lock.removeSpace('space-a');

    // A 的数据全清：只剩 space-b 的消息
    final remaining = await db
        .customSelect('SELECT space_id FROM local_messages')
        .get();
    expect(remaining.map((r) => r.read<String>('space_id')), ['space-b']);
    expect(await count('local_attachments'), 1);
    expect(await count('sync_state'), 1);
    final spaces = await db.select(db.spaces).get();
    expect(spaces.map((s) => s.spaceId), ['space-b']);

    // B 的凭证仍在，active 让给它
    final vault = (await lock.loadVault())!;
    expect(vault.spaces.map((s) => s.spaceId), ['space-b']);
    expect(vault.activeSpaceId, 'space-b');
  });

  test('PIN 模式下 removeSpace 不给 pin：数据立刻清干净，凭证挂 pending 等解锁再摘', () async {
    await lock.setPin('123456', payload: payloadA);
    await lock.addSpace(payloadB, pin: '123456');
    await seedTwoSpaces();

    // 聊天页撤销场景：没有 pin（也不该在页面里留 pin）
    await lock.removeSpace('space-a');

    // 数据已清（撤销=销毁，不能留明文）
    final remaining = await db.customSelect('SELECT space_id FROM local_messages').get();
    expect(remaining.map((r) => r.read<String>('space_id')), ['space-b']);
    expect(await count('local_attachments'), 1);

    // 密文包此时还没改（没有 pin 改不了），下次解锁补做
    final before = await lock.unlockVault('123456');
    expect(before.spaces.map((s) => s.spaceId), ['space-b'], reason: '解锁时自动应用 pending');
    final after = await lock.unlockVault('123456');
    expect(after.spaces.map((s) => s.spaceId), ['space-b'], reason: 'pending 只应用一次');
    expect(after.activeSpaceId, 'space-b');
  });

  test('per-space 设置互不干扰，且读得到 v7 之前的旧全局键', () async {
    // 旧全局键（存量数据）
    await BurnAfterSettings(db).save(300);
    await AttachmentStorageSettings(db).save('secured');

    final burnA = BurnAfterSettings(db, spaceId: 'space-a');
    final burnB = BurnAfterSettings(db, spaceId: 'space-b');
    expect(await burnA.load(), 300, reason: 'per-space 键缺失时回退旧全局值');
    await burnB.save(60);
    expect(await burnB.load(), 60);
    expect(await burnA.load(), 300, reason: 'B 的设置不影响 A');

    final storeA = AttachmentStorageSettings(db, spaceId: 'space-a');
    final storeB = AttachmentStorageSettings(db, spaceId: 'space-b');
    expect(await storeA.load(), 'secured', reason: '回退旧全局值');
    await storeB.save('stored');
    expect(await storeB.load(), 'stored');
    expect(await storeA.load(), 'secured');
  });

  test('removeSpace 连 per-space 设置键一起清', () async {
    await lock.savePlain(payloadA);
    await BurnAfterSettings(db, spaceId: 'space-a').save(60);
    await lock.removeSpace('space-a');
    expect(await BurnAfterSettings(db, spaceId: 'space-a').load(), 0, reason: '已回退到默认（旧全局键也不存在）');
  });

  test('媒体缓存保留名单只取本空间（缓存已按空间分目录）', () async {
    final repo = MessageRepository(
      db: db,
      api: ApiClient('http://fake'),
      spaceKey: await generateSpaceKey(),
      spaceId: 'space-a',
      deviceId: 'dev-a',
      keyVersion: 1,
      token: 'tok-a',
    );
    await seedTwoSpaces();

    final mine = await repo.allMessageIds();
    expect(mine, {'msg-space-a'}, reason: '保留名单只应含本空间');
    expect(mine.contains('msg-space-b'), isFalse, reason: '别的空间不在清理范围内，不该进名单');
  });
}
