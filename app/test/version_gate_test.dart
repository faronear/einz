// 版本闸的纯逻辑（app/lib/widgets/version_gate.dart）：
// 版本号比较 + "本机是否已冻结（frozen）"的判定。
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

  group('isAppVersionFrozen', () {
    test('本机低于冻结线 → true（frozen，该弹不可关闭的升级窗）', () {
      expect(isAppVersionFrozen('2609.1810.35', '2610.0412.30'), isTrue);
    });

    test('等于/高于冻结线 → false', () {
      expect(isAppVersionFrozen('2610.0412.30', '2610.0412.30'), isFalse);
      expect(isAppVersionFrozen('2610.0413.00', '2610.0412.30'), isFalse);
    });

    test('服务端不设冻结线（null / 空串）→ 永不拦', () {
      expect(isAppVersionFrozen('2609.1810.35', null), isFalse);
      expect(isAppVersionFrozen('2609.1810.35', ''), isFalse);
      expect(isAppVersionFrozen('2609.1810.35', '   '), isFalse);
    });

    test('拿不到本机版本（空串）→ 不拦（宁可漏拦，不误拦）', () {
      // 开发包/异常环境下 PackageInfo 可能拿不到版本；把用户锁在门外比放行更糟
      expect(isAppVersionFrozen('', '2610.0412.30'), isFalse);
    });
  });

  group('appVersionGateLevel（2026-10-10 温度三态判定）', () {
    const cold = '2609.0101.00';
    const hot = '2610.0412.30';

    test('低于冻结线 → frozen（即使也低于热版本）', () {
      expect(
        appVersionGateLevel('2608.2359.59', coldVersion: cold, hotVersion: hot),
        VersionGateLevel.frozen,
      );
    });

    test('边界：恰好等于冻结线不算"低于" → cooling（正在冷却，只提醒不拦）', () {
      expect(
        appVersionGateLevel(cold, coldVersion: cold, hotVersion: hot),
        VersionGateLevel.cooling,
      );
    });

    test('≥ 冻结线、低于热版本 → cooling（正在冷却）', () {
      expect(
        appVersionGateLevel('2610.0412.29', coldVersion: cold, hotVersion: hot),
        VersionGateLevel.cooling,
      );
    });

    test('≥ 热版本 → none', () {
      expect(
        appVersionGateLevel(hot, coldVersion: cold, hotVersion: hot),
        VersionGateLevel.none,
      );
      expect(
        appVersionGateLevel('2610.0413.00', coldVersion: cold, hotVersion: hot),
        VersionGateLevel.none,
      );
    });

    test('只配热版本、不配冻结线：低于热版本 → cooling（不拦，只提醒）', () {
      expect(
        appVersionGateLevel('2609.0101.00', hotVersion: hot),
        VersionGateLevel.cooling,
      );
      expect(
        appVersionGateLevel(hot, hotVersion: hot),
        VersionGateLevel.none,
      );
    });

    test('什么都不配 → none', () {
      expect(appVersionGateLevel('2608.0101.00'), VersionGateLevel.none);
      expect(
        appVersionGateLevel('2608.0101.00', coldVersion: '', hotVersion: '   '),
        VersionGateLevel.none,
      );
    });

    test('拿不到本机版本（空串）→ 一律 none（宁可漏拦/漏提醒，不误拦）', () {
      expect(
        appVersionGateLevel('', coldVersion: cold, hotVersion: hot),
        VersionGateLevel.none,
      );
    });
  });
}
