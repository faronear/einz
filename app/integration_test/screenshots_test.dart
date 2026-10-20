// App Store 截图自动化（2026-10-20 英文版 v2）：驱动真实 app 走英文界面，
// 由宿主机 simctl 截图（iOS 沙盒禁止测试内 Process.run，用文件握手）。
//
// 前置：模拟器语言 en-US（simctl spawn defaults write -g AppleLanguages）
// + app 全新安装（demo 按英文种入）。
//
// 运行（模拟器需已启动）：
//   bash app/integration_test/screenshots_drive.sh &
//   cd app && flutter test integration_test/screenshots_test.dart \
//     -d <SIM_ID> --dart-define=SHOT_DIR=/tmp/einz_shots
//
// 画面清单（2026-10-20 老板定 5 张：突出隐私，去掉交互细节图）：
//   01 空间向导首页（Create/Join/Demo 三入口）
//   02 向导分流页（Duo space / Group space——老板认为比 01 更有价值）
//   03 聊天主界面
//   04 阅后即焚设置弹层
//   05 锁屏码首次设置
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

/// 等某个英文文案出现（最长 [tries] 秒），返回是否出现。
Future<bool> _waitFor(WidgetTester tester, String text, {int tries = 15}) async {
  for (var i = 0; i < tries; i++) {
    if (find.textContaining(text).evaluate().isNotEmpty) return true;
    await tester.pump(const Duration(milliseconds: 500));
  }
  return false;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('appstore screenshots (english)', (tester) async {
    app.main();
    // 启动闸：等向导入口页出现（全新安装 + 英文系统，探测真实服务器最长 45s）
    final entryOk = await _waitFor(tester, 'Take a look around first', tries: 45);
    expect(entryOk, isTrue, reason: '向导入口页未出现（探测失败？）');
    await tester.pump(const Duration(seconds: 1));

    // 01 空间向导首页（Create / Join / Take a look around first）
    await _signalStep(tester, 1);

    // —— 向导分流页：Create → 第 1 步填名字+性别 → Next → 第 2 步 Duo/Group ——
    await tester.tap(find.text('Create').first);
    final nameOk = await _waitFor(tester, 'Name');
    expect(nameOk, isTrue, reason: '创建向导第 1 步（名字页）未出现');
    await tester.enterText(find.byType(TextField).first, 'Alice');
    await tester.tap(find.text('Female').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Next').first);
    final kindOk = await _waitFor(tester, 'Duo space');
    expect(kindOk, isTrue, reason: '向导分流页（Duo/Group）未出现');
    await tester.pump(const Duration(milliseconds: 500));

    // 02 向导分流页（Duo space / Group space）
    await _signalStep(tester, 2);

    // 退回入口页（Back 两次：分流页 → 名字页 → 入口页）
    await tester.tap(find.text('Back').first);
    await _waitFor(tester, 'Name');
    await tester.tap(find.text('Back').first);
    final backOk = await _waitFor(tester, 'Take a look around first');
    expect(backOk, isTrue, reason: '退回入口页失败');
    await tester.pump(const Duration(seconds: 1));

    // 进入演示秘境（首次进入按英文种入 demo 消息）
    await tester.tap(find.text('Take a look around first').first);
    // 多探针：列表滚动位置不确定，第一条可能未渲染；任何一条 demo 文案可见即算聊天页
    const probes = [
      'Welcome to Einz',
      'end-to-end encrypted',
      'disappear after a timer',
      'lives only on this device',
    ];
    var chatOk = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      for (final probe in probes) {
        if (find.textContaining(probe).evaluate().isNotEmpty) {
          chatOk = true;
          break;
        }
      }
      if (chatOk) break;
    }
    if (!chatOk) {
      // 诊断：到底停在了哪个画面？把可见文本倒进测试日志
      final visibleTexts = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .where((d) => d != null && d.trim().isNotEmpty)
          .take(25)
          .toList();
      // ignore: avoid_print
      print('DEMO-WAIT-DIAG visible texts: $visibleTexts');
    }
    expect(chatOk, isTrue, reason: '演示聊天页未出现');
    await tester.pump(const Duration(seconds: 1));

    // 03 聊天主界面
    await _signalStep(tester, 3);

    // 04 阅后即焚设置弹层：主菜单（右上汉堡）→ Burn-after-read → 空间级设置弹层
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pump(const Duration(milliseconds: 500));
    final burnOk = await _waitFor(tester, 'Burn-after-read', tries: 5);
    expect(burnOk, isTrue, reason: '主菜单未出现 Burn-after-read 项');
    await tester.tap(find.text('Burn-after-read').first);
    await tester.pump(const Duration(milliseconds: 1500)); // 等弹层动画
    await _signalStep(tester, 4);
    await tester.tapAt(const Offset(20, 120)); // 点弹层外关闭
    await tester.pump(const Duration(seconds: 1));

    // 05 锁屏码首次设置：主菜单 → PIN → Set PIN 弹窗
    // （演示空间未设 PIN → 首次设置表单；截图后必须取消，绝不在演示里真设 PIN）
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pump(const Duration(milliseconds: 500));
    final pinOk = await _waitFor(tester, 'PIN', tries: 5);
    expect(pinOk, isTrue, reason: '主菜单未出现 PIN 项');
    await tester.tap(find.text('PIN').first);
    final dialogOk = await _waitFor(tester, 'Set PIN');
    expect(dialogOk, isTrue, reason: 'Set PIN 弹窗未出现');
    FocusManager.instance.primaryFocus?.unfocus(); // 收键盘：弹窗是主体，键盘抢戏
    await tester.pump(const Duration(milliseconds: 800));
    await _signalStep(tester, 5);
    await tester.tap(find.byType(CancelButton).first); // 只看不设
    await tester.pump(const Duration(seconds: 1));
  });
}
