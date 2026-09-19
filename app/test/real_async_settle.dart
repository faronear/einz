import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 让**真实异步**（FFI 解密、图片解码）在 widget 测试里跑完。
///
/// widget 测试跑在 FakeAsync 里，`pump` 只推假时钟，推不动真实异步；而 `runAsync`
/// 期间又不能 `pump`。所以两者必须**交替多轮**：每轮让真实异步往前走一步，再 pump
/// 一次把新的 frame/future 接到下一环（单次长 `runAsync` 不够——后续步骤要等 pump）。
///
/// 背景：附件明文的 `FutureBuilder` 在字节就绪前显示 `CircularProgressIndicator`，
/// 那是无限动画，只靠 `pumpAndSettle` 会直接超时（2026-09-19 修 5 个既有红测试）。
Future<void> settleRealAsync(WidgetTester tester) async {
  // 每一轮只能推进一步（exists → 解密 → 落盘 → 取帧 → 解码），所以循环到
  // 「不再有转圈的附件」为止（没有附件时第一轮就退出）
  for (var round = 0; round < 12; round++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    if (tester.widgetList(find.byType(CircularProgressIndicator)).isEmpty) break;
  }
  await tester.pumpAndSettle();
}
