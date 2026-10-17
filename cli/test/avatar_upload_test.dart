// 头像上传回归（老板 2026-10-17）：TUI `/avatar <图片路径>` 的本地先行校验。
//
// 为什么在本地挡：服务端对 /avatar 的约束是 2MB + 非空（server/src/avatars.ts），
// App 端还多一层图片扩展名（file_picker 的 FileType.image）。TUI 收的是手敲路径，
// 没有 picker 那层过滤——不在本地先挡，用户要等网络往返才吃到 400/413，且失败信息
// 还是服务端的英文码。此处断言三种典型错误各自抛出、且**不发起任何请求**
// （server 留空：一旦走到网络阶段必抛另一种错，测试即失败）。
//
// 在线路径（真上传）由 pty 级 tui_smoke.py 覆盖，不走单测（需要真服务端）。

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

  /// 有 session token 但 server 留空 → 任何走到网络的调用都会失败（离线等价）
  EntranceStore storeWithSession() => EntranceStore(
        publicKey: base64Encode(List<int>.filled(32, 1)),
        privateKey: base64Encode(List<int>.filled(32, 2)),
        spaceKey: base64Encode(List<int>.filled(32, 3)),
        spaceId: 'space-x',
        keyVersion: 1,
        sessionToken: 'token-x',
      )..memberId = 'p1';

  test('头像：文件不存在 → 本地抛错（不发起请求）', () async {
    final dir = Directory.systemTemp.createTempSync('einz-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final session = ChatSession(storeWithSession(), '${dir.path}/s.json', '');

    await expectLater(
      session.setAvatar('${dir.path}/nope.png'),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('文件不存在'))),
    );
  });

  test('头像：非图片扩展名 → 本地抛错（不发起请求）', () async {
    final dir = Directory.systemTemp.createTempSync('einz-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/notes.txt')..writeAsStringSync('not an image');
    final session = ChatSession(storeWithSession(), '${dir.path}/s.json', '');

    await expectLater(
      session.setAvatar(file.path),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('不是图片文件'))),
    );
  });

  test('头像：空文件 → 本地抛错（服务端同样会 400）', () async {
    final dir = Directory.systemTemp.createTempSync('einz-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/empty.png')..writeAsBytesSync(const []);
    final session = ChatSession(storeWithSession(), '${dir.path}/s.json', '');

    await expectLater(
      session.setAvatar(file.path),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('内容为空'))),
    );
  });

  test('头像：超过 2MB → 本地抛错并给出实际大小（服务端 413 前置）', () async {
    final dir = Directory.systemTemp.createTempSync('einz-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/big.png')
      ..writeAsBytesSync(List<int>.filled(kMaxAvatarBytes + 1024, 0));
    final session = ChatSession(storeWithSession(), '${dir.path}/s.json', '');

    await expectLater(
      session.setAvatar(file.path),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('超过 2MB 上限'))),
    );
  });

  test('头像：~ 家目录路径会被展开（与 /attach 同一口径）', () async {
    final dir = Directory.systemTemp.createTempSync('einz-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final session = ChatSession(storeWithSession(), '${dir.path}/s.json', '');
    // 指向家目录下一个必然不存在的图片：报错信息里应出现展开后的绝对路径，
    // 证明 ~ 已被替换（否则用户看到的还是未展开的 ~，无从排查）
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']!;

    await expectLater(
      session.setAvatar('~/definitely-not-here-avatar.png'),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          allOf(contains('文件不存在'), contains(home)))),
    );
  });

  test('头像：未激活会话（无 token）→ 拒绝上传', () async {
    final dir = Directory.systemTemp.createTempSync('einz-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/a.png')..writeAsBytesSync(List<int>.filled(64, 7));
    // 不带 sessionToken：requireSession 应先炸，而不是走到上传
    final session = ChatSession(
      EntranceStore(
        publicKey: base64Encode(List<int>.filled(32, 1)),
        privateKey: base64Encode(List<int>.filled(32, 2)),
        spaceId: 'space-x',
        keyVersion: 1,
      )..memberId = 'p1',
      '${dir.path}/s.json',
      '',
    );

    await expectLater(session.setAvatar(file.path), throwsA(anything));
  });
}
