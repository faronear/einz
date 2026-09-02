// Einz TUI 聊天核心 —— 与 UI 无关的业务逻辑（方案 A 升级版）。
//
// 从 einz_chat.dart（方案 B）提炼：认证 / 发送 / 补发 / 增量同步 / 历史 /
// 解密 / UUIDv7 全部集中于此，供 TUI 界面（einz_tui.dart）复用。
// 定位不变：测试端明文落盘（同 store.dart），不上生产。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:einz_cli/store.dart';

/// 展示用消息（已解密明文 + 归属）。
class ChatMessage {
  ChatMessage({
    required this.env,
    required this.plain,
    required this.isMine,
    required this.createdAt,
    this.serverSequence,
    this.isSystem = false,
  });

  final MessageEnvelope env;
  final String plain;
  final bool isMine;
  final int createdAt;

  /// 系统提示消息（如邀请码、引导提示）：sender 显示为 system（不参与"我/对方"）。
  final bool isSystem;

  /// 显式 server 序号：本地刚发送的消息与 WS 实时消息在 env 上可能没有
  /// serverSequence（序号在应答/事件帧里），需由调用方显式传入，否则排序会错乱。
  final int? serverSequence;

  int? get seq => serverSequence ?? env.serverSequence;
  int get keyVersion => env.keyVersion;
}

/// 聊天会话：封装设备状态、服务器交互与消息缓存。
class ChatSession {
  ChatSession(this.store, this.storePath, this.server);

  final DeviceStore store;
  final String storePath;
  String server;

  /// 展示缓存（按 server_sequence 升序；未同步的排最后）。
  final List<ChatMessage> messages = [];

  /// WS 实时监听（null = 未启动）。
  WsClient? wsClient;

  /// 断线开始时间（WS 处于 connecting/reconnecting 时记录；connected 时清空）。
  /// 供 UI 状态栏显示"已断线 Ns"。
  DateTime? wsDownSince;

  /// 自动补拉周期：WS 推送可能丢帧、断线期间的消息不会回放，定时增量拉取兜底
  /// （同时顺带补发离线发送队列）。
  static const autoSyncInterval = Duration(seconds: 30);

  /// 周期兜底同步定时器（startWs 启动，stopWs 取消）。
  Timer? _autoSyncTimer;

  /// 后台同步并发保护（断线重连快路径 + 周期兜底共用，避免并发 sync）。
  bool _autoSyncing = false;

  /// 当前 WS 状态（无连接时为 stopped）。
  WsStatus get wsStatus => wsClient?.status ?? WsStatus.stopped;

  /// 已断线秒数（在线为 0）。
  int get wsDownSeconds {
    final since = wsDownSince;
    if (since == null) return 0;
    return DateTime.now().difference(since).inSeconds;
  }

  bool get hasSpace => store.spaceKey != null && store.spaceId != null;
  bool get hasSession => store.sessionToken != null;

  /// 从本地历史填充展示缓存（启动时调用，去重按 message_id）。
  Future<void> loadHistory() async {
    final seen = <String>{};
    messages.clear();
    for (final env in store.historyEnvelopes) {
      if (!seen.add(env.messageId)) continue;
      final plain = await _decrypt(env);
      messages.add(ChatMessage(
        env: env,
        plain: plain,
        isMine: env.senderPersonId != null && store.personId != null
            ? env.senderPersonId == store.personId
            : env.senderDeviceId == store.deviceId,
        createdAt: env.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        serverSequence: env.serverSequence,
      ));
    }
    _sortMessages();
  }

  /// 认证（challenge → sealOpen → verify），成功写入 store。
  Future<void> auth({String? serverOverride}) async {
    final target = serverOverride ?? server;
    if (target.isEmpty) throw StateError('缺少服务器地址（/auth <server> 或启动时 --server）');
    final api = ApiClient(target);
    final s = await sodium();

    // 未登记（登记失败/邀请码输错）时 deviceId 为 null——先检查，避免空断言崩溃
    final deviceId = store.deviceId;
    if (deviceId == null) {
      throw StateError('设备尚未登记（无 device_id），请先完成引导登记（自举或邀请码）');
    }
    final challenge = await api.challenge(deviceId);
    final opened = await sealOpen(
      s,
      base64Decode(challenge.sealedChallenge),
      store.publicKeyBytes,
      store.privateKeyBytes,
    );
    final session = await api.verify(challenge.challengeId, base64Encode(opened));
    store.sessionToken = session.sessionToken;
    store.save(storePath);
    if (serverOverride != null) server = serverOverride;
  }

