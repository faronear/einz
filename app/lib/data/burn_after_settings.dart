import 'local_database.dart';

/// 阅后即焚档位（秒）：0 = 无限（默认，不删除）。
/// 每设备独立设置（纯本地，Server 不参与——阅后即焚仅限本设备管理本地副本）。
const Map<String, int> kBurnAfterOptions = {
  '1 分钟': 60,
  '5 分钟': 300,
  '1 小时': 3600,
  '1 天': 86400,
  '7 天': 604800,
  '长期保留': 0, // 放最后：取消焚毁（消息永久保留）
};

/// 阅后即焚设置：存本设备 app_state（key-value），仅本机生效。
class BurnAfterSettings {
  BurnAfterSettings(this.db);

  final LocalDatabase db;

  static const _kKey = 'burn_after_seconds';

  /// 当前设置的焚毁秒数（默认 0 = 无限）。
  Future<int> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull();
    return int.tryParse(row?.value ?? '') ?? 0;
  }

  /// 保存焚毁秒数（必须来自 [kBurnAfterOptions]，0 = 无限）。
  Future<void> save(int seconds) async {
    assert(kBurnAfterOptions.containsValue(seconds), '非法档位: $seconds');
    await (db.into(db.appState)).insertOnConflictUpdate(
      AppStateCompanion.insert(key: _kKey, value: '$seconds'),
    );
  }
}
