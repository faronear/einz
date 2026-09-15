// 同步锚点不变量：只前进、不倒退。
//
// 来源：shared 的 `SyncState` 类已删除（2026-09-15 评审 A8——它与 App 的 drift 实现
// 和 CLI 的 store 各有一份，且无人引用），但"锚点只前进"这条不变量仍然承重：锚点倒退会
// 让已拉过的消息被反复重拉、已上报的回执被回退。这条用例原在 shared/test，随实现一起
// 移到 CLI 侧（App 侧对应 `message_repository._advanceAnchor`）。
import 'package:test/test.dart';

import 'package:einz_cli/store.dart';

void main() {
  test('advanceAnchor：锚点只前进不倒退', () {
    final store = DeviceStore(publicKey: 'pk', privateKey: 'sk')
      ..spaceId = 'space-1'
      ..lastServerSequence = 0;

    store.advanceAnchor(5);
    expect(store.lastServerSequence, 5);

    store.advanceAnchor(3); // 倒退 → 忽略
    expect(store.lastServerSequence, 5, reason: '锚点不得倒退');

    store.advanceAnchor(10);
    expect(store.lastServerSequence, 10);

    store.advanceAnchor(10); // 相同 → 无变化
    expect(store.lastServerSequence, 10);
  });
}
