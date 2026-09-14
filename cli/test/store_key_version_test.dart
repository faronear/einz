// key_version 选钥收口：一个 Space 只有一把钥匙（轮换不做，见 docs/SECURITY.md §3），
// 未知版本必须"取不到"而不是拿当前钥匙硬解。
//
// `key_version` 本身保留——它是信封/AAD 的一部分（E2EE.md §5.2），也是解密的收口；
// 但"归档密钥"这一层已随轮换方案一并删除（2026-09-14，无存量数据、不背兼容包袱）。
import 'package:test/test.dart';

import 'package:einz_cli/store.dart';

void main() {
  test('spaceKeyForVersion：当前版本可取，未知版本返回 null', () {
    final store = DeviceStore(publicKey: 'pk', privateKey: 'sk')
      ..spaceKey = 'CURRENT'
      ..spaceId = 'space-1'
      ..keyVersion = 1;

    expect(store.spaceKeyForVersion(1), 'CURRENT');
    expect(store.spaceKeyForVersion(2), isNull);
    expect(store.spaceKeyForVersion(0), isNull);
  });
}
