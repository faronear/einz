// LockPage 锁屏激活条件回归测试：锁屏仅在设置过 PIN（有锁包）时激活——
// 未设置 PIN（向导跳过 PIN 的明文配置）时显示提示，不显示解锁表单，
// 避免"无法解锁、跳不出去"的死锁（老板决策：PIN 锁屏仅当 PIN 非空才激活）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/lock_page.dart';

void main() {
  testWidgets('未设置 PIN（无锁包）：锁屏不激活，显示提示且无解锁表单', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: LockPage(db: db),
    ));
    await tester.pumpAndSettle();

    // 无锁包 → 显示"未设置 PIN 锁屏"提示（不激活锁屏）
    expect(find.text('尚未设置锁屏码（为空时不启用）'), findsOneWidget);
    // 不显示解锁输入框与解锁按钮（避免死锁）
    expect(find.byType(TextField), findsNothing);
    expect(find.text('解锁'), findsNothing);
  });
}
