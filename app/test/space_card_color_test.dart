// 「切换我的秘境」卡片底色的四条规则（老板 2026-10-04 定）：
//   duo + 性别已知 → 淡粉/淡蓝（当前空间 = 深粉/深蓝）
//   duo + 性别未知（对方没加入 / 没登记性别）→ 青
//   group → 紫（老板让我挑的）
//   当前正在使用的空间 → 深色（+ 立体阴影，阴影在 widget 层，不在这条纯函数里）
//
// 这张表是老板口头定的规则，最容易被后续改动碰坏（改配色时想不起"青=未知、紫=群"），
// 所以逐条钉死。
//
// 运行：flutter test test/space_card_color_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/widgets/space_switcher.dart';

void main() {
  group('duo + 性别已知：沿用性别象征色', () {
    test('女：未选中淡粉 / 当前深粉', () {
      expect(spaceCardColor(isGroup: false, peerGender: 'female', current: false),
          const Color(0xFFD6529C).withValues(alpha: 0.18));
      expect(spaceCardColor(isGroup: false, peerGender: 'female', current: true),
          const Color(0xFFB83D80));
    });

    test('男：未选中淡蓝 / 当前深蓝', () {
      expect(spaceCardColor(isGroup: false, peerGender: 'male', current: false),
          const Color(0xFF3BAFFD).withValues(alpha: 0.18));
      expect(spaceCardColor(isGroup: false, peerGender: 'male', current: true),
          const Color(0xFF2271F7));
    });
  });

  group('duo + 性别未知：青色', () {
    test('对方尚未加入（性别空串）：未选中淡青 / 当前深青', () {
      expect(spaceCardColor(isGroup: false, peerGender: '', current: false),
          const Color(0xFF26C6DA).withValues(alpha: 0.22));
      expect(spaceCardColor(isGroup: false, peerGender: '', current: true),
          const Color(0xFF00838F));
    });

    test('非 male/female 的脏值同样落到青（不崩、不误判成性别）', () {
      expect(spaceCardColor(isGroup: false, peerGender: '女', current: false),
          const Color(0xFF26C6DA).withValues(alpha: 0.22));
      expect(spaceCardColor(isGroup: false, peerGender: 'unknown', current: true),
          const Color(0xFF00838F));
    });
  });

  group('group：紫色（且压过性别——一群人没有"对方的性别"可言）', () {
    test('未选中淡紫 / 当前深紫', () {
      expect(spaceCardColor(isGroup: true, peerGender: '', current: false),
          const Color(0xFF9575CD).withValues(alpha: 0.18));
      expect(spaceCardColor(isGroup: true, peerGender: '', current: true),
          const Color(0xFF6A4FB6));
    });

    test('群组空间即使记着某个成员的性别，也仍然用紫', () {
      expect(spaceCardColor(isGroup: true, peerGender: 'female', current: false),
          const Color(0xFF9575CD).withValues(alpha: 0.18));
      expect(spaceCardColor(isGroup: true, peerGender: 'male', current: true),
          const Color(0xFF6A4FB6));
    });
  });

  test('四种情况的颜色互不相同（一眼能分辨空间类型）', () {
    final colors = {
      spaceCardColor(isGroup: false, peerGender: 'female', current: false),
      spaceCardColor(isGroup: false, peerGender: 'male', current: false),
      spaceCardColor(isGroup: false, peerGender: '', current: false),
      spaceCardColor(isGroup: true, peerGender: '', current: false),
    };
    expect(colors.length, 4, reason: '女/男/未知/群 四色不能撞');
  });
}
