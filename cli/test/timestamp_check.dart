// 存量时间戳回填验证（2026-09-02，自包含版）：脚本内拉起 server 子进程（用完即杀），
// 加载 store-a → auth → sync()，打印修复前后 history 的 created_at。
// store-a 当前含真实坏数据（created_at=1,2,3,13,14,15，旧版本 sync 落盘 seq 所致）。
// 用法（在 cli/ 下）：dart run test/timestamp_check.dart
import 'dart:convert';
import 'dart:io';

import 'package:einz_cli/chat_core.dart';
import 'package:einz_cli/store.dart';
import 'package:einz_shared/einz_shared.dart';

Future<void> main() async {
  await sodium();
  const port = 3902;
  final base = 'http://127.0.0.1:$port';
  final rootDir = Directory.current.parent.path; // cli/.. = einz 根
  final serverDir = '${rootDir}/server';

  // 1) 拉起临时 server（子进程，结束时杀掉）
  final proc = await Process.start('node', ['dist/app.js'], workingDirectory: serverDir, environment: {
    'EINZ_DB': '$rootDir/cli/demo/einz.sqlite.db',
    'EINZ_FILES': '$rootDir/cli/demo/files',
    'PORT': '$port',
  });
  proc.stderr.transform(utf8.decoder).listen((_) {});
  proc.stdout.transform(utf8.decoder).listen((_) {});
  final client = HttpClient();
  var ready = false;
  for (var i = 0; i < 60; i++) {
    try {
      final req = await client.getUrl(Uri.parse('$base/devices'));
      final res = await req.close();
      res.drain<void>();
      if (res.statusCode != 0) {
        ready = true;
        break;
      }
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  if (!ready) {
    stdout.writeln('❌ server 未就绪');
    proc.kill();
    exit(1);
  }

  try {
    final storePath = 'demo/store-a.json';
    final store = DeviceStore.load(storePath);
    final badBefore =
        store.history.where((m) => (m['created_at'] as int? ?? 0) < 100000000000).length;
    stdout.writeln('修复前坏时间戳条数: $badBefore / ${store.history.length}');
    stdout.writeln('修复前样例: ${store.history.map((m) => 'seq=${m['server_sequence']} ca=${m['created_at']}').join(' | ')}');

    final session = ChatSession(store, storePath, base);
    await session.auth();
    await session.sync(); // 内部触发 _backfillTimestamps

    final store2 = DeviceStore.load(storePath); // 重新读盘确认已修复
    final badAfter =
        store2.history.where((m) => (m['created_at'] as int? ?? 0) < 100000000000).length;
    stdout.writeln('修复后坏时间戳条数: $badAfter / ${store2.history.length}');
    stdout.writeln('修复后样例: ${store2.history.map((m) => 'seq=${m['server_sequence']} ca=${m['created_at']}').join(' | ')}');
    stdout.writeln(badAfter == 0 ? '✅ 存量坏时间戳已全部回填为真实值' : '❌ 仍有 $badAfter 条坏时间戳');
    exit(badAfter == 0 ? 0 : 1);
  } finally {
    proc.kill();
    client.close(force: true);
  }
}
