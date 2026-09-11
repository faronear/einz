// 验证 formatMessage 对系统消息的多行渲染（一条消息内 \n 拆成多条物理行，
// 前缀只出现在首物理行、其余缩进对齐；消息间空行由布局层另插，不在本函数内）。
//
// 通过 EINZ_UNITTEST=1 让 bin/einz_tui.dart 的 main 不启动交互 TUI，从而安全
// import 其顶层纯函数。
import 'dart:io';
import 'package:test/test.dart';

import 'package:einz_cli/chat_core.dart';
import 'package:einz_shared/einz_shared.dart';
import '../bin/einz_tui.dart';

void main() {
  // 构造一个系统消息（isSystem=true, isMine=false），plain 含显式 \n
  ChatMessage _sys(String text) => ChatMessage(
        env: MessageEnvelope(
          v: 1,
          type: 'text',
          keyVersion: 1,
          messageId: 'sys-${text.hashCode}',
          senderDeviceId: 'd',
          nonce: '',
          ciphertext: '',
        ),
        plain: text,
        isMine: false,
        isSystem: true,
        createdAt: 0,
      );

  test('系统消息保留显式换行：每条物理行单独渲染、前缀仅首行', () {
    final lines = formatMessage(
      _sys('❓ 秘境入口\n   c: 创建秘境\n   j: 加入秘境'),
      80,
    );
    // 3 条物理行 → 3 个渲染行（窄屏不触发额外折行）
    expect(lines, hasLength(3));
    // 首行带 [system ...] 前缀
    expect(lines[0], contains('[system'));
    expect(lines[0], contains('❓ 秘境入口'));
    // 后续行不带前缀、缩进对齐首行正文左缘（含显式前导空格）
    expect(lines[1], isNot(contains('[system')));
    expect(lines[1], contains('c: 创建秘境'));
    expect(lines[2], isNot(contains('[system')));
    expect(lines[2], contains('j: 加入秘境'));
  });

  test('系统消息显式空行（连续 \\n\\n）保留为空白行', () {
    final lines = formatMessage(_sys('A\n\nB'), 80);
    expect(lines, hasLength(3));
    expect(lines[1].trim(), isEmpty); // 中间空行
  });

  test('系统消息不再把 \\n 折叠成空格', () {
    final lines = formatMessage(_sys('a\nb'), 80);
    // 若被折叠则只有 1 行且含 "a b"；多行渲染应为 2 行
    expect(lines, hasLength(2));
    expect(lines[0], isNot(contains('a b')));
  });

  test('长物理行在窄列宽下折行、续行缩进不带前缀', () {
    // 一条物理行 30 字；列宽 60 → 可用正文宽 = 60 - prefixW(~28) - sideMargin(8)
    // ≈ 24，30 字拆成 2 行；续行不带 [system 前缀、缩进对齐
    final text = '一二三四五六七八九十十一十二十三十四十五十六十七十八十九二十';
    final lines = formatMessage(_sys(text), 60);
    expect(lines.length, greaterThanOrEqualTo(2));
    expect(lines.where((l) => l.contains('[system')), hasLength(1));
    // 末行（续行）不应再含前缀
    expect(lines.last, isNot(contains('[system')));
  });

  test('多条物理行 + 折行：每条物理行各自独立折行', () {
    // 两条物理行各 30 字、列宽 60 → 各拆 2 行，共 4 行；仅首物理行首行带前缀
    final text = '一二三四五六七八九十十一十二十三十四十五十六十七十八十九二十\n'
        '廿一廿二廿三廿四廿五廿六廿七廿八廿九三十卅一卅二卅三卅四卅五';
    final lines = formatMessage(_sys(text), 60);
    // 两条物理行各自折行 → 总行数 > 单物理行数（2）；此处 30 字/行在可用宽下
    // 拆成多行，断言整体 ≥4 且首物理行首行之外都不带前缀
    expect(lines.length, greaterThanOrEqualTo(4));
    expect(lines.where((l) => l.contains('[system')), hasLength(1));
  });
}
