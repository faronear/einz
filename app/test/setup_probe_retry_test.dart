// 检测页自动重试回归测试：首次探测失败（服务端不可达）→ 启动周期重试 →
// 服务器就绪后 4 秒内自动进入向导（不必等用户手动输入新地址）。
// 修复回归：_initServer 的 probe 失败是正常返回 ok=false（不抛异常），
// 之前 _startProbeRetry 只在 catch 分支调用导致重试从未启动。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';

void main() {
  testWidgets('检测页自动重试：服务器就绪后自动进入向导', (WidgetTester tester) async {
    var probeCalls = 0;
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        // 第一次探测失败（服务端不可达），之后成功（服务器就绪）
        probeServer: (_) async {
          probeCalls++;
          return (probeCalls > 1, <String, String>{}, <String, String>{});
        },
      ),
    ));
    // 首次探测失败 → 启动屏显示失败提示（自动重试已启动，等待周期触发）。
    // 注意：启动屏失败态仍显示旋转图标（自动重试中）→ 不能用 pumpAndSettle
    // （无限动画永不 settle），用有限 pump 推进。
    await tester.pump(); // probe future 完成 → setState → 启动屏失败态
    await tester.pump(); // 渲染启动屏新帧
    expect(find.text('暂时无法连接服务器，正在自动重试…'), findsOneWidget);
    expect(probeCalls, 1);

    // 4 秒重试周期触发 → 第二次探测成功 → 自动进入 create 步骤 1（名字页）
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(); // _reprobe future 完成 → 角色判定 → 进入向导
    await tester.pumpAndSettle();
    expect(probeCalls, greaterThanOrEqualTo(2), reason: '应已自动重新探测');
    expect(find.text('暂时无法连接服务器，正在自动重试…'), findsNothing,
        reason: '失败提示应消失（已连上）');
    // create 步骤 1 的 AppBar 组合标题（输入框 label 为「我的名字」）
    expect(find.text('Einz 秘境'), findsWidgets, reason: '应自动进入向导名字页');
  });
}
