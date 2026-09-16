// WsClient 单测：本地 HttpServer + WebSocketTransformer 模拟 Server /ws 端点，
// 验证连接、事件解析（hello/message.new/未知帧——含已撤除的 key.rotation）、断线重连状态。

import 'dart:convert';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

/// 起本地 WS server（/ws 端点），返回 (server, baseUrl, 已连接连接列表)。
Future<(HttpServer, String, List<WebSocket>)> _startWsServer() async {
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
  return (server, 'http://127.0.0.1:${server.port}', conns);
}

Map<String, dynamic> _messageNewFrame(int seq) => {
      'id': 0,
      'type': 'message.new',
      'payload': {
        'server_sequence': seq,
        'message': {
          'v': 1,
          'message_id': 'msg-$seq',
          'space_id': 'space-test',
          'sender_device_id': 'dev-b',
          'type': 'text',
          'key_version': 1,
          'nonce': 'AA==',
          'ciphertext': 'AQ==',
        },
      },
    };

void main() {
  test('连接成功：hello 事件 + connected 状态', () async {
    final (server, base, _) = await _startWsServer();
    addTearDown(() => server.close(force: true));
    final events = <WsEvent>[];
    final statuses = <WsStatus>[];
    final client = WsClient(server: base, token: 'tok', onEvent: events.add, onStatus: statuses.add);
    client.start();
    await Future.delayed(const Duration(milliseconds: 400));

    expect(statuses, contains(WsStatus.connected));
    final hello = events.whereType<WsHelloEvent>().single;
    expect(hello.deviceId, 'dev-a');
    expect(hello.spaceId, 'space-test');
    await client.stop();
  });

  test('message.new 事件：解析出信封与 server_sequence', () async {
    final (server, base, conns) = await _startWsServer();
    addTearDown(() => server.close(force: true));
    final events = <WsEvent>[];
    final client = WsClient(server: base, token: 'tok', onEvent: events.add);
    client.start();
    await Future.delayed(const Duration(milliseconds: 300));

    conns.first.add(jsonEncode(_messageNewFrame(42)));
    await Future.delayed(const Duration(milliseconds: 200));

    final ev = events.whereType<WsMessageNewEvent>().single;
    expect(ev.serverSequence, 42);
    expect(ev.message.messageId, 'msg-42');
    expect(ev.message.type, 'text');
    await client.stop();
  });

  test('peer.online/peer.offline：解析 device_id/person_id/online_since', () async {
    final (server, base, conns) = await _startWsServer();
    addTearDown(() => server.close(force: true));
    final events = <WsEvent>[];
    final client = WsClient(server: base, token: 'tok', onEvent: events.add);
    client.start();
    await Future.delayed(const Duration(milliseconds: 300));

    conns.first.add(jsonEncode({
      'id': 0,
      'type': 'peer.online',
      'payload': {
        'device_id': 'dev-b',
        'person_id': 'per-b',
        'online_since': 1787900000000,
      },
    }));
    conns.first.add(jsonEncode({
      'id': 0,
      'type': 'peer.offline',
      'payload': {'device_id': 'dev-b', 'person_id': 'per-b'},
    }));
    await Future.delayed(const Duration(milliseconds: 200));

    final online = events.whereType<WsPeerStatusEvent>().first;
    expect(online.deviceId, 'dev-b');
    expect(online.personId, 'per-b');
    expect(online.onlineSince, 1787900000000);
    // 离线帧不带该字段（已下线，上线时刻无意义）
    expect(events.whereType<WsPeerStatusEvent>().last.onlineSince, isNull);
    await client.stop();
  });

  test('未知类型帧被忽略', () async {
    final (server, base, conns) = await _startWsServer();
    addTearDown(() => server.close(force: true));
    final events = <WsEvent>[];
    final client = WsClient(server: base, token: 'tok', onEvent: events.add);
    client.start();
    await Future.delayed(const Duration(milliseconds: 300));

    // key.rotation 自 2026-09-14 起不再是协议帧（轮换方案不做，见 docs/SECURITY.md），
    // 与任意未知帧一样必须被安全忽略——旧服务器仍可能下发。
    conns.first.add(jsonEncode({'id': 0, 'type': 'unknown.event', 'payload': {}}));
    conns.first.add(jsonEncode({'id': 0, 'type': 'key.rotation', 'payload': {'key_version': 2}}));
    await Future.delayed(const Duration(milliseconds: 200));

    expect(events.where((e) => e.type == 'unknown.event'), isEmpty);
    expect(events.where((e) => e.type == 'key.rotation'), isEmpty);
    await client.stop();
  });

  test('服务器断开 → reconnecting 状态（自动重连）', () async {
    final (server, base, conns) = await _startWsServer();
    addTearDown(() => server.close(force: true));
    final statuses = <WsStatus>[];
    final client = WsClient(server: base, token: 'tok', onStatus: statuses.add);
    client.start();
    await Future.delayed(const Duration(milliseconds: 300));
    expect(statuses, contains(WsStatus.connected));

    await conns.first.close(); // Server 断开
    await Future.delayed(const Duration(milliseconds: 200));

    expect(statuses, contains(WsStatus.reconnecting));
    // 退避 1s 后应重连成功（等待验证）
    await Future.delayed(const Duration(milliseconds: 1600));
    expect(statuses, contains(WsStatus.connected));
    await client.stop();
  });
}
