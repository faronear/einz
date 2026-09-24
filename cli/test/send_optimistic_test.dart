// 离线发送回归：消息要立即进展示缓存并通知 UI 重绘，不能等补发网络返回。
//
// 背景（老板 2026-09-13）：服务器离线时 App 能立刻显示已发送的消息（pending），
// 但 TUI 之前要等 `flushPending()` 的网络重试/超时回来才刷新——乐观上屏的消息
// 其实早已入展示缓存，只是没人触发重绘。修复：ChatSession.onChanged 在
// _sortMessages（乐观上屏 / 同步 / WS 追加）后触发。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:einz_cli/chat_core.dart';
import 'package:einz_cli/store.dart';
import 'package:einz_shared/einz_shared.dart';

void main() {
  setUpAll(() async {
    await sodium();
  });

  test('离线发送：消息立即上屏、状态 pending，并通知 UI 重绘', () async {
    final dir = Directory.systemTemp.createTempSync('einz-send-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/s.json';

    // 已绑定空间（有 Space Key）但未配置 server/无 session = 离线
    final store = EntranceStore(
      publicKey: base64Encode(List<int>.filled(32, 1)),
      privateKey: base64Encode(List<int>.filled(32, 2)),
      spaceKey: base64Encode(List<int>.filled(32, 3)),
      spaceId: 'space-x',
      keyVersion: 1,
    )
      ..memberId = 'p1'
      ..entranceId = 'd1';
    final session = ChatSession(store, path, '');
    var changed = 0;
    session.onChanged = () => changed++;

    final ok = await session.sendText('离线消息');
    expect(ok, isFalse); // 离线：只入队、未确认
    expect(session.messages.any((m) => m.plain == '离线消息'), isTrue);
    expect(changed, greaterThan(0)); // 上屏即通知重绘（不依赖网络返回）
    expect(store.pendingCount, 1); // 留在离线队列，恢复后补发

    final msg = session.messages.firstWhere((m) => m.plain == '离线消息');
    expect(session.sentStatusOf(msg), 'pending');
  });
}
