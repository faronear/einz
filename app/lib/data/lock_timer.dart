/// 锁屏无操作/后台超时阈值（秒）。
///
/// 后台切回锁屏（[LockTimer]）与前台无操作锁屏（chat_page 的 idle ticker）
/// 共用同一阈值。默认 [kLockSeconds]；用户可在「设置锁屏码」弹窗的时长轴上
/// 自选（对数刻度 30 秒~30 分钟，持久化在 AppLockService 的 app_state，见
/// loadLockSeconds / saveLockSeconds），chat_page 加载后回填这两处。
const int kLockSeconds = 60;

/// 可调锁屏时长范围（秒）：10 秒 ~ 30 分钟（老板 2026-10-24 定，由 20 秒~20 分钟
/// 改来）。弹窗里的时长轴仿阅后即焚（burn_duration_sheet）：对数刻度、
/// 档位吸附（≤1 分钟吸附 10 秒、>1 分钟吸附整分钟）、轴下可点阶段标注。
const int kLockMinSeconds = 10;
const int kLockMaxSeconds = 30 * 60;

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
