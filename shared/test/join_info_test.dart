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

  test('格式不符返回 null', () {
    expect(JoinInfo.decode('https://only.tic.cc/foo'), isNull);
    expect(JoinInfo.decode('einz-join-v1?space=only'), isNull); // 缺 p
    expect(JoinInfo.decode('einz-join-v1?p=123'), isNull); // 缺 space
    expect(JoinInfo.decode(''), isNull);
  });
}
