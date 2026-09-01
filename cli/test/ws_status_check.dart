// WS 断线状态追踪验证：连接 → 停 server → 检查 wsStatus/wsDownSeconds 变化。
// 不依赖 pty 渲染（pty 下 stdout 渲染被吞是 Dart 已知行为，真实终端无碍），
// 直接验证 chat_core 的断线检测逻辑。
// 用法：cd cli && dart run test/ws_status_check.dart
import 'dart:async';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:einz_cli/store.dart';
import 'package:einz_cli/chat_core.dart';

Future<void> main() async {
  await sodium();
  final store = DeviceStore.load('demo/store-a.json');
  final server = 'http://127.0.0.1:3901';
  final session = ChatSession(store, 'demo/store-a.json', server);
  await session.auth();

  // 启动 WS，等待 connected
  final connected = Completer<bool>();
  session.startWs(
    onMessage: (_) {},
    onStatus: (status) {
      if (status == WsStatus.connected && !connected.isCompleted) connected.complete(true);
    },
  );
  await connected.future.timeout(const Duration(seconds: 10));
  print('✅ WS 已连接，wsStatus=${session.wsStatus}，断线秒数=${session.wsDownSeconds}');
  if (session.wsStatus != WsStatus.connected || session.wsDownSeconds != 0) {
    print('❌ 在线状态异常'); exit(1);
  }

  // 停 server（模拟服务端断服）：按命令行匹配，比 PID 文件可靠
  print('正在停止 server…');
  Process.runSync('pkill', ['-f', 'node dist/app.js']);
  await Future<void>.delayed(const Duration(seconds: 8)); // 等 WS 检测断线 + 重连循环

  final down = session.wsStatus;
  final secs = session.wsDownSeconds;
  print('停服后：wsStatus=$down，断线秒数=$secs');
  if (down == WsStatus.connected) {
    print('❌ 未检测到断线（wsStatus 仍是 connected）'); exit(1);
  }
  if (secs <= 0) {
    print('❌ 断线秒数未开始计时'); exit(1);
  }
  print('✅ 断线状态正确：$down，已断线 ${secs}s');

  session.stopWs();
  print('🎉 WS 断线状态追踪验证通过');
  exit(0);
}
