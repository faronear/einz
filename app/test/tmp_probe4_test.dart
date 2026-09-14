import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe4', (WidgetTester tester) async {
    final temp = Directory.systemTemp.createTempSync('einz_io_probe');
    final f = File('${temp.path}/x.mp4');

    // A: future 先起，再用 runAsync 开真实时间窗口
    final future = f.exists();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    debugPrint('PROBE_A window done');

    // B: 整个 await 放进 runAsync
    final v2 = await tester.runAsync(() => f.exists());
    debugPrint('PROBE_B exists=$v2');

    // A 的 future 现在完成了吗？（不 await，只看是否已 resolve）
    var done = false;
    unawaitedFuture(future.then((value) {
      done = true;
      debugPrint('PROBE_A exists=$value');
    }));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    debugPrint('PROBE_A done=$done');
    temp.deleteSync(recursive: true);
  });
}

void unawaitedFuture(Future<void> f) {}
