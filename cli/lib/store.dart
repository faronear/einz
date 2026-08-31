import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:onlyspace_shared/onlyspace_shared.dart';

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
    this.keyVersion = 1,
    this.sessionToken,
    this.server,
    this.lastServerSequence = 0,
    this.escrowUploaded = false,
    List<String>? pending,
    List<Map<String, dynamic>>? history,
    List<Map<String, dynamic>>? attachments,
    List<Map<String, dynamic>>? archivedSpaceKeys,
  })  : pending = pending ?? [],
        history = history ?? [],
        attachments = attachments ?? [],
        archivedSpaceKeys = archivedSpaceKeys ?? [];

  String? deviceId; // 规范设备 id（dev1/dev2…），登记后由服务端返回写入；登记前为 null（与 personId 一致）
  final String publicKey; // base64
  final String privateKey; // base64（测试用明文存储）
  String? personId; // 规范 person id（personA/personB），enroll 后由服务端返回写入
  String? personName; // 使用者自定义名称（如 lukas），显示层用
  String? deviceName; // 设备自定义名称（如 MacBook），显示层用
  String? spaceKey; // base64，config/import 后填充
  String? spaceId;
  int keyVersion;
  String? sessionToken;
  String? server; // 服务器地址（TUI 引导确认后持久化，多终端无需重复输入）
  int lastServerSequence;

  /// 创建者口令托管包是否已上传（escrow）：引导中断后重启据此再进引导设置口令。
  bool escrowUploaded;

  /// 离线发送队列：MessageEnvelope 的 JSON 字符串（已加密，落盘安全）。
  final List<String> pending;

  /// 本地消息历史：完整信封 + server_sequence + created_at（与 Server 同步后落盘）。
  final List<Map<String, dynamic>> history;

  /// 本地附件元数据（上传/同步后落盘，解密需要 nonce/sha256/key_version）。
  final List<Map<String, dynamic>> attachments;

  /// 归档 Space Key（E2EE.md §9.2）：[{key_version, space_key(base64)}]，只读用于解密旧消息。
  final List<Map<String, dynamic>> archivedSpaceKeys;

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
        'key_version': keyVersion,
        'session_token': sessionToken,
        'server': server,
        'last_server_sequence': lastServerSequence,
        'escrow_uploaded': escrowUploaded,
        'pending': pending,
        'history': history,
        'attachments': attachments,
        'archived_space_keys': archivedSpaceKeys,
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
        keyVersion: (json['key_version'] as int?) ?? 1,
        sessionToken: json['session_token'] as String?,
        server: json['server'] as String?,
        lastServerSequence: (json['last_server_sequence'] as int?) ?? 0,
        escrowUploaded: (json['escrow_uploaded'] as bool?) ?? false,
        pending: (json['pending'] as List?)?.cast<String>() ?? [],
        history: (json['history'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        attachments: (json['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        archivedSpaceKeys: (json['archived_space_keys'] as List?)?.cast<Map<String, dynamic>>() ?? [],
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

  /// 按 key_version 取 Space Key（当前或归档）；未知版本返回 null。
  /// 用于解密历史消息（E2EE.md §9.2：归档密钥只读，不参与新加密）。
  String? spaceKeyForVersion(int version) {
    if (version == keyVersion) return spaceKey;
    for (final entry in archivedSpaceKeys) {
      if (entry['key_version'] == version) return entry['space_key'] as String?;
    }
    return null;
  }

  /// 轮换 Space Key：当前密钥归档（key_version+1），生成新密钥（E2EE.md §9.1 步骤 3–4）。
  /// 返回新 Space Key（base64）；调用方负责 seal 给对方并保存。
  Future<String> rotateSpaceKey() async {
    final s = await sodium();
    final newKey = s.randombytes.buf(32);
    final newB64 = base64Encode(newKey);
    if (spaceKey != null) {
      archivedSpaceKeys.add({'key_version': keyVersion, 'space_key': spaceKey});
    }
    spaceKey = newB64;
    keyVersion = keyVersion + 1;
    return newB64;
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

  int get attachmentCount => attachments.length;
}
