import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:onlyspace_shared/onlyspace_shared.dart';

/// CLI 设备状态存储（测试用）。
///
/// ⚠️ 注意：这是**测试驱动**，密钥以明文 JSON 落在磁盘；真实 App 必须用
/// Keychain / Keystore（productLens §7.1）。此设计有意为之——CLI 只用于
/// Phase 0–4 验证协议与流程，不上生产。
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
  });

  final String deviceId;
  final String publicKey; // base64
  final String privateKey; // base64（测试用明文存储）
  String? spaceKey; // base64，config/import 后填充
  String? spaceId;
  int keyVersion;
  String? sessionToken;
  int lastServerSequence;

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
}
