import 'local_database.dart';

/// 「应用于本机所有秘境」偏好（邮件通知，2026-10-02）：存本设备 app_state，仅本机生效。
///
/// true（默认）＝邮件通知的保存/停用同步到本机所有秘境，新建/加入空间时也自动
/// 继承已有邮箱（_inheritNotifyEmail）；false＝一切只作用于当前秘境。
/// 只存一个设备级布尔：它表达的是"这台设备的默认策略"，不是某个空间的属性。
class NotifyAllSpacesPref {
  NotifyAllSpacesPref(this.db);

  final LocalDatabase db;

  static const _kKey = 'notify_all_spaces';

  /// 读取偏好；没有记录过 → true（默认全局，与 2026-10-01 起的既有行为一致）。
  Future<bool> load() async {
    final row =
        await (db.select(db.appState)..where((s) => s.key.equals(_kKey))).getSingleOrNull();
    if (row == null) return true;
    return row.value != '0';
  }

  /// 保存偏好（弹窗里每次勾选变化时落盘，钩子在任何时刻读到的都是最新意图）。
  Future<void> save(bool all) async {
    await (db.into(db.appState)).insertOnConflictUpdate(
      AppStateCompanion.insert(key: _kKey, value: all ? '1' : '0'),
    );
  }
}
