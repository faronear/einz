// dns_fallback 单测：DoH 应答解析、IP 钉扎经 connectionFactory 生效（Host 头
// 保持真域名）、TLS 失败/陈旧 pin 的自愈清除、probeWithDohFallback 流程与
// 60s 速率闸。全程本地 HttpServer/ServerSocket，无外网依赖。

import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

void main() {
  setUp(resetDohFallbackState);
  tearDown(resetDohFallbackState);

  group('parseDohAnswer', () {
    test('Status=0 + A 记录 → 返回 IP', () {
      const body = '{"Status":0,"Answer":[{"name":"x.test.","type":1,'
          '"TTL":300,"data":"36.154.238.42"}]}';
      expect(parseDohAnswer(body), '36.154.238.42');
    });

    test('CNAME+A 混合 → 取 type=1 的那条', () {
      const body = '{"Status":0,"Answer":['
          '{"name":"x.test.","type":5,"TTL":300,"data":"y.test."},'
          '{"name":"y.test.","type":1,"TTL":300,"data":"1.2.3.4"}]}';
      expect(parseDohAnswer(body), '1.2.3.4');
    });

    test('Status≠0 → null', () {
      expect(
          parseDohAnswer('{"Status":3,"Answer":[{"type":1,"data":"1.2.3.4"}]}'),
          isNull);
    });

    test('坏 JSON → null', () {
      expect(parseDohAnswer('not json'), isNull);
    });

    test('非 IPv4 data（如 AAAA 值混入）→ null', () {
      const body = '{"Status":0,"Answer":[{"type":1,"data":"::1"}]}';
      expect(parseDohAnswer(body), isNull);
    });

    test('无 Answer → null', () {
      expect(parseDohAnswer('{"Status":0}'), isNull);
    });
  });

  group('createPinnedHttpClient', () {
    test('pin 生效：假域名经钉扎 IP 连通，Host 头保持真域名', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? hostHeader;
      server.listen((req) async {
        hostHeader = req.headers.value(HttpHeaders.hostHeader);
        req.response.statusCode = 200;
        await req.response.close();
      });
      setServerPin('fake.einz.test', InternetAddress.loopbackIPv4.address);

      final client = createPinnedHttpClient();
      addTearDown(() => client.close(force: true));
      final res = await client
          .getUrl(Uri.parse('http://fake.einz.test:${server.port}/health'))
          .then((r) => r.close());
      await res.drain<void>();

      expect(res.statusCode, 200);
      expect(hostHeader, 'fake.einz.test:${server.port}');
    });

    test('无 pin → 正常按域名解析（本例应解析失败）', () async {
      final client = createPinnedHttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        client
            .getUrl(Uri.parse('http://no-such-host.einz.invalid/'))
            .then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
    });

    test('TLS 失败路径：钉到纯 TCP 监听 → 握手失败且 pin 被清除', () async {
      // 纯 TCP（非 TLS）监听：TLS ClientHello 不会得到应答，握手必然失败——
      // 证明证书校验未被绕过（若被绕过，请求会"成功"收到非 TLS 垃圾或挂住）。
      final plain = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plain.close());
      plain.listen((s) => s.destroy());
      setServerPin('tls-fail.einz.test', InternetAddress.loopbackIPv4.address);

      final client = createPinnedHttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        client
            .getUrl(Uri.parse('https://tls-fail.einz.test:${plain.port}/'))
            .then((r) => r.close()),
        // 新版 Dart SDK 对纯 TCP 监听上的 TLS 握手抛 HandshakeException，
        // 旧版抛 SocketException——两者都证明握手失败、证书未被绕过。
        throwsA(anyOf(isA<SocketException>(), isA<HandshakeException>())),
      );
      expect(pinnedServerIps.containsKey('tls-fail.einz.test'), isFalse);
    });

    test('陈旧 pin：钉到已关闭端口 → SocketException 且 pin 被清除', () async {
      final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close(force: true);
      setServerPin('stale.einz.test', InternetAddress.loopbackIPv4.address);

      final client = createPinnedHttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        client
            .getUrl(Uri.parse('http://stale.einz.test:$deadPort/'))
            .then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
      expect(pinnedServerIps.containsKey('stale.einz.test'), isFalse);
    });
  });

  group('probeWithDohFallback', () {
    test('首次成功 → 不调 DoH', () async {
      var resolverCalls = 0;
      final r = await probeWithDohFallback<bool>(
        'http://ok.einz.test',
        () async => true,
        ok: (v) => v,
        dohResolver: (h) async {
          resolverCalls++;
          return '1.2.3.4';
        },
      );
      expect(r, isTrue);
      expect(resolverCalls, 0);
      expect(pinnedServerIps, isEmpty);
    });

    test('直连失败 → DoH 给本地真 IP → 钉扎重试成功 + 污染钩子触发', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 200;
        await req.response.close();
      });

      var hookCalls = <String>[];
      onDnsPoisonDetected = (host, ip) => hookCalls.add('$host@$ip');
      addTearDown(() => onDnsPoisonDetected = null);

      // attempt 走钉扎工厂：无 pin 时假域名解析失败 → false
      Future<bool> attempt() async {
        final client = createPinnedHttpClient();
        try {
          final res = await client
              .getUrl(Uri.parse(
                  'http://poisoned.einz.test:${server.port}/health'))
              .then((r) => r.close());
          await res.drain<void>();
          return res.statusCode == 200;
        } on SocketException {
          return false;
        } finally {
          client.close(force: true);
        }
      }

      final ok = await probeWithDohFallback<bool>(
        'http://poisoned.einz.test:${server.port}',
        attempt,
        ok: (v) => v,
        dohResolver: (h) async => InternetAddress.loopbackIPv4.address,
      );
      expect(ok, isTrue);
      expect(pinnedServerIps['poisoned.einz.test'],
          InternetAddress.loopbackIPv4.address);
      await Future<void>.delayed(Duration.zero); // 上报/钩子是 fire-and-forget
      expect(hookCalls, [
        'poisoned.einz.test@${InternetAddress.loopbackIPv4.address}'
      ], reason: 'DoH 与系统解析分歧（= 污染）必须触发警报钩子');
    });

    test('DoH 失败（null）→ 返回原始失败结果，不钉扎', () async {
      var attempts = 0;
      final r = await probeWithDohFallback<bool>(
        'http://poisoned.einz.test',
        () async {
          attempts++;
          return false;
        },
        ok: (v) => v,
        dohResolver: (h) async => null,
      );
      expect(r, isFalse);
      expect(attempts, 1); // 只试一次，不做无谓重试
      expect(pinnedServerIps, isEmpty);
    });

    test('60s 速率闸：闸内第二次失败不再调 resolver', () async {
      var resolverCalls = 0;
      Future<bool> attempt() async => false;
      for (var i = 0; i < 2; i++) {
        await probeWithDohFallback<bool>(
          'http://gated.einz.test',
          attempt,
          ok: (v) => v,
          dohResolver: (h) async {
            resolverCalls++;
            return null;
          },
        );
      }
      expect(resolverCalls, 1);
    });

    test('IP 字面量 / localhost 不触发 DoH', () async {
      var resolverCalls = 0;
      Future<String?> resolver(String h) async {
        resolverCalls++;
        return null;
      }

      await probeWithDohFallback<bool>('http://127.0.0.1:1', () async => false,
          ok: (v) => v, dohResolver: resolver);
      await probeWithDohFallback<bool>('http://localhost:1', () async => false,
          ok: (v) => v, dohResolver: resolver);
      expect(resolverCalls, 0);
    });
  });
}
