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
          'payload': {'entrance_id': 'dev-a', 'space_id': 'space-test'},
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
          'sender_entrance_id': 'dev-b',
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
    expect(hello.entranceId, 'dev-a');
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

  test('peer.online/peer.offline：解析 entrance_id/member_id/online_since', () async {
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
        'entrance_id': 'dev-b',
        'member_id': 'per-b',
        'online_since': 1787900000000,
      },
    }));
    conns.first.add(jsonEncode({
      'id': 0,
      'type': 'peer.offline',
      'payload': {'entrance_id': 'dev-b', 'member_id': 'per-b'},
    }));
    await Future.delayed(const Duration(milliseconds: 200));

    final online = events.whereType<WsPeerStatusEvent>().first;
    expect(online.entranceId, 'dev-b');
    expect(online.memberId, 'per-b');
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

  test('4401 + 续期没换到新 token：走退避，不再是零延迟死循环', () async {
    // 2026-09-22 实测的线上 bug：App 侧 WsRealtimeService 只更新了自己的 _token，
    // 没更新 WsClient 的那一份 → WsClient 拿旧 token 重连 → 又被 4401 关掉 →
    // 立即重连（_attempt 归零，无退避）→ 每轮消耗一次 POST /auth/challenge，
    // 几秒就把服务端 auth 配额（60/5min）打光，连累同 IP 的邀请加入 429。
    // 这道兜底：token 没变就不许立即重连，必须走退避。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var attempts = 0;
    server.listen((req) {
      if (req.uri.path != '/ws') {
        req.response.statusCode = 404;
        req.response.close();
        return;
      }
      WebSocketTransformer.upgrade(req).then((ws) {
        attempts++;
        ws.close(4401, 'UNAUTHORIZED'); // Server：一律当作 session 过期
      });
    });
    addTearDown(() => server.close(force: true));

    var reauthCalls = 0;
    final client = WsClient(
      server: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      onUnauthorized: () async {
        reauthCalls++;
        // 刻意**不**调用 client.updateToken：复现 App 侧那个漏更新的 bug
      },
    );
    client.start();
    await Future.delayed(const Duration(milliseconds: 1500));
    await client.stop();

    // 退避 1s/2s/… 下 1.5s 内最多两三轮；死循环会是成百上千次
    expect(attempts, lessThan(10), reason: 'token 没变时必须退避，不能零延迟重连');
    expect(reauthCalls, lessThan(10));
  });

  test('4401 + 每次都拿到新 token 但仍被拒：连续 3 次后转退避', () async {
    // 上一道兜底只挡"token 没变"；这一类 token **变了**但服务端照样 4401
    // （通道不在册 / 服务端不认本通道）同样会变成零延迟循环 → 同样打满限流。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var attempts = 0;
    server.listen((req) {
      if (req.uri.path != '/ws') {
        req.response.statusCode = 404;
        req.response.close();
        return;
      }
      WebSocketTransformer.upgrade(req).then((ws) {
        attempts++;
        ws.close(4401, 'UNAUTHORIZED'); // 一律拒绝
      });
    });
    addTearDown(() => server.close(force: true));

    var n = 0;
    late final WsClient client;
    client = WsClient(
      server: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      onUnauthorized: () async => client.updateToken('tok-${++n}'), // 每次都是新 token
    );
    client.start();
    await Future.delayed(const Duration(milliseconds: 1500));
    await client.stop();

    expect(n, lessThan(10), reason: '续期链路明显无效时必须退避，不能一直立即重连');
    expect(attempts, lessThan(10));
  });

  test('4401 + 续期换到新 token：立即重连（无感恢复）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var attempts = 0;
    server.listen((req) {
      if (req.uri.path != '/ws') {
        req.response.statusCode = 404;
        req.response.close();
        return;
      }
      WebSocketTransformer.upgrade(req).then((ws) {
        attempts++;
        if (attempts == 1) {
          ws.close(4401, 'UNAUTHORIZED'); // 第一次：session 过期
        } else {
          ws.add(jsonEncode({
            'id': 0,
            'type': 'hello',
            'payload': {'entrance_id': 'dev-a', 'space_id': 'space-test'},
          }));
        }
      });
    });
    addTearDown(() => server.close(force: true));

    late final WsClient client;
    client = WsClient(
      server: 'http://127.0.0.1:${server.port}',
      token: 'tok',
      // 回调里要用到 client 自己（续期后更新它持有的那份 token）→ late final 先声明
      onUnauthorized: () async => client.updateToken('tok-fresh'),
    );
    client.start();
    await Future.delayed(const Duration(milliseconds: 600));

    expect(client.token, 'tok-fresh', reason: '续期后连接用的应是新 token');
    expect(attempts, greaterThanOrEqualTo(2), reason: '拿到新 token 应立即重连');
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
