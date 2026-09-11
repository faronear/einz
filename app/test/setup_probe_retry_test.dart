// 检测页自动重试回归测试：首次探测失败（服务端不可达）→ 启动周期重试 →
// 服务器就绪后 4 秒内自动进入向导（不必等用户手动输入新地址）。
// 修复回归：_initServer 的 probe 失败是正常返回 ok=false（不抛异常），
// 之前 _startProbeRetry 只在 catch 分支调用导致重试从未启动。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/brand_logo.dart';
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
          return (probeCalls > 1, 'v2-multiverse', const <String>[]);
        },
      ),
    ));
    // 首次探测失败 → 启动屏保持简洁（无失败文字，老板要求），自动重试已启动。
    // 注意：启动屏旋转 Logo 是无限动画 → 不能用 pumpAndSettle，用有限 pump 推进。
    await tester.pump(); // probe future 完成 → setState → 启动屏失败态
    await tester.pump(); // 渲染启动屏新帧
    expect(find.byType(SpinningBrandLogo), findsOneWidget, reason: '启动屏旋转 Logo 应保持显示');
    expect(find.text('暂时无法连接服务器，正在自动重试…'), findsNothing,
        reason: '启动屏不显示失败文字（保持简洁优美，老板要求 2026-09-09）');
    expect(probeCalls, 1);

    // 4 秒重试周期触发 → 第二次探测成功 → 自动进入空间入口页（Multiverse：
    // 不再自动判定 create/join，由用户选择新建/加入）
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(); // _reprobe future 完成 → 入口页
    await tester.pumpAndSettle();
    expect(probeCalls, greaterThanOrEqualTo(2), reason: '应已自动重新探测');
    expect(find.text('暂时无法连接服务器，正在自动重试…'), findsNothing,
        reason: '启动屏始终无失败文字');
    expect(find.byType(SpinningBrandLogo), findsNothing, reason: '进入向导后启动屏应消失');
    // 空间入口页（创建秘境 / 加入秘境）
    expect(find.text('创建秘境'), findsOneWidget, reason: '应自动进入空间入口页');
    expect(find.text('加入秘境'), findsOneWidget);
  });
}
