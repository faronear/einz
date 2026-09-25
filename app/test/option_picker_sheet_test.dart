// 选项弹层（OptionPickerSheet）的可滚动性回归。
//
// 老板 2026-09-24：档位多（阅后即焚 6 档）+ 窗口不高时，原先的死 Column 会被裁掉
// 底部并报 RenderFlex overflow；改为标题/提交按钮固定、中间选项区可滚动。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/option_picker_sheet.dart' show OptionPickerItem, OptionPickerSheet, showOptionPickerSheet;

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: home,
    );

void main() {
  testWidgets('选项高于弹层上限时可滚动，不溢出', (WidgetTester tester) async {
    // 默认测试窗口 800x600 → 底部弹层最高只有 9/16（337.5px），
    // 8 个选项必然超，正是之前溢出的场景。
    const n = 8;
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showModalBottomSheet<void>(
            context: ctx,
            builder: (_) => OptionPickerSheet(
              title: '选项弹层',
              selected: '0',
              options: [
                for (var i = 0; i < n; i++)
                  OptionPickerItem(value: '$i', label: '选项$i'),
              ],
              onApply: (_) async {},
            ),
          ),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '短窗口下不应溢出');
    expect(find.byType(SingleChildScrollView), findsOneWidget, reason: '选项区可滚动');

    // 最后一个选项初始在视口外 → 向上拖动能把它带上来
    final before = tester.getTopLeft(find.text('选项${n - 1}')).dy;
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -120));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(find.text('选项${n - 1}')).dy;
    expect(after, lessThan(before), reason: '拖动后底部选项上移（真的能滚）');
  });

  testWidgets('选项少时弹层贴合内容高度（不强行撑满）', (WidgetTester tester) async {
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showModalBottomSheet<void>(
            context: ctx,
            builder: (_) => OptionPickerSheet(
              title: '选项弹层',
              selected: '0',
              options: const [
                OptionPickerItem(value: '0', label: '选项0'),
                OptionPickerItem(value: '1', label: '选项1'),
              ],
              onApply: (_) async {},
            ),
          ),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 内容矮 → 弹层不该占满 9/16 的上限
    final sheetHeight = tester.getSize(find.byType(OptionPickerSheet)).height;
    expect(sheetHeight, lessThan(337.5 - 20), reason: '矮内容应贴合内容高度');
  });

  testWidgets('经 showOptionPickerSheet 打开时可超过 9/16 上限', (WidgetTester tester) async {
    // 桌面版窗口可以是扁的：默认 9/16（600 → 337.5px）会把底部档位裁掉，
    // 老板 2026-09-25 要求允许弹层占更多高度 → 上限抬到 0.9（540px）。
    const n = 20;
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showOptionPickerSheet<void>(
            context: ctx,
            builder: (_) => OptionPickerSheet(
              title: '选项弹层',
              selected: '0',
              options: [
                for (var i = 0; i < n; i++)
                  OptionPickerItem(value: '$i', label: '选项$i'),
              ],
              onApply: (_) async {},
            ),
          ),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '矮窗口下不应溢出');
    final sheetHeight = tester.getSize(find.byType(OptionPickerSheet)).height;
    expect(sheetHeight, greaterThan(400), reason: '应能占掉大半屏（远高于 337.5）');
    expect(sheetHeight, lessThanOrEqualTo(600 * 0.9), reason: '仍不超过窗口的 90%');
  });
}
