import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:einz_shared/einz_shared.dart';

import 'burn_after_settings.dart';
import 'local_database.dart';

/// 历史消息记录（UI 渲染单元）：env=密文信封、plaintext=明文、
/// sender=身份判断（'me'/'peer'，person 维度）、attachment=附件元数据、
/// expiresAt=阅后即焚到期时间（null=永久）、createdAt=发送时间戳（毫秒，
/// 落盘值，未同步消息为本地发送时间）、burnAfterSeconds=焚毁时长（秒，
/// 归档恢复缺快照时按 到期-创建 反推）、quote=引用快照（{messageId, preview}，
/// 密文载荷内传输，null=非引用消息）、deleted=本机墓碑（true=已删除/已焚毁，
/// UI 只显示时间+焚毁记录、隐藏内容——老板决策 2026-09-09）、
/// burnManual=该条焚毁是否由用户长按单条手动设置（true 才在气泡标注
/// 「设置/修改时间+时长」，全局设置快照只标时长——老板 2026-09-12）、
/// status=本地投递状态（pending=队列中/发送中、sent=已发送、failed=发送失败待重发；
/// 仅本机自己发的消息有意义，UI 据此显示时钟/对勾/警告——老板 2026-09-12）、
/// meta=载荷里的附加数据（密文内、Server 不可见；随消息同步，用于以后未知的
/// 新数据，老板 2026-09-13 定；当前键见 kMetaAudioDurationSeconds）。
typedef HistoryMessage = ({
  MessageEnvelope env,
  String plaintext,
  String sender,
  Map<String, dynamic>? attachment,
  int? expiresAt,
  int createdAt,
  int burnAfterSeconds,
  Map<String, dynamic>? quote,
  bool deleted,
  bool burnManual,
  String status,
  Map<String, dynamic>? meta,
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
    this.token,
    this.settings,
    this.reauth,
    String? personId,
  }) {
    // 向导完成时已知本端 personId：立即种入映射，保证首帧就按 person 判定归属
    // （离线启动时 GET /space 拉不到映射；持久化映射由 refreshDeviceMap 落盘）。
    final pid = personId;
    if (pid != null && pid.isNotEmpty) _personByDevice[deviceId] = pid;
  }

  final LocalDatabase db;
  final ApiClient api;
  final Uint8List spaceKey;
  final String spaceId;
  final String deviceId;
  final int keyVersion;

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

  /// 正在上传中的 messageId：避免同一封被并发重复上传。
  /// （send / retryMessage / _flushPending 三条路径都可能碰到同一行，
  /// 服务端虽按 message_id 幂等，但白发的请求也会占带宽、刷日志。
  /// 老板 2026-09-13 允许点按小飞机后，这条并发路径变得更常见。）
  final Set<String> _pendingUploads = {};

  /// 该异常是否属于「服务端**明确拒绝**」——只有这类才该标 failed。
  ///
  /// 4xx = 信封不合法 / 未授权 / 设备被撤销 → 重试也不会成功，必须让用户看到。
  /// 其余（网络异常、连接/响应超时、5xx）都属于**不确定**：服务端可能其实已存
  /// （响应丢在回程），保持 pending 交给 [_flushPending] 幂等重试即可自动收敛。
  static bool _isServerRejection(Object e) =>
      e is ApiException && e.httpStatus >= 400 && e.httpStatus < 500;

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

  /// 设备 → 用户（person_id）映射（GET /space 缓存，多设备凭证语义）。
  /// 用于判断消息是否"同一个人"发送：同 person 不同设备显示为 'me'。
  final Map<String, String> _personByDevice = {};

  /// device→person 映射的本地持久化键：离线启动时 GET /space 拿不到，只有靠这份
  /// 缓存才认得出"同一身份其他设备"发来的消息（否则一律判成对方、气泡全左对齐——
  /// 老板 2026-09-13 实测；TUI 侧因持久化 personId 而无此问题）。
  static const _kDevicePersonMap = 'identity.device_person_map';

  /// 身份缓存是否已从库里载入（首次判归属 / 发送前惰性载入一次）。
  bool _identityLoaded = false;

  /// 惰性载入持久化的 device→person 映射（离线也能用）。
  Future<void> _ensureIdentityLoaded() async {
    if (_identityLoaded) return;
    _identityLoaded = true;
    try {
      final row = await (db.select(db.appState)
            ..where((s) => s.key.equals(_kDevicePersonMap)))
          .getSingleOrNull();
      final raw = row?.value;
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      // putIfAbsent：不覆盖构造函数种入的本端 personId（向导已知，优先采信）
      for (final e in m.entries) {
        _personByDevice.putIfAbsent(e.key, () => e.value as String);
      }
    } catch (_) {
      // 缓存损坏：忽略（退化为 device 维度判断）
    }
  }

  /// 持久化 device→person 映射（GET /space 成功后 / 记录本端 personId 时）。
  Future<void> _saveIdentityMap() async {
    if (_personByDevice.isEmpty) return;
    try {
      await db.into(db.appState).insertOnConflictUpdate(
            AppStateCompanion.insert(
              key: _kDevicePersonMap,
              value: jsonEncode(_personByDevice),
            ),
          );
    } catch (_) {
      // 落盘失败不影响本次会话（下次联网刷新再写）
    }
  }

  /// 拉取空间设备映射（person_id）。映射缺失时 history 的 sender 判断降级为 device 维度。
  Future<void> refreshDeviceMap() async {
    final t = token;
    if (t == null) return;
    try {
      final space = await _withAutoAuth((tok) => api.getSpace(tok));
      final seeded = _personByDevice[deviceId]; // 构造函数种入的本端 personId
      _personByDevice
        ..clear()
        ..addEntries(space.devices.map((d) => MapEntry(d.deviceId, d.personId)));
      if (seeded != null && !_personByDevice.containsKey(deviceId)) {
        _personByDevice[deviceId] = seeded; // 服务端列表缺本机时兜底保留
      }
      await _saveIdentityMap(); // 落盘：离线启动仍能按 person 判定归属
    } catch (_) {
      // 网络抖动忽略：保留旧映射（无映射时降级 device 判断）
    }
  }

  /// 消息是否本端（我）发送：**优先 person 维度**——信封自带 senderPersonId，
  /// 离线也拿得到；映射缺失再依次退到映射查表、device 维度。
  /// （旧实现只看 device：离线映射为空时，"同一身份其他设备"发的消息会被误判成
  /// 对方 → 气泡全左对齐——老板 2026-09-13 实测。）
  bool _isMineMessage(MessageEnvelope env) {
    final myPerson = _personByDevice[deviceId];
    final senderPerson =
        env.senderPersonId ?? _personByDevice[env.senderDeviceId];
    if (myPerson != null && senderPerson != null) {
      return myPerson == senderPerson;
    }
    return env.senderDeviceId == deviceId;
  }

  /// 设备 → 用户（person_id）查询（渲染兜底：旧版附件消息信封可能缺 senderPersonId）。
  String? personIdOfDevice(String deviceId) => _personByDevice[deviceId];

  /// 当前同步锚点（本地库 sync_state）。
  Future<int> get lastSequence async {
    final row = await (db.select(db.syncState)
          ..where((s) => s.spaceId.equals(spaceId)))
        .getSingleOrNull();
    return row?.lastServerSequence ?? 0;
  }

  /// 发送一条消息：加密 → 落库（pending）→ 尝试立即上传；失败留队。
  /// [quote] 引用快照（{messageId, preview}）、[meta] 附加数据（如音频时长秒数）
  /// ——二者任一非空时载荷包装为 JSON（密文内传输，Server 不可见）。
  /// [onPersisted] 本地落库后、网络上传前回调（UI 据此「乐观回显」：立即把
  /// pending 气泡画出来，不必等上传/sync 往返——老板 2026-09-12）；回调异常被
  /// 吞掉，绝不影响发送本身。
  /// 返回 message_id。
  Future<String> send(
    String plaintext, {
    String type = 'text',
    Map<String, dynamic>? quote,
    Map<String, dynamic>? meta,
    FutureOr<void> Function(String messageId)? onPersisted,
  }) async {
    final messageId = _uuidv7();
    await _ensureIdentityLoaded(); // 离线也要带上本端 personId（归属判定/展示用）
    // 引用/附加数据：载荷 = {"plaintext":…, "quote":…, "meta":…} JSON（AEAD 密文内，
    // Server 不可见；旧客户端/CLI 未识别时按整段 JSON 文本展示，仅影响这类消息）
    final payload = encodeMessagePayload(plaintext, quote: quote, meta: meta);
    final env = await encryptMessage(
      plaintext: payload,
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
    await _notifyPersisted(onPersisted, messageId);

    final t = token;
    if (t != null) {
      _pendingUploads.add(messageId);
      try {
        final result = await _withAutoAuth((tok) => api.postMessage(env, tok));
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
      } on Exception catch (e) {
        // 只有**服务端明确拒绝**才标 failed；网络类失败保持 pending。
        // （老板 2026-09-13 定：pending = "还没确认"，交给 _flushPending 幂等重试
        //   自动收敛——服务端已存则返回原 seq、未存则本次存入，最终都变"已发送"，
        //   用户无需手动点按；failed 只留给重试也没用的明确拒绝。）
        if (_isServerRejection(e)) await _setStatus(messageId, 'failed');
      } finally {
        _pendingUploads.remove(messageId);
      }
    }
    return messageId;
  }

  /// 发送附件消息（语音/图像/视频，PROTOCOL.md §6）：
  /// 加密文件 blob 上传 /attachments + 发送 caption 消息 + 本地附件元数据落库。
  /// 无 token 时消息入 pending 队列（附件 blob 需联网时上传，v1 不做离线附件补传）。
  /// [quote] 引用快照（{messageId, preview, type}）——任何类型的消息都可引用任何
  /// 类型的消息（老板要求 2026-09-13），与 [send] 一致。
  /// [onPersisted] 见 [send]：本地落库后、上传前回调，用于乐观回显（此时附件元数据
  /// 已落库，图片/视频可直接显示）。
  /// 返回 message_id。
  Future<String> sendAttachment({
    required Uint8List fileBytes,
    required String fileName,
    required String type, // image | video | voice
    String? caption,
    Map<String, dynamic>? quote,
    Map<String, dynamic>? meta, // 附加数据（如音频时长），随密文载荷同步
    FutureOr<void> Function(String messageId)? onPersisted,
  }) async {
    final messageId = _uuidv7();
    final attachmentId = _uuidv7();
    await _ensureIdentityLoaded(); // 离线也要带上本端 personId（归属判定/展示用）
    final plain = caption ?? (type == 'voice' ? '🎤 语音消息' : '📎 $fileName');

    // 1) 加密文件（密文 + sha256 + nonce + size）
    final enc = await encryptAttachment(
      fileBytes: fileBytes,
      spaceKey: spaceKey,
      attachmentId: attachmentId,
      spaceId: spaceId,
      keyVersion: keyVersion,
    );

    // 2) 本地附件元数据 + 密文副本即时落库（上传前）——发送端气泡不依赖上传结果，
    //    上传/发送失败也能直接显示图片视频（老板 2026-09-11）
    await _insertAttachmentMeta({
      'attachment_id': attachmentId,
      'message_id': messageId,
      'key_version': keyVersion,
      'size': enc.size,
      'sha256': enc.sha256,
      'nonce': base64Encode(enc.nonce),
      'local_cipher': enc.cipher,
    });

    // 3) 发送 caption 消息（type 标记，供接收端渲染；quote + meta 随载荷一起进密文）
    final env = await encryptMessage(
      plaintext: encodeMessagePayload(plain, quote: quote, meta: meta),
      spaceKey: spaceKey,
      spaceId: spaceId,
      senderDeviceId: deviceId,
      senderPersonId: _personByDevice[deviceId],
      messageId: messageId,
      type: type,
      keyVersion: keyVersion,
    );
    // 附件消息同样受阅后即焚控制（此前漏带焚毁状态 → 本端副本永久保留）
    final bs = await _burnState();
    await _insertLocal(env, status: 'pending', burnAfterSeconds: bs.burn, expiresAt: bs.expiresAt);
    await _notifyPersisted(onPersisted, messageId);

    final t = token;
    if (t != null) {
      try {
        // 4) 上传密文 blob（x-attachment-meta 头带元数据）
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
        // 5) 发消息
        final result = await _withAutoAuth((tok) => api.postMessage(env, tok));
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
      } on Exception {
        // 失败：消息留 pending（补发时消息会重发，但附件 blob 未上传 v1 不自动补传）。
        // 不标 failed——附件 blob 本就无法自动补传，标失败会误导用户重试。
      }
    }
    return messageId;
  }

  /// 本设备上已到期的阅后即焚消息打**本地墓碑**（纯本地，Server 不参与）：
  /// 只置 deletedAt，行与附件保留——UI 隐藏内容、保留时间+时钟+时长记录
  /// （老板决策 2026-09-09，替代原来的到期删行）。已墓碑的不重复标记。
  /// [now] 可注入测试（毫秒时间戳）；返回本次新标记的 messageId 列表
  /// （调用方据此定点清理媒体解密缓存等关联资源）。
  Future<List<String>> tombstoneExpired({int? now}) async {
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    final expired = await (db.select(db.localMessages)
          ..where((m) =>
              m.deletedAt.isNull() &
              m.expiresAt.isNotNull() &
              m.expiresAt.isSmallerOrEqualValue(t)))
        .get();
    for (final row in expired) {
      await (db.update(db.localMessages)..where((m) => m.messageId.equals(row.messageId))).write(
        LocalMessagesCompanion(deletedAt: Value(t)),
      );
    }
    return [for (final row in expired) row.messageId];
  }

  /// 删除本机一条消息（**本地墓碑**，Server 不参与）：只置 deletedAt 标记，
  /// 行与附件元数据保留——UI 隐藏内容但保留时间+焚毁记录，不打破历史流水
  /// （老板决策 2026-09-09，替代原来的彻底删行；重启后记录仍在、内容仍隐藏）。
  Future<void> tombstoneMessage(String messageId) async {
    await (db.update(db.localMessages)..where((m) => m.messageId.equals(messageId))).write(
      LocalMessagesCompanion(deletedAt: Value(DateTime.now().millisecondsSinceEpoch)),
    );
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
    // 拉取对方回执（已送达/已读）高水位：为将来 UI 准备，失败不影响同步
    try {
      await refreshReceipts();
    } catch (_) {
      // 网络抖动忽略，下次 sync 再拉
    }
    return added;
  }

  /// 上报自己的送达/已读高水位（服务端只前进；本端也应只在前进时调用）。
  Future<void> reportReceipts({int? deliveredUptoSeq, int? readUptoSeq}) async {
    final t = token;
    if (t == null) return;
    if (deliveredUptoSeq == null && readUptoSeq == null) return;
    await _withAutoAuth((tok) => api.postReceipts(
          tok,
          deliveredUptoSeq: deliveredUptoSeq,
          readUptoSeq: readUptoSeq,
        ));
  }

  /// 拉取本 space 全部回执行并落库（重连/补拉用；WS `receipt.updated` 是实时路径）。
  Future<void> refreshReceipts() async {
    final t = token;
    if (t == null) return;
    final rows = await _withAutoAuth((tok) => api.getReceipts(tok));
    for (final r in rows) {
      await upsertPeerReceipt(
        personId: r.personId,
        deliveredUptoSeq: r.deliveredUptoSeq,
        readUptoSeq: r.readUptoSeq,
        updatedAt: r.updatedAt,
      );
    }
  }

  /// 落库一条对方回执（单调只前进——陈旧的重放不会把高水位拉低）。
  /// 对方可能有多台设备，任一设备上报即代表该 person；这里取 max 合并。
  Future<void> upsertPeerReceipt({
    required String personId,
    required int deliveredUptoSeq,
    required int readUptoSeq,
    int updatedAt = 0,
  }) async {
    final existing = await (db.select(db.peerReceipts)
          ..where((r) => r.spaceId.equals(spaceId) & r.personId.equals(personId)))
        .getSingleOrNull();
    await db.into(db.peerReceipts).insertOnConflictUpdate(PeerReceiptsCompanion.insert(
          spaceId: spaceId,
          personId: personId,
          deliveredUptoSeq:
              Value(max(existing?.deliveredUptoSeq ?? 0, deliveredUptoSeq)),
          readUptoSeq: Value(max(existing?.readUptoSeq ?? 0, readUptoSeq)),
          updatedAt: Value(updatedAt > 0
              ? updatedAt
              : DateTime.now().millisecondsSinceEpoch),
        ));
  }

  /// 本 space 的对方回执行（仅 peer person——本端自己从不写这张表）。
  /// 对方的回执行（用于推导"我发出的消息"是否已送达/已读）。
  ///
  /// **必须排除我自己那一行**（老板 2026-09-13 实测的 bug）：`GET /receipts` 返回
  /// 本空间**所有人**的行，其中包括我自己上报的高水位；而我自己的水位描述的是
  /// "**我收到了对方哪些消息**"，与我发出的消息无关。若不排除，`receiptOf` 的
  /// `every` 会拿我自己那条（通常远低于我最新发出的 seq）去卡，导致"对方明明已
  /// 收到、我这边却永远单勾"；直到对方也发来一条（把我自己的水位抬上去）才变双勾。
  Future<List<PeerReceipt>> peerReceipts() async {
    final rows = await (db.select(db.peerReceipts)
          ..where((r) => r.spaceId.equals(spaceId)))
        .get();
    final myPersonId = _personByDevice[deviceId];
    if (myPersonId == null) return rows;
    return rows.where((r) => r.personId != myPersonId).toList();
  }

  /// 推导自己某条消息的回执状态（纯函数，便于单测）。
  ///
  /// [seq] 为该消息的 server_sequence（未同步 → null）。规则：**所有接收方**都
  /// `readUptoSeq ≥ seq` → `'read'`；都 `deliveredUptoSeq ≥ seq` → `'delivered'`；
  /// 否则 `null`（即仅 `sent`）。2 人空间下 peers 只有一行，`every` 等价于唯一对方；
  /// 多人时 `every` = "所有其他人都已收到"，语义更严格（正确）。
  ///
  /// ⚠️ [peers] **必须只含接收方**（即排除我自己那一行）——用 [peerReceipts] 取值
  /// 即可，它已做过滤；直接塞入整张表会把"我自己收到对方消息的水位"也当成条件，
  /// 导致发出的消息永远停在单勾（见 [peerReceipts] 的说明）。
  static String? receiptOf(int? seq, List<PeerReceipt> peers) {
    if (seq == null || peers.isEmpty) return null;
    if (peers.every((p) => p.readUptoSeq >= seq)) return 'read';
    if (peers.every((p) => p.deliveredUptoSeq >= seq)) return 'delivered';
    return null;
  }

  /// 补发 pending 队列（成功后置 sent 并推进锚点）。
  Future<int> _flushPending() async {
    final t = token;
    if (t == null) return 0;

    // 注意：**不排除**墓碑（删除/焚毁）——删除是"本设备隐藏正文"，不改变消息在
    // 服务器与对方的路径（老板 2026-09-13 定），所以尚未确认的消息仍应继续补发。
    final rows = await (db.select(db.localMessages)
          ..where((m) => m.status.equals('pending')))
        .get();
    var flushed = 0;
    for (final row in rows) {
      // 跳过正在上传中的（如刚点按小飞机重发的）——避免同一封并发重复上传
      if (_pendingUploads.contains(row.messageId)) continue;
      final env = MessageEnvelope.fromJson(jsonDecode(row.ciphertext) as Map<String, dynamic>);
      _pendingUploads.add(row.messageId);
      try {
        final result = await _withAutoAuth((tok) => api.postMessage(env, tok));
        await _markSent(env.messageId, result.serverSequence, result.createdAt);
        flushed++;
      } on Exception {
        break; // 网络层问题：停止本轮补发，下次再试
      } finally {
        _pendingUploads.remove(row.messageId);
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

  /// 按 messageId 查 serverSequence（点击引用卡跳转定位用；消息不存在/未同步
  /// 返回 null）。
  Future<int?> sequenceOfMessage(String messageId) async {
    final row = await (db.select(db.localMessages)
          ..where((m) =>
              m.spaceId.equals(spaceId) & m.messageId.equals(messageId)))
        .getSingleOrNull();
    return row?.serverSequence;
  }

  /// 设置本机单条消息的阅后即焚（长按菜单「阅后即焚」用，纯本地，仅对未
  /// 墓碑消息）：更新 burnAfterSeconds 与到期时间戳——burn<=0 表示取消
  /// （expiresAt=null 无限期），>0 表示新设/调整（expiresAt=now+burn）；
  /// 到期由 tombstoneExpired 统一打墓碑。返回是否找到并设置成功。
  Future<bool> setMessageBurn(String messageId, int burnSeconds) async {
    final row = await (db.select(db.localMessages)
          ..where((m) =>
              m.spaceId.equals(spaceId) &
              m.messageId.equals(messageId) &
              m.deletedAt.isNull()))
        .getSingleOrNull();
    if (row == null) return false;
    final expiresAt = burnSeconds > 0
        ? DateTime.now().millisecondsSinceEpoch + burnSeconds * 1000
        : null;
    await (db.update(db.localMessages)..where((m) => m.messageId.equals(messageId)))
        .write(LocalMessagesCompanion(
      burnAfterSeconds: Value(burnSeconds),
      expiresAt: Value(expiresAt),
      // 标记为「用户手动设置」：气泡据此标注修改时间；取消（burn<=0）无标签故置 false
      burnManual: Value(burnSeconds > 0),
    ));
    return true;
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

  /// 按 messageId 批量读取本地历史（解密）。用于把界面列表里**仍标为
  /// pending/failed** 的消息按 id 重新对齐一次。
  ///
  /// 为什么需要它（老板 2026-09-12 实测：对方已收到消息，本端却一直显示"发送中"）：
  /// [historySince] 用的是"本地已加载最大 server_sequence"这个高水位，只取 seq
  /// 更大的行。但本机自己发的消息，seq 是 postMessage 之后才由服务端分配回填的——
  /// 若在这之间恰好先把一条 seq 更高的对方消息并入了列表（高水位抬到本消息 seq
  /// 之上），之后 historySince 就再也取不到本消息（seq 不大于高水位、也不再是
  /// NULL），它的状态便永远停在 pending。按 id 兜底重读即可收敛。
  Future<List<HistoryMessage>> historyByMessageIds(List<String> messageIds) async {
    if (messageIds.isEmpty) return const [];
    final rows = await (db.select(db.localMessages)
          ..where((m) => m.spaceId.equals(spaceId) & m.messageId.isIn(messageIds)))
        .get();
    return _rowsToHistory(rows);
  }

  /// 本 space 全部消息的 messageId（媒体缓存孤儿清理的保留名单用；纯 id 查询，不解密）。
  Future<Set<String>> allMessageIds() async {
    final rows = await (db.select(db.localMessages)
          ..where((m) => m.spaceId.equals(spaceId)))
        .get();
    return {for (final row in rows) row.messageId};
  }

  /// 行 → 历史记录（解密 + 附件元数据 + person 身份 + 阅后即焚到期）。
  Future<List<HistoryMessage>> _rowsToHistory(List<LocalMessage> rows) async {
    await _ensureIdentityLoaded(); // 离线：用持久化的 device→person 映射判定归属
    final out = <HistoryMessage>[];
    for (final row in rows) {
      // 回填 server_sequence：本机发送的消息 ciphertext 落盘时无 seq（由 _markSent
      // 只写列），重建时以列为准，否则 env.serverSequence 恒为 null → 分页/跳转/
      // 增量锚点（_lastLoadedSequence）误判（老板 2026-09-12）。
      final env = MessageEnvelope.fromJson({
        ...jsonDecode(row.ciphertext) as Map<String, dynamic>,
        if (row.serverSequence != null) 'server_sequence': row.serverSequence,
      });
      final key = _keyForVersion(env.keyVersion);
      if (key == null) {
        throw StateError('缺少 key_version=${env.keyVersion} 的 Space Key，无法解密历史消息（需导入归档密钥）');
      }
      final raw = await decryptMessage(
        env: env,
        spaceKey: key,
        spaceId: spaceId,
      );
      // 载荷 = 裸文本 / {"plaintext":…, "quote":…, "meta":…} JSON（旧版消息为裸文本）
      final payload = decodeMessagePayload(raw);
      var plain = payload.plaintext;
      final quote = payload.quote;
      final meta = payload.meta;
      final att = await (db.select(db.localAttachments)
            ..where((a) => a.messageId.equals(env.messageId)))
          .getSingleOrNull();
      out.add((
        env: env,
        plaintext: plain,
        sender: _isMineMessage(env) ? 'me' : 'peer',
        attachment: att == null
            ? null
            : {
                'attachment_id': att.attachmentId,
                'key_version': att.keyVersion,
                'size': att.size,
                'sha256': att.sha256,
                'nonce': att.nonce,
                if (att.localCipher != null) 'local_cipher': att.localCipher,
              },
        expiresAt: row.expiresAt,
        createdAt: row.createdAt,
        // 焚毁时长：优先本机落盘快照；归档恢复（快照缺失）按 到期-创建 反推
        burnAfterSeconds: row.burnAfterSeconds > 0
            ? row.burnAfterSeconds
            : (row.expiresAt == null ? 0 : max(1, row.expiresAt! - row.createdAt)),
        quote: quote,
        deleted: row.deletedAt != null,
        burnManual: row.burnManual,
        status: row.status,
        meta: meta,
      ));
    }
    return out;
  }

  /// 附件明文：发送端优先本地密文副本（local_cipher）解密——上传完成前/失败后
  /// 也能即时显示（图片视频直接展示，老板 2026-09-11）；无本地副本（接收端）
  /// 走服务端拉取。
  Future<Uint8List> attachmentBytes(Map<String, dynamic> att) async {
    final local = att['local_cipher'];
    if (local is Uint8List && local.isNotEmpty) {
      final key = _keyForVersion(att['key_version'] as int);
      if (key == null) throw StateError('缺少 key_version=${att['key_version']} 的 Space Key');
      return decryptAttachment(
        cipherText: local,
        nonce: base64Decode(att['nonce'] as String),
        spaceKey: key,
        attachmentId: att['attachment_id'] as String,
        spaceId: spaceId,
        keyVersion: att['key_version'] as int,
      );
    }
    return fetchAttachment(
      attachmentId: att['attachment_id'] as String,
      keyVersion: att['key_version'] as int,
      sha256: att['sha256'] as String,
      nonce: base64Decode(att['nonce'] as String),
    );
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

  /// 按 key_version 选解密密钥：只有当前版本（一个 Space 一把钥匙），
  /// 未知版本返回 null → 调用方报错，而不是拿错钥匙硬解出一堆垃圾。
  /// （`key_version` 是信封/AAD 的一部分，所以这个收口必须存在——E2EE.md §5.2。）
  Uint8List? _keyForVersion(int version) {
    if (version == keyVersion) return spaceKey;
    return null;
  }

  /// 待发送队列长度。
  Future<int> get pendingCount async {
    final count = await (db.selectOnly(db.localMessages)
          ..addColumns([db.localMessages.messageId.count()])
          // 与 _flushPending 对齐：墓碑消息若仍在补发，也应计入"待发送"
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

  /// 导入归档恢复的历史消息（chat_page「从完整备份恢复」）：逐条按 env 落库
  /// （messageId 幂等，已存在仅刷新 server_sequence/status），附件元数据补写
  /// local_attachments。status 按 sender 归属：'me'（本设备发送）→ sent，否则
  /// delivered。
  Future<void> importArchiveHistory(List<Map<String, dynamic>> history) async {
    for (final entry in history) {
      final env = MessageEnvelope.fromJson(
          (entry['env'] as Map).cast<String, dynamic>());
      final sender = entry['sender'] as String? ?? 'peer';
      final att = entry['attachment'] as Map<String, dynamic>?;
      await _insertLocal(
        env,
        status: sender == 'me' ? 'sent' : 'delivered',
        expiresAt: entry['expiresAt'] as int?,
      );
      if (att != null) {
        await _insertAttachmentMeta({
          'attachment_id': att['attachment_id'],
          'message_id': env.messageId,
          'key_version': att['key_version'],
          'size': att['size'],
          'sha256': att['sha256'],
          'nonce': att['nonce'],
        });
      }
    }
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

  /// 只改本地投递状态（pending/sent/failed）。
  Future<void> _setStatus(String messageId, String status) async {
    await (db.update(db.localMessages)..where((m) => m.messageId.equals(messageId))).write(
      LocalMessagesCompanion(status: Value(status)),
    );
  }

  /// 乐观回显回调：本地落库后、网络上传前触发；异常吞掉，绝不影响发送本身
  /// （例如缺 key_version 时 _rowsToHistory 会抛 StateError）。
  Future<void> _notifyPersisted(
    FutureOr<void> Function(String messageId)? onPersisted,
    String messageId,
  ) async {
    if (onPersisted == null) return;
    try {
      await onPersisted(messageId);
    } catch (_) {
      // 回调只影响 UI 即时性，失败忽略
    }
  }

  /// 手动重发一条 failed 消息（UI 点按「发送失败」图标）：先置 pending（界面立即
  /// 显示发送中）→ 重发 → 成功置 sent、失败回置 failed。无 token 保持 pending
  /// （等联网后由 sync 补发）。已墓碑/不存在的消息忽略。
  Future<void> retryMessage(String messageId) async {
    // 注意：这里**故意不检查** _pendingUploads —— 老板 2026-09-13 的场景正是
    // "请求还在途（响应丢了），本端一直显示小飞机"，此时用户点按就是要**立刻**
    // 重发去问服务端要个结果；若因"已有请求在途"而忽略点按，就等于让用户白等
    // 到超时。并发重发是安全的：服务端按 message_id 幂等，返回同一个 seq。
    // 不排除墓碑：墓碑消息（删除/焚毁）的状态小标仍可点按重发（见 _flushPending 注释）
    final row = await (db.select(db.localMessages)
          ..where((m) => m.messageId.equals(messageId)))
        .getSingleOrNull();
    if (row == null) return;
    await _setStatus(messageId, 'pending');
    final t = token;
    if (t == null) return; // 离线：留 pending，联网后 sync 补发
    final env = MessageEnvelope.fromJson({
      ...jsonDecode(row.ciphertext) as Map<String, dynamic>,
      if (row.serverSequence != null) 'server_sequence': row.serverSequence,
    });
    _pendingUploads.add(messageId);
    try {
      final result = await _withAutoAuth((tok) => api.postMessage(env, tok));
      await _markSent(env.messageId, result.serverSequence, result.createdAt);
    } on Exception catch (e) {
      // 与 send 同规则：明确拒绝 → failed；其余保持 pending 等自动重试
      await _setStatus(messageId, _isServerRejection(e) ? 'failed' : 'pending');
    } finally {
      _pendingUploads.remove(messageId);
    }
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
          // 同步响应不带 local_cipher：Value.absent() 保留本地已有副本，不覆盖
          localCipher: meta['local_cipher'] == null
              ? const Value.absent()
              : Value(meta['local_cipher'] as Uint8List),
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
            // 可空列 insert 参数为 Value<T>：同步响应无 local_cipher 时写 NULL
            localCipher: Value(meta['local_cipher'] as Uint8List?),
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
