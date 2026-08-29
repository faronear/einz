/// 后台锁定计时（纯逻辑，可单测）。
///
/// App 切后台记录时间；回前台时若离开超过 [backgroundLockSeconds] 则要求重新锁定。
class LockTimer {
  LockTimer({this.backgroundLockSeconds = 30});

  /// 后台超过该秒数，回前台需重新锁定。
  final int backgroundLockSeconds;

  DateTime? _backgroundedAt;

  /// 记录进入后台时刻。
  void recordBackgrounded(DateTime now) {
    _backgroundedAt = now;
  }

  /// 回前台判断：离开后台超过阈值 → true（需重新锁定）。
  bool shouldRelock({required DateTime now}) {
    final bg = _backgroundedAt;
    if (bg == null) return false;
    return now.difference(bg).inSeconds >= backgroundLockSeconds;
  }

  /// 清除计时（未超时回前台 / 已重新锁定后）。
  void clear() {
    _backgroundedAt = null;
  }
}
