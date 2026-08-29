// WsRealtimeService 单测：本地 WS server 模拟广播，
// 验证 message.new → onMessageNew 回调 + connected 状态变化。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onlyspace/data/ws_realtime_service.dart';

/// 起本地 WS server（/ws 端点），返回 (server, 已连接连接列表)。
Future<(HttpServer, List<WebSocket>)> _startWsServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final conns = <WebSocket>[];
  server.listen((req) {
    if (req.uri.path == '/ws') {
      WebSocketTransformer.upgrade(req).then((ws) {
        conns.add(ws);
        ws.add(jsonEncode({
          'id': 0,
          'type': 'hello',
          'payload': {'device_id': 'dev-a', 'space_id': 'space-test'},
        }));
      });
    } else {
      req.response.statusCode = 404;
      req.response.close();
    }
  });
  return (server, conns);
}

void main() {
  test('message.new 广播 → onMessageNew 触发 + connected 状态变化', () async {
    final (server, conns) = await _startWsServer();
    addTearDown(() => server.close(force: true));

    final service = WsRealtimeService(server: 'http://127.0.0.1:${server.port}', token: 'tok');
    var calls = 0;
    service.start(onMessageNew: () => calls++);
    await Future.delayed(const Duration(milliseconds: 400));
    expect(service.connected.value, isTrue, reason: 'WS 连接后 connected 应为 true');

    // Server 广播 message.new → 客户端触发 onMessageNew（chat_page 据此立即增量刷新）
    conns.first.add(jsonEncode({
      'id': 0,
      'type': 'message.new',
      'payload': {
        'server_sequence': 1,
        'message': {
          'v': 1,
          'message_id': 'm1',
          'space_id': 'space-test',
          'sender_device_id': 'dev-b',
          'type': 'text',
          'key_version': 1,
          'nonce': 'AA==',
          'ciphertext': 'AQ==',
        },
      },
    }));
    await Future.delayed(const Duration(milliseconds: 200));
    expect(calls, 1, reason: '收到 message.new 应触发一次 onMessageNew');

    await service.stop();
    expect(service.connected.value, isFalse, reason: 'stop 后 connected 应为 false');
  });

  test('device.revoked 广播 → onDeviceRevoked 触发（撤销登出）', () async {
    final (server, conns) = await _startWsServer();
    addTearDown(() => server.close(force: true));

    final service = WsRealtimeService(server: 'http://127.0.0.1:${server.port}', token: 'tok');
    var revoked = 0;
    service.start(onDeviceRevoked: () => revoked++);
    await Future.delayed(const Duration(milliseconds: 400));
    expect(service.connected.value, isTrue);

    // Server 广播 device.revoked → 客户端触发 onDeviceRevoked（chat_page 据此清理并登出）
    conns.first.add(jsonEncode({
      'id': 0,
      'type': 'device.revoked',
      'payload': {'device_id': 'dev-a'},
    }));
    await Future.delayed(const Duration(milliseconds: 200));
    expect(revoked, 1, reason: '收到 device.revoked 应触发一次 onDeviceRevoked');

    await service.stop();
  });
}
