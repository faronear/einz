// OnlySpace app 骨架 widget 测试。
//
// 仅验证首屏设置页元素渲染；不触发"生成设备密钥"按钮，
// 避免在测试环境加载 libsodium 原生库。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:onlyspace/main.dart';

void main() {
  testWidgets('OnlySpace 设置页首屏渲染', (WidgetTester tester) async {
    await tester.pumpWidget(const OnlySpaceApp());

    // AppBar 标题
    expect(find.text('OnlySpace · 设备配置'), findsOneWidget);
    // 一次性配置说明
    expect(find.text('一次性配置'), findsOneWidget);
    // 两个操作按钮
    expect(find.text('① 生成设备密钥'), findsOneWidget);
    expect(find.text('② 导入并认证'), findsOneWidget);
  });
}
