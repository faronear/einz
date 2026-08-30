// OnlySpace 设置向导 widget 测试。
//
// 直接渲染 SetupPage 验证向导流程（不经过 StartupGate——它依赖真实
// drift 数据库初始化；不触发密钥生成按钮，避免在测试环境加载 libsodium）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:onlyspace/l10n/app_localizations.dart';
import 'package:onlyspace/setup_page.dart';

void main() {
  Widget _wrap() => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const SetupPage(),
      );

  testWidgets('设置向导首屏：角色选择', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap());

    // 标题在 AppBar 与页面内各出现一次
    expect(find.text('选择你的情况'), findsWidgets);
    expect(find.text('我是第一个使用者，创建新空间'), findsOneWidget);
    expect(find.text('我要加入对方的空间'), findsOneWidget);
    expect(find.text('高级：导入 sealed 密钥副本'), findsOneWidget);
  });

  testWidgets('角色分流：点"创建新空间"进入设备名称步骤，未生成密钥点下一步提示先生成',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap());

    await tester.tap(find.text('我是第一个使用者，创建新空间'));
    await tester.pumpAndSettle();

    // 设备名称步骤：步骤标题 + 生成密钥按钮
    expect(find.text('设备名称'), findsOneWidget);
    expect(find.text('① 生成设备密钥'), findsOneWidget);

    // 未生成设备密钥点"下一步" → 提示先生成
    await tester.tap(find.text('下一步'));
    await tester.pump();
    expect(find.text('⚠️ 先生成设备密钥'), findsOneWidget);
  });

  testWidgets('角色分流：点"加入对方空间"进入设备名称步骤（标题切换）', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap());

    await tester.tap(find.text('我要加入对方的空间'));
    await tester.pumpAndSettle();

    expect(find.text('设备名称'), findsOneWidget);
    // 底部导航有"上一步"（可返回角色选择）
    expect(find.text('上一步'), findsOneWidget);
  });
}
