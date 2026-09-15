/// 同步与配置产物：Space Key 生成 + 一次性配置载荷（PROTOCOL.md §5.3 / E2EE.md §7.1）。
///
/// 注（2026-09-15 评审）：本文件原有的 `SyncState` / `PendingMessage` 两个类
/// 与 App 端的 drift 实现（`sync_state` 表 + pending 队列 + `_advanceAnchor`）
/// 重复且**无人引用**，已删除；`generateSpaceKey` / `buildConfigPayload` 仍在用
/// （CLI：`einz.dart`、`einz_tui.dart`；测试：`shared/test/einz_shared_test.dart`），保留。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../crypto/keys.dart';
import '../sodium.dart';

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
