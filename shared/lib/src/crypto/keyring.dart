/// Space Key 轮换结构（E2EE.md §9.2）：current + archived（只读归档）。
///
/// - 轮换：生成新 Space Key（key_version +1），旧密钥移入 archived
/// - 新消息用 current 加密；解密时按消息携带的 key_version 选择密钥
/// - archived 只用于解密旧数据，不参与新加密
library;

import 'dart:convert';
import 'dart:typed_data';

import '../sodium.dart';

class SpaceKeyRing {
  SpaceKeyRing({required this.currentVersion, required this.currentKey, List<Map<String, dynamic>>? archived})
      : archived = archived ?? [];

  /// 当前版本号（key_version）。
  final int currentVersion;

  /// 当前 Space Key 明文（32B，仅本机安全存储）。
  final Uint8List currentKey;

  /// 归档密钥：[{key_version, space_key(base64)}]，旧版本升序。
  final List<Map<String, dynamic>> archived;

  static Future<SpaceKeyRing> create(Uint8List spaceKey, {int keyVersion = 1}) async {
    return SpaceKeyRing(currentVersion: keyVersion, currentKey: spaceKey);
  }

  /// 轮换：旧 current 归档，生成并返回新密钥环（key_version +1）。
  Future<SpaceKeyRing> rotate() async {
    final s = await sodium();
    final newKey = s.randombytes.buf(32);
    final newArchived = [
      ...archived,
      {'key_version': currentVersion, 'space_key': base64Encode(currentKey)},
    ];
    return SpaceKeyRing(currentVersion: currentVersion + 1, currentKey: newKey, archived: newArchived);
  }

  /// 按 key_version 取密钥（当前或归档）；未知版本返回 null。
  Uint8List? keyForVersion(int keyVersion) {
    if (keyVersion == currentVersion) return currentKey;
    for (final entry in archived) {
      if (entry['key_version'] == keyVersion) {
        return base64Decode(entry['space_key'] as String);
      }
    }
    return null;
  }

  /// 归档是否包含某版本。
  bool hasVersion(int keyVersion) => keyForVersion(keyVersion) != null;

  Map<String, dynamic> toJson() => {
        'current': {'key_version': currentVersion, 'space_key': base64Encode(currentKey)},
        'archived': archived,
      };

  factory SpaceKeyRing.fromJson(Map<String, dynamic> json) {
    final current = json['current'] as Map<String, dynamic>;
    return SpaceKeyRing(
      currentVersion: current['key_version'] as int,
      currentKey: base64Decode(current['space_key'] as String),
      archived: (json['archived'] as List? ?? []).cast<Map<String, dynamic>>(),
    );
  }
}
