// 版本闸的纯逻辑（app/lib/widgets/version_gate.dart）：
// 版本号比较 + "本机是否已不被支持"的判定。
//
// 为什么单独测这两条：它们是**唯一**会导致"把用户锁在门外"的代码，而且输入来自
// 服务端配置（人手写的 yymm.ddhh.mm）——写错/写漏零、段数不齐都必须不炸。
// 弹窗本身（UI）由老板真机自测，这里只钉逻辑。
//
// 运行：flutter test test/version_gate_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/widgets/version_gate.dart';

void main() {
  group('compareAppVersions', () {
    test('逐段按整数比，忽略段内前导零', () {
      expect(compareAppVersions('2610.0412.30', '2610.0412.30'), 0);
      // 手写配置容易漏零：2610.412.30 与 2610.0412.30 是同一个东西
      expect(compareAppVersions('2610.412.30', '2610.0412.30'), 0);
      expect(compareAppVersions('2610.0412.29', '2610.0412.30'), -1);
      expect(compareAppVersions('2610.0412.31', '2610.0412.30'), 1);
      // 跨段进位（字符串比较会在这里出错）
      expect(compareAppVersions('2609.2359.59', '2610.0000.00'), -1);
      // 段内位数不同：字符串比较会说 "2610.100.00" 更大（'1' > '0'），
      // 但按整数 100 < 959 —— 这正是"逐段按整数比"的意义
      expect(compareAppVersions('2610.100.00', '2610.0959.00'), -1);
    });

    test('段数不齐时缺的当 0（服务端写两段也能比）', () {
      expect(compareAppVersions('2610.0412', '2610.0412.0'), 0);
      expect(compareAppVersions('2610.0412', '2610.0412.30'), -1);
      expect(compareAppVersions('2610.0412.30', '2610.0412'), 1);
    });

    test('解析不出数字的段当 0（配置写错不该让客户端崩）', () {
      expect(compareAppVersions('2610.x.30', '2610.0000.30'), 0);
      expect(compareAppVersions('', '2610.0412.30'), -1);
    });
  });

  group('isAppVersionUnsupported', () {
    test('本机低于下限 → true（该弹升级窗）', () {
      expect(isAppVersionUnsupported('2609.1810.35', '2610.0412.30'), isTrue);
    });

    test('等于/高于下限 → false', () {
      expect(isAppVersionUnsupported('2610.0412.30', '2610.0412.30'), isFalse);
      expect(isAppVersionUnsupported('2610.0413.00', '2610.0412.30'), isFalse);
    });

    test('服务端不设下限（null / 空串）→ 永不拦', () {
      expect(isAppVersionUnsupported('2609.1810.35', null), isFalse);
      expect(isAppVersionUnsupported('2609.1810.35', ''), isFalse);
      expect(isAppVersionUnsupported('2609.1810.35', '   '), isFalse);
    });

    test('拿不到本机版本（空串）→ 不拦（宁可漏拦，不误拦）', () {
      // 开发包/异常环境下 PackageInfo 可能拿不到版本；把用户锁在门外比放行更糟
      expect(isAppVersionUnsupported('', '2610.0412.30'), isFalse);
    });
  });
}
