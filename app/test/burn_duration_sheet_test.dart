// 阅后即焚时长弹层测试（老板 2026-10-16：任意时长，对数滑动轴 1 分钟 ~ 60 天）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/burn_duration_sheet.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

void main() {
  late LocalDatabase db;

  setUp(() {
    db = LocalDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('formatBurnDuration', () {
    test('0 → 关闭', () {
      expect(formatBurnDuration(0, _zh), _zh.burnOptionOff);
    });

    test('预设档位与专用键一致', () {
      expect(formatBurnDuration(60, _zh), '1 分钟');
      expect(formatBurnDuration(300, _zh), '5 分钟');
      expect(formatBurnDuration(3600, _zh), '1 小时');
      expect(formatBurnDuration(86400, _zh), '1 天');
      expect(formatBurnDuration(604800, _zh), '7 天');
    });

    test('任意组合：天/时/分，零单位省略', () {
      expect(formatBurnDuration(3 * 86400 + 5 * 3600 + 20 * 60, _zh), '3 天 5 小时 20 分钟');
      expect(formatBurnDuration(90 * 60, _zh), '1 小时 30 分钟');
      expect(formatBurnDuration(2 * 86400, _zh), '2 天');
    });

    test('不足 1 分钟才落到秒', () {
      expect(formatBurnDuration(45, _zh), '45 秒');
    });
  });

  /// 打开弹层并把结果捕获到 [result]（null = 取消）。
  Future<void> openSheet(WidgetTester tester, int current,
      {String? scopeAllLabel,
      required ValueChanged<({int seconds, bool scopeAll})?> onResult}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(builder: (ctx) {
          return TextButton(
            onPressed: () async {
              onResult(await showBurnDurationSheet(
                context: ctx,
                current: current,
                scopeAllLabel: scopeAllLabel,
              ));
            },
            child: const Text('open'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('滑动轴', () {
    testWidgets('方位标注：1 分钟/1 小时/1 天在刻度位，右端是关闭顶点（无 60 天标签）',
        (WidgetTester tester) async {
      await openSheet(tester, 300, onResult: (_) {});

      // 预览显示时长本身（burnPreviewDelay=纯 "{duration}"）
      expect(find.text('5 分钟'), findsOneWidget, reason: '预览文案=纯时长');
      // 三个时长标注 + 右端红色加粗的「关闭」顶点（无 60 天标签）
      expect(find.text('1 分钟'), findsWidgets);
      expect(find.text('1 小时'), findsWidgets);
      expect(find.text('1 天'), findsWidgets);
      expect(find.text(_zh.burnAxisOffLabel), findsOneWidget);
      expect(find.text('60 天'), findsNothing, reason: '右端改为关闭顶点，不再标 60 天');

      // 「关闭」标注：红色 + 加粗（比其余标注醒目）
      final offStyle =
          tester.widget<Text>(find.text(_zh.burnAxisOffLabel)).style!;
      final dayStyle = tester.widget<Text>(find.text('1 天')).style!;
      expect(offStyle.color, Theme.of(tester.element(find.text(_zh.burnAxisOffLabel))).colorScheme.error);
      expect(offStyle.fontWeight, FontWeight.w600);
      expect(dayStyle.color, isNot(offStyle.color));

      // 标注位置对准刻度：1 小时在 1 分钟右侧、1 天在 1 小时右侧
      final x1m = tester.getTopLeft(find.text('1 分钟')).dx;
      final x1h = tester.getTopLeft(find.text('1 小时')).dx;
      final x1d = tester.getTopLeft(find.text('1 天')).dx;
      expect(x1h, greaterThan(x1m));
      expect(x1d, greaterThan(x1h));
      // 对数刻度：同样跨一个数量级，越往上间距越密（1 分钟→1 小时 60 倍，
      // 1 小时→1 天 24 倍）
      expect(x1d - x1h, lessThan(x1h - x1m));
    });

    testWidgets('轴下标注可点：点「1 天」跳到 1 天，点「关闭」跳到关闭顶点',
        (WidgetTester tester) async {
      ({int seconds, bool scopeAll})? result;
      await openSheet(tester, 300, onResult: (v) => result = v);

      // 点「1 天」标注 → 轴立刻跳到 1 天
      await tester.tap(find.text('1 天').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('1 天'), findsWidgets);

      // 点「关闭」标注 → 跳到右端顶点（预览翻成关闭文案）
      await tester.tap(find.text(_zh.burnAxisOffLabel));
      await tester.pumpAndSettle();
      expect(find.text(_zh.burnOptionOff), findsOneWidget);

      // 提交 → 0
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.seconds, 0);

      // 重开，点「1 小时」标注 → 1 小时
      result = null;
      await openSheet(tester, 300, onResult: (v) => result = v);
      await tester.tap(find.text('1 小时').last, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('1 小时'), findsWidgets);
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.seconds, 3600);
    });

    testWidgets('拖轴提交：结果随时长升档保持干净（分钟/小时/天）', (WidgetTester tester) async {
      ({int seconds, bool scopeAll})? result;
      await openSheet(tester, 300, onResult: (v) => result = v);

      final slider = find.byType(Slider);
      final width = tester.getSize(slider).width;

      // 拖到 ≈65% 处（1 小时~1 天区间）：应吸附到整小时
      await tester.drag(slider, Offset(0.15 * width, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.seconds, greaterThan(3600));
      expect(result!.seconds % 3600, 0, reason: '1 小时~1 天之间应细分到小时');

      // 重开，拖到 ≈85% 处（>1 天）：应吸附到整天
      result = null;
      await openSheet(tester, 300, onResult: (v) => result = v);
      await tester.drag(find.byType(Slider), Offset(0.35 * width, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.seconds, greaterThan(86400));
      expect(result!.seconds % 86400, 0, reason: '超过 1 天应只细分到天');

      // 重开，拖到 ≈30% 处（<1 小时）：应吸附到整分钟
      result = null;
      await openSheet(tester, 300, onResult: (v) => result = v);
      await tester.drag(find.byType(Slider), Offset(-0.2 * width, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.seconds <= 3600 && result!.seconds % 60 == 0, isTrue,
          reason: '1 小时内应细分到分钟');
    });

    testWidgets('拖到最右顶点 = 关闭；往左拖恢复时长', (WidgetTester tester) async {
      ({int seconds, bool scopeAll})? result;
      await openSheet(tester, 300, onResult: (v) => result = v);

      // 一路拖到最右（顶点 = 关闭）：预览翻成关闭文案
      final width = tester.getSize(find.byType(Slider)).width;
      await tester.drag(find.byType(Slider), Offset(width, 0));
      await tester.pumpAndSettle();
      expect(find.text(_zh.burnOptionOff), findsOneWidget);
      expect(find.text('5 分钟'), findsNothing, reason: '关闭后预览不再是时长');

      // 提交 → 0（关闭）
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.seconds, 0);

      // 重开（当前=0 → 顶点即关闭），往左拖 → 恢复成时长预览
      result = null;
      await openSheet(tester, 0, onResult: (v) => result = v);
      expect(find.text(_zh.burnOptionOff), findsOneWidget);
      await tester.drag(find.byType(Slider), Offset(-0.5 * width, 0));
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp('小时|分钟|天')), findsAtLeastNWidgets(2),
          reason: '从关闭顶点往左拖应恢复时长预览（预览+轴标注）');
    });

    testWidgets('点遮罩 = 取消（返回 null，不写任何值）', (WidgetTester tester) async {
      ({int seconds, bool scopeAll})? result;
      await openSheet(tester, 300, onResult: (v) => result = v);

      await tester.tapAt(const Offset(400, 60)); // 弹层外（顶部区域）
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });

  group('「应用于本机所有秘境」勾选框', () {
    testWidgets('传了标签才渲染（提交按钮上方）；默认不勾选；勾上随提交交出',
        (WidgetTester tester) async {
      ({int seconds, bool scopeAll})? result;
      await openSheet(tester, 300,
          scopeAllLabel: _zh.settingsScopeAll, onResult: (v) => result = v);

      // 勾选框在、默认不勾选（每次显式 opt-in）
      final checkbox = find.byType(Checkbox);
      expect(find.text(_zh.settingsScopeAll), findsOneWidget);
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      // 位置在提交按钮上方
      expect(tester.getTopLeft(checkbox).dy,
          lessThan(tester.getTopLeft(find.text(_zh.burnSubmit)).dy));

      // 勾上 → 提交 → scopeAll: true
      await tester.tap(find.text(_zh.settingsScopeAll));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.scopeAll, isTrue);
      expect(result!.seconds, greaterThan(0));
    });

    testWidgets('不传标签（逐条消息燃焚）→ 不渲染勾选框，scopeAll 恒 false',
        (WidgetTester tester) async {
      ({int seconds, bool scopeAll})? result;
      await openSheet(tester, 300, onResult: (v) => result = v);

      expect(find.text(_zh.settingsScopeAll), findsNothing,
          reason: '单条消息燃焚没有空间维度，不渲染勾选框');
      await tester.tap(find.text(_zh.burnSubmit));
      await tester.pumpAndSettle();
      expect(result!.scopeAll, isFalse);
    });
  });
}
