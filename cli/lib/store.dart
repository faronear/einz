import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:einz_shared/einz_shared.dart';

/// CLI 通道状态存储（测试用）。
///
/// ⚠️ 注意：这是**测试驱动**，密钥以明文 JSON 落在磁盘；真实 App 必须用
/// Keychain / Keystore（productLens §7.1）。此设计有意为之——CLI 只用于
/// Phase 0–4 验证协议与流程，不上生产。
///
/// Phase 1 扩展：离线发送队列（pending）与本地消息历史（history）都落盘，
/// 支持"离线发送 → 恢复网络 → 自动补发 → 无重复无乱序"的验证。
class EntranceStore {
  EntranceStore({
    this.entranceId,
    required this.publicKey,
    required this.privateKey,
    this.partnerId,
    this.partnerName,
    this.peerName,
    this.entranceName,
    this.spaceKey,
    this.spaceId,
    this.spaceAddress,
    this.slot,
    this.keyVersion = 1,
    this.sessionToken,
    this.pinHash,
    this.escrowUpdatedAt,
    this.installUid,
    this.lastServerSequence = 0,
    this.lastReportedDeliveredSeq = 0,
    this.lastReportedReadSeq = 0,
    this.escrowUploaded = false,
    Map<String, String>? partnerNames,
    Map<String, String>? partnerGenders,
    Map<String, int>? partnerSlots,
    List<String>? pending,
    List<Map<String, dynamic>>? history,
    List<Map<String, dynamic>>? attachments,
  })  : partnerNames = partnerNames ?? {},
        partnerGenders = partnerGenders ?? {},
        partnerSlots = partnerSlots ?? {},
        pending = pending ?? [],
        history = history ?? [],
        attachments = attachments ?? [];

  String? entranceId; // 规范通道 id（dev1/dev2…），登记后由服务端返回写入；登记前为 null（与 partnerId 一致）
  final String publicKey; // base64
  final String privateKey; // base64（测试用明文存储）
  String? partnerId; // 空间内身份 id（v2：createSpace 返回 creatorPartnerId / joinSpace 返回 partnerId，均为 UUID）
  int? slot; // 本通道在空间里的身份槽位（0=创建者/第一人，1=伴侣/第二人；v2 create/join 返回）
  String? partnerName; // 使用者自定义名称（如 lukas），显示层用

  /// 对方（另一身份）名字：create 录入的伴侣名 / join 时另一身份槽位的名字。
  /// 对方**尚未加入**时空间里还没有他的 partner_id，GET /space 的 partner 表拿不到
  /// 这个名字 → 顶部条用本字段兜底（否则刚创建/刚加入后一直显示 '-'；老板 2026-09-16）。
  /// 对方加入后以其真实名字为准（partnerNames 优先），本字段只是离线/未加入时的兜底。
  String? peerName;

  String? entranceName; // 通道自定义名称（如 MacBook），显示层用
  String? spaceKey; // base64，config/import 后填充
  String? spaceId;
  String? spaceAddress; // 空间地址（Multiverse create/join 后填充；旧 store 迁移后为 null）
  int keyVersion;
  String? sessionToken;
  String? pinHash; // PIN 锁屏哈希（argon2id，crypto_pwhash_str 自含盐；null = 未设置）
  int? escrowUpdatedAt; // 本端已知服务端口令更新时间（上线补查：口令被重设则提示）

  /// 安装级标识（服务端 `entrances.install_uid` 的来源）：服务端据此把同一台物理设备
  /// 在各空间的 entrance_id 认成一台。**TUI 的粒度是"一个 store = 一条通道"**（见
  /// `_deleteLocalData` 的注释：同机多 store 是刻意的多通道模拟），故各 store 各一份；
  /// 随 create/join 上报，存量 store 由启动时补登（`_registerInstallUid`）。
  /// 惰性生成，见 [ensureInstallUid]。
  String? installUid;

  int lastServerSequence;

  /// 已上报过的回执高水位（**仅用于防抖**，不是数据源——真值在服务端）。
  /// 回执语义：我上报 delivered/read = N ⟺ 对方发来的 seq ≤ N 我均已收到/已读。
  /// 重启后这里仍保留，可少发一次；丢失也无害（重复上报服务端单调夹紧，是 no-op）。
  int lastReportedDeliveredSeq = 0;
  int lastReportedReadSeq = 0;

  /// 创建者口令密保箱是否已上传（escrow）：引导中断后重启据此再进引导设置口令。
  bool escrowUploaded;

  /// 空间成员名称缓存（partner_id → partnerName）：GET /space 成功后落盘。
  /// 服务器离线启动时仍能显示正确名字/对方身份（否则回退"对方"）。
  Map<String, String> partnerNames;

  /// 空间成员性别缓存（partner_id → male/female）：同上，离线启动仍能按性别配色
  /// （否则所有气泡回退青绿——老板 2026-09-13）。
  Map<String, String> partnerGenders;

