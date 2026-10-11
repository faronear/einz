// AboutSheet 连接状态行测试（2026-10-11）：
// 全候选可达 → 已连接；仅兜底外的候选可达 → 标注实际入口；全不可达 → 明确显示
// "无法连接任何服务器入口"（不许默默展示连不上的兜底地址）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/server_config.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/about_sheet.dart';

Future<void> _pump(
    WidgetTester tester, Future<ServerHealth> Function(String) probe) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: AboutSheet(probe: probe)),
  ));
}

void main() {
  testWidgets('全部候选可达（首个即主域名）→ 已连接，无实际入口附注', (tester) async {
    await _pump(tester, (server) async =>
        server == 'https://einz.tic.cc' ? const ServerHealth(ok: true) : const ServerHealth());
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget);
    expect(find.textContaining('当前实际入口'), findsNothing);
  });

  testWidgets('仅备用候选可达 → 已连接 + 如实标注实际入口', (tester) async {
    await _pump(tester, (server) async =>
        server.contains('yuanjinx') ? const ServerHealth(ok: true) : const ServerHealth());
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget);
    expect(find.textContaining('当前实际入口'), findsOneWidget);
  });

  testWidgets('全部候选不可达 → 明确显示无法连接（不冒充已连接）', (tester) async {
    await _pump(tester, (server) async => const ServerHealth());
    await tester.pumpAndSettle();
    expect(find.text('无法连接任何服务器入口（自动重试中）'), findsOneWidget);
    expect(find.text('已连接'), findsNothing);
    // 兜底名义地址仍然如实展示（语义由连接状态行说明）
    expect(find.text(effectiveServer), findsOneWidget);
  });

  testWidgets('探测中 → 检测中…', (tester) async {
    await _pump(tester, (server) => Completer<ServerHealth>().future);
    await tester.pump();
    expect(find.text('检测中…'), findsOneWidget);
  });
}
