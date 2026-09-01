// ApiClient.getSpace 单测：本地 HttpServer 模拟 /space 响应，
// 验证 SpaceResult 解析（device_id → person_id 映射，多设备身份语义）。

import 'dart:convert';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

void main() {
  test('getSpace 解析设备列表（含 person_id 映射）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      expect(req.headers.value(HttpHeaders.authorizationHeader), 'Bearer tok-1');
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'space_id': 'space-test',
          'devices': [
            {'device_id': 'dev-a1', 'person_id': 'person-a', 'status': 'active', 'last_seen': 1000},
            {'device_id': 'dev-a2', 'person_id': 'person-a', 'status': 'active', 'last_seen': 2000},
            {'device_id': 'dev-b1', 'person_id': 'person-b', 'status': 'active'},
          ],
        }))
        ..close();
    });

    final api = ApiClient('http://127.0.0.1:${server.port}');
    final space = await api.getSpace('tok-1');
    await server.close(force: true);

    expect(space.spaceId, 'space-test');
    expect(space.devices.length, 3);
    // person 映射：同用户多设备（dev-a1/dev-a2 → person-a）
    final byDevice = {for (final d in space.devices) d.deviceId: d.personId};
    expect(byDevice['dev-a1'], 'person-a');
    expect(byDevice['dev-a2'], 'person-a');
    expect(byDevice['dev-b1'], 'person-b');
  });

  test('SpaceResult.fromJson 直接解析（无 last_seen 兼容）', () {
    final result = SpaceResult.fromJson(jsonDecode('''
      {"space_id":"s","devices":[{"device_id":"d1","person_id":"p1","status":"active"}]}
    ''') as Map<String, dynamic>);
    expect(result.devices.single.personId, 'p1');
    expect(result.devices.single.lastSeen, isNull);
  });
}
