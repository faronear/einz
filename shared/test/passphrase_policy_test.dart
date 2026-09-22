// 共享口令强度策略单测（唯一来源，三端共用）。
//
// 背景：口令是**免设备认证**的取包端点（POST /spaces/{id}/key-escrow）的唯一凭证，
// 服务端只存 argon2id hash → 强度是这条链路的主要防线（见 docs/SECURITY.md §2）。
import 'package:test/test.dart';

import 'package:einz_shared/einz_shared.dart';

void main() {
  test('长度不足 → tooShort', () {
    expect(checkPassphrasePolicy('abc1234'), PassphrasePolicyViolation.tooShort);
    expect(checkPassphrasePolicy('',), PassphrasePolicyViolation.tooShort);
  });

  test('只要求长度：不卡字符种类（老板 2026-09-15）', () {
    // 纯数字 / 纯字母 / 纯符号，只要够长就放行——复杂度交给用户自己决定
    expect(checkPassphrasePolicy('12345678'), isNull);
    expect(checkPassphrasePolicy('abcdefgh'), isNull);
    expect(checkPassphrasePolicy('!!!!!!!!'), isNull);
    expect(checkPassphrasePolicy('口令口令口令口令'), isNull); // 中文也按字数算
  });

  test('满足策略（≥8 位）→ 通过', () {
    expect(checkPassphrasePolicy('einz-pass-2026'), isNull);
    expect(checkPassphrasePolicy('correct horse'), isNull); // 词串
    expect(kPassphraseMinLength, 8);
  });
}
