// App Store 截图自动化（2026-10-20）：驱动真实 app 进入演示秘境，
// 在各画面调用 binding.takeScreenshot 抓图，PNG 落盘到 SHOT_DIR。
//
// 运行（模拟器需已启动）：
//   flutter test integration_test/screenshots_test.dart -d <SIM_ID> \
//     --dart-define=SHOT_DIR=/tmp/einz_shots
//
// 画面清单（老板确认过的 6 张目标，v1 先做可稳定到达的 4 张）：
//   01 聊天主界面  02 长按菜单  03 阅后即焚弹层  04 输入栏"+"附件面板
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:einz/main.dart' as app;

const _shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: '/tmp/einz_shots');

/// 通知宿主机截图脚本：当前画面就绪（写 ready_i 文件），然后等宿主机截完
/// （撤掉 ready_i）再继续。iOS 沙盒禁止测试内 Process.run（"Starting new
/// processes is not supported on iOS"，实测 2026-10-20），simctl 截图只能
/// 由宿主机做——用文件握手协调。
Future<void> _signalStep(WidgetTester tester, int step) async {
  final flag = File('$_shotDir/ready_$step');
  await flag.create(recursive: true);
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (!await flag.exists()) return; // 宿主机已截图并撤信号
  }
  throw StateError('宿主机截图脚本未响应 step $step（60s 超时）');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('appstore screenshots', (tester) async {
    app.main();
    // 启动闸：等向导入口页出现（探测真实服务器，最长等 45s）
    var entryFound = false;
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(seconds: 1));
      if (find.textContaining('demo, no sign-up').evaluate().isNotEmpty ||
          find.textContaining('先看看演示').evaluate().isNotEmpty) {
        entryFound = true;
        break;
      }
    }
    expect(entryFound, isTrue, reason: '向导入口页未出现（探测失败？）');

    // 进入演示秘境（探测页可能在入口页出现后又重建一次 → tap 前重查+二次等待；
    // 模拟器可能是中文系统 → 中英双匹配，且不能写 `.first`——零匹配时会抛 StateError）
    Finder demoBtn() => find.textContaining('demo, no sign-up');
    final demoBtnZh = find.textContaining('先看看演示');
    for (var i = 0; i < 10; i++) {
      if (tester.any(demoBtn()) || tester.any(demoBtnZh)) break;
      await tester.pump(const Duration(seconds: 1));
    }
    final btn = tester.any(demoBtn()) ? demoBtn().first : demoBtnZh.first;
    expect(tester.any(btn), isTrue, reason: 'demo 入口按钮不可点');
    await tester.tap(btn);
    // 等聊天页消息出现（seeding + 首屏解密）
    var chatFound = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.textContaining('Welcome to Einz').evaluate().isNotEmpty ||
          find.textContaining('欢迎来到秘境').evaluate().isNotEmpty) {
        chatFound = true;
        break;
      }
    }
    expect(chatFound, isTrue, reason: '演示聊天页未出现');
    await tester.pump(const Duration(seconds: 1));
    await _signalStep(tester, 1);

    // 02 长按菜单（气泡文案随设备语言：中英双匹配，选存在的那支）
    Finder bubbleFinder() => tester.any(find.textContaining('Welcome to Einz'))
        ? find.textContaining('Welcome to Einz').first
        : find.textContaining('欢迎来到秘境').first;
    final bubble = bubbleFinder();
    await tester.longPress(bubble);
    await tester.pump(const Duration(seconds: 1));
    if (find.text('Quote').evaluate().isNotEmpty ||
        find.text('引用').evaluate().isNotEmpty) {
      await _signalStep(tester, 2);
      // 关闭弹层（点弹层外）
      await tester.tapAt(const Offset(20, 120));
      await tester.pump(const Duration(seconds: 1));
    }

    // 03 阅后即焚弹层：从长按菜单进入（重新长按 → 点 Burn after reading）
    await tester.longPress(bubbleFinder());
    await tester.pump(const Duration(seconds: 1));
    final burn = find.text('Burn after reading').evaluate().isNotEmpty
        ? find.text('Burn after reading')
        : find.text('阅后即焚');
    if (burn.evaluate().isNotEmpty) {
      await tester.tap(burn.first);
      await tester.pump(const Duration(seconds: 1));
      await _signalStep(tester, 3);
      await tester.tapAt(const Offset(20, 120));
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
