import 'local_database.dart';

/// 阅后即焚设置：存本设备 app_state（key-value），仅本机生效。
///
/// 多空间：给 [spaceId] 时键为 `space.<spaceId>.burn_after_seconds`（每空间一份）；
/// 不给（或读不到 per-space 键）时回退旧全局键——存量用户的设置不会丢。
class BurnAfterSettings {
  BurnAfterSettings(this.db, {this.spaceId});

  final LocalDatabase db;

  /// 归属空间；null = 用旧全局键（单空间/无空间上下文的场景）。
  final String? spaceId;

  static const _kKey = 'burn_after_seconds';

  String get _key => spaceId == null ? _kKey : spaceScopedKey(spaceId!, _kKey);

  /// 当前设置的焚毁秒数（默认 0 = 无限）。
  Future<int> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_key))).getSingleOrNull();
    if (row == null && spaceId != null) {
      // 回退：v7 之前的设置没有空间维度（该空间迁移自旧单空间）
      final legacy = await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull();
      return int.tryParse(legacy?.value ?? '') ?? 0;
    }
    return int.tryParse(row?.value ?? '') ?? 0;
  }

  /// 保存焚毁秒数（0 = 无限/关闭；其余任意正数，2026-10-16 起用户可自设
  /// 1 分钟 ~ 60 天的任意时长）。
  Future<void> save(int seconds) async {
    assert(seconds >= 0, '非法焚毁时长: $seconds');
    await (db.into(db.appState)).insertOnConflictUpdate(
      AppStateCompanion.insert(key: _key, value: '$seconds'),
    );
  }
}
