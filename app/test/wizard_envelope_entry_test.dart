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

/// 打开向导并走到口令页。join=true 走 Multiverse join 路径（入口页 → token
/// preflight → 名字 → 口令）；false=create（首设备，名字页——createSpace 无
/// fake 注入，名字页下一步即红字拦截，断言只查"无信封入口"仍成立）。
Future<void> pumpToPassphrase(
  WidgetTester tester, {
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
      probeServer: (_) async => (true, 'v2-multiverse', const <String>[]),
      // Multiverse join：token 校验（preflight）用 fake——默认走真实 ApiClient
      preflightOverride: join
          ? (token) async => const SpaceJoinPreflight(
              spaceId: 'space-test',
              displayName: 'Lukas',
              status: 'waiting',
              memberCount: 1,
              slots: [
                SpaceMemberSlot(slot: 0, displayName: 'Lukas', gender: 'male', status: 'active'),
                SpaceMemberSlot(slot: 1, displayName: 'Alice', gender: 'female', status: 'pending'),
              ],
            )
          : null,
      // create 名字页下一步触发 Multiverse 创建（_runBootstrap → POST /spaces），
      // 需 createOverride fake 返回成功结果才能放行到口令页
      createOverride: () async => const SpaceCreateResult(
        spaceId: 'space-test',
        spaceAddress: '0x00',
        joinToken: 'tok-1',
        link: 'https://einz.tic.cc/join/tok-1',
        expiresAt: 9999999999,
        deviceId: 'dev1',
        creatorPersonId: 'personA',
        sessionToken: 'tok',
      ),
      // join 走到口令页前不登记，此 fake 不会被调用也无妨
      enrollOverride: (_) async =>
          const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test'),
    ),
  ));
  await tester.pumpAndSettle();

  if (join) {
    // join：入口页 → 加入 → token 页（preflight 通过）→ 身份选择页（选第二人）→ 口令页
    await tester.tap(find.text('加入秘境'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TOKEN-1');
    await tester.tap(find.text('下一步')); // preflight 通过 → 直接进身份选择页（不再显示确认卡片）
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Alice')); // 选第二人（伴侣）
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle(); // → 口令页
  } else {
    // create：入口页 → 新建 → 名字页（填名字+性别）→ 伴侣页（填名字+性别）→ 口令页
    await tester.tap(find.text('创建秘境'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Lukas');
    await tester.tap(find.byIcon(Icons.male)); // 选性别男
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle(); // → 伴侣页
    await tester.enterText(find.byType(TextField), 'Alice');
    await tester.tap(find.byIcon(Icons.female)); // 选伴侣性别女
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle(); // → 口令页
  }
}

void main() {
  testWidgets('首设备 create 口令页：不显示信封导入入口', (WidgetTester tester) async {
    await pumpToPassphrase(tester);
    expect(find.byIcon(Icons.mail_outline), findsNothing,
        reason: '首设备没有对端设备导出的信封，不应提供信封导入入口');
  });

  testWidgets('后续设备 join 口令页：显示信封导入入口', (WidgetTester tester) async {
    await pumpToPassphrase(tester, join: true);
    expect(find.byIcon(Icons.mail_outline), findsOneWidget,
        reason: 'join 用户可用对端导出的信封替代口令获取 Space Key（标题行右上角切换图标）');
  });

  testWidgets('create 步骤 1：名字/性别缺一不可——双红字同显、填写即消、选中放行', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        probeServer: (_) async => (true, 'v2-multiverse', const <String>[]),
        // 步骤 1 放行后触发 Multiverse 创建（_runBootstrap → POST /spaces），
        // 需 createOverride fake 返回成功结果才能放行到口令页
        createOverride: () async => const SpaceCreateResult(
          spaceId: 'space-test',
          spaceAddress: '0x00',
          joinToken: 'tok-1',
          link: 'https://einz.tic.cc/join/tok-1',
          expiresAt: 9999999999,
          deviceId: 'dev1',
          creatorPersonId: 'personA',
          sessionToken: 'tok',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // Multiverse：探测成功 → 空间入口页 → 新建 → 名字页（步骤 1）
    await tester.tap(find.text('创建秘境'));
    await tester.pumpAndSettle();
    // 名字与性别都未填：点下一步 → 两项红字同时出现（统一检查，不因首个失败跳过其余）
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('填写我的名字'), findsOneWidget, reason: '名字必填：未填应红字提醒');
    expect(find.text('请选择性别'), findsOneWidget, reason: '性别必选：未选应红字提醒');
    expect(find.text('关于我'), findsOneWidget, reason: '应停留在步骤 1（我的名字页）');
    // 只填名字：旧「名字为空」红字不残留（每轮先清 + 填写即消），性别红字保留
    await tester.enterText(find.byType(TextField), 'Lukas');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('填写我的名字'), findsNothing, reason: '名字已填：旧红字不应残留');
    expect(find.text('请选择性别'), findsOneWidget, reason: '性别仍未选，红字保留');
    // 选中「男」后下一步 → 放行进入步骤 2（伴侣页）
    await tester.tap(find.byIcon(Icons.male));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('请选择性别'), findsNothing, reason: '选中性别后提醒应消失');
    expect(find.text('关于伴侣'), findsOneWidget,
        reason: '应进入步骤 2（伴侣页——名字/性别必填，老板 2026-09-10 定稿）');
  });

  testWidgets('create 口令页：口令需二次输入确认（两个输入框）', (WidgetTester tester) async {
    await pumpToPassphrase(tester); // create
    expect(find.text('设置密保口令'), findsOneWidget, reason: 'create 口令页');
    expect(find.byType(TextField), findsNWidgets(2),
        reason: '首台设备设置口令需输入两次（口令 + 确认）——老板 2026-09-12');
  });

  testWidgets('join 口令页：仅一个口令输入框（验证已有口令，无需确认）', (WidgetTester tester) async {
    await pumpToPassphrase(tester, join: true);
    expect(find.byType(TextField), findsOneWidget,
        reason: 'join 是验证已有口令，无需二次确认');
  });

  testWidgets('create 口令页：两次不一致 → 红字拦截；一致 → 放行进 PIN 页', (WidgetTester tester) async {
    await pumpToPassphrase(tester);
    expect(find.byType(TextField), findsNWidgets(2));

    // 两次不一致：停留本页 + 红字
    await tester.enterText(find.byType(TextField).at(0), 'secret-1');
    await tester.enterText(find.byType(TextField).at(1), 'secret-2');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('两次输入的口令不一致'), findsOneWidget, reason: '不一致应红字提醒');
    expect(find.text('设置密保口令'), findsOneWidget, reason: '不一致应停留口令页');

    // 改为一致：放行进入 PIN 步骤
    await tester.enterText(find.byType(TextField).at(1), 'secret-1');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('两次输入的口令不一致'), findsNothing, reason: '一致后旧红字不应残留');
    expect(find.text('设置锁屏码'), findsOneWidget, reason: '一致应放行进 PIN 步骤');
  });
}