  /// 401（session 过期）时自动重新认证（challenge-response 无需用户干预）并重试一次。
  /// 保证 24h 会话过期后不退出 TUI 也能无感续期；其他错误原样抛出。
  Future<T> _withAutoAuth<T>(Future<T> Function(String token) fn) async {
    try {
      return await fn(store.sessionToken!);
    } on ApiException catch (e) {
      if (e.httpStatus != 401) rethrow;
      await auth(); // 自动续期
      return await fn(store.sessionToken!);
    }
  }

  /// 凭口令接入（escrow download，KEY_ESCROW.md §4）：先认证拿到 token，
  /// 再从 Server 拉取口令托管包解出 Space Key 写回 store。
  /// 新设备接入无需对方公钥（与 App「加入」流程一致）；口令错误抛 [FormatException]。
  Future<void> accessByEscrow(String passphrase) async {
    await auth(); // 拉取托管包需要 session_token
    final api = ApiClient(server);
    final escrow = KeyEscrowService(api);
    final payload = await escrow.fetch(passphrase: passphrase, token: store.sessionToken!);
    if (payload == null) {
      throw StateError('Server 无口令托管包（请先在对端执行 escrow upload）');
    }
    // 写回 store（参照 import 的归档逻辑：新版本 > 当前时归档旧密钥）
    if (payload.keyVersion > store.keyVersion && store.spaceKey != null) {
      store.archivedSpaceKeys.add({'key_version': store.keyVersion, 'space_key': store.spaceKey});
    }
    store.spaceKey = payload.spaceKeyB64;
    store.spaceId = payload.spaceId;
    store.keyVersion = payload.keyVersion;
    store.save(storePath);
  }

  /// 发送文本：加密 → 入队（离线不丢）→ 在线立即补发。
  Future<bool> sendText(String text) async {
    store.requireSpace();
    final messageId = await _uuidv7();
    final env = await encryptMessage(
      plaintext: text,
      spaceKey: base64Decode(store.spaceKey!),
      spaceId: store.spaceId!,
      senderDeviceId: store.deviceId!,
      senderPersonId: store.personId,
      messageId: messageId,
      keyVersion: store.keyVersion,
    );
    store.enqueuePending(jsonEncode(env.toJson()));
    store.save(storePath);

    if (server.isEmpty || store.sessionToken == null) {
      return false; // 离线：只入队
    }
    final sent = await flushPending();
    if (sent.isNotEmpty) {
      // 已发送：找到自己刚发的这条（按 messageId，避免补发旧消息时取错），
      // 用 server 应答的真实 seq/createdAt 写入展示缓存，保证排序正确。
      final mine = sent.where((e) => e.env.messageId == messageId).toList();
      if (mine.isNotEmpty) {
        final r = mine.first;
        _appendDecrypted(
          env,
          serverSequence: r.serverSequence,
          isMine: true,
          plain: text,
          createdAt: r.createdAt,
        );
      }
    }
    return sent.any((e) => e.env.messageId == messageId);
  }

  /// 补发离线队列：成功一条出队一条并写入历史；网络失败停止本轮。
  /// 返回成功发送的（信封, serverSequence, createdAt），供调用方以真实序号落展示缓存。
  Future<List<({MessageEnvelope env, int serverSequence, int createdAt})>> flushPending() async {
    store.requireSession();
    final api = ApiClient(server);
    final sent = <({MessageEnvelope env, int serverSequence, int createdAt})>[];
    for (final env in store.pendingEnvelopes) {
      try {
        final result = await _withAutoAuth((token) => api.postMessage(env, token));
        store.dequeuePending(env.messageId);
        store.upsertHistory(env, serverSequence: result.serverSequence, createdAt: result.createdAt);
        sent.add((env: env, serverSequence: result.serverSequence, createdAt: result.createdAt));
      } on Exception {
        break; // 网络层问题：停止本轮，避免空转
      }
    }
    if (sent.isNotEmpty) store.save(storePath);
    return sent;
  }

