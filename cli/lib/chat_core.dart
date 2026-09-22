// Einz TUI 聊天核心 —— 与 UI 无关的业务逻辑（方案 A 升级版）。
//
// 从旧版脚本 CLI（已随 v1 收敛删除）提炼：认证 / 发送 / 补发 / 增量同步 / 历史 /
// 解密 / UUIDv7 全部集中于此，供 TUI 界面（einz_tui.dart）复用。
// 定位不变：测试端明文落盘（同 store.dart），不上生产。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:einz_shared/einz_shared.dart';
import 'package:einz_cli/store.dart';

/// 附件解密缓存目录（`~/.einz/cache`）：下载的附件明文落在这里，用系统默认应用打开。
/// 抽成函数是为了让"撤销自毁"和下载两处共用同一个路径（TUI 撤销时要连同它一起清掉）。
String attachmentCacheDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  return '$home/.einz/cache';
}

/// 展示消息的全局插入序号（仅用于排序平局决胜）。Dart 的 `List.sort` **不稳定**，
/// 同毫秒创建的系统消息（如 join 向导里「✅ 我是 X」「----------------」「❓ 验证密保口令:」
/// 基本同刻产生）排序后会被打乱（老板 2026-09-13 实测：口令提示跑到"我是 X"之前）。
int _messageOrderSeq = 0;

/// 展示用消息（已解密明文 + 归属）。
class ChatMessage {
  ChatMessage({
    required this.env,
    required this.plain,
    required this.isMine,
    required this.createdAt,
    this.serverSequence,
    this.isSystem = false,
    this.meta,
    int? order,
  }) : order = order ?? _messageOrderSeq++;

  final MessageEnvelope env;
  final String plain;
  final bool isMine;
  final int createdAt;

  /// 插入顺序（全局单调递增）：仅作排序平局决胜，保证同等时间戳/序号的消息稳定有序。
  final int order;

  /// 系统提示消息（如令牌、引导提示）：sender 显示为 system（不参与"我/对方"）。
  final bool isSystem;

  /// 消息载荷 meta 袋（密文内 `{"plaintext":…,"meta":…}` 的 meta）：
  /// 当前用于语音/音频时长（[kMetaAudioDurationSeconds]）。裸文本消息为 null。
  final Map<String, dynamic>? meta;

  /// 显式 server 序号：本地刚发送的消息与 WS 实时消息在 env 上可能没有
  /// serverSequence（序号在应答/事件帧里），需由调用方显式传入，否则排序会错乱。
  final int? serverSequence;

  int? get seq => serverSequence ?? env.serverSequence;
  int get keyVersion => env.keyVersion;
}

/// 展示消息排序比较器（纯函数，便于单测）：
/// - 对话消息按 `server_sequence`（服务端分配递增）；
/// - 系统消息（无 seq）按 `createdAt`，与对话消息混合时也按 createdAt 对齐——
///   系统消息穿插在对话历史里、不排到末尾（否则渲染（最新在底部）会把系统消息
///   画到最下方、对话消息反而跑到上方）；
/// - 完全平局（同毫秒 createdAt / 同 seq）时按插入顺序 [ChatMessage.order] 决胜——
///   Dart 的 `List.sort` **不稳定**，无此决胜会打乱同刻系统消息（老板 2026-09-13
///   实测：join 向导里「❓ 验证密保口令」跑到「✅ 我是 X」之前）。
int compareChatMessages(ChatMessage a, ChatMessage b) {
  final an = a.seq;
  final bn = b.seq;
  final int byTime;
  if (an == null || bn == null) {
    byTime = a.createdAt.compareTo(b.createdAt);
  } else {
    byTime = an.compareTo(bn);
  }
  if (byTime != 0) return byTime;
  return a.order.compareTo(b.order);
}

/// 聊天会话：封装设备状态、服务器交互与消息缓存。
class ChatSession {
  ChatSession(this.store, this.storePath, this.server);

  final DeviceStore store;
  final String storePath;
  String server;

  /// 展示缓存（按 server_sequence 升序；未同步的排最后）。
  final List<ChatMessage> messages = [];

