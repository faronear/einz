import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:einz_shared/einz_shared.dart';

import 'burn_after_settings.dart';
import 'local_database.dart';

/// 历史消息记录（UI 渲染单元）：env=密文信封、plaintext=明文、
/// sender=身份判断（'me'/'peer'，person 维度）、attachment=附件元数据、
/// expiresAt=阅后即焚到期时间（null=永久）。
typedef HistoryMessage = ({
  MessageEnvelope env,
  String plaintext,
  String sender,
  Map<String, dynamic>? attachment,
  int? expiresAt
});

/// 客户端消息仓库：把 drift 本地库（DATABASE.md §3）与 shared 核心包
/// （加密/解密、ApiClient、同步语义）接起来。
///
/// - 发送：加密 → 写入本地（status=pending）→ 尝试立即上传；失败留队
/// - 同步：has_more 翻页拉全量 → 落库 → 推进锚点 → 补发 pending 队列
/// - 历史：从本地库读取并解密展示（按消息 key_version 选密钥，轮换后旧消息用归档密钥）
///
/// 密钥（SpaceKey）由调用方注入（真机来自 Keychain/Keystore，见 DATABASE.md §4）。
class MessageRepository {
  MessageRepository({
    required this.db,
    required this.api,
    required this.spaceKey,
    required this.spaceId,
    required this.deviceId,
    this.keyVersion = 1,
    Map<int, Uint8List>? archivedKeys,
    this.token,
    this.settings,
    this.reauth,
  }) : archivedKeys = archivedKeys ?? {};

  final LocalDatabase db;
  final ApiClient api;
  final Uint8List spaceKey;
  final String spaceId;
  final String deviceId;
  final int keyVersion;

  /// 归档 Space Key（key_version → 密钥），轮换后解密旧消息（E2EE.md §9.2）。
  final Map<int, Uint8List> archivedKeys;

  /// 阅后即焚设置（可选；未注入时默认 0=无限，行为与旧版一致）。
  final BurnAfterSettings? settings;

  /// 当前阅后即焚秒数（0=无限）。
  Future<int> _burnAfter() async => await settings?.load() ?? 0;

  /// 阅后即焚状态快照：当前设置的秒数 + 到期时间戳（burn<=0 时 expiresAt=null 永久）。
  Future<({int burn, int? expiresAt})> _burnState() async {
    final burn = await _burnAfter();
    final expiresAt = burn > 0 ? DateTime.now().millisecondsSinceEpoch + burn * 1000 : null;
    return (burn: burn, expiresAt: expiresAt);
  }

  /// 会话 token（认证后注入；未认证时发送只入队不同步）。
  String? token;

  /// 401（session 过期）时自动重新认证的回调（由上层注入：setup_page 的
  /// challenge-response 流程），返回新 token 供 [_withAutoAuth] 重试。
  final Future<String> Function()? reauth;

  /// 401（session 过期）自动续期：调 [reauth] 拿新 token → 更新 [token] → 重试一次。
  /// 保证 24h 会话过期后 app 请求无感恢复；其他错误原样抛出。
  Future<T> _withAutoAuth<T>(Future<T> Function(String token) fn) async {
    final t = token;
    if (t == null) throw StateError('未认证');
    try {
      return await fn(t);
    } on ApiException catch (e) {
      if (e.httpStatus != 401 || reauth == null) rethrow;
      final fresh = await reauth!();
      token = fresh;
      return await fn(fresh);
    }
  }

  /// 设备 → 用户（person_id）映射（GET /space 缓存，多设备身份语义）。
  /// 用于判断消息是否"同一个人"发送：同 person 不同设备显示为 'me'。
  final Map<String, String> _personByDevice = {};

  /// 拉取空间设备映射（person_id）。映射缺失时 history 的 sender 判断降级为 device 维度。
  Future<void> refreshDeviceMap() async {
    final t = token;
    if (t == null) return;
    try {
      final space = await _withAutoAuth((tok) => api.getSpace(tok));
      _personByDevice
        ..clear()
        ..addEntries(space.devices.map((d) => MapEntry(d.deviceId, d.personId)));
    } catch (_) {
      // 网络抖动忽略：保留旧映射（无映射时降级 device 判断）
    }
  }

