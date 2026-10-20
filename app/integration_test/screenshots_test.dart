// App Store 截图自动化（2026-10-20）：驱动真实 app 进入演示秘境，
// 在各画面由宿主机 simctl 截图（iOS 沙盒禁止测试内 Process.run，用文件握手）。
//
// 运行（模拟器需已启动）：
//   bash app/integration_test/screenshots_drive.sh &
//   cd app && flutter test integration_test/screenshots_test.dart \
//     -d <SIM_ID> --dart-define=SHOT_DIR=/tmp/einz_shots
//
// 画面清单（2026-10-20 老板扩到 6 张；ASC 6.9" 槽位最多传 4 张，提审前取舍）：
//   01 空间向导首页（新建/加入选择）  02 聊天主界面  03 长按菜单
//   04 阅后即焚设置弹层（主菜单→阅后即焚）  05 输入栏"+"附件面板  06 锁屏码首次设置
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:einz/main.dart' as app;
import 'package:einz/widgets/cancel_button.dart';

const _shotDir = String.fromEnvironment('SHOT_DIR', defaultValue: '/tmp/einz_shots');

/// 通知宿主机截图脚本：当前画面就绪（写 ready_i 文件），然后等宿主机截完
/// （撤掉 ready_i）再继续。
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
      if (find.textContaining('Take a look around first').evaluate().isNotEmpty ||
          find.textContaining('先看看演示').evaluate().isNotEmpty) {
        entryFound = true;
        break;
      }
    }
    expect(entryFound, isTrue, reason: '向导入口页未出现（探测失败？）');
    // 按钮可能在探测完成后重建一次 → 二次等待
    Finder demoBtn() => find.textContaining('Take a look around first');
    final demoBtnZh = find.textContaining('先看看演示');
    for (var i = 0; i < 10; i++) {
      if (tester.any(demoBtn()) || tester.any(demoBtnZh)) break;
      await tester.pump(const Duration(seconds: 1));
    }

    // 01 空间向导首页（创建/加入/演示 三入口）
    await tester.pump(const Duration(seconds: 1));
    await _signalStep(tester, 1);

    // 进入演示秘境（中英双匹配；不能写 `.first`——零匹配时抛 StateError）
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

    // 02 聊天主界面
    await _signalStep(tester, 2);

    // 03 长按菜单（气泡文案随设备语言：中英双匹配，选存在的那支）
    Finder bubbleFinder() => tester.any(find.textContaining('Welcome to Einz'))
        ? find.textContaining('Welcome to Einz').first
        : find.textContaining('欢迎来到秘境').first;
    await tester.longPress(bubbleFinder());
    await tester.pump(const Duration(seconds: 1));
    if (find.text('Quote').evaluate().isNotEmpty ||
        find.text('引用').evaluate().isNotEmpty) {
      await _signalStep(tester, 3);
      await tester.tapAt(const Offset(20, 120)); // 点弹层外关闭
      await tester.pump(const Duration(seconds: 1));
    }

    // 04 阅后即焚设置弹层：主菜单（右上汉堡）→「阅后即焚」→ _showBurnPicker
    // （空间级设置弹层；与长按菜单的单条消息焚毁不同）
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pump(const Duration(milliseconds: 500));
    final burnItem = find.text('Burn-after-read').evaluate().isNotEmpty
        ? find.text('Burn-after-read')
        : find.text('阅后即焚');
    if (burnItem.evaluate().isNotEmpty) {
      await tester.tap(burnItem.first);
      await tester.pump(const Duration(milliseconds: 1500)); // 等弹层动画
      await _signalStep(tester, 4);
      await tester.tapAt(const Offset(20, 120)); // 点弹层外关闭
      await tester.pump(const Duration(seconds: 1));
    }

    // 05 输入栏"+"附件面板（add_circle_outline → _showAttachmentSheet）
    FocusManager.instance.primaryFocus?.unfocus(); // 收起键盘，避免遮挡面板
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.add_circle_outline).first);
    await tester.pump(const Duration(milliseconds: 1500)); // 等弹层动画
    await _signalStep(tester, 5);
    await tester.tapAt(const Offset(20, 120)); // 点弹层外关闭
    await tester.pump(const Duration(seconds: 1));

    // 06 锁屏码首次设置：主菜单 →「锁屏码/PIN」→ _showSetLockDialog
    // （演示空间未设 PIN → 首次设置表单；截图后必须取消，绝不能真的给演示设 PIN）
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pump(const Duration(milliseconds: 500));
    final pinItem = find.text('PIN').evaluate().isNotEmpty
        ? find.text('PIN')
        : find.text('锁屏码');
    if (pinItem.evaluate().isNotEmpty) {
      await tester.tap(pinItem.first);
      await tester.pump(const Duration(seconds: 1));
      final dialogOpen = find.text('Set PIN').evaluate().isNotEmpty ||
          find.text('设置锁屏码').evaluate().isNotEmpty;
      expect(dialogOpen, isTrue, reason: 'PIN 设置弹窗未出现');
      FocusManager.instance.primaryFocus?.unfocus(); // 收键盘：弹窗是主体，键盘抢戏
      await tester.pump(const Duration(milliseconds: 800));
      await _signalStep(tester, 6);
      await tester.tap(find.byType(CancelButton).first); // 只看不设
      await tester.pump(const Duration(seconds: 1));
    }
  });
}
