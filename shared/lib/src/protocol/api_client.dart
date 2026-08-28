import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'types.dart';
import '../crypto/message_crypto.dart';

/// OnlySpace REST 客户端（dart:io，App 与 CLI 共用）。
///
/// 对应 docs/PROTOCOL.md §3–§6。
class ApiClient {
  ApiClient(this.baseUrl);

  final String baseUrl;

  HttpClient get _client {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 10);
    return c;
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

  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async {
    final res = await _post(Api.messages, env.toJson(), token: token);
    return PostMessageResult.fromJson(res);
  }

  /// 上传附件密文 blob（PROTOCOL.md §6.1）：元数据走 x-attachment-meta 头，body 为密文。
  Future<Map<String, dynamic>> postAttachment({
    required String messageId,
    required String attachmentId,
    required int keyVersion,
    required int size,
    required String sha256,
    required String nonce,
    required Uint8List blob,
    required String token,
  }) async {
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
  }

  /// 下载附件密文 blob（PROTOCOL.md §6.2）。
  Future<Uint8List> getAttachment(String attachmentId, String token) async {
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
      {String? token, bool withToken = true}) async {
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
  }

  Future<Map<String, dynamic>> _get(String path, {String? token}) async {
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