  /// 空间成员槽位缓存（partner_id → 0=第一人/创建者，1=第二人/伴侣）：
  /// 同性别时第二人气泡取青色（GET /space 的 partner_slots，离线兜底用）。
  Map<String, int> partnerSlots;

  /// 离线发送队列：MessageEnvelope 的 JSON 字符串（已加密，落盘安全）。
  final List<String> pending;

  /// 本地消息历史：完整信封 + server_sequence + created_at（与 Server 同步后落盘）。
  final List<Map<String, dynamic>> history;

  /// 本地附件元数据（上传/同步后落盘，解密需要 nonce/sha256/key_version）。
  final List<Map<String, dynamic>> attachments;

  static Future<EntranceStore> create({String? entranceId}) async {
    final kp = await EntranceKeyPair.generate(entranceId: entranceId);
    return EntranceStore(
      entranceId: entranceId, // 显式临时 id；默认 null（登记后由服务端分配规范 id）
      publicKey: kp.publicKeyB64,
      privateKey: kp.privateKeyB64,
    );
  }

  /// 取安装级标识，没有就生成一个（16 字节 hex，与服务端形状约束一致）。
  /// 只改内存——调用方负责 `save()`，否则下次启动会换一个新的。
  String ensureInstallUid() {
    final existing = installUid;
    if (existing != null && existing.isNotEmpty) return existing;
    final r = Random.secure();
    final fresh =
        List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    installUid = fresh;
    return fresh;
  }

  Map<String, dynamic> toJson() => {
        'entrance_id': entranceId,
        'public_key': publicKey,
        'private_key': privateKey,
        'partner_id': partnerId,
        'slot': slot,
        'partner_name': partnerName,
        'peer_name': peerName,
        'entrance_name': entranceName,
        'space_key': spaceKey,
        'space_id': spaceId,
        'space_address': spaceAddress,
        'key_version': keyVersion,
        'session_token': sessionToken,
        'last_server_sequence': lastServerSequence,
        'last_reported_delivered_seq': lastReportedDeliveredSeq,
        'last_reported_read_seq': lastReportedReadSeq,
        'escrow_uploaded': escrowUploaded,
        'pin_hash': pinHash,
        'escrow_updated_at': escrowUpdatedAt,
        'install_uid': installUid,
        'partner_names': partnerNames,
        'partner_genders': partnerGenders,
        'partner_slots': partnerSlots,
        'pending': pending,
        'history': history,
        'attachments': attachments,
      };

