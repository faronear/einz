import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/passphrase_crypto.dart';
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

  /// **响应**超时（不含建连）：建连超时见 [_client] 的 connectionTimeout。
  ///
  /// 为什么必须有：只设 connectionTimeout 时，若服务端已收到请求但响应在回程丢失
  /// （或被中间设备吞掉），`req.close()`/读 body 会**永远挂住**——消息卡在
  /// pending（发送中小飞机）不落 failed，用户既不知道成没成、也没法重试
  /// （老板 2026-09-13 实测：对方已收到，本端一直是小飞机）。
  /// 超时按 [TimeoutException] 抛出 → [_withRetry] 会重试，仍失败则上层标 failed。
  /// 30s 取值偏宽松：大陆网络经代理时 RTT 可能较长，宁可慢也不要误判失败。
  static const responseTimeout = Duration(seconds: 30);

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
    String? partnerName,
    String? personGender,
    String? partnerGender,
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
        if (partnerName != null && partnerName.isNotEmpty) 'partner_name': partnerName,
        if (personGender != null && personGender.isNotEmpty) 'person_gender': personGender,
        if (partnerGender != null && partnerGender.isNotEmpty) 'partner_gender': partnerGender,
        if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
        if (personId != null && personId.isNotEmpty) 'person_id': personId,
      },
      withToken: false,
    );
    return EnrollResult.fromJson(res);
  }

  /// Multiverse：join token 轻量校验（不消费），返回空间公开信息供确认
  /// （POST /spaces/join/preflight，PROTOCOL_MULTIVERSE.md §5——App 向导
  /// 第一步 fail-fast：无效/过期/已用/已满在此拦截）。
  Future<SpaceJoinPreflight> preflightJoin(String token) async {
    final res = await _post(
      Api.spaceJoinPreflight,
      {'token': token},
      withToken: false,
    );
    return SpaceJoinPreflight.fromJson(res);
  }

  /// Multiverse：加入空间（POST /spaces/join——设备登记 + session 签发，绑定该
  /// Space，PROTOCOL_MULTIVERSE.md §4.1）。
  Future<SpaceJoinResult> joinSpace({
    required String token,
    required String publicKey,
    String? deviceName,
    String? displayName,
    String? gender,
    int? partnerSlot,
  }) async {
    final res = await _post(
      Api.spaceJoin,
      {
        'token': token,
        'public_key': publicKey,
        if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
        if (displayName != null && displayName.isNotEmpty) 'display_name': displayName,
        if (gender != null && gender.isNotEmpty) 'gender': gender,
        if (partnerSlot != null) 'partner_slot': partnerSlot,
      },
      withToken: false,
    );
    return SpaceJoinResult.fromJson(res);
  }

  /// Multiverse：创建空间（POST /spaces——创建者设备登记 + session + 首个
  /// join token，PROTOCOL_MULTIVERSE.md §4.1）。partnerName/partnerGender 为
  /// 第二人（伴侣）的名字/性别（create 时预置两身份，join 按身份选择）。
  Future<SpaceCreateResult> createSpace({
    String? spaceId,
    String? displayName,
    String? gender,
    String? partnerName,
    String? partnerGender,
    PassphraseEnvelope? sealedSpaceKey,
    String? escrowPassphrase,
    String? publicKey,
    String? deviceName,
  }) async {
    final res = await _post(
      Api.spaces,
      {
        if (spaceId != null && spaceId.isNotEmpty) 'space_id': spaceId,
        if (displayName != null && displayName.isNotEmpty) 'display_name': displayName,
        if (gender != null && gender.isNotEmpty) 'gender': gender,
        if (partnerName != null && partnerName.isNotEmpty) 'partner_name': partnerName,
        if (partnerGender != null && partnerGender.isNotEmpty)
          'partner_gender': partnerGender,
        if (sealedSpaceKey != null) 'sealed_space_key': sealedSpaceKey.toJson(),
        if (escrowPassphrase != null && escrowPassphrase.isNotEmpty)
          'escrow_passphrase': escrowPassphrase,
        if (publicKey != null && publicKey.isNotEmpty) 'public_key': publicKey,
        if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
      },
      withToken: false,
    );
    return SpaceCreateResult.fromJson(res);
  }

  /// Multiverse：生成绑定新设备的邀请（POST /spaces/{id}/join-tokens——
  /// 24h 一次性 token，新设备 /space join 绑定；服务端不要求认证）。
  Future<JoinTokenResult> createJoinToken(String spaceId) async {
    final res = await _post(
      '/spaces/$spaceId/join-tokens',
      const {},
      withToken: false,
    );
    return JoinTokenResult.fromJson(res);
  }

  /// Multiverse：按空间口令取回 Space Key 密封包（POST /spaces/{id}/key-escrow，
  /// 口令正确才返回，PROTOCOL_MULTIVERSE.md §4.2——join 方取钥，不撤销设备）。
  Future<PassphraseEnvelope?> fetchSpaceEscrow(String spaceId, String passphrase) async {
    final res = await _post(
      '/spaces/$spaceId/key-escrow',
      {'passphrase': passphrase},
      withToken: false,
    );
    final pkg = res['package'] as Map<String, dynamic>?;
    if (pkg == null) return null;
    return PassphraseEnvelope.fromJson(pkg);
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

  /// 设备列表（含 last_seen 活跃时间戳（毫秒）；对方在线状态判定用）。
  Future<List<Map<String, dynamic>>> listDevices(String token) async {
    final res = await _get('/devices', token: token);
    return (res['devices'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// 更新本设备名称（TUI 改名后同步后台，显示层用）。
  Future<void> updateDeviceName(String deviceName, String token) async {
    await _post('/devices/name', {'device_name': deviceName}, token: token);
  }

  /// 更新本设备 person 显示名（/rename 命令，显示层用）。
  Future<void> updatePersonName(String personName, String token) async {
    await _post('/devices/person-name', {'person_name': personName}, token: token);
  }

  /// 上传本人头像（raw 图片 bytes，服务端按 person 存储覆盖）。
  Future<void> uploadAvatar(Uint8List bytes, String token) async {
    await _postBytes('/avatar', bytes, token: token);
  }

  /// 获取指定 person 的头像 bytes；未设置返回 null。
  Future<Uint8List?> getAvatar(String personId) async {
    return _getBytes('/avatar/$personId');
  }

  /// 上传口令托管密文包（KEY_ESCROW.md §4）：Server 只存密文，不解析内容。
  /// 上传口令托管密文包；可选附口令 argon2id 哈希
  /// （服务端据它校验「加入方取包时输入的口令」是否正确）。
  /// [rotated] 仅"修改口令"流程置 true——服务端据此推进 updated_at 并广播
  /// passphrase.rotated；普通重传（首次设口令/解锁同步）保持 false，不得误报。
  Future<void> uploadKeyEscrow(PassphraseEnvelope package, String token,
      {String? passphraseHash, bool rotated = false}) async {
    await _post(Api.keyEscrow, {
      'package': package.toJson(),
      if (passphraseHash != null) 'passphrase_hash': passphraseHash,
      if (rotated) 'rotated': true,
    }, token: token);
  }

  /// 拉取口令托管密文包；未托管时返回 null。
  /// 下载口令托管密文包（含服务端 updated_at——客户端用于"口令是否被重设"的
  /// 离线补查：本端记录的上次时间 < updated_at → 口令已重设）。
  Future<({PassphraseEnvelope? file, int? updatedAt})> getKeyEscrow(String token) async {
    final res = await _get(Api.keyEscrow, token: token);
    final pkg = res['package'];
    return (
      file: pkg == null ? null : PassphraseEnvelope.fromJson(pkg as Map<String, dynamic>),
      updatedAt: res['updated_at'] as int?,
    );
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
        final res = await req.close().timeout(responseTimeout);
        final text = await res.transform(utf8.decoder).join().timeout(responseTimeout);
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

  /// 上报自己的送达/已读高水位（服务端只前进，且读隐含送达）。
  /// 两个参数都可缺省；返回服务端夹紧后的当前值。
  Future<({int deliveredUptoSeq, int readUptoSeq})> postReceipts(
    String token, {
    int? deliveredUptoSeq,
    int? readUptoSeq,
  }) async {
    final res = await _post(
      Api.receipts,
      {
        if (deliveredUptoSeq != null) 'delivered_upto_seq': deliveredUptoSeq,
        if (readUptoSeq != null) 'read_upto_seq': readUptoSeq,
      },
      token: token,
    );
    return (
      deliveredUptoSeq: (res['delivered_upto_seq'] as int?) ?? 0,
      readUptoSeq: (res['read_upto_seq'] as int?) ?? 0,
    );
  }

  /// 拉取本 space 全部回执行（重连/补拉用）。
  Future<List<ReceiptRow>> getReceipts(String token) async {
    final res = await _get(Api.receipts, token: token);
    return (res['receipts'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .map(ReceiptRow.fromJson)
        .toList();
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
        final res = await req.close().timeout(responseTimeout);
        final text = await res.transform(utf8.decoder).join().timeout(responseTimeout);
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
        final res = await req.close().timeout(responseTimeout);
        final text = await res.transform(utf8.decoder).join().timeout(responseTimeout);
        if (res.statusCode >= 400) {
          throw _errorFrom(res.statusCode, text);
        }
        return jsonDecode(text) as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    });
  }

  /// raw bytes 上传（头像等二进制）：image/png + Bearer token。
  Future<void> _postBytes(String path, Uint8List bytes, {String? token}) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await client.postUrl(Uri.parse('$baseUrl$path'));
        req.headers.contentType = ContentType('image', 'png');
        if (token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        req.add(bytes);
        final res = await req.close().timeout(responseTimeout);
        final text = await res.transform(utf8.decoder).join().timeout(responseTimeout);
        if (res.statusCode >= 400) {
          throw _errorFrom(res.statusCode, text);
        }
      } finally {
        client.close(force: true);
      }
    });
  }

  /// raw bytes 获取（头像等）：404 = 未设置 → null。
  Future<Uint8List?> _getBytes(String path) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await client.getUrl(Uri.parse('$baseUrl$path'));
        final res = await req.close().timeout(responseTimeout);
        if (res.statusCode == 404) return null; // 未设置
        if (res.statusCode >= 400) {
          final text = await res.transform(utf8.decoder).join().timeout(responseTimeout);
          throw _errorFrom(res.statusCode, text);
        }
        final builder = BytesBuilder();
        await for (final chunk in res.timeout(responseTimeout)) {
          builder.add(chunk);
        }
        return builder.takeBytes();
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
        final res = await req.close().timeout(responseTimeout);
        final text = await res.transform(utf8.decoder).join().timeout(responseTimeout);
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
