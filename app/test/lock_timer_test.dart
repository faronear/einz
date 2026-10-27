// LockTimer 单测：后台计时与超时判断（纯逻辑，无需原生库）。
// 阈值一律以 kLockSeconds 表达（默认 60s，2026-10-27 由 30 秒改来）；默认值再调不破测试。

import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/lock_timer.dart';

void main() {
  test('未进入后台：不要求重新锁定', () {
    final timer = LockTimer();
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 0)), false);
  });

  test('后台未超过阈值（阈值-1s）：不重新锁定', () {
    final timer = LockTimer();
    final start = DateTime(2026, 1, 1, 12, 0, 0);
    timer.recordBackgrounded(start);
    expect(
        timer.shouldRelock(
            now: start.add(Duration(seconds: kLockSeconds - 1))),
        false);
  });

  test('后台达到阈值：重新锁定', () {
    final timer = LockTimer();
    final start = DateTime(2026, 1, 1, 12, 0, 0);
    timer.recordBackgrounded(start);
    expect(
        timer.shouldRelock(now: start.add(Duration(seconds: kLockSeconds))),
        true);
    // 更久后台也锁定
    expect(timer.shouldRelock(now: start.add(const Duration(minutes: 5))), true);
  });

  test('未超时回前台后 clear：不再锁定，且重新计时', () {
    final timer = LockTimer();
    final start = DateTime(2026, 1, 1, 12, 0, 0);
    timer.recordBackgrounded(start);
    expect(timer.shouldRelock(now: start.add(const Duration(seconds: 10))),
        false);
    timer.clear();
    expect(
        timer.shouldRelock(
            now: start.add(Duration(seconds: kLockSeconds + 10))),
        false);

    // 重新进入后台：重新计时
    final again = DateTime(2026, 1, 1, 12, 1, 0);
    timer.recordBackgrounded(again);
    expect(
        timer.shouldRelock(now: again.add(Duration(seconds: kLockSeconds + 1))),
        true);
  });

  test('自定义阈值', () {
    final timer = LockTimer(backgroundLockSeconds: 5);
    timer.recordBackgrounded(DateTime(2026, 1, 1, 12, 0, 0));
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 4)), false);
    expect(timer.shouldRelock(now: DateTime(2026, 1, 1, 12, 0, 5)), true);
  });
}
