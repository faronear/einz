// OnlySpace app 骨架 widget 测试。
//
// 直接渲染 SetupPage 验证设置页元素（不经过 StartupGate——它依赖真实
// drift 数据库初始化，widget 测试环境用内存库；也不触发密钥生成按钮，
// 避免在测试环境加载 libsodium 原生库）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:onlyspace/l10n/app_localizations.dart';
import 'package:onlyspace/setup_page.dart';

void main() {
  testWidgets('OnlySpace 设置页首屏渲染', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: const SetupPage(),
    ));

    // AppBar 标题
    expect(find.text('OnlySpace · 设备配置'), findsOneWidget);
    // 一次性配置说明
    expect(find.text('一次性配置'), findsOneWidget);
    // 两个操作按钮
    expect(find.text('① 生成设备密钥'), findsOneWidget);
    expect(find.text('② 导入并认证'), findsOneWidget);
  });
}
