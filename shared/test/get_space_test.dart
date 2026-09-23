// ApiClient.getSpace 单测：本地 HttpServer 模拟 /space 响应，
// 验证 SpaceResult 解析（entrance_id → partner_id 映射，多通道凭证语义）。

import 'dart:convert';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

void main() {
  test('getSpace 解析通道列表（含 partner_id 映射）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      expect(req.headers.value(HttpHeaders.authorizationHeader), 'Bearer tok-1');
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'space_id': 'space-test',
          'entrances': [
            {'entrance_id': 'dev-a1', 'partner_id': 'partner-a', 'status': 'active', 'last_seen': 1000},
            {'entrance_id': 'dev-a2', 'partner_id': 'partner-a', 'status': 'active', 'last_seen': 2000},
            {'entrance_id': 'dev-b1', 'partner_id': 'partner-b', 'status': 'active'},
          ],
        }))
        ..close();
    });

    final api = ApiClient('http://127.0.0.1:${server.port}');
    final space = await api.getSpace('tok-1');
    await server.close(force: true);

    expect(space.spaceId, 'space-test');
    expect(space.entrances.length, 3);
    // partner 映射：同用户多通道（dev-a1/dev-a2 → partner-a）
    final byEntrance = {for (final d in space.entrances) d.entranceId: d.partnerId};
    expect(byEntrance['dev-a1'], 'partner-a');
    expect(byEntrance['dev-a2'], 'partner-a');
    expect(byEntrance['dev-b1'], 'partner-b');
  });

  test('SpaceResult.fromJson 直接解析（无 last_seen 兼容）', () {
    final result = SpaceResult.fromJson(jsonDecode('''
      {"space_id":"s","entrances":[{"entrance_id":"d1","partner_id":"p1","status":"active"}]}
    ''') as Map<String, dynamic>);
    expect(result.entrances.single.partnerId, 'p1');
    expect(result.entrances.single.lastSeen, isNull);
  });
}
