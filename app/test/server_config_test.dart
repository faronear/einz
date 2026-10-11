import 'dart:convert';
import 'dart:io';

import 'package:einz/data/server_config.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // kPrimaryServer 身兼三职（候选之首 / 全不通兜底 / 编译期覆盖的默认值与判定参照），
  // 而候选列表可以随时插新域名——这条断言守住"加了备用域名却忘了同步主域名"的漂移。
  test('候选列表第一项必须就是主域名', () {
    expect(kServerCandidates, isNotEmpty);
    expect(kServerCandidates.first, kPrimaryServer);
    expect(kServerCandidates.first, startsWith('http'));
  });

  group('probeServer DNS 污染兜底', () {
    setUp(resetDohFallbackState);
    tearDown(resetDohFallbackState);

    test('直连失败 → DoH 解析到本地真 IP → 钉扎重探成功', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        expect(req.uri.path, '/health');
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'protocol_version': '2',
          'capabilities': ['spaces'],
          'max_attachment_bytes': 4096,
        }));
        await req.response.close();
      });

      final health = await probeServer(
        'http://poisoned.einz.test:${server.port}',
        dohResolver: (host) async => InternetAddress.loopbackIPv4.address,
      );

      expect(health.ok, isTrue);
      expect(health.protocolVersion, '2');
      expect(health.maxAttachmentBytes, 4096);
      expect(pinnedServerIps['poisoned.einz.test'],
          InternetAddress.loopbackIPv4.address);
      // 顺带验证 probeServer 的唯一收口副作用仍生效
      expect(serverMaxAttachmentBytes, 4096);
    });

    test('DoH 也失败 → 保留原始失败（不钉扎、不重试）', () async {
      final health = await probeServer(
        'http://poisoned.einz.test:1',
        dohResolver: (host) async => null,
      );
      expect(health.ok, isFalse);
      expect(pinnedServerIps, isEmpty);
    });
  });
}
