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

    // 进入 create 名字步骤（AppBar 标题 wizardAppBarCreate + 输入框 hint「我的名字（以后可以随时修改）」）
    expect(find.text('创建秘境'), findsWidgets);
    expect(find.text('我的名字（以后可以随时修改）'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);

    // 名字含空格 → 下一步被拦下并出红字（老板 2026-09-16：名字字符白名单，
    // 只允许中文字/英文字母/数字/`_`/`-`/emoji）
    await tester.enterText(find.byType(TextField).first, 'Mr Lukas');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('名字只能用中文字、英文字母、数字、下划线(_)、中划线(-)和表情符'),
        findsOneWidget, reason: '含空格的名字必须被拦下并提示');
    // 仍停在名字步骤（没被放行到下一页）
    expect(find.text('我的名字（以后可以随时修改）'), findsOneWidget);
  });

  testWidgets('入口页选「加入秘境」→ token 页（粘贴/扫码）',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('加入秘境'));
    await tester.pumpAndSettle();

    // join token 输入页（标题 setupTokenTitle「验证邀请码」+ 扫码）
    expect(find.text('验证邀请码'), findsOneWidget);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
  });

  testWidgets('join：token 校验通过（preflight）→ 直接进入身份选择页',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp(
      preflightOverride: (token) async => const SpaceJoinPreflight(
        spaceId: 'space-test',
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
    await tester.tap(find.text('下一步')); // preflight 通过 → 直接进下一页（不再停留显示确认卡片）
    await tester.pumpAndSettle();
    expect(find.text('加入 Lukas 的空间'), findsNothing, reason: '不再显示空间确认卡片');
    expect(find.text('选择身份'), findsOneWidget, reason: '有效 token 应直接放行到身份选择页');
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
