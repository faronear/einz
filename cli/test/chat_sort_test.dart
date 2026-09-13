// 展示消息排序回归：同毫秒创建的系统消息必须保持插入顺序。
//
// 背景（老板 2026-09-13 实测）：Dart 的 List.sort 不稳定，join 向导里
// 「✅ 我是 X」「----------------」「❓ 验证密保口令:」几乎同刻产生（同毫秒
// createdAt），排序后被打乱——口令提示跑到"我是 X"之前。用 ChatMessage.order
// （全局插入序号）作平局决胜修复。
import 'package:test/test.dart';

import 'package:einz_cli/chat_core.dart';
import 'package:einz_shared/einz_shared.dart';

ChatMessage _msg({
  required String id,
  required int createdAt,
  required String plain,
  int? seq,
  bool isSystem = false,
}) =>
    ChatMessage(
      env: MessageEnvelope(
        v: 1,
        type: 'text',
        keyVersion: 1,
        messageId: id,
        senderDeviceId: 'd',
        nonce: '',
        ciphertext: '',
      ),
      plain: plain,
      isMine: false,
      isSystem: isSystem,
      createdAt: createdAt,
      serverSequence: seq,
    );

void main() {
  test('同毫秒系统消息排序后保持插入顺序（List.sort 不稳定的回归）', () {
    final list = <ChatMessage>[];
    // 20 条对话消息 + 20 条同毫秒系统消息 → 总长 > 32，触发 Dart 的不稳定排序路径；
    // 该形状下旧比较器（无 order 决胜）会把系统消息打乱
    for (var i = 1; i <= 20; i++) {
      list.add(_msg(id: 'r$i', createdAt: 1000 + i, plain: 'r$i', seq: i));
    }
    final sysTags = <String>[];
    for (var j = 1; j <= 20; j++) {
      final tag = 'S$j';
      sysTags.add(tag);
      list.add(_msg(id: 'sys$j', createdAt: 999999, plain: tag, isSystem: true));
    }

    list.sort(compareChatMessages);
    final sysOrder =
        list.where((m) => m.isSystem).map((m) => m.plain).toList();
    expect(sysOrder, sysTags); // 同刻系统消息保持插入顺序
  });

  test('系统消息按 createdAt 与对话消息穿插（不同时刻仍按时间）', () {
    final list = [
      _msg(id: 'a', createdAt: 100, plain: 'A', seq: 1),
      _msg(id: 'early', createdAt: 50, plain: '早', isSystem: true),
      _msg(id: 'late', createdAt: 150, plain: '晚', isSystem: true),
    ];
    list.sort(compareChatMessages);
    expect(list.map((m) => m.plain).toList(), ['早', 'A', '晚']);
  });
}
