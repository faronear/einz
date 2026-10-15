import 'local_database.dart';

/// 墓碑消息的显示模式（老板 2026-10-15）：本设备设置（存 app_state，不同步到
/// 空间——每设备一个选择），仅影响**消息流里**已删除/已焚毁消息（本地墓碑，
/// deletedAt 非空）的呈现：
///
/// - `keep`（**默认**，现行行为）：显示为占位墓碑——正文隐藏，时间与记录仍在，
///   不打破消息历史流水（老板 2026-09-09 定的墓碑语义）；
/// - `hide`：墓碑整条不显示，从消息流中彻底消失。
///
/// 注意只改**显示**：delete/tombstone 的数据行为（打标记不打行、附件保留、
/// pending 墓碑仍补发）两种模式下一模一样。
const List<String> kTombstoneDisplayOptions = ['keep', 'hide'];

/// 墓碑显示模式设置（存本设备 app_state，key='tombstone_display'）。
///
/// 多空间：给 [spaceId] 时键为 `space.<spaceId>.tombstone_display`；读不到时回退
/// 旧全局键（存量设置没有空间维度）。
class TombstoneSettings {
  TombstoneSettings(this.db, {this.spaceId});

  final LocalDatabase db;

  /// 归属空间；null = 用旧全局键。
  final String? spaceId;

  static const _kKey = 'tombstone_display';

  String get _key => spaceId == null ? _kKey : spaceScopedKey(spaceId!, _kKey);

  /// 当前模式（默认 'keep' = 保留消息状态；老版本升上来也是它）。
  Future<String> load() async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(_key)))
        .getSingleOrNull();
    final v = row?.value ?? (spaceId == null
        ? null
        : (await (db.select(db.appState)..where((s) => s.key.equals(_kKey)))
                .getSingleOrNull())
            ?.value);
    return (v == null || !kTombstoneDisplayOptions.contains(v)) ? 'keep' : v;
  }

  /// 保存模式（'keep' / 'hide'）。
  Future<void> save(String mode) async {
    assert(kTombstoneDisplayOptions.contains(mode), '非法墓碑显示模式: $mode');
    await (db.into(db.appState))
        .insertOnConflictUpdate(AppStateCompanion.insert(key: _key, value: mode));
  }
}
