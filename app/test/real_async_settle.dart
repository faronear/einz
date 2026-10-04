import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 关掉**常驻动画**：把系统的「减少动态效果」偏好打开，生产代码里的常驻动画
/// （消息里的发送小飞机 `_SendingPlane`、菜单「阅后即焚」那行的翻转沙漏
/// `_HourglassFlip`、语音波形…）会退化成静态图标，于是 `pumpAndSettle` 不会
/// 被"永远在动的图标"卡到超时。
///
/// 在测试文件 `main()` 开头调用一次即可（内部注册 setUp/tearDown）。**凡是会打开
/// 汉堡菜单的测试都必须调**——菜单里的沙漏是常驻动画，2026-10-04 之前它让
/// `chat_page_menu_test` / `entrance_list_sheet_test` / `invite_dialog_layout_test` /
/// `ui_style_switch_test` 四个文件的全部用例挂在 `pumpAndSettle timed out`。
void disableAnimationsInTests() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  });
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
  });
}

/// 点「错峰」入口（菜单项 / 高级弹层条目 / 通道卡改名角标）后再 settle。
///
/// 这些入口都用 `Future.delayed(300ms)` 等上一个弹层收起动画走完再开下一个
/// （`_menuAction` 与高级弹层是同一手法）；而 `pumpAndSettle` 只推到"没有待排帧"就停、
/// **跨不过这 300ms**，所以点完必须显式把假时钟推过去，否则弹层/弹窗还没出现、断言就找 0 个。
Future<void> tapDeferred(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

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