  /// 增量同步：从本地锚点拉取，落盘历史，返回新增消息（解密后已追加展示缓存）。
  /// 同时补发离线队列。
  Future<List<ChatMessage>> sync() async {
    if (server.isEmpty) throw StateError('缺少服务器地址（--server）');
    store.requireSpace();
    store.requireSession();
    final api = ApiClient(server);

    var cursor = store.lastServerSequence;
    final added = <MessageEnvelope>[];
    while (true) {
      final result = await _withAutoAuth((token) => api.sync(token, after: cursor));
      for (final env in result.messages) {
        final seq = env.serverSequence ?? cursor;
        // 关键：用服务端下发的真实 created_at 落盘（旧版本误存 seq/0 →
        // 重启后时间显示 1970；服务端 sync 响应始终携带 created_at）
        store.upsertHistory(env, serverSequence: seq, createdAt: env.createdAt ?? seq);
        added.add(env);
        cursor = seq;
      }
      if (result.lastSequence > cursor) cursor = result.lastSequence;
      store.advanceAnchor(result.lastSequence);
      if (!result.hasMore || result.messages.isEmpty) break;
    }
    store.save(storePath);

    // 存量修复（尽力而为）：旧版本曾把 created_at 落成 server_sequence 或 0，
    // 重启后时间标签显示 1970。检测到坏时间戳（< 1973 年）时全量拉取服务端消息，
    // 按 message_id 幂等覆盖为真实 created_at，并重建展示缓存让当前会话立即正确。
    try {
      if (await _backfillTimestamps()) {
        await loadHistory();
      }
    } catch (_) {
      // 忽略：网络异常时下次 sync 再试，不影响本次增量结果
    }

    await flushPending();

    final seen = <String>{};
    final fresh = <ChatMessage>[];
    for (final env in added) {
      if (!seen.add(env.messageId)) continue;
      final plain = await _decrypt(env);
      final seq = env.serverSequence;
      final msg = ChatMessage(
        env: env,
        plain: plain,
        isMine: env.senderPersonId != null && store.personId != null
            ? env.senderPersonId == store.personId
            : env.senderDeviceId == store.deviceId,
        createdAt: env.createdAt ?? seq ?? 0,
        serverSequence: seq,
      );
      fresh.add(msg);
      _appendDedup(msg);
    }
    _sortMessages();
    return fresh;
  }

  /// 存量时间戳修复：本地历史里 created_at 疑似为序号或 0（< 1973 年，旧版本
  /// sync/WS 落盘 bug 所致）时，全量拉取服务端消息，按 message_id 幂等覆盖为
  /// 真实 created_at（服务端始终保存真实时间）。返回是否发生过修复。
  Future<bool> _backfillTimestamps() async {
    const minPlausible = 100000000000; // 1973-03 之前的毫秒时间戳视为坏值
    final bad = store.history.any((m) => (m['created_at'] as int? ?? 0) < minPlausible);
    if (!bad) return false;
    final api = ApiClient(server);
    var cursor = 0;
    var repaired = false;
    while (true) {
      final result = await _withAutoAuth((token) => api.sync(token, after: cursor));
      for (final env in result.messages) {
        final seq = env.serverSequence ?? cursor;
        final createdAt = env.createdAt;
        if (createdAt != null && createdAt >= minPlausible) {
          store.upsertHistory(env, serverSequence: seq, createdAt: createdAt);
          repaired = true;
        }
        cursor = seq;
      }
      if (result.lastSequence > cursor) cursor = result.lastSequence;
      if (!result.hasMore || result.messages.isEmpty) break;
    }
    if (repaired) store.save(storePath);
    return repaired;
  }

