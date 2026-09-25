import 'local_database.dart';

/// 阅后即焚档位（秒）：0 = 无限（默认，不删除）。
/// 每设备独立设置（纯本地，Server 不参与——阅后即焚仅限本设备管理本地副本）。
///
/// 顺序即弹层里的展示顺序：**0（关闭）放第一项**——桌面版窗口可以很扁，档位多时
/// 底部会被裁进滚动区，"取消焚毁"这种关键项不该被藏起来（老板 2026-09-25）。
const Map<String, int> kBurnAfterOptions = {
  '不设期限': 0,
  '1 分钟': 60,
  '5 分钟': 300,
  '1 小时': 3600,
  '1 天': 86400,
  '7 天': 604800,
};

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

  /// 保存焚毁秒数（必须来自 [kBurnAfterOptions]，0 = 无限）。
  Future<void> save(int seconds) async {
    assert(kBurnAfterOptions.containsValue(seconds), '非法档位: $seconds');
    await (db.into(db.appState)).insertOnConflictUpdate(
      AppStateCompanion.insert(key: _key, value: '$seconds'),
    );
  }
}
