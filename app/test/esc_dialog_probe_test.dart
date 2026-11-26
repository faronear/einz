// 探针测试：复现「Esc 在 PopScope(canPop:false) 弹窗里不生效」的根因。
// 复现路径：showDialog + PopScope(onPopInvokedWithResult 补 pop(false))，
// autofocus 按钮，然后模拟按下 Esc，看弹窗是否关闭、回调是否触发。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/widgets/dialog_keyboard.dart';

void main() {
  testWidgets('Esc on PopScope dialog with onPopInvokedWithResult',
      (tester) async {
    bool? dialogResult;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return Center(
            child: TextButton(
              onPressed: () async {
                dialogResult = await showEscDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) => PopScope(
                    canPop: false,
                    child: AlertDialog(
                      actions: [
                        FilledButton(
                          autofocus: true,
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          );
        }),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Esc 事件走真实按键派发（跟桌面按 Esc 同路径）
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // showEscDialog：Esc → 子树 DismissIntent → pop(false)，直接关闭
    expect(dialogResult, false, reason: 'Esc 应关闭弹窗并返回 false');
    expect(find.byType(AlertDialog), findsNothing);
  });
}
