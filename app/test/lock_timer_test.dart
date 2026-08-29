// LockTimer 单测：后台计时与超时判断（纯逻辑，无需原生库）。

import 'package:flutter_test/flutter_test.dart';
import 'package:onlyspace/data/lock_timer.dart';

void main() {
  test('未进入后台：不要求重新锁定', () {
    final timer = LockTimer();
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 0)), false);
  });

  test('后台未超过阈值（29s）：不重新锁定', () {
    final timer = LockTimer();
    timer.recordBackgrounded(DateTime(2026, 1, 1, 12, 0, 0));
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 29)), false);
  });

  test('后台达到阈值（30s）：重新锁定', () {
    final timer = LockTimer();
    timer.recordBackgrounded(DateTime(2026, 1, 1, 12, 0, 0));
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 30)), true);
    // 更久后台也锁定
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 5, 0)), true);
  });

  test('未超时回前台后 clear：不再锁定，且重新计时', () {
    final timer = LockTimer();
    timer.recordBackgrounded(DateTime(2026, 1, 1, 12, 0, 0));
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 10)), false);
    timer.clear();
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 40)), false);

    // 重新进入后台：重新计时
    timer.recordBackgrounded(DateTime(2026, 1, 1, 12, 1, 0));
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 1, 31)), true);
  });

  test('自定义阈值', () {
    final timer = LockTimer(backgroundLockSeconds: 5);
    timer.recordBackgrounded(DateTime(2026, 1, 1, 12, 0, 0));
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 4)), false);
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 5)), true);
  });
}
