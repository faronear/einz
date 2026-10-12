// AboutSheet 连接状态行测试（2026-10-11；2026-10-12 改口径）：
// 只探测**启动时定下的活地址**（effectiveServer）——可达 → 已连接；不可达 →
// 如实显示"无法连接"，**不尝试其他候选**（候选切换/兜底是启动探测的事，老板
// 2026-10-12：开发环境连 localhost 断开时，跑去显示连上了线上域名没有意义）。
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
  testWidgets('启动定下的活地址可达 → 已连接', (tester) async {
    await _pump(tester, (server) async =>
        server == 'https://einz.tic.cc' ? const ServerHealth(ok: true) : const ServerHealth());
    await tester.pumpAndSettle();
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets('启动地址不可达（其他候选可达）→ 仍显示无法连接，不尝试其他候选',
      (tester) async {
    // 老板 2026-10-12：About 只认启动时定下的活地址；别的候选可达也不改口。
    await _pump(tester, (server) async =>
        server.contains('yuanjinx') ? const ServerHealth(ok: true) : const ServerHealth());
    await tester.pumpAndSettle();
    expect(find.text('无法连接'), findsOneWidget);
    expect(find.text('已连接'), findsNothing);
  });

  testWidgets('全部不可达 → 明确显示无法连接（不冒充已连接）', (tester) async {
    await _pump(tester, (server) async => const ServerHealth());
    await tester.pumpAndSettle();
    expect(find.text('无法连接'), findsOneWidget);
    expect(find.text('已连接'), findsNothing);
    // 兜底名义地址仍然如实展示（语义由连接状态行说明）
    expect(find.text(effectiveServer), findsOneWidget);
  });

  testWidgets('探测中 → 检测中…', (tester) async {
    await _pump(tester, (server) => Completer<ServerHealth>().future);
    await tester.pump();
    expect(find.text('检测中…'), findsOneWidget);
  });

  testWidgets('版本号下有下载入口：releases 链接原样展示且排在版本号下方',
      (tester) async {
    await _pump(tester, (server) async => const ServerHealth(ok: true));
    await tester.pumpAndSettle();
    // 绑 l10n 键不绑字面（文案常改）
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutDownloadLabel), findsOneWidget);
    // URL 原样展示：打不开浏览器时用户能手抄（同 version_gate 口径）
    expect(find.text('https://github.com/faronear/einz/releases/tag/latest'),
        findsOneWidget);
    // 「在版本号下」：下载行整体比版本号行更靠下
    expect(
      tester.getTopLeft(find.text(l10n.aboutDownloadLabel)).dy,
      greaterThan(tester.getTopLeft(find.text(l10n.aboutVersionLabel)).dy),
      reason: '下载入口应排在版本号下一行',
    );
  });
}