  /// 消息是否"同一个人"发送：优先 person 维度，映射缺失降级 device 维度。
  bool _isSamePerson(String senderDeviceId) {
    final my = _personByDevice[deviceId];
    final sender = _personByDevice[senderDeviceId];
    if (my != null && sender != null) return my == sender;
    return senderDeviceId == deviceId;
  }

  /// 当前同步锚点（本地库 sync_state）。
  Future<int> get lastSequence async {
    final row = await (db.select(db.syncState)
          ..where((s) => s.spaceId.equals(spaceId)))
        .getSingleOrNull();
    return row?.lastServerSequence ?? 0;
  }

  /// 发送一条消息：加密 → 落库（pending）→ 尝试立即上传；失败留队。
  /// 返回 message_id。
  Future<String> send(String plaintext, {String type = 'text'}) async {
    final messageId = _uuidv7();
    final env = await encryptMessage(
      plaintext: plaintext,
      spaceKey: spaceKey,
      spaceId: spaceId,
      senderDeviceId: deviceId,
      senderPersonId: _personByDevice[deviceId],
      messageId: messageId,
      type: type,
      keyVersion: keyVersion,
    );
    final bs = await _burnState();
    await _insertLocal(env, status: 'pending', burnAfterSeconds: bs.burn, expiresAt: bs.expiresAt);

    final t = token;
    if (t != null) {
      try {
        final result = await _withAutoAuth((tok) => api.postMessage(env, tok));
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
      } on Exception {
        // 网络失败：留在 pending 队列，下次 sync 自动补发
      }
    }
    return messageId;
  }

  /// 发送附件消息（语音/图像/视频，PROTOCOL.md §6）：
  /// 加密文件 blob 上传 /attachments + 发送 caption 消息 + 本地附件元数据落库。
  /// 无 token 时消息入 pending 队列（附件 blob 需联网时上传，v1 不做离线附件补传）。
  /// 返回 message_id。
  Future<String> sendAttachment({
    required Uint8List fileBytes,
    required String fileName,
    required String type, // image | video | voice
    String? caption,
  }) async {
    final messageId = _uuidv7();
    final attachmentId = _uuidv7();
    final plain = caption ?? (type == 'voice' ? '🎤 语音消息' : '📎 $fileName');

    // 1) 加密文件（密文 + sha256 + nonce + size）
    final enc = await encryptAttachment(
      fileBytes: fileBytes,
      spaceKey: spaceKey,
      attachmentId: attachmentId,
      spaceId: spaceId,
      keyVersion: keyVersion,
    );

    // 2) 发送 caption 消息（type 标记，供接收端渲染）
    final env = await encryptMessage(
      plaintext: plain,
      spaceKey: spaceKey,
      spaceId: spaceId,
      senderDeviceId: deviceId,
      messageId: messageId,
      type: type,
      keyVersion: keyVersion,
    );
    await _insertLocal(env, status: 'pending');

    final t = token;
    if (t != null) {
      try {
        // 3) 上传密文 blob（x-attachment-meta 头带元数据）
        await _withAutoAuth((tok) => api.postAttachment(
              messageId: messageId,
              attachmentId: attachmentId,
              keyVersion: keyVersion,
              size: enc.size,
              sha256: enc.sha256,
              nonce: base64Encode(enc.nonce),
              blob: enc.cipher,
              token: tok,
            ));
        // 4) 发消息
        final result = await _withAutoAuth((tok) => api.postMessage(env, tok));
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
        // 5) 本地附件元数据落库（供历史渲染关联）
        await _insertAttachmentMeta({
          'attachment_id': attachmentId,
          'message_id': messageId,
          'key_version': keyVersion,
          'size': enc.size,
          'sha256': enc.sha256,
          'nonce': base64Encode(enc.nonce),
        });
      } on Exception {
        // 失败：消息留 pending（补发时消息会重发，但附件 blob 未上传 v1 不自动补传）
      }
    }
    return messageId;
  }