  /// 展示缓存变化回调（UI 用）：消息被乐观上屏 / 同步追加 / WS 到达时触发重绘。
  /// 在 [_sortMessages] 末尾统一调用——这样离线发送时乐观上屏的消息能在
  /// `flushPending()` 的网络等待**之前**就刷新到屏幕（老板 2026-09-13：App 能
  /// 立刻显示离线消息，TUI 之前要等补发网络超时回来才显示）。
  void Function()? onChanged;

  /// 认证时被服务端**明确撤销**（403 `DEVICE_REVOKED`）的回调——UI 据此清盘并退出。
  /// 与其它撤销路径（WS `device.revoked` 帧、启动自检、引导认证）语义一致：
  /// **只有明确撤销才清空本地数据**；`FORBIDDEN`（库被重置/未登记）不走这里。
  void Function()? onDeviceRevoked;

  /// WS 实时监听（null = 未启动）。
  WsClient? wsClient;

  /// 断线开始时间（WS 处于 connecting/reconnecting 时记录；connected 时清空）。
  /// 供 UI 状态栏显示"已断线 Ns"。
  DateTime? wsDownSince;

  /// 对方（接收方）已送达高水位：personId → seq，只前进不倒退。
  /// 用于推导"我发出的消息"是否已送达（delivered）。**不含本端自己那行**——
  /// 自己的水位描述的是"我收到对方哪些消息"，与我发出的消息无关（App 同款坑）。
  final Map<String, int> peerDeliveredUpto = {};

  /// 对方已读高水位：personId → seq，只前进不倒退（语义同 [peerDeliveredUpto]）。
  /// 服务端保证 read ≤ delivered；TUI 据此把"已读"的消息状态字符标蓝。
  final Map<String, int> peerReadUpto = {};

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
  /// 未发送的离线队列（pending）也一并上屏（展示为 pending）——恢复网络补发后
  /// 按 messageId 覆盖为 sent，与我发出的每条消息都有状态一致。
  Future<void> loadHistory() async {
    final seen = <String>{};
    messages.clear();
    for (final env in store.historyEnvelopes) {
      if (!seen.add(env.messageId)) continue;
      final dec = await _decrypt(env);
      messages.add(ChatMessage(
        env: env,
        plain: dec.plain,
        meta: dec.meta,
        isMine: env.senderPersonId != null && store.personId != null
            ? env.senderPersonId == store.personId
            : env.senderDeviceId == store.deviceId,
        createdAt: env.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        serverSequence: env.serverSequence,
      ));
    }
    for (final env in store.pendingEnvelopes) {
      if (!seen.add(env.messageId)) continue; // 已在历史（补发后落盘）的不重复
      final dec = await _decrypt(env);
      messages.add(ChatMessage(
        env: env,
        plain: dec.plain,
        meta: dec.meta,
        isMine: true, // 离线队列里的必然是本端发出的
        createdAt: env.createdAt ?? DateTime.now().millisecondsSinceEpoch,
        serverSequence: null,
      ));
    }
    _sortMessages();
  }

