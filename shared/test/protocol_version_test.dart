// 协议版本头回归：ApiClient 的**每一个** REST 请求都必须带 X-Protocol-Version。
//
// 背景（2026-09-15）：服务端补齐了协议版本硬校验（PROTOCOL.md §1，缺头/版本不符 → 400），
// 而客户端当初把该头**手动写在各个请求点**，附件上传/下载、头像上传三处漏了 ——
// 表现是"上传文件总是失败"。请求构造已收敛到 `_openRequest` 单一入口，这里用真实的
// 本地 HTTP server 守住"每个请求都带上了头"这件事（新增请求点时漏了会在这里挂掉）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:einz_shared/einz_shared.dart';

void main() {
  late HttpServer server;
  final received = <HttpRequest>[];

  setUp(() async {
    received.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      received.add(req);
      // 每个请求都回一个"字段齐全"的最小响应，让调用方走完解析流程
      // （本测试只校验请求头，不校验业务语义）
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'ok': true,
        'challenge_id': 'cid',
        'sealed_challenge': 'c2VhbGVk',
        'session_token': 'tok',
        'space_id': 'space-1',
        'expires_in': 60,
        'devices': <Map<String, dynamic>>[],
        'person_names': <String, String>{},
        'person_genders': <String, String>{},
        'package': null,
        'updated_at': null,
        'joinToken': 'e1_stub',
        'link': 'https://stub/join/e1_stub',
        'expiresAt': 1,
        'spaceId': 'space-1',
        'spaceAddress': '0xstub',
        'deviceId': 'dev-stub',
        'personId': 'person-stub',
        'creatorPersonId': 'person-stub',
        'partnerSlot': 1,
        'messages': <Map<String, dynamic>>[],
        'attachments_meta': <Map<String, dynamic>>[],
        'last_sequence': 0,
        'has_more': false,
        'delivered_upto_seq': 0,
        'read_upto_seq': 0,
        'receipts': <Map<String, dynamic>>[],
      }));
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  ApiClient apiFor() => ApiClient('http://127.0.0.1:${server.port}');

  void expectVersionOnAll(String what) {
    expect(received, isNotEmpty, reason: '$what：应发出至少一个请求');
    for (final req in received) {
      expect(
        req.headers.value(ApiClient.protocolVersionHeader),
        ApiClient.protocolVersion,
        reason: '$what：${req.method} ${req.uri.path} 缺少/错误的协议版本头',
      );
    }
  }

  test('challenge / verify（POST）带协议版本头', () async {
    await apiFor().challenge('dev-1', spaceId: 'space-1');
    expectVersionOnAll('challenge');
    received.clear();
    await apiFor().verify('cid', 'plain');
    expectVersionOnAll('verify');
  });

  test('附件上传 postAttachment 带协议版本头', () async {
    await apiFor().postAttachment(
      messageId: 'c0001aaaa',
      attachmentId: 'aa11bb22cc33dd44',
      keyVersion: 1,
      size: 4,
      sha256: 'sha',
      nonce: 'n',
      blob: Uint8List.fromList([9, 9, 9, 9]),
      token: 'tok',
    );
    expectVersionOnAll('postAttachment');
  });

  test('附件下载 getAttachment 带协议版本头', () async {
    await apiFor().getAttachment('aa11bb22cc33dd44', 'tok');
    expectVersionOnAll('getAttachment');
  });

  test('头像上传/下载带协议版本头', () async {
    await apiFor().uploadAvatar(Uint8List.fromList([1, 2, 3]), 'tok');
    expectVersionOnAll('uploadAvatar');
    received.clear();
    await apiFor().getAvatar('person-1');
    expectVersionOnAll('getAvatar');
  });

  test('GET / DELETE 通用路径带协议版本头', () async {
    await apiFor().getSpace('tok');
    expectVersionOnAll('getSpace');
    received.clear();
    await apiFor().listDevices('tok');
    expectVersionOnAll('listDevices');
    received.clear();
    await apiFor().deleteKeyEscrow('tok');
    expectVersionOnAll('deleteKeyEscrow');
  });
}
