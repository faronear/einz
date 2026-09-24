// 附件上传回归：回车后附件消息要**立刻**进消息流（pending `⋯`），不能等上传往返。
//
// 背景（老板 2026-09-14）：TUI 里 `/attach` 此前要等加密+上传+发消息全部回来才把消息
// 追加进展示缓存——大文件上传期间消息流毫无反馈（回车后干等，体验停顿）。修复：
// [ChatSession.attachFile] 信封一装好就乐观上屏（与 sendText 同款），网络阶段在后台
// 继续，拿到应答后按 messageId 覆盖为 sent。
// 另一面：附件 blob v1 不做补传，所以失败时必须撤掉这条乐观气泡，否则会误导成"已发出"。
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

  test('附件：上传前即上屏（pending），失败后撤下（不留幽灵气泡）', () async {
    final dir = Directory.systemTemp.createTempSync('einz-attach-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/s.json';
    final file = File('${dir.path}/note.txt')..writeAsStringSync('hello');

    // 有 Space Key + session token，但 server 留空 → 网络阶段必失败（离线/不可达等价）
    final store = EntranceStore(
      publicKey: base64Encode(List<int>.filled(32, 1)),
      privateKey: base64Encode(List<int>.filled(32, 2)),
      spaceKey: base64Encode(List<int>.filled(32, 3)),
      spaceId: 'space-x',
      keyVersion: 1,
      sessionToken: 'token-x',
    )
      ..memberId = 'p1'
      ..entranceId = 'd1';
    final session = ChatSession(store, path, '');

    // 每次重绘（onChanged）时快照一次：气泡可见吗？可见时状态是 pending 吗？
    // 乐观上屏 = 这些快照出现在网络往返/失败**之前**。
    final visibleOnRender = <bool>[];
    final pendingOnRender = <bool>[];
    session.onChanged = () {
      final hit = session.messages.where((m) => m.env.type == 'file').toList();
      visibleOnRender.add(hit.isNotEmpty);
      pendingOnRender.add(hit.isNotEmpty && session.sentStatusOf(hit.first) == 'pending');
    };

    await expectLater(session.attachFile(file.path), throwsA(anything));

    expect(visibleOnRender.contains(true), isTrue, reason: '附件气泡要在上传往返之前就上屏');
    expect(pendingOnRender.contains(true), isTrue, reason: '上屏那一刻状态应为 pending ⋯');
    expect(session.messages.any((m) => m.env.type == 'file'), isFalse,
        reason: '上传失败要撤掉乐观气泡，不留"已发出"的假象');
  });

  test('附件：文件不存在时直接抛错，不上屏（无假气泡）', () async {
    final dir = Directory.systemTemp.createTempSync('einz-attach-missing-');
    addTearDown(() => dir.deleteSync(recursive: true));

    final store = EntranceStore(
      publicKey: base64Encode(List<int>.filled(32, 1)),
      privateKey: base64Encode(List<int>.filled(32, 2)),
      spaceKey: base64Encode(List<int>.filled(32, 3)),
      spaceId: 'space-x',
      sessionToken: 'token-x',
    )
      ..memberId = 'p1'
      ..entranceId = 'd1';
    final session = ChatSession(store, '${dir.path}/s.json', '');

    await expectLater(
      session.attachFile('${dir.path}/nope.txt'),
      throwsA(isA<StateError>()),
    );
    expect(session.messages, isEmpty);
  });
}