  /// 认证（challenge → sealOpen → verify），成功写入 store。
  Future<void> auth({String? serverOverride}) async {
    final target = serverOverride ?? server;
    if (target.isEmpty) throw StateError('缺少服务器地址（启动时 --server 或 /server <地址>）');
    final api = ApiClient(target);
    final s = await sodium();

    // 未登记（登记失败/令牌输错）时 deviceId 为 null——先检查，避免空断言崩溃
    final deviceId = store.deviceId;
    if (deviceId == null) {
      throw StateError('设备尚未绑定秘境，请先 /space create（新建）或 /space join <令牌或令牌链接>（加入）');
    }
    // spaceId 必须一并提交：否则拿到的是"无 space 的 legacy 会话"，/sync 与
    // /messages 会落到空 space 桶 → 会话过期自动续期后消息全空（P1 收敛）。
    final ChallengeResult challenge;
    try {
      challenge = await api.challenge(deviceId, spaceId: store.spaceId);
    } on ApiException catch (e) {
      // 挑战被明确拒绝为"设备已撤销" → 通知 UI 清盘退出（其他失败原样抛出：
      // FORBIDDEN 只是"服务器不认本设备"，最常见的原因是后台库被重置，绝不能删数据）
      if (e.code == 'DEVICE_REVOKED') onDeviceRevoked?.call();
      rethrow;
    }
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
  /// 再从 Server 拉取口令密保箱解出 Space Key 写回 store。
  /// 新设备接入无需对方公钥（与 App「加入」流程一致）；口令错误抛 [FormatException]。
  Future<void> accessByEscrow(String passphrase) async {
    await auth(); // 拉取口令密保箱需要 session_token
    final api = ApiClient(server);
    final escrow = KeyEscrowService(api);
    final payload = await escrow.fetch(passphrase: passphrase, token: store.sessionToken!);
    if (payload == null) {
      throw StateError('Server 无口令密保箱（请先在对端执行 escrow upload）');
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

    // 立即上屏（pending）：不等服务端往返——确认后同一 messageId 覆盖为 sent。
    // 离线/失败时留在队列里，恢复后补发并覆盖（见 flushPending）。
    _appendDedup(ChatMessage(
      env: env,
      plain: text,
      isMine: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      serverSequence: null,
    ));
    _sortMessages();

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
        // 展示缓存里的 pending 消息覆盖为 sent（拿到真实 seq/时间，按 messageId 去重）
        final dec = await _decrypt(env);
        _appendDedup(ChatMessage(
          env: env,
          plain: dec.plain,
          meta: dec.meta,
          isMine: env.senderPersonId != null && store.personId != null
              ? env.senderPersonId == store.personId
              : env.senderDeviceId == store.deviceId,
          createdAt: result.createdAt,
          serverSequence: result.serverSequence,
        ));
        _sortMessages();
      } on Exception {
        break; // 网络层问题：停止本轮，避免空转
      }
    }
    if (sent.isNotEmpty) store.save(storePath);
    return sent;
  }

  /// 上报自己的送达/已读高水位（服务端只前进；失败不致命，下次会再报——
  /// 重复上报因单调夹紧是 no-op）。返回是否成功。
  Future<bool> _reportReceipts({int? deliveredUptoSeq, int? readUptoSeq}) async {
    if (server.isEmpty || store.sessionToken == null) return false;
    if (deliveredUptoSeq == null && readUptoSeq == null) return false;
    try {
      final api = ApiClient(server);
      await _withAutoAuth((token) => api.postReceipts(
            token,
            deliveredUptoSeq: deliveredUptoSeq,
            readUptoSeq: readUptoSeq,
          ));
      return true;
    } catch (_) {
      // 网络抖动忽略：下次 sync/收消息会再报
      return false;
    }
  }

  /// 本端已同步到 [store.lastServerSequence] → 这些消息确实收到了 → 上报"已送达"
  /// （单调 + 防抖：用 store 里已上报过的高水位去重）。
  Future<void> _reportDeliveredIfAdvanced() async {
    final seq = store.lastServerSequence;
    if (seq <= store.lastReportedDeliveredSeq) return;
    // 成功才推进防抖标记：否则一次失败就再也不会重报（服务端永远缺这一档）
    if (await _reportReceipts(deliveredUptoSeq: seq)) {
      store.advanceReported(delivered: seq);
      store.save(storePath);
    }
  }

  /// 上报"已读"：**仅由 WS 实时到达**（用户正看着终端）调用，补拉的历史不算
  /// （老板 2026-09-12）。单调 + 防抖：成功才推进标记，失败下次会重报。
  Future<void> _reportReadIfAdvanced(int seq) async {
    if (seq <= store.lastReportedReadSeq) return;
    if (await _reportReceipts(readUptoSeq: seq)) {
      store.advanceReported(read: seq);
      store.save(storePath);
    }
  }

