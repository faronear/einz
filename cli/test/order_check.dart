// 排序回归验证：A/B 两台设备交错收发，断言各自 messages 的 server_sequence 严格递增。
// 用法：cd cli && dart run test/order_check.dart
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:einz_cli/store.dart';
import 'package:einz_cli/chat_core.dart';

Future<void> main() async {
  await sodium();
  final storeA = DeviceStore.load('demo/store-a.json');
  final storeB = DeviceStore.load('demo/store-b.json');
  final server = 'http://127.0.0.1:3901';

  final a = ChatSession(storeA, 'demo/store-a.json', server);
  final b = ChatSession(storeB, 'demo/store-b.json', server);

  // 确保 token 有效（server 可能重启过）
  await a.auth();
  await b.auth();
  print('✅ 双端认证 OK');

  // 交错发送 6 条：A1, B1, A2, B2, A3, B3（每步后各自 sync 拉齐）
  for (var i = 1; i <= 3; i++) {
    final msgA = 'A$i-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final msgB = 'B$i-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final okA = await a.sendText(msgA);
    final okB = await b.sendText(msgB);
    await a.sync();
    await b.sync();
    print('  第 $i 轮: A发=$okA B发=$okB');
  }
  await a.sync();
  await b.sync();

  // 断言排序
  final okA = checkOrder(a, 'A');
  final okB = checkOrder(b, 'B');
  if (okA && okB) {
    print('✅ 排序正确：两边 messages 均按 server_sequence 严格递增');
    exit(0);
  } else {
    print('❌ 排序有误');
    exit(1);
  }
}

bool checkOrder(ChatSession s, String name) {
  final msgs = s.messages;
  print('--- $name 端 messages（${msgs.length} 条）---');
  int? prev;
  var ok = true;
  for (final m in msgs) {
    final seq = m.seq;
    final who = m.isMine ? '我' : '对方';
    print('  seq=${seq} $who v${m.keyVersion} ${m.plain}');
    if (seq == null) {
      print('  ⚠️  seq=null（离线未同步？在线场景不应出现）');
      ok = false;
      continue;
    }
    if (prev != null && seq <= prev) {
      print('  ❌ 乱序: $seq <= $prev');
      ok = false;
    }
    prev = seq;
  }
  return ok;
}
