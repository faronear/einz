// 密保信封入口可见性回归测试：信封（及邀请码）是"后续设备加入"机制——
// 仅 join（第二/三台设备）口令页显示「改用线下密保信封」入口；
// 首设备（create）没有对端设备可用信封，口令页不显示该入口。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart';

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';

/// 打开向导并走到口令页。probeNames 空=create（首设备），非空=join（后续设备）。
Future<void> pumpToPassphrase(
  WidgetTester tester, {
  required Map<String, String> probeNames,
  bool join = false,
}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, probeNames, <String, String>{}),
      // create 名字页下一步触发自动登记（_runBootstrap），需返回成功结果；
      // join 走到口令页前不登记，此 fake 不会被调用也无妨
      enrollOverride: (_) async =>
          const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
    ),
  ));
  await tester.pumpAndSettle();

  if (join) {
    // join：身份名字（自动进邀请码页）→ 邀请码（填值）→ 口令页
    await tester.tap(find.text('Lukas'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'INVITE-ABC');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
  } else {
    // create：身份名字 → 自动登记 → 口令页
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('首设备 create 口令页：不显示信封导入入口', (WidgetTester tester) async {
    await pumpToPassphrase(tester, probeNames: const {});
    expect(find.text('改用线下密保信封'), findsNothing,
        reason: '首设备没有对端设备导出的信封，不应提供信封导入入口');
  });

  testWidgets('后续设备 join 口令页：显示信封导入入口', (WidgetTester tester) async {
    await pumpToPassphrase(tester, probeNames: const {'personA': 'Lukas'}, join: true);
    expect(find.text('改用线下密保信封'), findsOneWidget,
        reason: 'join 用户可用对端导出的信封替代口令获取 Space Key');
  });

  testWidgets('create 步骤 1：性别未选点「下一步」→ 红字提醒并停留，选中后放行', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        probeServer: (_) async => (true, <String, String>{}, <String, String>{}),
        // 步骤 1 放行后自动登记（_runBootstrap）需要成功结果
        enrollOverride: (_) async =>
            const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
      ),
    ));
    await tester.pumpAndSettle();
    // 只填名字不选性别 → 下一步被拦截：红字提醒出现在选项卡下方
    await tester.enterText(find.byType(TextField), 'Lukas');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('请选择性别'), findsOneWidget, reason: '性别必选：未选应红字提醒');
    expect(find.text('关于我'), findsOneWidget, reason: '应停留在步骤 1（我的名字页）');
    // 选中「男」后下一步 → 放行进入步骤 2（伴侣页）
    await tester.tap(find.byIcon(Icons.male));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('请选择性别'), findsNothing, reason: '选中性别后提醒应消失');
    expect(find.text('关于伴侣'), findsOneWidget, reason: '应进入步骤 2（伴侣名字页）');
  });
}