  /// 拉取本 space 回执行，合并对方的已送达高水位（启动 / 重连 / 周期兜底用；
  /// WS `receipt.updated` 是实时路径）。排除自己那一行——见 [peerDeliveredUpto]。
  /// 网络抖动静默忽略：下次同步/重连再拉。
  Future<void> refreshReceipts() async {
    if (server.isEmpty || store.sessionToken == null) return;
    try {
      final rows = await _withAutoAuth((token) => ApiClient(server).getReceipts(token));
      for (final r in rows) {
        if (r.personId == store.personId) continue;
        final cur = peerDeliveredUpto[r.personId] ?? 0;
        if (r.deliveredUptoSeq > cur) peerDeliveredUpto[r.personId] = r.deliveredUptoSeq;
        final curRead = peerReadUpto[r.personId] ?? 0;
        if (r.readUptoSeq > curRead) peerReadUpto[r.personId] = r.readUptoSeq;
      }
    } catch (_) {
      // 网络抖动忽略
    }
  }

  /// 我发出消息的发送状态（UI 展示用）：
  /// - `pending`：尚未被服务端确认（仍在离线队列，或还没拿到 server_sequence）
  /// - `sent`：服务端已收下（有 server_sequence），但对方尚未确认送达
  /// - `delivered`：对方（所有接收方）已送达高水位 ≥ 该消息 seq
  /// - `read`：对方已读高水位 ≥ 该消息 seq（TUI 用它把状态字符标蓝）
  /// 非我的消息 / 系统消息返回空串。
  String sentStatusOf(ChatMessage m) {
    if (!m.isMine || m.isSystem) return '';
    if (store.hasPending(m.env.messageId)) return 'pending';
    final seq = m.seq;
    if (seq == null) return 'pending';
    if (peerReadUpto.isNotEmpty && peerReadUpto.values.every((r) => r >= seq)) {
      return 'read';
    }
    if (peerDeliveredUpto.isEmpty) return 'sent';
    return peerDeliveredUpto.values.every((d) => d >= seq) ? 'delivered' : 'sent';
  }

