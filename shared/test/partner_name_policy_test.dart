// 用户名称（partner 显示名）规则单测（唯一来源，App / TUI / CLI 共用；
// 服务端 partnerName.ts 同约定）。
//
// 老板 2026-09-16：最多 32 字符，只允许中文字 / 英文字母 / 数字 / `_` / `-` /
// emoji。与设备名的差别是**允许 emoji**（名字是亲昵称呼，设备名是机器标识）。
// 用例里的 emoji 一律写成码点转义，避免源文件编码/编辑器差异影响断言。
import 'package:test/test.dart';

import 'package:einz_shared/einz_shared.dart';

void main() {
  const smile = '\u{1F600}'; // 😀
  const flag = '\u{1F1E8}\u{1F1F3}'; // 🇨🇳 区域指示符对
  const family = '\u{1F468}‍\u{1F469}‍\u{1F467}'; // 👨‍👩‍👧 ZWJ 组合
  const heart = '❤️'; // ❤ + VS16
  const keycap = '1️⃣'; // 1 + VS16 + 键帽
  const sparkles = '✨'; // 杂项符号（Extended_Pictographic）

  group('checkPartnerNamePolicy', () {
    test('合规：中英文 / 数字 / _ / - / emoji', () {
      expect(checkPartnerNamePolicy('Lukas'), isNull);
      expect(checkPartnerNamePolicy('a_张-1'), isNull);
      expect(checkPartnerNamePolicy('小猪$smile'), isNull);
      expect(checkPartnerNamePolicy(smile), isNull);
      expect(checkPartnerNamePolicy(flag), isNull);
      expect(checkPartnerNamePolicy(family), isNull);
      expect(checkPartnerNamePolicy(heart), isNull);
      expect(checkPartnerNamePolicy(keycap), isNull);
      expect(checkPartnerNamePolicy(sparkles), isNull);
    });

  test('不合规：空格 / 中文标点 / @ / 全角符号 / 空', () {
    expect(checkPartnerNamePolicy(''), PartnerNameViolation.empty);
    expect(checkPartnerNamePolicy('   '), PartnerNameViolation.empty);
    // 空格不在白名单里（老板清单只有中英文、数字、`_`、`-`、emoji）
    expect(checkPartnerNamePolicy('Mr Lukas'), PartnerNameViolation.illegalCharacter);
    expect(checkPartnerNamePolicy('名字。'), PartnerNameViolation.illegalCharacter);
    expect(checkPartnerNamePolicy('a@b'), PartnerNameViolation.illegalCharacter);
    expect(checkPartnerNamePolicy('Ｌｕｋａｓ'), PartnerNameViolation.illegalCharacter); // 全角
  });

  test('中文字 = \p{Script=Han}：罕见姓名用字放行，假名/谚文仍拒', () {
    expect(checkPartnerNamePolicy('张'), isNull); // 基本区
    expect(checkPartnerNamePolicy('𠮷'), isNull); // 扩展 B（U+20BB7，老板 2026-09-16 要求放行）
    expect(checkPartnerNamePolicy('㐀'), isNull); // 扩展 A
    // 不是汉字：日文假名、韩文、全角字母
    expect(checkPartnerNamePolicy('あ'), PartnerNameViolation.illegalCharacter);
    expect(checkPartnerNamePolicy('한'), PartnerNameViolation.illegalCharacter);
    expect(checkPartnerNamePolicy('Ａ'), PartnerNameViolation.illegalCharacter);
  });

    test('不合规：超长（按码点计 >32）', () {
      expect(checkPartnerNamePolicy('a' * 32), isNull); // 边界：32 正好
      expect(checkPartnerNamePolicy('a' * 33), PartnerNameViolation.tooLong);
      expect(checkPartnerNamePolicy('张' * 33), PartnerNameViolation.tooLong);
      expect(checkPartnerNamePolicy(smile * 33), PartnerNameViolation.tooLong);
    });

    test('长度上限常量（三端一致）', () {
      expect(kPartnerNameMaxLength, 32);
    });
  });
}
