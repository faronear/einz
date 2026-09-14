import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:einz_shared/einz_shared.dart';

/// CLI 设备状态存储（测试用）。
///
/// ⚠️ 注意：这是**测试驱动**，密钥以明文 JSON 落在磁盘；真实 App 必须用
/// Keychain / Keystore（productLens §7.1）。此设计有意为之——CLI 只用于
/// Phase 0–4 验证协议与流程，不上生产。
///
/// Phase 1 扩展：离线发送队列（pending）与本地消息历史（history）都落盘，
/// 支持"离线发送 → 恢复网络 → 自动补发 → 无重复无乱序"的验证。
class DeviceStore {
  DeviceStore({
    this.deviceId,
    required this.publicKey,
    required this.privateKey,
    this.personId,
    this.personName,
    this.deviceName,
    this.spaceKey,
    this.spaceId,
    this.spaceAddress,
    this.keyVersion = 1,
    this.sessionToken,
    this.server,
    this.pinHash,
    this.escrowUpdatedAt,
    this.lastServerSequence = 0,
    this.lastReportedDeliveredSeq = 0,
    this.lastReportedReadSeq = 0,
    this.escrowUploaded = false,
    Map<String, String>? personNames,
    Map<String, String>? personGenders,
    List<String>? pending,
    List<Map<String, dynamic>>? history,
    List<Map<String, dynamic>>? attachments,
  })  : personNames = personNames ?? {},
        personGenders = personGenders ?? {},
        pending = pending ?? [],
        history = history ?? [],
        attachments = attachments ?? [];

  String? deviceId; // 规范设备 id（dev1/dev2…），登记后由服务端返回写入；登记前为 null（与 personId 一致）
  final String publicKey; // base64
  final String privateKey; // base64（测试用明文存储）
  String? personId; // 规范 person id（personA/personB），enroll 后由服务端返回写入
  String? personName; // 使用者自定义名称（如 lukas），显示层用
  String? deviceName; // 设备自定义名称（如 MacBook），显示层用
  String? spaceKey; // base64，config/import 后填充
  String? spaceId;
  String? spaceAddress; // 空间地址（Multiverse create/join 后填充；旧 store 迁移后为 null）
  int keyVersion;
  String? sessionToken;
  String? server; // 服务器地址（TUI 引导确认后持久化，多终端无需重复输入）
  String? pinHash; // PIN 锁屏哈希（argon2id，crypto_pwhash_str 自含盐；null = 未设置）
  int? escrowUpdatedAt; // 本端已知服务端口令更新时间（上线补查：口令被重设则提示）
  int lastServerSequence;

  /// 已上报过的回执高水位（**仅用于防抖**，不是数据源——真值在服务端）。
  /// 回执语义：我上报 delivered/read = N ⟺ 对方发来的 seq ≤ N 我均已收到/已读。
  /// 重启后这里仍保留，可少发一次；丢失也无害（重复上报服务端单调夹紧，是 no-op）。
  int lastReportedDeliveredSeq = 0;
  int lastReportedReadSeq = 0;

  /// 创建者口令密保箱是否已上传（escrow）：引导中断后重启据此再进引导设置口令。
  bool escrowUploaded;

  /// 空间成员名称缓存（person_id → personName）：GET /space 成功后落盘。
  /// 服务器离线启动时仍能显示正确名字/对方身份（否则回退"对方"）。
  Map<String, String> personNames;

  /// 空间成员性别缓存（person_id → male/female）：同上，离线启动仍能按性别配色
  /// （否则所有气泡回退青绿——老板 2026-09-13）。
  Map<String, String> personGenders;

  /// 离线发送队列：MessageEnvelope 的 JSON 字符串（已加密，落盘安全）。
  final List<String> pending;

  /// 本地消息历史：完整信封 + server_sequence + created_at（与 Server 同步后落盘）。
  final List<Map<String, dynamic>> history;

  /// 本地附件元数据（上传/同步后落盘，解密需要 nonce/sha256/key_version）。
  final List<Map<String, dynamic>> attachments;

  static Future<DeviceStore> create({String? deviceId}) async {
    final kp = await DeviceKeyPair.generate(deviceId: deviceId);
    return DeviceStore(
      deviceId: deviceId, // 显式临时 id；默认 null（登记后由服务端分配规范 id）
      publicKey: kp.publicKeyB64,
      privateKey: kp.privateKeyB64,
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'public_key': publicKey,
        'private_key': privateKey,
        'person_id': personId,
        'person_name': personName,
        'device_name': deviceName,
        'space_key': spaceKey,
        'space_id': spaceId,
        'space_address': spaceAddress,
        'key_version': keyVersion,
        'session_token': sessionToken,
        'server': server,
        'last_server_sequence': lastServerSequence,
        'last_reported_delivered_seq': lastReportedDeliveredSeq,
        'last_reported_read_seq': lastReportedReadSeq,
        'escrow_uploaded': escrowUploaded,
        'pin_hash': pinHash,
        'escrow_updated_at': escrowUpdatedAt,
        'person_names': personNames,
        'person_genders': personGenders,
        'pending': pending,
        'history': history,
        'attachments': attachments,
      };

  static DeviceStore fromJson(Map<String, dynamic> json) => DeviceStore(
        deviceId: json['device_id'] as String?,
        publicKey: json['public_key'] as String,
        privateKey: json['private_key'] as String,
        personId: json['person_id'] as String?,
        personName: json['person_name'] as String?,
        deviceName: json['device_name'] as String?,
        spaceKey: json['space_key'] as String?,
        spaceId: json['space_id'] as String?,
        spaceAddress: json['space_address'] as String?,
        keyVersion: (json['key_version'] as int?) ?? 1,
        sessionToken: json['session_token'] as String?,
        server: json['server'] as String?,
        lastServerSequence: (json['last_server_sequence'] as int?) ?? 0,
        lastReportedDeliveredSeq: (json['last_reported_delivered_seq'] as int?) ?? 0,
        lastReportedReadSeq: (json['last_reported_read_seq'] as int?) ?? 0,
        escrowUploaded: (json['escrow_uploaded'] as bool?) ?? false,
        pinHash: json['pin_hash'] as String?,
        escrowUpdatedAt: json['escrow_updated_at'] as int?,
        personNames: (json['person_names'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? {},
        personGenders: (json['person_genders'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? {},
        pending: (json['pending'] as List?)?.cast<String>() ?? [],
        history: (json['history'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        attachments: (json['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? [],
      );

  void save(String path) {
    File(path).writeAsStringSync(JsonEncoder.withIndent('  ').convert(toJson()));
  }

  static DeviceStore load(String path) {
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
      throw StateError('设备尚未导入 Space Key（先运行 config 或 import）');
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