  /// 增量同步：从本地锚点拉取，落盘历史，返回新增消息（解密后已追加展示缓存）。
  /// 同时补发离线队列。
  /// [from]：定向补拉起点（覆盖本地锚点，不倒退锚点）——WS 实时收到消息时
  /// 锚点已推进，普通增量 sync 不会重发已收消息；需要其附件元数据
  /// （attachments_meta 只随当页消息下发）时，从目标消息之前重拉即可补上。
  Future<List<ChatMessage>> sync({int? from}) async {
    if (server.isEmpty) throw StateError('缺少服务器地址（--server）');
    store.requireSpace();
    store.requireSession();
    final api = ApiClient(server);

    var cursor = from ?? store.lastServerSequence;
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
      // 附件元数据落盘（供 /open 解密：nonce/sha256/key_version 必需，
      // PROTOCOL.md §5.2 attachments_meta）——收到的附件消息同样要能打开
      for (final meta in result.attachmentsMeta) {
        store.upsertAttachment(
          attachmentId: meta['attachment_id'] as String,
          messageId: meta['message_id'] as String,
          keyVersion: meta['key_version'] as int,
          size: meta['size'] as int,
          sha256: meta['sha256'] as String,
          nonce: meta['nonce'] as String,
          createdAt: meta['created_at'] as int,
        );
      }
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
    // 回执：本端已同步到 cursor（确实收到了这些消息）→ 上报"已送达"。
    // **不**上报已读——补拉的历史不等于人看过（老板 2026-09-12）：已读只由 WS
    // 实时到达（用户正看着终端）推进，见下面的 WS 分支。
    await _reportDeliveredIfAdvanced();

    final seen = <String>{};
    final fresh = <ChatMessage>[];
    for (final env in added) {
      if (!seen.add(env.messageId)) continue;
      final dec = await _decrypt(env);
      final seq = env.serverSequence;
      final msg = ChatMessage(
        env: env,
        plain: dec.plain,
        meta: dec.meta,
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
    void Function(WsPeerStatusEvent event)? onPeerStatus,
    void Function(WsPassphraseRotatedEvent event)? onPassphraseRotated,
    void Function(WsProfileUpdatedEvent event)? onProfileUpdated,
    void Function(WsDeviceRevokedEvent event)? onRevoked,
    void Function()? onUnrecognized,
    void Function()? onReceiptUpdated,
  }) {
    if (server.isEmpty || store.sessionToken == null) return;
    wsClient = WsClient(
      server: server,
      token: store.sessionToken!,
      onUnauthorized: () async {
        // session 过期（WS 4401）：自动重新认证并更新 token，随后 WsClient 立即重连
        try {
          await auth();
          wsClient?.updateToken(store.sessionToken!);
        } on ApiException catch (e) {
          // 重新认证失败要区分语义（老板 2026-09-16）——异常被 ws_client 吞掉的话，
          // 后台库被重置时客户端会无限静默退避重连，用户看不到任何解释。
          if (e.code == 'DEVICE_REVOKED') {
            // 设备被明确撤销：交给 UI 走"自毁 + 退出"（WS 就此结束，不必再重连）
            onRevoked?.call(WsDeviceRevokedEvent(
              type: kWsTypeDeviceRevoked,
              deviceId: store.deviceId ?? '',
            ));
            wsClient?.stop();
            return;
          }
          if (e.code == 'FORBIDDEN') {
            // 服务器不认本设备（最可能是后台库被重置）→ 只警告。异常**照旧抛出**：
            // ws_client 只在 onUnauthorized 抛异常时走退避重连（正常返回会立刻重连
            // → 每次 4401 就重连一次，等于打服务端）；退避重连也保证库被复原后自动恢复
            onUnrecognized?.call();
          }
          rethrow;
        }
      },
      onEvent: (event) async {
        if (event is WsMessageNewEvent) {
          final env = event.message;
          store.upsertHistory(env, serverSequence: event.serverSequence, createdAt: env.createdAt ?? event.serverSequence);
          store.advanceAnchor(event.serverSequence);
          store.save(storePath);
          final dec = await _decrypt(env);
          final msg = ChatMessage(
            env: env,
            plain: dec.plain,
            meta: dec.meta,
            isMine: env.senderPersonId != null && store.personId != null
            ? env.senderPersonId == store.personId
            : env.senderDeviceId == store.deviceId,
            createdAt: env.createdAt ?? event.serverSequence,
            serverSequence: event.serverSequence,
          );
          _appendDedup(msg);
          _sortMessages();
          onMessage(msg);
          // 回执：实时到达并已上屏 → 立即上报"已读"（读隐含送达）
          await _reportReadIfAdvanced(event.serverSequence);
        }
        if (event is WsPeerStatusEvent) {
          onPeerStatus?.call(event);
        }
        if (event is WsPassphraseRotatedEvent) {
          onPassphraseRotated?.call(event);
        }
        if (event is WsProfileUpdatedEvent) {
          onProfileUpdated?.call(event);
        }
        if (event is WsReceiptUpdatedEvent) {
          // 对方送达/已读水位更新：合并到本地（排除自己那行——见 peerDeliveredUpto）
          if (event.personId != store.personId) {
            final cur = peerDeliveredUpto[event.personId] ?? 0;
            if (event.deliveredUptoSeq > cur) {
              peerDeliveredUpto[event.personId] = event.deliveredUptoSeq;
            }
            final curRead = peerReadUpto[event.personId] ?? 0;
            if (event.readUptoSeq > curRead) {
              peerReadUpto[event.personId] = event.readUptoSeq;
            }
          }
          onReceiptUpdated?.call();
        }
        if (event is WsDeviceRevokedEvent) {
          // 本设备已被撤销（Server 发帧后随即断开）：UI 应立即提示并退出
          onRevoked?.call(event);
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
      await refreshReceipts(); // 顺带刷新对方送达水位（delivered 状态展示）
      onAutoSync?.call(fresh.length);
    } catch (_) {
      // 静默：后台补拉失败不打扰用户
    } finally {
      _autoSyncing = false;
    }
  }

  /// 上传附件（PROTOCOL.md §6.1，两阶段先传后链）：加密文件 → 先上传密文 blob →
  /// 再发附件消息（正文为描述）。**上链顺序不变**：blob 就位后才发消息，避免
  /// "消息已广播但对端 blob 缺失"的幽灵消息；blob 已传但消息发送失败时，孤儿 blob
  /// 由服务端定期清理。
  ///
  /// 但**展示层不等网络**（老板 2026-09-14）：信封一装好就先乐观上屏（pending `⋯`，
  /// 与 [sendText] 同款），加密/上传/发消息在后台继续，拿到应答后按 messageId 覆盖为
  /// sent（`✓`）。否则大文件上传期间消息流毫无反馈，回车后要干等（体验停顿）。
  /// 失败时撤掉这条乐观气泡并 rethrow（附件 blob v1 不做补传，留着会误导成"已发出"）。
  /// 返回 (messageId, attachmentId, caption)。
  Future<({String messageId, String attachmentId, String caption})> attachFile(
    String filePath, {
    String? caption,
  }) async {
    store.requireSpace();
    store.requireSession();
    final resolved = _expandUserHome(filePath);
    final file = File(resolved);
    if (!file.existsSync()) throw StateError('文件不存在: $filePath（已展开为 $resolved）');
    final fileName = resolved.split(RegExp(r'[\\/]')).last;

    final messageId = await _uuidv7();
    final attachmentId = await _uuidv7();
    final type = _inferAttachmentType(fileName);
    final cap = caption ?? '📎 $fileName';

    // 1) 附件消息信封（正文=描述）。与文件字节无关，先装好即可上屏
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

    // 2) 立即上屏（pending）：不等加密/上传往返——确认后同一 messageId 覆盖为 sent
    _appendDedup(ChatMessage(
      env: env,
      plain: cap,
      isMine: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      serverSequence: null,
    ));
    _sortMessages();

    try {
      // 3) 加密文件（密文 + 元数据）
      final fileBytes = await file.readAsBytes();
      final enc = await encryptAttachment(
        fileBytes: fileBytes,
        spaceKey: base64Decode(store.spaceKey!),
        attachmentId: attachmentId,
        spaceId: store.spaceId!,
        keyVersion: store.keyVersion,
      );

      // 4) 先上传附件 blob（Server 校验 size + sha256；对应 message 此时可尚不存在）
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

      // 5) 再发附件消息（正文为描述文本，密文上链）
      final msg = await _withAutoAuth((token) => api.postMessage(env, token));

      // 6) 落盘：附件元数据 + 消息历史 + 推进锚点
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
      // 乐观气泡覆盖为 sent（_appendDecrypted 内部会 _sortMessages 通知 UI 重绘）
      _appendDecrypted(
        env,
        serverSequence: msg.serverSequence,
        isMine: true,
        plain: cap,
        createdAt: msg.createdAt,
      );
    } catch (e) {
      // 加密/上传/发送失败：撤掉乐观气泡（blob 未就位，留着会误导成"已发出"）
      messages.removeWhere((m) => m.env.messageId == messageId);
      _sortMessages();
      rethrow;
    }
    return (messageId: messageId, attachmentId: attachmentId, caption: cap);
  }

  /// 打开某条消息的附件（/open）：按 message_id 定位附件元数据 → 下载密文 blob
  /// → 校验 sha256 → 解密 → 写入缓存文件 → 系统默认应用打开（macOS open /
  /// Linux xdg-open）。返回本地缓存路径（无打开器的平台仅保存，由界面提示）。
  Future<String> openAttachment(ChatMessage msg) async {
    store.requireSpace();
    store.requireSession();
    final meta = store.attachmentMetaByMessage(msg.env.messageId);
    if (meta == null) {
      throw StateError('该消息没有附件元数据（对方发来的附件请先 /sync 拉取）');
    }
    final attachmentId = meta['attachment_id'] as String;
    final api = ApiClient(server);
    final blob = await _withAutoAuth((token) => api.getAttachment(attachmentId, token));
    // 校验密文完整性（sha256 与元数据一致，PROTOCOL.md §6.1；编码同为 base64）
    final actual = base64Encode(crypto.sha256.convert(blob).bytes);
    if (actual != meta['sha256']) {
      throw StateError('附件密文 sha256 校验失败（传输损坏或被篡改）');
    }
    final plain = await decryptAttachment(
      cipherText: blob,
      nonce: base64Decode(meta['nonce'] as String),
      spaceKey: base64Decode(store.spaceKey!),
      attachmentId: attachmentId,
      spaceId: store.spaceId!,
      keyVersion: meta['key_version'] as int,
    );
    // 缓存目录 ~/.einz/cache；扩展名优先取 caption 里的文件名，其次按消息类型兜底
    final cacheDir = Directory(attachmentCacheDir())..createSync(recursive: true);
    final extMatch = RegExp(r'\.([A-Za-z0-9]{1,8})$').firstMatch(msg.plain);
    final ext = extMatch?.group(1)?.toLowerCase() ??
        switch (msg.env.type) {
          'image' => 'jpg',
          'video' => 'mp4',
          'voice' || 'audio' => 'm4a',
          'text' => 'txt',
          _ => 'bin',
        };
    final outPath = '${cacheDir.path}/${attachmentId.substring(0, 8)}.$ext';
    File(outPath).writeAsBytesSync(plain);
    // 系统默认应用打开（图片/音视频由系统查看器/播放器接管）
    final opener = Platform.isMacOS
        ? 'open'
        : Platform.isLinux
            ? 'xdg-open'
            : null;
    if (opener != null) {
      final pr = await Process.run(opener, [outPath]);
      if (pr.exitCode != 0) {
        throw StateError('打开失败（$opener 退出码 ${pr.exitCode}），文件已保存: $outPath');
      }
    }
    return outPath;
  }

  /// 按扩展名推断附件类型。
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
    // 未知扩展名（txt/pdf/zip/doc…）归通用 file 类型：服务端消息类型白名单
    // （text/image/video/voice/audio/file/system）含 file，任意文件可上传
    return 'file';
  }

  /// 按 key_version 选密钥解密（轮换后旧消息用归档密钥），返回载荷解析结果
  /// （正文 + meta）。设备未接入空间（spaceKey 为 null）时返回占位文本，避免
  /// sync/WS 解密崩溃。
  /// 载荷可能是裸文本，也可能是 `{"plaintext":…,"quote":…,"meta":…}` JSON
  /// （App 引用/meta 扩展）——统一走 shared 的 [decodeMessagePayload]；TUI 不做
  /// 引用块渲染，但 meta 要取出（如语音/音频时长 [kMetaAudioDurationSeconds]）。
  Future<({String plain, Map<String, dynamic>? meta})> _decrypt(MessageEnvelope env) async {
    final keyB64 = store.spaceKeyForVersion(env.keyVersion) ?? store.spaceKey;
    if (keyB64 == null) return (plain: '（未接入空间，无法解密）', meta: null);
    final raw = await decryptMessage(
      env: env,
      spaceKey: base64Decode(keyB64),
      spaceId: store.spaceId!,
    );
    final payload = decodeMessagePayload(raw);
    return (plain: payload.plaintext, meta: payload.meta);
  }

  void _appendDecrypted(
    MessageEnvelope env, {
    required int serverSequence,
    required bool isMine,
    required String plain,
    required int createdAt,
    Map<String, dynamic>? meta,
  }) {
    _appendDedup(ChatMessage(
      env: env,
      plain: plain,
      meta: meta,
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
    messages.sort(compareChatMessages);
    onChanged?.call(); // 通知 UI 重绘（乐观上屏 / 同步 / WS 追加后立即刷新）
  }

  /// 简易 UUIDv7（TUI/CLI 与 App 各自的近似实现，语义一致）。
  Future<String> _uuidv7() async {
    final s = await sodium();
    final rand = s.randombytes.buf(10);
    final t = DateTime.now().millisecondsSinceEpoch;
    final hex = rand.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final tHex = t.toRadixString(16).padLeft(12, '0');
    return '${tHex.substring(0, 8)}-${tHex.substring(8)}-7${hex.substring(0, 3)}-9${hex.substring(3, 7)}-${hex.substring(7)}';
  }
}

/// 展开路径开头的 ~（家目录）：TUI/CLI 内用户输入的路径不经 shell 展开，
/// File('~/v.jpg') 会被当字面量（CWD 下名为 ~ 的目录）→ 文件不存在而失败。
/// 仅处理 ~ 与 ~/（~user 形式需解析 passwd，不支持）；Windows 兼容 USERPROFILE。
String _expandUserHome(String path) {
  if (path == '~') return _homeDir();
  if (path.startsWith('~/') || path.startsWith('~\\')) {
    return '${_homeDir()}${path.substring(1)}';
  }
  return path;
}

String _homeDir() {
  return Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
}
