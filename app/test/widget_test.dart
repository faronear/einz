// OnlySpace app 骨架 widget 测试。
//
// 仅验证首屏骨架元素渲染；不触发"生成设备密钥"按钮，
// 避免在测试环境加载 libsodium 原生库。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:onlyspace/main.dart';

void main() {
  testWidgets('OnlySpace 骨架首屏渲染', (WidgetTester tester) async {
    await tester.pumpWidget(const OnlySpaceApp());

    // AppBar 标题
    expect(find.text('OnlySpace'), findsOneWidget);
    // 产品定位文案
    expect(find.text('两个人的私密聊天与共享私人空间'), findsOneWidget);
    // shared 接入说明
    expect(find.textContaining('shared 核心包'), findsOneWidget);
    // 生成设备密钥按钮
    expect(find.widgetWithText(FilledButton, '生成设备密钥'), findsOneWidget);
  });
}
