// 本地库迁移幂等回归。
//
// 2026-09-24 实测：某些历史/开发库的 `user_version` **落后于实际 schema**——version 记 6，
// 但已存在 v7 才引入的 `spaces` 表与 `local_attachments.space_id`。此时旧的迁移直接
// `ALTER TABLE ADD COLUMN space_id` 抛 "duplicate column name" → 迁移失败 → 启动门重试
// 耗尽 → 界面停在"启动初始化失败"，且无出路（iMac 生产库撞到）。
//
// 本测试构造这种"版本戳落后"的库，断言迁移能一路升到当前版本且列改名正确。
// 另覆盖 v10 存量库（main 已发布的 schema）→ v11 补建语音转写表的回归。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/local_database.dart';

Future<bool> _has(LocalDatabase db, String table, String column) async {
  final rows = await db.customSelect('PRAGMA table_info($table)').get();
  return rows.any((r) => r.read<String>('name') == column);
}

Future<int> _userVersion(LocalDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle())
        .read<int>('user_version');

void main() {
  test('迁移幂等：user_version=6 但已含 v7 对象时，仍升到 v11 且列改名正确', () async {
    final dir = Directory.systemTemp.createTempSync('einz-mig-');
    final path = '${dir.path}/einz.sqlite';
    final script = '''
CREATE TABLE spaces (space_id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL DEFAULT '', peer_name TEXT NOT NULL DEFAULT '', person_id TEXT, device_id TEXT NOT NULL DEFAULT '', key_version INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL DEFAULT 0, last_active_at INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0);
CREATE TABLE peer_receipts (space_id TEXT NOT NULL, person_id TEXT NOT NULL, delivered_upto_seq INTEGER NOT NULL DEFAULT 0, read_upto_seq INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (space_id, person_id));
CREATE TABLE local_messages (message_id TEXT NOT NULL PRIMARY KEY, space_id TEXT NOT NULL, sender_device_id TEXT, type TEXT NOT NULL DEFAULT 'text');
CREATE TABLE local_attachments (attachment_id TEXT NOT NULL PRIMARY KEY, message_id TEXT NOT NULL, space_id TEXT NOT NULL DEFAULT '');
PRAGMA user_version = 6;
''';
    // 用 sqlite3 CLI 造出"版本戳落后"的库（避免为测试引入 sqlite3 包依赖）。
    final p = await Process.start('/usr/bin/sqlite3', [path]);
    p.stdin.write(script);
    await p.stdin.close();
    expect(await p.exitCode, 0, reason: '构造遗留库失败');

    final db = LocalDatabase.forTesting(NativeDatabase(File(path)));
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    // 触发打开 → 迁移（原先就在这里抛 "duplicate column name: space_id"）。
    await db.select(db.spaces).get();

    expect(await _userVersion(db), 11,
        reason: '迁移后版本戳应升到当前 schema 版本（v11：+voice_transcripts）');

    // v11 新表已建（语音转写派生缓存）。
    expect(await _has(db, 'local_voice_transcripts', 'message_id'), isTrue);

    // v8 列改名已生效，旧列不残留。
    expect(await _has(db, 'spaces', 'member_id'), isTrue);
    expect(await _has(db, 'spaces', 'entrance_id'), isTrue);
    expect(await _has(db, 'spaces', 'person_id'), isFalse);
    expect(await _has(db, 'spaces', 'device_id'), isFalse);
    expect(await _has(db, 'peer_receipts', 'member_id'), isTrue);
    expect(await _has(db, 'peer_receipts', 'person_id'), isFalse);
    expect(await _has(db, 'local_messages', 'sender_entrance_id'), isTrue);
    expect(await _has(db, 'local_messages', 'sender_device_id'), isFalse);
    // v10：墓碑来路列（deleted_kind）已补上。
    expect(await _has(db, 'local_messages', 'deleted_kind'), isTrue);
  });

  test('v10 存量库（main 已发布的 schema）打开 → 补建 local_voice_transcripts 并升到 v11',
      () async {
    final dir = Directory.systemTemp.createTempSync('einz-mig-v10-');
    final path = '${dir.path}/einz.sqlite';
    // 造一份"v10 形状"的库：先按当前 schema 建全表，再删掉 v11 新表、版本戳改回 10
    // ——即 main 分支构建留给存量用户的库（from==10，from<10 的迁移块永不再跑）。
    final seed = LocalDatabase.forTesting(NativeDatabase(File(path)));
    await seed.select(seed.localMessages).get(); // 触发建表
    await seed.customStatement('DROP TABLE local_voice_transcripts');
    await seed.customStatement('PRAGMA user_version = 10');
    await seed.close();

    final db = LocalDatabase.forTesting(NativeDatabase(File(path)));
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    // 触发打开 → 迁移（回归：新表曾塞进 from<10 块，v10 存量库打不开它）。
    await db.select(db.localVoiceTranscripts).get();

    expect(await _userVersion(db), 11, reason: 'v10 存量库应升到 v11');
    expect(await _has(db, 'local_voice_transcripts', 'message_id'), isTrue,
        reason: 'v10 存量库必须补建语音转写表，否则转写行报 no such table');
    // v10 已引入的列不受影响。
    expect(await _has(db, 'local_messages', 'deleted_kind'), isTrue);
  });
}
