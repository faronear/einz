// 语音转写设置的 per-space 隔离回归（老板 2026-10-24 实测：不勾「应用于本机所有
// 秘境」的保存也影响了所有空间——根因是 _ScopedKey.write 误写全局裸键而非
// scopedKey，所有空间读到时（per-space 缺失回退全局）都生效。
// 本文件锁死三条语义：
// ① 不勾范围 → 只写本空间 per-space 键，全局键不落，别空间不受影响；
// ② 勾了范围（saveAll）→ 写全局 + 清所有 per-space 覆盖，所有空间跟随；
// ③ v12 迁移把存量污染全局键认领进各空间后清除（见 local_database_migration_test）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/voice_transcript_settings.dart';

void main() {
  test('不勾「所有秘境」：只写本空间，全局键不落、别空间不受影响', () async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceA = VoiceTranscriptSettings(db, spaceId: 'space-a');
    final spaceB = VoiceTranscriptSettings(db, spaceId: 'space-b');

    await spaceA.saveEngine('server');
    await spaceA.saveAuto(true);

    // 本空间读到新值
    expect(await spaceA.loadEngine(), 'server');
    expect(await spaceA.loadAuto(), isTrue);
    // 别空间完全不受影响（仍默认 local / 手动）
    expect(await spaceB.loadEngine(), 'local');
    expect(await spaceB.loadAuto(), isFalse);

    // per-space 键落的是 scopedKey；全局键一个都没写（回归点）
    final scoped = await (db.select(db.appState)
          ..where((s) => s.key.equals('space.space-a.voice_transcript_engine')))
        .getSingleOrNull();
    expect(scoped?.value, 'server');
    for (final globalKey in const [
      'voice_transcript_engine',
      'voice_transcript_auto',
    ]) {
      final global = await (db.select(db.appState)
            ..where((s) => s.key.equals(globalKey)))
          .getSingleOrNull();
      expect(global, isNull, reason: '不勾范围不许写全局键 $globalKey');
    }
  });

  test('勾了「所有秘境」（saveAll）：写全局 + 清覆盖，所有空间跟随', () async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceA = VoiceTranscriptSettings(db, spaceId: 'space-a');
    final spaceB = VoiceTranscriptSettings(db, spaceId: 'space-b');
    // 先给 B 一个自己的覆盖（模拟曾单独配置过）
    await spaceB.saveEngine('server');
    await spaceB.saveAuto(true);

    await spaceA.saveAll(engine: 'local', auto: false);

    // 全局值生效到所有空间（B 的覆盖已被清）
    expect(await spaceA.loadEngine(), 'local');
    expect(await spaceA.loadAuto(), isFalse);
    expect(await spaceB.loadEngine(), 'local');
    expect(await spaceB.loadAuto(), isFalse);

    // 全局键在、per-space 覆盖已清
    final global = await (db.select(db.appState)
          ..where((s) => s.key.equals('voice_transcript_engine')))
        .getSingleOrNull();
    expect(global?.value, 'local');
    final scoped = await (db.select(db.appState)
          ..where((s) => s.key.equals('space.space-b.voice_transcript_engine')))
        .getSingleOrNull();
    expect(scoped, isNull);
  });
}
