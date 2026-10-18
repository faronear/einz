/// 锁屏无操作/后台超时阈值（秒）。
///
/// 后台切回锁屏（[LockTimer]）与前台无操作锁屏（chat_page 的 idle ticker）
/// 共用同一阈值。默认 [kLockSeconds]；用户可在「设置锁屏码」弹窗里从
/// [kLockSecondsChoices] 中自选（持久化在 AppLockService 的 app_state，见
/// loadLockSeconds / saveLockSeconds），chat_page 加载后回填这两处。
const int kLockSeconds = 30;

/// 可调锁屏时长的档位（秒）：30 秒到 1 小时（老板 2026-10-18 定）。
/// 滚动轴按档位吸附，不做连续秒数——展示与理解都按整档来。
const List<int> kLockSecondsChoices = [30, 60, 120, 300, 600, 1800, 3600];

/// 后台锁定计时（纯逻辑，可单测）。
///
/// App 切后台记录时间；回前台时若离开超过 [backgroundLockSeconds] 则要求重新锁定。
class LockTimer {
  LockTimer({this.backgroundLockSeconds = kLockSeconds});

  /// 后台超过该秒数，回前台需重新锁定。
  /// 可变：chat_page 加载用户自选的锁屏时长后回填（默认 [kLockSeconds]）。
  int backgroundLockSeconds;

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
