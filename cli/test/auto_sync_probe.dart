// 自动补拉断线场景探测脚本（2026-09-02，验证用）：
// A 设备加载指定 store（默认 demo/store-a.json），auth 后 startWs 常驻；等待目标消息出现。
// 输出：STATUS xxx（WS 状态）、PUSH plain=xxx（WS 实时推送到达）、
//      AUTOSYNC added=N（断线重连/周期兜底的自动同步完成）。
// 用法（在 cli/ 下）：
//   dart run test/auto_sync_probe.dart <目标消息文本> [超时秒数] [store 路径] [server]
// （store/server 可省，默认 demo/store-a.json + http://127.0.0.1:3901，兼容手工 demo 环境）
import 'dart:async';
import 'dart:io';

import 'package:einz_cli/chat_core.dart';
import 'package:einz_cli/store.dart';
import 'package:einz_shared/einz_shared.dart';

Future<void> main(List<String> args) async {
  await sodium();
  final target = args.isNotEmpty ? args[0] : 'GAP-';
  final timeoutSec = args.length > 1 ? int.parse(args[1]) : 90;
  final storePath = args.length > 2 ? args[2] : 'demo/store-a.json';
  final server = args.length > 3 ? args[3] : 'http://127.0.0.1:3901';
  final store = DeviceStore.load(storePath);
  final session = ChatSession(store, storePath, server);

  await session.auth();
  session.startWs(
    onMessage: (m) {
      print('PUSH plain=${m.plain}');
      if (m.plain.contains(target)) {
        print('FOUND-VIA-PUSH');
        exit(0);
      }
    },
    onStatus: (st) => print('STATUS ${st.name}'),
    onAutoSync: (added) {
      print('AUTOSYNC added=$added');
      // 自动补拉后检查目标是否已到达（sync 已追加进展示缓存）
      if (session.messages.any((m) => m.plain.contains(target))) {
        print('FOUND-VIA-AUTOSYNC');
        exit(0);
      }
    },
  );
  stdout.writeln('READY_WAITING target=$target');
  stdout.flush();

  // 兜底轮询（WS 推送/自动补拉之外的消息通道）
  for (var i = 0; i < timeoutSec * 2; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (session.messages.any((m) => m.plain.contains(target))) {
      print('FOUND-VIA-POLL');
      exit(0);
    }
  }
  print('TIMEOUT 目标消息未到达');
  exit(1);
}
