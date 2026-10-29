// AboutSheet 连接状态行测试（2026-10-11；2026-10-12 改口径）：
// 只探测**启动时定下的活地址**（effectiveServer）——可达 → 已连接；不可达 →
// 如实显示"无法连接"，**不尝试其他候选**（候选切换/兜底是启动探测的事，老板
// 2026-10-12：开发环境连 localhost 断开时，跑去显示连上了线上域名没有意义）。
// 下载入口行（2026-10-13）：URL **服务端优先**（/health 的 app_download_url）、
// **硬编码兜底**（服务端没给/探测不通）——两条路径各有单测守着。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/dns_poison_notice.dart';
import 'package:einz/data/server_bootstrap.dart';
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
  setUp(() {
    resetServerRuntimeForTest();
    ServerBootstrap.instance.reset();
  });

  tearDown(() {
    resetServerRuntimeForTest();
    ServerBootstrap.instance.reset();
  });

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

  // ---------- 选路状态 / 最近切换（3B-2，2026-10-29） ----------
  testWidgets('启动选路中 → 显示选路状态', (tester) async {
    ServerBootstrap.instance.phase.value = ServerPhase.probing;
    await _pump(tester, (server) async => const ServerHealth(ok: true));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutRouteLabel), findsOneWidget);
    expect(find.text(l10n.aboutRouteProbing), findsOneWidget);
  });

  testWidgets('选路完成 → 选路行不占位', (tester) async {
    ServerBootstrap.instance.phase.value = ServerPhase.ready;
    await _pump(tester, (server) async => const ServerHealth(ok: true));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutRouteLabel), findsNothing);
  });

  testWidgets('地址变更 → 弹层实时刷新地址与连接状态', (tester) async {
    const next = 'https://einz.farinear.cn';
    await _pump(tester, (server) async => ServerHealth(ok: server == next));
    await tester.pumpAndSettle();
    expect(find.text(kPrimaryServer), findsOneWidget);
    expect(find.text('无法连接'), findsOneWidget);

    applyEffectiveServer(next);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(next), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets('最近切换 → 显示 from → to', (tester) async {
    const next = 'https://einz.farinear.cn';
    await _pump(tester, (server) async => const ServerHealth(ok: true));
    await tester.pumpAndSettle();

    applyEffectiveServer(next);
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutLastSwitchLabel), findsOneWidget);
    expect(find.text('$kPrimaryServer → $next'), findsOneWidget);
  });

  testWidgets('下载入口：服务端没给 URL → 回退硬编码 releases 地址，排在版本号下方',
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

  testWidgets('下载入口：服务端下发 app_download_url → 用它，不显示硬编码地址',
      (tester) async {
    const served = 'https://example.com/einz-download';
    await _pump(tester,
        (server) async => const ServerHealth(ok: true, appDownloadUrl: served));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(served), findsOneWidget);
    expect(find.text('https://github.com/faronear/einz/releases/tag/latest'),
        findsNothing);
    expect(find.text(l10n.aboutDownloadLabel), findsOneWidget);
  });

  testWidgets('下载入口：探测不通 → 仍回退硬编码地址（入口不消失）',
      (tester) async {
    await _pump(tester, (server) async => const ServerHealth());
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutDownloadLabel), findsOneWidget);
    expect(find.text('https://github.com/faronear/einz/releases/tag/latest'),
        findsOneWidget);
  });

  // ---------- DNS 污染提示（老板 2026-10-13：放「连接状态」下方） ----------
  // 全局单槽：用例间必须清理，否则互相污染。
  setUp(() => dnsPoisonNotice.value = null);
  tearDown(() => dnsPoisonNotice.value = null);

  testWidgets('无污染事件 → 连接状态下方不出现 DNS 污染行', (tester) async {
    await _pump(tester, (server) async => const ServerHealth(ok: true));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutDnsPoisonLabel), findsNothing);
  });

  testWidgets('发生过 DoH 兜底 → 连接状态下方展示 DNS 污染行（域名+假 IP）',
      (tester) async {
    dnsPoisonNotice.value = DnsPoisonNotice(
        host: 'einz.tic.cc',
        poisonedIp: '198.51.100.7',
        at: DateTime(2026, 10, 13));    await _pump(tester, (server) async => const ServerHealth(ok: true));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutDnsPoisonLabel), findsOneWidget);
    // 假 IP 展示；真 IP 不出现在界面上（老板 2026-10-13：要保护）
    expect(l10n.aboutDnsPoisonValue('einz.tic.cc', '198.51.100.7'),
        contains('198.51.100.7'));
    expect(find.textContaining('198.51.100.7'), findsOneWidget);
    // note 整串展示（含"自动修复/已上报/真地址不展示"口径）
    expect(find.text(l10n.aboutDnsPoisonNote), findsOneWidget);
    // 「放在已连接下面」：污染行整体比连接状态行更靠下
    expect(
      tester.getTopLeft(find.text(l10n.aboutDnsPoisonLabel)).dy,
      greaterThan(tester.getTopLeft(find.text(l10n.aboutStatusLabel)).dy),
      reason: 'DNS 污染行应紧贴连接状态行下方',
    );
  });

  testWidgets('假 IP 没能捕获 → 降级"未知"，行仍在', (tester) async {
    dnsPoisonNotice.value = DnsPoisonNotice(
        host: 'einz.tic.cc',
        poisonedIp: null,
        at: DateTime(2026, 10, 13));
    await _pump(tester, (server) async => const ServerHealth(ok: true));
    await tester.pumpAndSettle();
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(find.text(l10n.aboutDnsPoisonLabel), findsOneWidget);
    expect(find.text(l10n.aboutDnsPoisonValue('einz.tic.cc', '未知')),
        findsOneWidget);
  });
}