  static EntranceStore fromJson(Map<String, dynamic> json) => EntranceStore(
        entranceId: json['entrance_id'] as String?,
        publicKey: json['public_key'] as String,
        privateKey: json['private_key'] as String,
        partnerId: json['partner_id'] as String?,
        slot: json['slot'] as int?,
        partnerName: json['partner_name'] as String?,
        peerName: json['peer_name'] as String?,
        entranceName: json['entrance_name'] as String?,
        spaceKey: json['space_key'] as String?,
        spaceId: json['space_id'] as String?,
        spaceAddress: json['space_address'] as String?,
        keyVersion: (json['key_version'] as int?) ?? 1,
        sessionToken: json['session_token'] as String?,
        lastServerSequence: (json['last_server_sequence'] as int?) ?? 0,
        lastReportedDeliveredSeq: (json['last_reported_delivered_seq'] as int?) ?? 0,
        lastReportedReadSeq: (json['last_reported_read_seq'] as int?) ?? 0,
        escrowUploaded: (json['escrow_uploaded'] as bool?) ?? false,
        pinHash: json['pin_hash'] as String?,
        escrowUpdatedAt: json['escrow_updated_at'] as int?,
        installUid: json['install_uid'] as String?,
        partnerNames: (json['partner_names'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? {},
        partnerGenders: (json['partner_genders'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? {},
        partnerSlots: (json['partner_slots'] as Map?)?.map((k, v) => MapEntry('$k', v as int)) ?? {},
        pending: (json['pending'] as List?)?.cast<String>() ?? [],
        history: (json['history'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        attachments: (json['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? [],
      );

  void save(String path) {
    File(path).writeAsStringSync(JsonEncoder.withIndent('  ').convert(toJson()));
  }

  static EntranceStore load(String path) {
    if (!File(path).existsSync()) {
      throw StateError('存储文件不存在: $path（先运行 init）');
    }
    return fromJson(jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);
  }

  /// 从安全存储还原私钥字节（测试：base64 明文）。
  Uint8List get privateKeyBytes => Uint8List.fromList(base64Decode(privateKey));
  Uint8List get publicKeyBytes => Uint8List.fromList(base64Decode(publicKey));

  void requireSpace() {
    if (spaceKey == null || spaceId == null) {
      throw StateError('通道尚未导入 Space Key（先运行 config 或 import）');
    }
  }

  /// 按 key_version 取 Space Key：只有**当前版本**可取（一个 Space 一把钥匙），
  /// 未知版本返回 null → 调用方报错，而不是拿错钥匙硬解出一堆垃圾。
  /// 这个收口必须存在，因为 `key_version` 是信封/AAD 的一部分（E2EE.md §5.2）。
  String? spaceKeyForVersion(int version) {
    if (version == keyVersion) return spaceKey;
    return null;
  }

  void requireSession() {
    if (sessionToken == null) {
      throw StateError('未认证，先运行 auth');
    }
  }

  /// 推进同步锚点（只前进，不倒退，与 SyncState 语义一致）。
  void advanceAnchor(int serverSequence) {
    if (serverSequence > lastServerSequence) {
      lastServerSequence = serverSequence;
    }
  }

  /// 记录"已上报过"的回执高水位（只前进；只用于防抖，不是数据源）。
  /// [delivered]/[read] 可只传其一。
  void advanceReported({int? delivered, int? read}) {
    if (delivered != null && delivered > lastReportedDeliveredSeq) {
      lastReportedDeliveredSeq = delivered;
    }
    if (read != null && read > lastReportedReadSeq) {
      lastReportedReadSeq = read;
    }
  }

  // ---------- 离线发送队列 ----------

  /// 入队（消息已加密为信封 JSON）。
  void enqueuePending(String envelopeJson) {
    pending.add(envelopeJson);
  }

  /// 按 message_id 出队（发送成功或确认无需再发）。
  void dequeuePending(String messageId) {
    pending.removeWhere((json) {
      try {
        final env = jsonDecode(json) as Map<String, dynamic>;
        return env['message_id'] == messageId;
      } catch (_) {
        return false;
      }
    });
  }

  /// 队列中的信封（解析失败项跳过）。
  List<MessageEnvelope> get pendingEnvelopes => pending
      .map((json) => MessageEnvelope.fromJson(jsonDecode(json) as Map<String, dynamic>))
      .toList();

  int get pendingCount => pending.length;

  /// 队列里是否已存在该 message_id（幂等入队）。
  bool hasPending(String messageId) {
    return pending.any((json) {
      try {
        final env = jsonDecode(json) as Map<String, dynamic>;
        return env['message_id'] == messageId;
      } catch (_) {
        return false;
      }
    });
  }

  // ---------- 本地消息历史 ----------

  /// 写入一条历史消息（按 message_id 幂等，重复写入忽略）。
  void upsertHistory(MessageEnvelope env, {required int serverSequence, required int createdAt}) {
    final existing = history.indexWhere((m) => m['message_id'] == env.messageId);
    final entry = {
      ...env.toJson(),
      'server_sequence': serverSequence,
      'created_at': createdAt,
    };
    if (existing >= 0) {
      history[existing] = entry;
    } else {
      history.add(entry);
    }
  }

  /// 历史消息信封列表（按 server_sequence 升序；未同步的排最后，P3 修复与注释一致）。
  List<MessageEnvelope> get historyEnvelopes {
    final list = history.map((m) {
      final env = MessageEnvelope.fromJson(m);
      return (env: env, seq: m['server_sequence'] as int?);
    }).toList();
    list.sort((a, b) {
      final an = a.seq;
      final bn = b.seq;
      if (an == null && bn == null) return 0;
      if (an == null) return 1;
      if (bn == null) return -1;
      return an.compareTo(bn);
    });
    return list.map((e) => e.env).toList();
  }

  int get historyCount => history.length;

  // ---------- 附件元数据 ----------

  /// 记录一条附件元数据（按 attachment_id 幂等 upsert）。
  void upsertAttachment({
    required String attachmentId,
    required String messageId,
    required int keyVersion,
    required int size,
    required String sha256,
    required String nonce,
    required int createdAt,
  }) {
    final existing = attachments.indexWhere((a) => a['attachment_id'] == attachmentId);
    final entry = {
      'attachment_id': attachmentId,
      'message_id': messageId,
      'key_version': keyVersion,
      'size': size,
      'sha256': sha256,
      'nonce': nonce,
      'created_at': createdAt,
    };
    if (existing >= 0) {
      attachments[existing] = entry;
    } else {
      attachments.add(entry);
    }
  }

  /// 按 attachment_id 查询附件元数据（不存在返回 null）。
  Map<String, dynamic>? attachmentMeta(String attachmentId) {
    for (final a in attachments) {
      if (a['attachment_id'] == attachmentId) return a;
    }
    return null;
  }

  /// 按 message_id 查询附件元数据（一条消息至多一个附件；不存在返回 null）。
  Map<String, dynamic>? attachmentMetaByMessage(String messageId) {
    for (final a in attachments) {
      if (a['message_id'] == messageId) return a;
    }
    return null;
  }

  int get attachmentCount => attachments.length;
}