  /// 删除本设备上已到期的阅后即焚消息（纯本地，Server 不参与）。
  /// [now] 可注入测试（毫秒时间戳）；返回删除条数。
  Future<int> purgeExpired({int? now}) async {
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    final expired = await (db.select(db.localMessages)
          ..where((m) => m.expiresAt.isNotNull() & m.expiresAt.isSmallerOrEqualValue(t)))
        .get();
    var deleted = 0;
    for (final row in expired) {
      await (db.delete(db.localAttachments)..where((a) => a.messageId.equals(row.messageId))).go();
      await (db.delete(db.localMessages)..where((m) => m.messageId.equals(row.messageId))).go();
      deleted++;
    }
    return deleted;
  }

  /// 增量同步：翻页拉全量 → 落库 → 推进锚点 → 补发 pending 队列。
  /// 返回本次新增的消息条数。
  Future<int> sync() async {
    final t = token;
    if (t == null) return 0;

    var added = 0;
    var cursor = await lastSequence;
    while (true) {
      final result = await _withAutoAuth((tok) => api.sync(tok, after: cursor));
      for (final env in result.messages) {
        final bs = await _burnState();
        await _insertLocal(
          env,
          status: env.senderDeviceId == deviceId ? 'sent' : 'delivered',
          burnAfterSeconds: bs.burn,
          expiresAt: bs.expiresAt,
        );
        added++;
      }
      for (final meta in result.attachmentsMeta) {
        await _insertAttachmentMeta(meta);
      }
      if (result.messages.isNotEmpty) {
        cursor = result.lastSequence;
        await _advanceAnchor(result.lastSequence);
      }
      if (!result.hasMore || result.messages.isEmpty) break;
    }

    // 补发离线队列
    await _flushPending();
    return added;
  }

  /// 补发 pending 队列（成功后置 sent 并推进锚点）。
  Future<int> _flushPending() async {
    final t = token;
    if (t == null) return 0;

    final rows = await (db.select(db.localMessages)
          ..where((m) => m.status.equals('pending')))
        .get();
    var flushed = 0;
    for (final row in rows) {
      final env = MessageEnvelope.fromJson(jsonDecode(row.ciphertext) as Map<String, dynamic>);
      try {
        final result = await _withAutoAuth((tok) => api.postMessage(env, tok));
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
        flushed++;
      } on Exception {
        break; // 网络层问题：停止本轮补发，下次再试
      }
    }
    return flushed;
  }

  /// 读取本地历史（解密为明文，按 server_sequence 升序；未同步的排最后）。
  /// 附件消息附带本地附件元数据（attachment != null）；阅后即焚消息附带到期时间（expiresAt）。
  /// 读取本地历史（解密为明文，按 server_sequence 升序；未同步的排最后）。
  /// 附件消息附带本地附件元数据（attachment != null）；阅后即焚消息附带到期时间（expiresAt）。
  Future<List<HistoryMessage>> history() async {
    final rows = await (db.select(db.localMessages)
          ..where((m) => m.spaceId.equals(spaceId)))
        .get();
    // 未同步（serverSequence 为 null）排最后；同步的按 seq 升序（P3 修复，与注释一致）
    rows.sort((a, b) {
      final an = a.serverSequence;
      final bn = b.serverSequence;
      if (an == null && bn == null) return a.localCreatedAt.compareTo(b.localCreatedAt);
      if (an == null) return 1;
      if (bn == null) return -1;
      return an.compareTo(bn);
    });
    return _rowsToHistory(rows);
  }

