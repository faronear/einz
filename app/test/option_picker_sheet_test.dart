// 选项弹层（OptionPickerSheet）的可滚动性回归。
//
// 老板 2026-09-24：档位多（阅后即焚 6 档）+ 窗口不高时，原先的死 Column 会被裁掉
// 底部并报 RenderFlex overflow；改为标题/提交按钮固定，中间选项区可滚动。
//
// 2026-10-15：scopeAllLabel 勾选框（「应用于本机所有秘境」）回归——固定位渲染、
// 点选即生效模式下勾选态随 onApply 的 scopeAll 交出。

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
              onApply: (_, {bool scopeAll = false}) async {},
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
              onApply: (_, {bool scopeAll = false}) async {},
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
    // 桌面版窗口可以是扁的：默认 9/16（600 → 337.5px）会把底部档位裁掉。
    // 2026-09-25 先抬到 0.9（540）；2026-10-02 起统一改成 `isScrollControlled: true`
    // = **可用满窗高**（与「我的通道」等弹层同口径），所以上限是窗口高度本身。
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
              onApply: (_, {bool scopeAll = false}) async {},
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
    expect(sheetHeight, lessThanOrEqualTo(600.0), reason: '上限 = 满窗高（不再卡 90%）');
  });

  testWidgets('scopeAllLabel：勾选框固定渲染在选项区上方（阅读顺序=交互顺序），勾选态随 onApply 交出',
      (WidgetTester tester) async {
    // 记录 onApply 收到的 (value, scopeAll)
    final applied = <(String, bool)>[];
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showOptionPickerSheet<void>(
            context: ctx,
            builder: (_) => OptionPickerSheet(
              title: '选项弹层',
              selected: 'a',
              scopeAllLabel: '应用于本机所有秘境',
              options: const [
                OptionPickerItem(value: 'a', label: '甲'),
                OptionPickerItem(value: 'b', label: '乙'),
              ],
              onApply: (value, {bool scopeAll = false}) async {
                applied.add((value, scopeAll));
              },
            ),
          ),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();

    // 勾选框在（选项「甲/乙」都在它**下面**——先定作用域再选，点选即生效的
    // 弹层里若放选项下方，用户先点到选项就关闭了，没机会改范围）
    expect(find.text('应用于本机所有秘境'), findsOneWidget);
    final optionTop = tester.getTopLeft(find.text('甲')).dy;
    final checkboxTop = tester.getTopLeft(find.text('应用于本机所有秘境')).dy;
    expect(checkboxTop, lessThan(optionTop), reason: '勾选框应固定在选项区上方');

    // 不勾 → 点选：scopeAll = false
    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();
    expect(applied, [('b', false)]);

    // 勾上 → 再点同一个选项：scopeAll = true（点选即生效模式下重点选也重新触发）
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用于本机所有秘境')); // 整行可点
    await tester.pumpAndSettle();
    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();
    expect(applied.last, ('b', true));
  });

  testWidgets('不传 scopeAllLabel：不渲染勾选框', (WidgetTester tester) async {
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showOptionPickerSheet<void>(
            context: ctx,
            builder: (_) => OptionPickerSheet(
              title: '选项弹层',
              selected: 'a',
              options: const [
                OptionPickerItem(value: 'a', label: '甲'),
              ],
              onApply: (_, {bool scopeAll = false}) async {},
            ),
          ),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('提交模式：勾选框在提交按钮上方；只勾范围不改选项也能提交',
      (WidgetTester tester) async {
    final applied = <(String, bool)>[];
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showOptionPickerSheet<void>(
            context: ctx,
            builder: (_) => OptionPickerSheet(
              title: '选项弹层',
              selected: 'a',
              submitLabel: '提交',
              scopeAllLabel: '应用于本机所有秘境',
              options: const [
                OptionPickerItem(value: 'a', label: '甲'),
                OptionPickerItem(value: 'b', label: '乙'),
              ],
              onApply: (value, {bool scopeAll = false}) async {
                applied.add((value, scopeAll));
              },
            ),
          ),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();

    // 位置：选项 → 勾选框 → 提交按钮（自上而下）
    final optionTop = tester.getTopLeft(find.text('甲')).dy;
    final checkboxTop = tester.getTopLeft(find.text('应用于本机所有秘境')).dy;
    final submitTop = tester.getTopLeft(find.text('提交')).dy;
    expect(optionTop, lessThan(checkboxTop));
    expect(checkboxTop, lessThan(submitTop),
        reason: '提交模式下勾选框应在提交按钮上方（防呆：提交前统一确认）');

    // 提交按钮初始不可用（选项与作用域都没动）
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);

    // 只勾范围、不改选项 → 提交按钮可用，提交后 scopeAll=true（作用域本身是
    // 有效操作：把当前模式推广到所有空间）
    await tester.tap(find.text('应用于本机所有秘境'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(applied, [('a', true)]);
  });
}
