// 启动参数 `--server` 解析的边界测试。
//
// 只测纯函数 parseServerArg（不碰平台通道），覆盖：
// 空格形式 / 等号形式 / 缺值 / 空值 / 夹杂其他参数 / 重复出现。

import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/launch_args.dart';

void main() {
  group('parseServerArg', () {
    test('空参数 → null', () {
      expect(parseServerArg(const <String>[]), isNull);
    });

    test('无关参数 → null', () {
      expect(parseServerArg(const ['--foo', 'bar']), isNull);
    });

    test('--server <地址>（空格形式）', () {
      expect(
        parseServerArg(const ['--server', 'http://localhost:3000']),
        'http://localhost:3000',
      );
    });

    test('--server=<地址>（等号形式）', () {
      expect(
        parseServerArg(const ['--server=https://einz.tic.cc']),
        'https://einz.tic.cc',
      );
    });

    test('夹杂其他参数时仍能取到', () {
      expect(
        parseServerArg(const ['--foo', '--server', 'https://a', '--bar']),
        'https://a',
      );
    });

    test('--server 在末尾缺值 → null', () {
      expect(parseServerArg(const ['--foo', '--server']), isNull);
    });

    test('--server= 空值 → null', () {
      expect(parseServerArg(const ['--server=']), isNull);
    });

    test('--server 后跟空串 → null', () {
      expect(parseServerArg(const ['--server', '']), isNull);
    });

    test('重复出现取最后一个（后写覆盖前写）', () {
      expect(
        parseServerArg(const ['--server', 'https://a', '--server=https://b']),
        'https://b',
      );
    });
  });
}
