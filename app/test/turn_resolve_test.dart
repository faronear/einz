// resolveTurnUrls 单测：TURN 地址的 DoH 消毒——IP 字面量透传、域名改写、
// DoH 失败退系统解析、全失败保留原样、未知形态不碰、会话缓存命中。
import 'dart:io';

import 'package:einz/data/voice_call_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(resetTurnResolution);

  test('IP 字面量原样透传（零解析）', () async {
    var called = 0;
    final out = await resolveTurnUrls(
      ['turn:36.154.238.42:3478'],
      dohResolver: (h) async {
        called++;
        return '1.1.1.1';
      },
    );
    expect(out, ['turn:36.154.238.42:3478']);
    expect(called, 0);
  });

  test('域名 + DoH 成功 → 改写为 IP（保留 scheme 与端口）', () async {
    final out = await resolveTurnUrls(
      ['turn:turn.farinear.cn:3478'],
      dohResolver: (h) async => '36.154.238.42',
    );
    expect(out, ['turn:36.154.238.42:3478']);
  });

  test('DoH 失败 → 退系统解析', () async {
    final out = await resolveTurnUrls(
      ['turn:turn.bittic.cn:3478'],
      dohResolver: (h) async => null,
      systemLookup: (h) async => [InternetAddress('36.154.238.42')],
    );
    expect(out, ['turn:36.154.238.42:3478']);
  });

  test('DoH 与系统解析全失败 → 保留原地址（优雅降级）', () async {
    final out = await resolveTurnUrls(
      ['turn:doomed.einz.test:3478'],
      dohResolver: (h) async => null,
      systemLookup: (h) async => throw const SocketException('offline'),
    );
    expect(out, ['turn:doomed.einz.test:3478']);
  });

  test('未知形态不碰（如带凭证的 URL）', () async {
    final out = await resolveTurnUrls(
      ['turns:user:pass@host.example:5349', 'stun:stun.miwifi.com:3478'],
      dohResolver: (h) async => '1.2.3.4',
    );
    expect(out, ['turns:user:pass@host.example:5349', 'stun:stun.miwifi.com:3478']);
  });

  test('会话缓存：同 host 第二次不再调用解析器', () async {
    var called = 0;
    Future<String?> resolver(String h) async {
      called++;
      return '36.154.238.42';
    }

    await resolveTurnUrls(['turn:cached.einz.test:3478'], dohResolver: resolver);
    await resolveTurnUrls(['turn:cached.einz.test:3478'], dohResolver: resolver);
    expect(called, 1, reason: '会话级缓存应命中，一次通话建立只解析一次');
  });
}
