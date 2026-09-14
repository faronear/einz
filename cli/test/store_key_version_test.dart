// 只读兼容路径：按 key_version 选密钥解密旧消息。
//
// 2026-09-14 决策：Space Key 轮换方案**不做**（端侧无入口、分发链路不成立、ROI 极低，
// 见 docs/SECURITY.md）。但"读懂轮换状态"的读侧路径保留——`archived_space_keys` 是
// 备份/恢复载荷的既有字段，且将来若恢复轮换，解密侧无需改动。产生轮换状态的入口
// （`einz rotate` 命令、`DeviceStore.rotateSpaceKey()`、shared `SpaceKeyRing`）已撤除。
import 'package:test/test.dart';

import 'package:einz_cli/store.dart';

void main() {
  test('spaceKeyForVersion：当前版本取当前、归档版本取归档、未知版本 null', () {
    final store = DeviceStore(publicKey: 'pk', privateKey: 'sk')
      ..spaceKey = 'CURRENT-V2'
      ..spaceId = 'space-1'
      ..keyVersion = 2
      ..archivedSpaceKeys.add({'key_version': 1, 'space_key': 'ARCHIVED-V1'});

    expect(store.spaceKeyForVersion(2), 'CURRENT-V2');
    expect(store.spaceKeyForVersion(1), 'ARCHIVED-V1');
    expect(store.spaceKeyForVersion(99), isNull);
  });
}
