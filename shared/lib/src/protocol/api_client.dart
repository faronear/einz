import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/backup.dart';
import 'types.dart';
import '../crypto/message_crypto.dart';

/// Einz REST 客户端（dart:io，App 与 CLI 共用）。
///
/// 对应 docs/PROTOCOL.md §3–§6。
class ApiClient {
  ApiClient(this.baseUrl);

  final String baseUrl;

  /// 瞬时网络错误自动重试次数（翻墙/网络抖动下的间歇性握手失败不致命）。
  static const retryCount = 3;

  HttpClient get _client {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 10);
    return c;
  }

  /// 对瞬时网络错误（握手/连接/超时）自动重试；业务错误（4xx/5xx）不重试。
  Future<T> _withRetry<T>(Future<T> Function() fn) async {
    Object? last;
    for (var attempt = 0; attempt < retryCount; attempt++) {
      try {
        return await fn();
      } on SocketException catch (e) {
        last = e;
      } on HandshakeException catch (e) {
        last = e;
      } on TimeoutException catch (e) {
        last = e;
      }
      if (attempt < retryCount - 1) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }
    throw last!;
  }

  Future<ChallengeResult> challenge(String deviceId) async {
    final res = await _post(Api.challenge, {'device_id': deviceId}, withToken: false);
    return ChallengeResult.fromJson(res);
  }

  Future<SessionResult> verify(String challengeId, String plaintextB64) async {
    final res = await _post(
      Api.verify,
      {'challenge_id': challengeId, 'challenge_plaintext': plaintextB64},
      withToken: false,
    );
    return SessionResult.fromJson(res);
  }

  /// 新设备凭一次性邀请码动态登记（POST /devices/enroll，免认证——邀请码即准入令牌）。
  /// 登记成功后设备立即在服务端白名单生效（无需人工改 config.json / 重启）。
  Future<EnrollResult> enrollDevice({
    String? deviceId,
    required String publicKey,
    String? inviteCode,
    String? personName,
    String? deviceName,
    String? personId,
  }) async {
    final res = await _post(
      Api.devicesEnroll,
      {
        if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
        'public_key': publicKey,
        if (inviteCode != null && inviteCode.isNotEmpty) 'invite_code': inviteCode,
        if (personName != null && personName.isNotEmpty) 'person_name': personName,
        if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
        if (personId != null && personId.isNotEmpty) 'person_id': personId,
      },
      withToken: false,
    );
    return EnrollResult.fromJson(res);
  }

  /// 生成邀请码（POST /invites，需认证 token）：person_id 为规范 id（personA/personB）。
  Future<InviteResult> createInvite({
    required String token,
    required String personId,
    String? personName,
    int hours = 24,
  }) async {
    final res = await _post(
      Api.invites,
      {
        'person_id': personId,
        if (personName != null && personName.isNotEmpty) 'person_name': personName,
        'hours': hours,
      },
      token: token,
    );
    return InviteResult.fromJson(res);
  }

  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async {
    final res = await _post(Api.messages, env.toJson(), token: token);
    return PostMessageResult.fromJson(res);
  }

  /// 注册 Push Token（PROTOCOL.md §7.3）：platform = ios | android。
  /// 推送只发"有新消息"提示，绝不携带正文（productLens §10）。
  Future<void> registerPushToken(String platform, String pushToken, String token) async {
    await _post(Api.pushRegister, {'platform': platform, 'token': pushToken}, token: token);
  }

  /// 注销 Push Token。
  Future<void> unregisterPushToken(String token) async {
    await _delete(Api.pushRegister, token: token);
  }

  /// 获取空间信息（space_id + 设备列表，含 person_id 映射，PROTOCOL.md §7.3）。
  Future<SpaceResult> getSpace(String token) async {
    final res = await _get(Api.space, token: token);
    return SpaceResult.fromJson(res);
  }

  /// 更新本设备名称（TUI 改名后同步后台，显示层用）。
  Future<void> updateDeviceName(String deviceName, String token) async {
    await _post('/devices/name', {'device_name': deviceName}, token: token);
  }

  /// 更新本设备 person 显示名（/rename 命令，显示层用）。
  Future<void> updatePersonName(String personName, String token) async {
    await _post('/devices/person-name', {'person_name': personName}, token: token);
  }

  /// 上传口令托管密文包（KEY_ESCROW.md §4）：Server 只存密文，不解析内容。
  Future<void> uploadKeyEscrow(BackupFile package, String token) async {
    await _post(Api.keyEscrow, {'package': package.toJson()}, token: token);
  }

  /// 拉取口令托管密文包；未托管时返回 null。
  Future<BackupFile?> getKeyEscrow(String token) async {
    final res = await _get(Api.keyEscrow, token: token);
    final pkg = res['package'];
    if (pkg == null) return null;
    return BackupFile.fromJson(pkg as Map<String, dynamic>);
  }

  /// 清除口令托管密文包。
  Future<void> deleteKeyEscrow(String token) async {
    await _delete(Api.keyEscrow, token: token);
  }

  /// 上传附件密文 blob（PROTOCOL.md §6.1）：元数据走 x-attachment-meta 头，body 为密文。
  /// 大 blob 上传耗时更长，更易受网络抖动/握手中断影响，故同样套 _withRetry 重试。
  Future<Map<String, dynamic>> postAttachment({
    required String messageId,
    required String attachmentId,
    required int keyVersion,
    required int size,
    required String sha256,
    required String nonce,
    required Uint8List blob,
    required String token,
  }) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await client.postUrl(Uri.parse('$baseUrl${Api.attachments}'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set('x-attachment-meta', jsonEncode({
          'message_id': messageId,
          'attachment_id': attachmentId,
          'key_version': keyVersion,
          'size': size,
          'sha256': sha256,
          'nonce': nonce,
        }));
        req.headers.contentType = ContentType.binary;
        req.add(blob);
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 400) {
          throw _errorFrom(res.statusCode, text);
        }
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    });
  }

  /// 下载附件密文 blob（PROTOCOL.md §6.2）。
  Future<Uint8List> getAttachment(String attachmentId, String token) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await client.getUrl(Uri.parse('$baseUrl${Api.attachments}/$attachmentId'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        final res = await req.close();
        if (res.statusCode >= 400) {
          final text = await res.transform(utf8.decoder).join();
          throw _errorFrom(res.statusCode, text);
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in res) {
          builder.add(chunk);
        }
        return builder.takeBytes();
      } finally {
        client.close(force: true);
      }
    });
  }

  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    final res = await _get('${Api.sync}?after=$after&limit=$limit', token: token);
    final list = (res['messages'] as List).cast<Map<String, dynamic>>();
    return (
      messages: list.map(MessageEnvelope.fromJson).toList(),
      attachmentsMeta: (res['attachments_meta'] as List? ?? []).cast<Map<String, dynamic>>(),
      lastSequence: res['last_sequence'] as int,
      hasMore: res['has_more'] as bool,
    );
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {String? token, bool withToken = true}) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await client.postUrl(Uri.parse('$baseUrl$path'));
        req.headers.contentType = ContentType.json;
        if (withToken && token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        req.write(jsonEncode(body));
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 400) {
          throw _errorFrom(res.statusCode, text);
        }
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    });
  }

  Future<Map<String, dynamic>> _get(String path, {String? token}) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await client.getUrl(Uri.parse('$baseUrl$path'));
        if (token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 400) {
          throw _errorFrom(res.statusCode, text);
        }
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    });
  }

  Future<Map<String, dynamic>> _delete(String path, {String? token}) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await client.deleteUrl(Uri.parse('$baseUrl$path'));
        if (token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 400) {
          throw _errorFrom(res.statusCode, text);
        }
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    });
  }

  ApiException _errorFrom(int status, String text) {
    try {
      final body = jsonDecode(text) as Map<String, dynamic>;
      final err = body['error'] as Map<String, dynamic>;
      return ApiException(err['code'] as String, err['message'] as String, status);
    } catch (_) {
      return ApiException('HTTP_$status', 'HTTP $status: $text', status);
    }
  }
}