  /// 启动 WS 实时监听（message.new → 落盘 + 解密 + 追加展示缓存）。
  /// 收到 [onEvent]（已处理完消息后）回调，UI 据此重绘；
  /// [onStatus]（连接状态变化）回调同样转发，UI 据此刷新状态栏；
  /// [onAutoSync]（后台自动补拉完成后，携带新增条数）回调——断线重连与周期兜底
  /// 拉到的漏发消息已追加进展示缓存，UI 据此重绘（无需改状态栏）。
  void startWs({
    required void Function(ChatMessage msg) onMessage,
    void Function(WsStatus status)? onStatus,
    void Function(int added)? onAutoSync,
  }) {
    if (server.isEmpty || store.sessionToken == null) return;
    wsClient = WsClient(
      server: server,
      token: store.sessionToken!,
      onUnauthorized: () async {
        // session 过期（WS 4401）：自动重新认证并更新 token，随后 WsClient 立即重连
        await auth();
        wsClient?.updateToken(store.sessionToken!);
      },
      onEvent: (event) async {
        if (event is WsMessageNewEvent) {
          final env = event.message;
          store.upsertHistory(env, serverSequence: event.serverSequence, createdAt: env.createdAt ?? event.serverSequence);
          store.advanceAnchor(event.serverSequence);
          store.save(storePath);
          final plain = await _decrypt(env);
          final msg = ChatMessage(
            env: env,
            plain: plain,
            isMine: env.senderPersonId != null && store.personId != null
            ? env.senderPersonId == store.personId
            : env.senderDeviceId == store.deviceId,
            createdAt: env.createdAt ?? event.serverSequence,
            serverSequence: event.serverSequence,
          );
          _appendDedup(msg);
          _sortMessages();
          onMessage(msg);
        }
      },
      onStatus: (status) {
        // 维护断线时间：connected 清空，connecting/reconnecting 首次进入时记录
        final wasDown = wsDownSince != null;
        switch (status) {
          case WsStatus.connected:
            wsDownSince = null;
          case WsStatus.connecting:
          case WsStatus.reconnecting:
            wsDownSince ??= DateTime.now();
          case WsStatus.stopped:
            break;
        }
        // 断线后重连成功：立即补拉断线期间漏掉的消息（快路径；
        // 周期兜底定时器在下方，双保险防漏）
        if (status == WsStatus.connected && wasDown) {
          _autoSync(onAutoSync: onAutoSync);
        }
        onStatus?.call(status);
      },
    );
    wsClient!.start();
    // 周期兜底同步：WS 推送丢帧/断线不回放漏消息时，定时增量拉取补齐
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(autoSyncInterval, (_) {
      if (wsClient != null) _autoSync(onAutoSync: onAutoSync);
    });
  }