  /// 分页读取最近 [limit] 条（升序：同步的旧→新 + 未同步排最后），UI 首屏用。
  Future<List<HistoryMessage>> historyRecent({int limit = 50}) async {
    final unsynced = await (db.select(db.localMessages)
          ..where((m) => m.spaceId.equals(spaceId) & m.serverSequence.isNull()))
        .get();
    final synced = await (db.select(db.localMessages)
          ..where((m) => m.spaceId.equals(spaceId) & m.serverSequence.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.serverSequence)])
          ..limit(limit))
        .get();
    return _rowsToHistory([...synced.reversed, ...unsynced]);
  }

  /// 分页读取比 [beforeSequence] 更早的 [limit] 条（升序），上滑加载历史用。
  Future<List<HistoryMessage>> historyBefore({
    required int beforeSequence,
    required int limit,
  }) async {
    final rows = await (db.select(db.localMessages)
          ..where((m) =>
              m.spaceId.equals(spaceId) &
              m.serverSequence.isNotNull() &
              m.serverSequence.isSmallerThanValue(beforeSequence))
          ..orderBy([(t) => OrderingTerm.desc(t.serverSequence)])
          ..limit(limit))
        .get();
    return _rowsToHistory(rows.reversed.toList());
  }

  /// 分页读取比 [afterSequence] 更新的消息（含未同步 pending），增量刷新追加用。
  Future<List<HistoryMessage>> historySince({required int afterSequence}) async {
    final rows = await (db.select(db.localMessages)
          ..where((m) =>
              m.spaceId.equals(spaceId) &
              (m.serverSequence.isNull() | m.serverSequence.isBiggerThanValue(afterSequence))))
        .get();
    rows.sort((a, b) {
      final an = a.serverSequence;
      final bn = b.serverSequence;
      if (an == null && bn == null) return a.localCreatedAt.compareTo(b.localCreatedAt);
      if (an == null) return 1;
      if (bn == null) return -1;
      return an.compareTo(bn);
    });
    return _rowsToHistory(rows);
  }

  /// 行 → 历史记录（解密 + 附件元数据 + person 身份 + 阅后即焚到期）。
  Future<List<HistoryMessage>> _rowsToHistory(List<LocalMessage> rows) async {
    final out = <HistoryMessage>[];
    for (final row in rows) {
      final env = MessageEnvelope.fromJson(jsonDecode(row.ciphertext) as Map<String, dynamic>);
      final key = _keyForVersion(env.keyVersion);
      if (key == null) {
        throw StateError('缺少 key_version=${env.keyVersion} 的 Space Key，无法解密历史消息（需导入归档密钥）');
      }
      final plain = await decryptMessage(
        env: env,
        spaceKey: key,
        spaceId: spaceId,
      );
      final att = await (db.select(db.localAttachments)
            ..where((a) => a.messageId.equals(env.messageId)))
          .getSingleOrNull();
      out.add((
        env: env,
        plaintext: plain,
        sender: _isSamePerson(env.senderDeviceId) ? 'me' : 'peer',
        attachment: att == null
            ? null
            : {
                'attachment_id': att.attachmentId,
                'key_version': att.keyVersion,
                'size': att.size,
                'sha256': att.sha256,
                'nonce': att.nonce,
              },
        expiresAt: row.expiresAt,
      ));
    }
    return out;
  }

  /// 下载并解密附件密文（校验 sha256 + AEAD 解密，PROTOCOL.md §6.2）。
  Future<Uint8List> fetchAttachment({
    required String attachmentId,
    required int keyVersion,
    required String sha256,
    required Uint8List nonce,
  }) async {
    final t = token;
    if (t == null) throw StateError('未认证，无法下载附件');
    final key = _keyForVersion(keyVersion);
    if (key == null) throw StateError('缺少 key_version=$keyVersion 的 Space Key');
    final blob = await _withAutoAuth((tok) => api.getAttachment(attachmentId, tok));
    return decryptAttachment(
      cipherText: blob,
      nonce: nonce,
      spaceKey: key,
      attachmentId: attachmentId,
      spaceId: spaceId,
      keyVersion: keyVersion,
    );
  }

  /// 按 key_version 选解密密钥：当前版本用 spaceKey，旧版本用归档（E2EE.md §9.2）。
  Uint8List? _keyForVersion(int version) {
    if (version == keyVersion) return spaceKey;
    return archivedKeys[version];
  }

  /// 待发送队列长度。
  Future<int> get pendingCount async {
    final count = await (db.selectOnly(db.localMessages)
          ..addColumns([db.localMessages.messageId.count()])
          ..where(db.localMessages.status.equals('pending')))
        .getSingle();
    return count.read(db.localMessages.messageId.count()) ?? 0;
  }

  // ---------- 本地库操作 ----------

  Future<void> _insertLocal(
    MessageEnvelope env, {
    required String status,
    int burnAfterSeconds = 0,
    int? expiresAt,
  }) async {
    final existing = await (db.select(db.localMessages)
          ..where((m) => m.messageId.equals(env.messageId)))
        .getSingleOrNull();
    if (existing != null) {
      await (db.update(db.localMessages)..where((m) => m.messageId.equals(env.messageId))).write(
        LocalMessagesCompanion(
          serverSequence: Value(env.serverSequence),
          status: Value(status),
        ),
      );
      return;
    }
    await db.into(db.localMessages).insert(
          LocalMessagesCompanion.insert(
            messageId: env.messageId,
            spaceId: spaceId,
            senderDeviceId: env.senderDeviceId,
            type: env.type,
            keyVersion: env.keyVersion,
            nonce: env.nonce,
            ciphertext: jsonEncode(env.toJson()),
            createdAt: env.createdAt ?? DateTime.now().millisecondsSinceEpoch,
            localCreatedAt: DateTime.now().millisecondsSinceEpoch,
            status: Value(status),
            serverSequence: Value(env.serverSequence),
            burnAfterSeconds: Value(burnAfterSeconds),
            expiresAt: Value(expiresAt),
          ),
        );
  }

  Future<void> _markSent(String messageId, int serverSequence, int createdAt) async {
    await (db.update(db.localMessages)..where((m) => m.messageId.equals(messageId))).write(
      LocalMessagesCompanion(
        status: const Value('sent'),
        serverSequence: Value(serverSequence),
        createdAt: Value(createdAt),
      ),
    );
    // 注意：不在这里推进锚点。锚点只在 /sync 响应时推进（P2 修复）——
    // 否则新设备未同步先发消息会跳过对方历史（PROTOCOL.md §5.2）。
  }

  Future<void> _advanceAnchor(int serverSequence) async {
    final row = await (db.select(db.syncState)
          ..where((s) => s.spaceId.equals(spaceId)))
        .getSingleOrNull();
    if (row == null) {
      await db.into(db.syncState).insert(
            SyncStateCompanion.insert(spaceId: spaceId, lastServerSequence: Value(serverSequence)),
          );
    } else if (serverSequence > row.lastServerSequence) {
      await (db.update(db.syncState)..where((s) => s.spaceId.equals(spaceId))).write(
        SyncStateCompanion(lastServerSequence: Value(serverSequence)),
      );
    }
  }

  Future<void> _insertAttachmentMeta(Map<String, dynamic> meta) async {
    final existing = await (db.select(db.localAttachments)
          ..where((a) => a.attachmentId.equals(meta['attachment_id'] as String)))
        .getSingleOrNull();
    if (existing != null) {
      await (db.update(db.localAttachments)
            ..where((a) => a.attachmentId.equals(meta['attachment_id'] as String)))
          .write(
        LocalAttachmentsCompanion(
          size: Value(meta['size'] as int),
          sha256: Value(meta['sha256'] as String),
          nonce: Value(meta['nonce'] as String),
        ),
      );
      return;
    }
    await db.into(db.localAttachments).insert(
          LocalAttachmentsCompanion.insert(
            attachmentId: meta['attachment_id'] as String,
            messageId: meta['message_id'] as String,
            keyVersion: meta['key_version'] as int,
            size: meta['size'] as int,
            sha256: meta['sha256'] as String,
            nonce: meta['nonce'] as String,
          ),
        );
  }

  /// UUIDv7（CSPRNG 随机段，格式 8-4-4-4-12；P2 修复：原实现用时间戳当随机数会碰撞丢消息）。
  String _uuidv7() {
    final r = Random.secure();
    final rand = List<int>.generate(12, (_) => r.nextInt(256)); // 24 hex 随机段
    final t = DateTime.now().millisecondsSinceEpoch;
    final tHex = t.toRadixString(16).padLeft(12, '0');
    final hex = rand.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${tHex.substring(0, 8)}-${tHex.substring(8, 12)}-7${hex.substring(0, 3)}-9${hex.substring(3, 6)}-${hex.substring(6, 18)}';
  }
}
