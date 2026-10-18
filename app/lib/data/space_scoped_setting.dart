import 'local_database.dart';

/// per-space app_state 设置的共同骨架（老板 2026-10-15 抽自
/// AttachmentStorageSettings / TombstoneSettings）。
///
/// 存在的理由：「应用于本机所有秘境」勾选框要给几乎每个配置项都加，而它的
/// 落地逻辑（写全局键 + 清除各空间 per-space 覆盖）在每个设置类里都一样——
/// 不该每类抄一遍。宿主提供三样：[settingKey]（主键名）、[spaceId]（归属
/// 空间）、[db]。
///
/// 键的两个层级：
/// - per-space：`space.<spaceId>.<settingKey>`（[scopedKey]）——只影响当前空间；
/// - 全局：`<settingKey>`——影响本机所有空间（v7 多空间上线前的旧键，存量
///   设置的回退源）。
mixin SpaceScopedSetting {
  /// 设置存底库（app_state 表）。
  LocalDatabase get db;

  /// 归属空间；null = 用旧全局键（单空间/无空间上下文的场景）。
  String? get spaceId;

  /// 设置项主键名（如 'attachment_storage'）。
  String get settingKey;

  /// per-space 键；无空间上下文时即全局键。
  String get scopedKey =>
      spaceId == null ? settingKey : spaceScopedKey(spaceId!, settingKey);

  /// 写一行 app_state（upsert）。
  Future<void> writeSetting(String key, String value) async {
    await (db.into(db.appState))
        .insertOnConflictUpdate(AppStateCompanion.insert(key: key, value: value));
  }

  /// 保存为**全局**模式（作用于本机所有空间；「应用于本机所有秘境」勾选框）。
  ///
  /// 两步：① 写全局键；② **清除所有空间的 per-space 覆盖**——不清的话那些
  /// 空间仍读自己的键，全局值对它们不生效，"所有秘境"名不副实。
  Future<void> saveAll(String value) async {
    await writeSetting(settingKey, value);
    await clearSpaceOverrides();
  }

  /// 清除所有空间的 per-space 覆盖（[saveAll] 的第二步行）。
  ///
  /// 只动本设置项的 `space.*.<settingKey>` 行——Dart 侧精确匹配首尾，不拿 SQL
  /// LIKE（键名里的 `_` 是通配符，会误伤）。
  Future<void> clearSpaceOverrides() async {
    final rows = await db.select(db.appState).get();
    final scopedKeys = [
      for (final r in rows)
        if (r.key.startsWith('space.') && r.key.endsWith('.$settingKey')) r.key,
    ];
    if (scopedKeys.isEmpty) return;
    await (db.delete(db.appState)..where((s) => s.key.isIn(scopedKeys))).go();
  }
}
