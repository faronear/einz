// 用户名称（person 显示名）规则单测（唯一来源，App / TUI / CLI 共用；
// 服务端 personName.ts 同约定）。
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

  group('checkPersonNamePolicy', () {
    test('合规：中英文 / 数字 / _ / - / emoji', () {
      expect(checkPersonNamePolicy('Lukas'), isNull);
      expect(checkPersonNamePolicy('a_张-1'), isNull);
      expect(checkPersonNamePolicy('小猪$smile'), isNull);
      expect(checkPersonNamePolicy(smile), isNull);
      expect(checkPersonNamePolicy(flag), isNull);
      expect(checkPersonNamePolicy(family), isNull);
      expect(checkPersonNamePolicy(heart), isNull);
      expect(checkPersonNamePolicy(keycap), isNull);
      expect(checkPersonNamePolicy(sparkles), isNull);
    });

  test('不合规：空格 / 中文标点 / @ / 全角符号 / 空', () {
    expect(checkPersonNamePolicy(''), PersonNameViolation.empty);
    expect(checkPersonNamePolicy('   '), PersonNameViolation.empty);
    // 空格不在白名单里（老板清单只有中英文、数字、`_`、`-`、emoji）
    expect(checkPersonNamePolicy('Mr Lukas'), PersonNameViolation.illegalCharacter);
    expect(checkPersonNamePolicy('名字。'), PersonNameViolation.illegalCharacter);
    expect(checkPersonNamePolicy('a@b'), PersonNameViolation.illegalCharacter);
    expect(checkPersonNamePolicy('Ｌｕｋａｓ'), PersonNameViolation.illegalCharacter); // 全角
  });

  test('中文字 = \p{Script=Han}：罕见姓名用字放行，假名/谚文仍拒', () {
    expect(checkPersonNamePolicy('张'), isNull); // 基本区
    expect(checkPersonNamePolicy('𠮷'), isNull); // 扩展 B（U+20BB7，老板 2026-09-16 要求放行）
    expect(checkPersonNamePolicy('㐀'), isNull); // 扩展 A
    // 不是汉字：日文假名、韩文、全角字母
    expect(checkPersonNamePolicy('あ'), PersonNameViolation.illegalCharacter);
    expect(checkPersonNamePolicy('한'), PersonNameViolation.illegalCharacter);
    expect(checkPersonNamePolicy('Ａ'), PersonNameViolation.illegalCharacter);
  });

    test('不合规：超长（按码点计 >32）', () {
      expect(checkPersonNamePolicy('a' * 32), isNull); // 边界：32 正好
      expect(checkPersonNamePolicy('a' * 33), PersonNameViolation.tooLong);
      expect(checkPersonNamePolicy('张' * 33), PersonNameViolation.tooLong);
      expect(checkPersonNamePolicy(smile * 33), PersonNameViolation.tooLong);
    });

    test('长度上限常量（三端一致）', () {
      expect(kPersonNameMaxLength, 32);
    });
  });
}
