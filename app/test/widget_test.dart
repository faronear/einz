// Einz 设置向导 widget 测试。
//
// 直接渲染 SetupPage 验证向导流程（不经过 StartupGate——它依赖真实
// drift 数据库初始化）。Multiverse 流程（2026-09-10）：探测服务器 →
// 空间入口页（新建/加入选择）→ create：名字→口令→PIN；join：
// token（preflight）→名字→口令→PIN。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/brand_logo.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';
import 'package:einz_shared/einz_shared.dart';

void main() {
  setUpAll(() async {
    await sodium(); // 自动建钥需要 libsodium（macOS 经 LIBSODIUM_PATH/brew 可用）
  });

  Widget wrapApp({
    bool probeOk = true,
    Future<SpaceJoinPreflight> Function(String token)? preflightOverride,
  }) {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        probeServer: (_) async => (probeOk, 'v2-multiverse', const <String>[]),
        preflightOverride: preflightOverride,
      ),
    );
  }

  testWidgets('探测成功 → 空间入口页：创建秘境 / 加入秘境',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();

    // Multiverse：探测成功后显示空间入口页（不再自动判定 create/join）
    expect(find.text('创建秘境'), findsOneWidget);
    expect(find.text('加入秘境'), findsOneWidget);
    // 启动屏已消失
    expect(find.byType(SpinningBrandLogo), findsNothing);
  });

  testWidgets('入口页选「创建秘境」→ 我的名字步骤', (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('创建秘境'));
    await tester.pumpAndSettle();

    // 进入 create 名字步骤（AppBar 标题 + 输入框 hint「我的名字（以后可以随时修改）」）
    expect(find.text('Einz 秘境'), findsWidgets);
    expect(find.text('我的名字（以后可以随时修改）'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
  });

  testWidgets('入口页选「加入秘境」→ token 页（粘贴/扫码）',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('加入秘境'));
    await tester.pumpAndSettle();

    // join token 输入页（粘贴邀请链接或代码 + 扫码）
    expect(find.text('输入邀请链接'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
  });

  testWidgets('join：token 校验通过（preflight）→ 空间确认卡片显示',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp(
      preflightOverride: (token) async => const SpaceJoinPreflight(
        spaceId: 'space-test',
        displayName: 'Lukas',
        status: 'waiting',
        memberCount: 1,
        slots: [
          SpaceMemberSlot(slot: 0, displayName: 'Lukas', gender: 'male', status: 'active'),
          SpaceMemberSlot(slot: 1, displayName: 'Alice', gender: 'female', status: 'pending'),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入秘境'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TOKEN-1');
    await tester.tap(find.text('下一步')); // 首次：preflight 校验 → 停留显示空间确认卡片
    await tester.pumpAndSettle();
    // 空间确认卡片显示（加入创建者的空间）；再次点「下一步」才放行到身份选择页
    expect(find.text('加入 Lukas 的空间'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('你是哪一个用户？'), findsOneWidget, reason: '确认空间后应放行到身份选择页');
  });

  testWidgets('探测失败：启动屏保持旋转 Logo、无失败文字并自动重试（无输入框/信封入口）',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp(probeOk: false));
    // 启动屏失败态仍显示旋转图标（自动重试中）→ 不能用 pumpAndSettle
    // （无限动画永不 settle），用有限 pump 推进（同 setup_probe_retry_test）
    await tester.pump(); // probe future 完成 → setState → 启动屏失败态
    await tester.pump(); // 渲染启动屏新帧

    // 品牌启动屏保持旋转 Logo、不显示失败文字（老板要求 2026-09-09 保持简洁优美）
    expect(find.byType(SpinningBrandLogo), findsOneWidget,
        reason: '启动屏旋转 Logo 应保持显示（自动重试中）');
    expect(find.text('暂时无法连接服务器，正在自动重试…'), findsNothing,
        reason: '启动屏不显示失败文字（2026-09-09 起删除）');
    // 品牌启动屏无 AppBar/菜单/服务器输入框：不显示离线信封入口（菜单已移除）
    expect(find.byTooltip('导入线下密保信封'), findsNothing);
  });
}
