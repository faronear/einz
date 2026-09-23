// 向导「切到新步骤应聚焦第一个输入框」回归（老板 2026-09-23 实测：没有聚焦）。
//
// 背景：另一个 agent 的提交 6f9d66c 给每个步骤的首框加了 `autofocus: true`，
// 但 `autofocus` 只在**元素首次插入**时生效；向导六个步骤是同一个位置的
// TextField 被复用（switch 出来的 Column，首框类型相同）→ 切步骤时元素没重建，
// autofocus 不重触发，焦点也不会回到新步骤的输入框。
//
// 这个测试只钉"切步骤后聚焦"，不做像素对比（goldens 默认跳过）。
// 运行：flutter test test/wizard_autofocus_test.dart
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';
import 'package:einz_shared/einz_shared.dart';

final EntranceKeyPair _keyPair = EntranceKeyPair(
  entranceId: 'dev-focus',
  publicKey: Uint8List(32),
  privateKey: Uint8List(32),
);

/// 启动向导（create：空名称表 → 自动建钥 → 第 1 步「名字」）。
Future<void> _pumpCreate(WidgetTester tester) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, 'multiverse', const <String>[]),
      keyPairOverride: _keyPair,
    ),
  ));
  await tester.pumpAndSettle();
  // 探测成功后停在入口页（选择秘境：创建/加入）→ 进 create 流程第 1 步
  await tester.tap(find.text('创建秘境'));
  await tester.pumpAndSettle();
}

/// 填好当前步骤的必填项并进入下一步（名字 + 性别都是必填，漏了性别会停在原地）。
Future<void> _fillAndNext(WidgetTester tester, {required String name, required String gender}) async {
  await tester.enterText(find.byType(TextField).first, name);
  await tester.tap(find.text(gender));
  await tester.pumpAndSettle();
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle();
}

/// 当前第一个输入框是否持有焦点（向导里每步首框都显式传了 focusNode）。
bool _firstFieldFocused(WidgetTester tester) {
  final fields = find.byType(TextField);
  if (fields.evaluate().isEmpty) return false;
  final tf = tester.widget<TextField>(fields.first);
  return tf.focusNode?.hasFocus ?? false;
}

void main() {
  testWidgets('向导：打开第 1 步（名字）即聚焦', (WidgetTester tester) async {
    await _pumpCreate(tester);
    expect(_firstFieldFocused(tester), isTrue, reason: '第 1 步打开就该聚焦名字框');
  });

  testWidgets('向导：下一步进入第 2 步（对方名字）应聚焦', (WidgetTester tester) async {
    await _pumpCreate(tester);
    await _fillAndNext(tester, name: 'Lukas', gender: '男');
    expect(_firstFieldFocused(tester), isTrue, reason: '第 2 步应聚焦对方名字框');
  });

  testWidgets('向导：再下一步进入第 3 步（共享口令）应聚焦', (WidgetTester tester) async {
    await _pumpCreate(tester);
    await _fillAndNext(tester, name: 'Lukas', gender: '男');
    await _fillAndNext(tester, name: 'Alice', gender: '女');
    expect(_firstFieldFocused(tester), isTrue, reason: '第 3 步应聚焦口令框');
  });

  testWidgets('向导：join 流程第 1 步（开通码）应聚焦', (WidgetTester tester) async {
    await _pumpCreate(tester);
    await tester.tap(find.text('上一步')); // 回到入口页（create 第 1 步 → 入口页）
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入秘境'));
    await tester.pumpAndSettle();
    expect(_firstFieldFocused(tester), isTrue, reason: 'join 第 1 步应聚焦开通码框');
  });

  testWidgets('向导：返回上一步也应聚焦该步第一个框', (WidgetTester tester) async {
    await _pumpCreate(tester);
    await _fillAndNext(tester, name: 'Lukas', gender: '男');
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(_firstFieldFocused(tester), isTrue, reason: '返回第 1 步应聚焦名字框');
  });
}
