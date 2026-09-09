// Einz 设置向导 widget 测试。
//
// 直接渲染 SetupPage 验证向导流程（不经过 StartupGate——它依赖真实
// drift 数据库初始化）。新流程（2026-09-05，对齐 TUI）：探测服务器 →
// 自动判定身份（person 名称表空=首设备 create，非空=后续设备 join）→
// 自动生成密钥 → 按角色进入对应步骤序列。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';
import 'package:einz_shared/einz_shared.dart';

void main() {
  setUpAll(() async {
    await sodium(); // 自动建钥需要 libsodium（macOS 经 LIBSODIUM_PATH/brew 可用）
  });

  Widget wrapApp({Map<String, String> probeNames = const {}, bool probeOk = true}) {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        probeServer: (_) async => (probeOk, probeNames, <String, String>{}),
      ),
    );
  }

  testWidgets('首设备：探测空名称表 → 自动进入"我的名字"步骤（无角色选择/密钥按钮）',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp()); // probeNames 空 → create
    await tester.pumpAndSettle();

    // 新流程：不再有角色选择页，也没有"生成设备密钥"按钮
    expect(find.text('我是第一个使用者，创建新空间'), findsNothing);
    expect(find.text('① 生成设备密钥'), findsNothing);
    // 自动进入 create 步骤 1（AppBar 组合标题；输入框 label 是「我的名字」）
    expect(find.text('Einz 秘境'), findsWidgets); // AppBar 标题
    // 底部保留"上一步"（可返回检测页）与"下一步"
    expect(find.text('上一步'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
  });

  testWidgets('后续设备：探测到 personA → 自动进入"我的名字"步骤', (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp(probeNames: {'personA': 'Lukas'})); // 非空 → join
    await tester.pumpAndSettle();

    expect(find.text('我是'), findsWidgets); // 身份步骤标题
    // 点击卡片即前进（无「下一步」/对勾）：身份页不应出现 checkbox 图标
    expect(find.byIcon(Icons.check_circle), findsNothing);
    // 有名字的身份卡片直接显示名字（无名字才显示身份标签本身）
    expect(find.text('Lukas'), findsOneWidget);
    expect(find.textContaining('共有者'), findsOneWidget);
    // join step1 无「下一步」/「完成」按钮：点卡片即自动前进（老板 UX 决策）
    expect(find.text('下一步'), findsNothing);
    expect(find.text('完成'), findsNothing);
    // 点身份卡片 → 自动进入邀请码页
    await tester.tap(find.text('Lukas'));
    await tester.pumpAndSettle();
    expect(find.text('验证邀请码'), findsWidgets); // 邀请码页步骤标题（join=验证套）
  });

  testWidgets('探测失败：启动屏显示失败提示并自动重试（无输入框/信封入口）', (WidgetTester tester) async {
    await tester.pumpWidget(wrapApp(probeOk: false));
    // 启动屏失败态仍显示旋转图标（自动重试中）→ 不能用 pumpAndSettle
    // （无限动画永不 settle），用有限 pump 推进（同 setup_probe_retry_test）
    await tester.pump(); // probe future 完成 → setState → 启动屏失败态
    await tester.pump(); // 渲染启动屏新帧

    expect(find.text('暂时无法连接服务器，正在自动重试…'), findsOneWidget);
    // 品牌启动屏无 AppBar/菜单/服务器输入框：不显示离线信封入口（菜单已移除）
    expect(find.byTooltip('导入线下密保信封'), findsNothing);
  });
}
