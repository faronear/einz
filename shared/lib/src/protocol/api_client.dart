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

  /// 协议版本头（PROTOCOL.md §1）：服务端做硬校验，缺失/不匹配 → 400。
  /// 所有 REST 请求都带上（WS 用握手的 `?pv=`）。
  static const protocolVersionHeader = 'X-Protocol-Version';
  static const protocolVersion = '1';

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

  /// 阶段 1：取密封 challenge。
  ///
  /// [spaceId] 必须传（Multiverse）：签发出来的 session 会绑定该 Space，后续
  /// `/sync`、`/messages`、escrow 都按会话里的 space 定位数据。不传 → 服务端
  /// 落"无 space 的 legacy 会话"，该会话看不到任何空间的数据（P1 收敛前 CLI 的
  /// `/auth` 就是漏传，导致会话过期续期后消息全空）。
  Future<ChallengeResult> challenge(String entranceId, {String? spaceId}) async {
    final res = await _post(
      Api.challenge,
      {
        'entrance_id': entranceId,
        if (spaceId != null && spaceId.isNotEmpty) 'space_id': spaceId,
      },
      withToken: false,
    );
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

  /// Multiverse：加入空间（POST /spaces/join——通道登记 + session 签发，绑定该
  /// Space，PROTOCOL_MULTIVERSE.md §4.1）。
  Future<SpaceJoinResult> joinSpace({
    required String token,
    required String publicKey,
    String? entranceName,
    int? slot,
    String? installUid,
  }) async {
    final res = await _post(
      Api.spaceJoin,
      {
        'token': token,
        'public_key': publicKey,
        if (entranceName != null && entranceName.isNotEmpty) 'entrance_name': entranceName,
        if (slot != null) 'slot': slot,
        // 安装级标识（多空间：同一安装各空间同名，服务端内部关联用）
        if (installUid != null && installUid.isNotEmpty) 'install_uid': installUid,
      },
      withToken: false,
    );
    return SpaceJoinResult.fromJson(res);
  }

  /// Multiverse：创建空间（POST /spaces——创建者通道登记 + session + 首个
  /// join token，PROTOCOL_MULTIVERSE.md §4.1）。creatorName/peerName 为
  /// 第一人（创建者）与第二人（对方）的名字（create 时预置两身份，join 按身份选择）。
  Future<SpaceCreateResult> createSpace({
    String? spaceId,
    String? creatorName,
    String? creatorGender,
    String? peerName,
    String? peerGender,
    PassphraseEnvelope? sealedSpaceKey,
    String? escrowPassphrase,
    String? publicKey,
    String? entranceName,
    String? installUid,
  }) async {
    final res = await _post(
      Api.spaces,
      {
        if (spaceId != null && spaceId.isNotEmpty) 'space_id': spaceId,
        if (creatorName != null && creatorName.isNotEmpty) 'creator_name': creatorName,
        if (creatorGender != null && creatorGender.isNotEmpty)
          'creator_gender': creatorGender,
        if (peerName != null && peerName.isNotEmpty) 'peer_name': peerName,
        if (peerGender != null && peerGender.isNotEmpty)
          'peer_gender': peerGender,
        if (sealedSpaceKey != null) 'sealed_space_key': sealedSpaceKey.toJson(),
        if (escrowPassphrase != null && escrowPassphrase.isNotEmpty)
          'escrow_passphrase': escrowPassphrase,
        if (publicKey != null && publicKey.isNotEmpty) 'public_key': publicKey,
        if (entranceName != null && entranceName.isNotEmpty) 'entrance_name': entranceName,
        // 安装级标识（多空间：同一安装各空间同名，服务端内部关联用）
        if (installUid != null && installUid.isNotEmpty) 'install_uid': installUid,
      },
      withToken: false,
    );
    return SpaceCreateResult.fromJson(res);
  }

  /// Multiverse：生成绑定新通道的邀请（POST /spaces/{id}/join-tokens——
  /// 24h 一次性 token，新通道 /space join 绑定）。
  ///
  /// 需认证：签发邀请凭证 = 空间级操作，服务端要求调用方持该空间成员会话
  /// （2026-09-15 评审 C1 修复；此前免认证，任何人拿到 spaceId 即可自签）。
  Future<JoinTokenResult> createJoinToken(String spaceId, String token) async {
    final res = await _post(
      '/spaces/$spaceId/join-tokens',
      const {},
      token: token,
    );
    return JoinTokenResult.fromJson(res);
  }

  /// Multiverse：按空间口令取回 Space Key 密封包（POST /spaces/{id}/key-escrow，
  /// 口令正确才返回，PROTOCOL_MULTIVERSE.md §4.2——join 方取钥，不撤销通道）。
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

  /// 生成邀请码（POST /invites，需认证 token）：partner_id 为规范 id（partnerA/partnerB）。
  
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

  /// 未读条数（GET /messages/unread）：本空间里"对方发来的、晚于我读取水位"的条数。
  ///
  /// 多空间列表角标用。读取水位是**服务端**的 `receipts.read_upto_seq`（客户端在
  /// "用户真看到最新消息"时才上报，见 chat_page._scheduleReadReport），所以这是纯派生量：
  /// 客户端不必拉各空间的历史、也不需要本地 schema。
  Future<int> unreadCount(String token) async {
    final res = await _get(Api.messagesUnread, token: token);
    return (res['unread'] as num?)?.toInt() ?? 0;
  }

  /// 补登安装级标识（POST /entrances/install-uid）：多空间下同一台物理设备在每个空间各有
  /// 一个 entrance_id，`installUid` 是它们共用的那一份（服务端内部认知用）。
  ///
  /// 幂等；只写本会话对应的那一行（一个空间的虚拟通道），别的空间由客户端在那边再登一次。
  /// 失败不影响聊天——调用方应 best-effort（同 registerPushToken）。
  Future<void> registerInstallUid(String installUid, String token) async {
    await _post(Api.installUid, {'install_uid': installUid}, token: token);
  }

  /// 获取空间信息（space_id + 通道列表，含 partner_id 映射，PROTOCOL.md §7.3）。
  Future<SpaceResult> getSpace(String token) async {
    final res = await _get(Api.space, token: token);
    return SpaceResult.fromJson(res);
  }

  /// 通道列表（含 last_seen 活跃时间戳（毫秒）；对方在线状态判定用）。
  Future<List<Map<String, dynamic>>> listEntrances(String token) async {
    final res = await _get('/entrances', token: token);
    return (res['entrances'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// 更新本通道名称（TUI 改名后同步后台，显示层用）。
  Future<void> updateEntranceName(String entranceName, String token) async {
    await _post('/entrances/name', {'entrance_name': entranceName}, token: token);
  }

  /// 更新本通道 partner 显示名（/rename 命令，显示层用）。
  Future<void> updatePartnerName(String partnerName, String token) async {
    await _post('/partners/name', {'partner_name': partnerName}, token: token);
  }

  /// 撤销**本空间内**的另一条通道（POST /entrances/:id/revoke，PROTOCOL.md §7.2）。
  ///
  /// 授权（2026-09-16）：同 space 内可互撤，但**每次都要校验共享口令**——撤销会让  /// 对方客户端自毁本地数据，属不可逆操作。失败码：口令错 401 `ESCROW_VERIFY_FAILED`、
  /// 尝试过多 429 `ESCROW_RATE_LIMITED`、该空间未托管口令 409 `PASSPHRASE_NOT_SET`、
  /// 目标不在本空间 403 `FORBIDDEN`。**调用方必须在成功后才提示/清理**（失败时目标
  /// 通道不受任何影响）。
  Future<void> revokeEntrance(String entranceId, String passphrase, String token) async {
    await _post('/entrances/$entranceId/revoke', {'passphrase': passphrase}, token: token);
  }

  /// 上传本人头像（raw 图片 bytes，服务端按 partner 存储覆盖）。
  ///
  /// 返回服务端确认的 partner_id：上传方**收不到**自己的 profile.updated 广播
  /// （ws.ts 的 broadcastProfileUpdated 跳过发送通道），客户端只能靠这个返回值
  /// 失效本端头像缓存（重启路径 widget.partnerId 为空 → 旧实现静默失效失败，
  /// 老板 2026-09-16 实测：上传后消息流仍显示旧头像，重启才更新）。
  /// 响应体不合法/缺字段时返回 null（partner_id 只用于本地缓存失效，
  /// 不能让解析失败把已经成功的一次上传报成失败）。
  Future<String?> uploadAvatar(Uint8List bytes, String token) async {
    final text = await _postBytes('/avatar', bytes, token: token);
    if (text.isEmpty) return null;
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return json['partner_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 获取指定 partner 的头像 bytes；未设置返回 null。
  Future<Uint8List?> getAvatar(String partnerId) async {
    return _getBytes('/avatar/$partnerId');
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
        final req = await _openRequest('POST', '$baseUrl${Api.attachments}');
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
        final req = await _openRequest('GET', '$baseUrl${Api.attachments}/$attachmentId');
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

  /// **本机自助退役**（POST /entrances/retire，PROTOCOL.md §7.3）：把自己从服务端注销
  /// ——清会话/Push Token/待签 challenge，通道置 revoked。与 [revokeEntrance] 的区别：
  /// 目标恒为自己、**不校验共享口令**（口令是共享给伴侣的加入凭证，不该有销毁我这台
  /// 通道的权力），调用方在此之前应已完成本地闸门（输入通道名 + 本机 PIN）。
  ///
  /// 调用约定：**先调它、成功之后再清本地数据**——token 存在本地，清完就再也调不动了。
  /// 异常按 [ApiException] 上抛，由调用方决定「退役失败是否仍要清本地」。
  Future<void> retireEntrance(String token) async {
    await _post(Api.entranceRetire, {}, token: token);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {String? token, bool withToken = true}) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await _openRequest('POST', '$baseUrl$path');
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
        final req = await _openRequest('GET', '$baseUrl$path');
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

  /// 打开一个请求：所有 REST 请求都从这里出去，**统一带上协议版本头**。
  /// 2026-09-15 教训：此前该头被（手动）写在各个请求点，附件上传/下载/头像上传
  /// 三处漏了 → 服务端硬校验直接 400，表现是"上传文件总失败"。收敛到一处，
  /// 以后新增请求不可能再漏。
  Future<HttpClientRequest> _openRequest(String method, String url) async {
    final HttpClientRequest req;
    switch (method) {
      case 'POST':
        req = await _client.postUrl(Uri.parse(url));
      case 'GET':
        req = await _client.getUrl(Uri.parse(url));
      case 'DELETE':
        req = await _client.deleteUrl(Uri.parse(url));
      default:
        throw ArgumentError.value(method, 'method', 'unsupported http method');
    }
    req.headers.set(protocolVersionHeader, protocolVersion);
    return req;
  }

  /// raw bytes 上传（头像等二进制）：image/png + Bearer token。
  /// 返回响应体文本（调用方按需解析，如 /avatar 的 partner_id）。
  Future<String> _postBytes(String path, Uint8List bytes, {String? token}) {
    return _withRetry(() async {
      final client = _client;
      try {
        final req = await _openRequest('POST', '$baseUrl$path');
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
        return text;
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
        final req = await _openRequest('GET', '$baseUrl$path');
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
        final req = await _openRequest('DELETE', '$baseUrl$path');
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
