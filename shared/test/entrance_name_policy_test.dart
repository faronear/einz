// 设备名规则单测（唯一来源，App / TUI / CLI 共用；服务端 entranceName.ts 同约定）。
//
// 老板 2026-09-16：设备名只允许中文字 / 英文字母 / 数字 / `_` / `-`，最长 32。
// 自动取的名（宿主机名、手机型号）走 sanitize 消毒；用户输入的走 check 拒绝。
import 'package:test/test.dart';

import 'package:einz_shared/einz_shared.dart';

void main() {
  group('checkEntranceNamePolicy（用户输入 → 拒绝）', () {
    test('合规：中英文 / 数字 / _ / -', () {
      expect(checkEntranceNamePolicy('doomship'), isNull);
      expect(checkEntranceNamePolicy('My-Mac_01'), isNull);
      expect(checkEntranceNamePolicy('老板的电脑'), isNull);
      expect(checkEntranceNamePolicy('_'), isNull); // 消毒产物也可能是纯下划线
    });

    test('中文字 = \\p{Script=Han}：罕见用字放行，假名/谚文/全角仍拒', () {
      expect(checkEntranceNamePolicy('𠮷'), isNull); // 扩展 B 汉字
      expect(checkEntranceNamePolicy('㐀'), isNull); // 扩展 A 汉字
      expect(checkEntranceNamePolicy('あ'), EntranceNameViolation.illegalCharacter); // 假名
      expect(checkEntranceNamePolicy('한'), EntranceNameViolation.illegalCharacter); // 谚文
      expect(checkEntranceNamePolicy('Ａ'), EntranceNameViolation.illegalCharacter); // 全角
    });

    test('不合规：空 / 空格 / 中文标点 / emoji / 空格分隔的词', () {
      expect(checkEntranceNamePolicy(''), EntranceNameViolation.empty);
      expect(checkEntranceNamePolicy('   '), EntranceNameViolation.empty);
      expect(checkEntranceNamePolicy('MacBook Pro'), EntranceNameViolation.illegalCharacter);
      expect(checkEntranceNamePolicy('iPhone15!'), EntranceNameViolation.illegalCharacter);
      expect(checkEntranceNamePolicy('设备。一号'), EntranceNameViolation.illegalCharacter);
      expect(checkEntranceNamePolicy('📱phone'), EntranceNameViolation.illegalCharacter);
    });

    test('不合规：超长（>32）', () {
      final tooLong = 'a' * 33;
      expect(checkEntranceNamePolicy(tooLong), EntranceNameViolation.tooLong);
      expect(checkEntranceNamePolicy('a' * 32), isNull); // 边界：32 正好
    });

    test('长度上限常量（三端一致）', () {
      expect(kEntranceNameMaxLength, 32);
    });
  });

  group('sanitizeEntranceName（自动名 → 换成 _）', () {
    test('宿主机名/机型里的空格与符号换成 _', () {
      expect(sanitizeEntranceName('lukde-MacBook-Pro'), 'lukde-MacBook-Pro'); // 合规原样
      expect(sanitizeEntranceName('MacBook Pro'), 'MacBook_Pro');
      expect(sanitizeEntranceName('iPhone 15 Pro'), 'iPhone_15_Pro');
      expect(sanitizeEntranceName('老板的 iPhone'), '老板的_iPhone');
      expect(sanitizeEntranceName('dev-mobile'), 'dev-mobile');
    });

    test('首尾空白 trim 后不再产生 _', () {
      expect(sanitizeEntranceName('  doomship  '), 'doomship');
    });

    test('全不合规 → 一串下划线（仍是合法名）', () {
      expect(sanitizeEntranceName('???'), '___');
      expect(checkEntranceNamePolicy(sanitizeEntranceName('???')), isNull);
    });

    test('超长截断到 32，且截断后仍合规', () {
      final out = sanitizeEntranceName('测' * 50);
      expect(out.length, kEntranceNameMaxLength);
      expect(checkEntranceNamePolicy(out), isNull);
    });

    test('消毒结果一律能通过校验（不变量）', () {
      for (final raw in ['', ' ', 'a b', '!!!', '中文 名-字_1', 'x' * 100, '😀😀']) {
        final out = sanitizeEntranceName(raw);
        if (out.isEmpty) continue; // 空串不算名（调用方自行兜底）
        expect(checkEntranceNamePolicy(out), isNull, reason: '$raw → $out');
      }
    });
  });
}
