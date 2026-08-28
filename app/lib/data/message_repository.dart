import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

import 'local_database.dart';

/// 客户端消息仓库：把 drift 本地库（DATABASE.md §3）与 shared 核心包
/// （加密/解密、ApiClient、同步语义）接起来。
///
/// - 发送：加密 → 写入本地（status=pending）→ 尝试立即上传；失败留队
/// - 同步：has_more 翻页拉全量 → 落库 → 推进锚点 → 补发 pending 队列
/// - 历史：从本地库读取并解密展示
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
    this.token,
  });

  final LocalDatabase db;
  final ApiClient api;
  final Uint8List spaceKey;
  final String spaceId;
  final String deviceId;
  final int keyVersion;

  /// 会话 token（认证后注入；未认证时发送只入队不同步）。
  String? token;

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
      messageId: messageId,
      type: type,
      keyVersion: keyVersion,
    );
    await _insertLocal(env, status: 'pending');

    final t = token;
    if (t != null) {
      try {
        final result = await api.postMessage(env, t);
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
      } on Exception {
        // 网络失败：留在 pending 队列，下次 sync 自动补发
      }
    }
    return messageId;
  }

  /// 增量同步：翻页拉全量 → 落库 → 推进锚点 → 补发 pending 队列。
  /// 返回本次新增的消息条数。
  Future<int> sync() async {
    final t = token;
    if (t == null) return 0;

    var added = 0;
    var cursor = await lastSequence;
    while (true) {
      final result = await api.sync(t, after: cursor);
      for (final env in result.messages) {
        await _insertLocal(
          env,
          status: env.senderDeviceId == deviceId ? 'sent' : 'delivered',
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
        final result = await api.postMessage(env, t);
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
        flushed++;
      } on Exception {
        break; // 网络层问题：停止本轮补发，下次再试
      }
    }
    return flushed;
  }

  /// 读取本地历史（解密为明文，按 server_sequence 升序；未同步的排最后）。
  Future<List<({MessageEnvelope env, String plaintext, String sender})>> history() async {
    final rows = await (db.select(db.localMessages)
          ..where((m) => m.spaceId.equals(spaceId)))
        .get();
    rows.sort((a, b) => (a.serverSequence ?? 0).compareTo(b.serverSequence ?? 0));

    final out = <({MessageEnvelope env, String plaintext, String sender})>[];
    for (final row in rows) {
      final env = MessageEnvelope.fromJson(jsonDecode(row.ciphertext) as Map<String, dynamic>);
      final plain = await decryptMessage(
        env: env,
        spaceKey: spaceKey,
        spaceId: spaceId,
        keyVersion: keyVersion,
      );
      out.add((env: env, plaintext: plain, sender: env.senderDeviceId == deviceId ? 'me' : 'peer'));
    }
    return out;
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

  Future<void> _insertLocal(MessageEnvelope env, {required String status}) async {
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
    await _advanceAnchor(serverSequence);
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

  /// 简易 UUIDv7（与 CLI 测试端同构；App 生产可用 uuid 包）。
  String _uuidv7() {
    final rand = List<int>.generate(10, (_) => DateTime.now().millisecondsSinceEpoch % 256);
    final t = DateTime.now().millisecondsSinceEpoch;
    final hex = rand.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final tHex = t.toRadixString(16).padLeft(12, '0');
    return '${tHex.substring(0, 8)}-${tHex.substring(8)}-7${hex.substring(0, 3)}-9${hex.substring(3, 7)}-${hex.substring(7)}';
  }
}