  void stopWs() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    wsClient?.stop();
    wsClient = null;
  }

  /// 后台自动补拉（断线重连快路径 / 周期兜底共用）：增量同步 + 顺带补发离线队列，
  /// 完成后回调 [onAutoSync]。并发保护：同一时间只跑一个；网络异常静默，
  /// 等下一轮定时器或下次重连再试。
  Future<void> _autoSync({void Function(int added)? onAutoSync}) async {
    if (_autoSyncing) return;
    _autoSyncing = true;
    try {
      final fresh = await sync();
      onAutoSync?.call(fresh.length);
    } catch (_) {
      // 静默：后台补拉失败不打扰用户
    } finally {
      _autoSyncing = false;
    }
  }

  /// 上传附件（PROTOCOL.md §6.1，两阶段先传后链）：加密文件 → 先上传密文 blob →
  /// 再发附件消息（正文为描述）。blob 就位后才发消息，避免"消息已广播但对端 blob
  /// 缺失"的幽灵消息；blob 已传但消息发送失败时，孤儿 blob 由服务端定期清理。
  /// 返回 (messageId, attachmentId, caption)。
  Future<({String messageId, String attachmentId, String caption})> attachFile(
    String filePath, {
    String? caption,
  }) async {
    store.requireSpace();
    store.requireSession();
    final file = File(filePath);
    if (!file.existsSync()) throw StateError('文件不存在: $filePath');
    final fileBytes = file.readAsBytesSync();
    final fileName = file.path.split(RegExp(r'[\\/]')).last;

    final messageId = await _uuidv7();
    final attachmentId = await _uuidv7();
    final type = _inferAttachmentType(fileName);
    final cap = caption ?? '📎 $fileName';

    // 1) 加密文件（密文 + 元数据）
    final enc = await encryptAttachment(
      fileBytes: fileBytes,
      spaceKey: base64Decode(store.spaceKey!),
      attachmentId: attachmentId,
      spaceId: store.spaceId!,
      keyVersion: store.keyVersion,
    );

    // 2) 先上传附件 blob（Server 校验 size + sha256；对应 message 此时可尚不存在）
    final env = await encryptMessage(
      plaintext: cap,
      spaceKey: base64Decode(store.spaceKey!),
      spaceId: store.spaceId!,
      senderDeviceId: store.deviceId!,
      senderPersonId: store.personId,
      messageId: messageId,
      type: type,
      keyVersion: store.keyVersion,
    );
    final api = ApiClient(server);
    final att = await _withAutoAuth((token) => api.postAttachment(
          messageId: messageId,
          attachmentId: attachmentId,
          keyVersion: store.keyVersion,
          size: enc.size,
          sha256: enc.sha256,
          nonce: base64Encode(enc.nonce),
          blob: enc.cipher,
          token: token,
        ));

    // 3) 再发附件消息（正文为描述文本，密文上链）
    final msg = await _withAutoAuth((token) => api.postMessage(env, token));

    // 4) 落盘：附件元数据 + 消息历史 + 推进锚点
    store.upsertAttachment(
      attachmentId: attachmentId,
      messageId: messageId,
      keyVersion: store.keyVersion,
      size: enc.size,
      sha256: enc.sha256,
      nonce: base64Encode(enc.nonce),
      createdAt: att['created_at'] as int,
    );
    store.upsertHistory(env, serverSequence: msg.serverSequence, createdAt: msg.createdAt);
    store.advanceAnchor(msg.serverSequence);
    store.save(storePath);
    _appendDecrypted(
      env,
      serverSequence: msg.serverSequence,
      isMine: true,
      plain: cap,
      createdAt: msg.createdAt,
    );
    _sortMessages();
    return (messageId: messageId, attachmentId: attachmentId, caption: cap);
  }

  /// 按扩展名推断附件类型（与 einz.dart 的 _inferAttachmentType 一致）。
  static String _inferAttachmentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic')) {
      return 'image';
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.webm')) {
      return 'video';
    }
    if (lower.endsWith('.m4a') || lower.endsWith('.mp3') || lower.endsWith('.wav') || lower.endsWith('.aac')) {
      return 'voice';
    }
    return 'other';
  }

  /// 按 key_version 选密钥解密（轮换后旧消息用归档密钥）。
  /// 设备未接入空间（spaceKey 为 null）时返回占位文本，避免 sync/WS 解密崩溃。
  Future<String> _decrypt(MessageEnvelope env) async {
    final keyB64 = store.spaceKeyForVersion(env.keyVersion) ?? store.spaceKey;
    if (keyB64 == null) return '（未接入空间，无法解密）';
    return decryptMessage(
      env: env,
      spaceKey: base64Decode(keyB64),
      spaceId: store.spaceId!,
    );
  }

  void _appendDecrypted(
    MessageEnvelope env, {
    required int serverSequence,
    required bool isMine,
    required String plain,
    required int createdAt,
  }) {
    _appendDedup(ChatMessage(
      env: env,
      plain: plain,
      isMine: isMine,
      createdAt: createdAt,
      serverSequence: serverSequence,
    ));
    _sortMessages();
  }

  void _appendDedup(ChatMessage msg) {
    messages.removeWhere((m) => m.env.messageId == msg.env.messageId);
    messages.add(msg);
  }

  void _sortMessages() {
    messages.sort((a, b) {
      final an = a.seq;
      final bn = b.seq;
      // 统一时间序：对话消息按 seq（服务端分配递增）；系统消息（无 seq）按
      // createdAt，且与对话消息混合时也按 createdAt 对齐——系统消息穿插在
      // 对话历史里、不排到末尾（否则渲染（最新在底部）会把系统消息画到最
      // 下方、对话消息反而跑到上方）
      if (an == null || bn == null) {
        return a.createdAt.compareTo(b.createdAt);
      }
      return an.compareTo(bn);
    });
  }

  /// 简易 UUIDv7（与 einz.dart 一致的近似实现）。
  Future<String> _uuidv7() async {
    final s = await sodium();
    final rand = s.randombytes.buf(10);
    final t = DateTime.now().millisecondsSinceEpoch;
    final hex = rand.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final tHex = t.toRadixString(16).padLeft(12, '0');
    return '${tHex.substring(0, 8)}-${tHex.substring(8)}-7${hex.substring(0, 3)}-9${hex.substring(3, 7)}-${hex.substring(7)}';
  }
}
