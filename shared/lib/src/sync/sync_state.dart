/// 同步状态跟踪（PROTOCOL.md §5.3）：本地 last_server_sequence + 离线发送队列。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../crypto/keys.dart';
import '../sodium.dart';

/// 本地同步锚点（每 Space 一个）。
class SyncState {
  SyncState({required this.spaceId, this.lastServerSequence = 0});

  final String spaceId;
  int lastServerSequence;

  /// 收到新消息后推进锚点（只前进，不倒退）。
  void advance(int serverSequence) {
    if (serverSequence > lastServerSequence) {
      lastServerSequence = serverSequence;
    }
  }

  Map<String, dynamic> toJson() => {
        'space_id': spaceId,
        'last_server_sequence': lastServerSequence,
      };

  factory SyncState.fromJson(Map<String, dynamic> json) => SyncState(
        spaceId: json['space_id'] as String,
        lastServerSequence: json['last_server_sequence'] as int,
      );
}

/// 离线发送队列项。
class PendingMessage {
  PendingMessage({required this.envelopeJson, required this.createdAt});

  final String envelopeJson;
  final int createdAt;

  Map<String, dynamic> toJson() => {
        'envelope': jsonDecode(envelopeJson),
        'created_at': createdAt,
      };
}

/// 生成新的 Space Key（32B）。
Future<Uint8List> generateSpaceKey() async {
  final s = await sodium();
  return s.randombytes.buf(32);
}

/// 一次性配置产物（E2EE.md §7.1）：Space Key 分别密封给两台设备。
Future<Map<String, dynamic>> buildConfigPayload({
  required Uint8List spaceKey,
  required String spaceId,
  required String deviceIdA,
  required Uint8List publicKeyA,
  required String deviceIdB,
  required Uint8List publicKeyB,
  int keyVersion = 1,
}) async {
  final s = await sodium();
  final sealedA = await sealFor(s, publicKeyA, spaceKey);
  final sealedB = await sealFor(s, publicKeyB, spaceKey);
  return {
    'format': 'einz-config-v1',
    'space_id': spaceId,
    'key_version': keyVersion,
    'sealed_space_keys': [
      {'device_id': deviceIdA, 'sealed': base64Encode(sealedA)},
      {'device_id': deviceIdB, 'sealed': base64Encode(sealedB)},
    ],
  };
}
