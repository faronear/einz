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
    required this.deviceId,
    required this.publicKey,
    required this.privateKey,
    this.spaceKey,
    this.spaceId,
    this.keyVersion = 1,
    this.sessionToken,
    this.lastServerSequence = 0,
    List<String>? pending,
    List<Map<String, dynamic>>? history,
  })  : pending = pending ?? [],
        history = history ?? [];

  final String deviceId;
  final String publicKey; // base64
  final String privateKey; // base64（测试用明文存储）
  String? spaceKey; // base64，config/import 后填充
  String? spaceId;
  int keyVersion;
  String? sessionToken;
  int lastServerSequence;

  /// 离线发送队列：MessageEnvelope 的 JSON 字符串（已加密，落盘安全）。
  final List<String> pending;

  /// 本地消息历史：完整信封 + server_sequence + created_at（与 Server 同步后落盘）。
  final List<Map<String, dynamic>> history;

  static Future<DeviceStore> create(String deviceId) async {
    final kp = await DeviceKeyPair.generate(deviceId: deviceId);
    return DeviceStore(
      deviceId: kp.deviceId,
      publicKey: kp.publicKeyB64,
      privateKey: kp.privateKeyB64,
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'public_key': publicKey,
        'private_key': privateKey,
        'space_key': spaceKey,
        'space_id': spaceId,
        'key_version': keyVersion,
        'session_token': sessionToken,
        'last_server_sequence': lastServerSequence,
        'pending': pending,
        'history': history,
      };

  static DeviceStore fromJson(Map<String, dynamic> json) => DeviceStore(
        deviceId: json['device_id'] as String,
        publicKey: json['public_key'] as String,
        privateKey: json['private_key'] as String,
        spaceKey: json['space_key'] as String?,
        spaceId: json['space_id'] as String?,
        keyVersion: (json['key_version'] as int?) ?? 1,
        sessionToken: json['session_token'] as String?,
        lastServerSequence: (json['last_server_sequence'] as int?) ?? 0,
        pending: (json['pending'] as List?)?.cast<String>() ?? [],
        history: (json['history'] as List?)?.cast<Map<String, dynamic>>() ?? [],
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

  /// 历史消息信封列表（按 server_sequence 升序；未同步的排最后）。
  List<MessageEnvelope> get historyEnvelopes {
    final list = history.map((m) {
      final env = MessageEnvelope.fromJson(m);
      return (env: env, seq: (m['server_sequence'] as int?) ?? 0);
    }).toList();
    list.sort((a, b) => a.seq.compareTo(b.seq));
    return list.map((e) => e.env).toList();
  }

  int get historyCount => history.length;
}
