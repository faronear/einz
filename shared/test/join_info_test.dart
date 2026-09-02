// JoinInfo 单测：A → B 加入信息的编解码（einz-join-v1 格式）。

import 'package:einz_shared/einz_shared.dart';
import 'package:test/test.dart';

void main() {
  test('encode/decode 往返：普通口令', () {
    final info = JoinInfo(spaceId: 'space-demo', passphrase: '123456');
    final raw = info.encode();
    expect(raw, 'einz-join-v1?space=space-demo&p=123456');
    final decoded = JoinInfo.decode(raw);
    expect(decoded, isNotNull);
    expect(decoded!.spaceId, 'space-demo');
    expect(decoded.passphrase, '123456');
  });

  test('特殊字符口令 URL 编码往返（+/= 空格 中文）', () {
    final info = JoinInfo(spaceId: 'space-demo', passphrase: 'p@ss w0rd+/=汉字');
    final decoded = JoinInfo.decode(info.encode());
    expect(decoded, isNotNull);
    expect(decoded!.passphrase, 'p@ss w0rd+/=汉字');
    expect(decoded.spaceId, 'space-demo');
  });

  test('encode/decode 往返：含邀请码', () {
    final info = JoinInfo(spaceId: 'space-demo', passphrase: '123456', inviteCode: 'ABC-xyz-987');
    final raw = info.encode();
    expect(raw, 'einz-join-v1?space=space-demo&p=123456&i=ABC-xyz-987');
    final decoded = JoinInfo.decode(raw);
    expect(decoded, isNotNull);
    expect(decoded!.inviteCode, 'ABC-xyz-987');
  });

  test('旧格式（无邀请码）解码兼容：inviteCode 为 null', () {
    final decoded = JoinInfo.decode('einz-join-v1?space=space-demo&p=123456');
    expect(decoded, isNotNull);
    expect(decoded!.spaceId, 'space-demo');
    expect(decoded.passphrase, '123456');
    expect(decoded.inviteCode, isNull);
  });

  test('格式不符返回 null', () {
    expect(JoinInfo.decode('https://einz.tic.cc/foo'), isNull);
    expect(JoinInfo.decode('einz-join-v1?space=only'), isNull); // 缺 p
    expect(JoinInfo.decode('einz-join-v1?p=123'), isNull); // 缺 space
    expect(JoinInfo.decode(''), isNull);
  });
}
