import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:einz/data/demo_art.dart';
import 'package:flutter_test/flutter_test.dart';

/// 演示秘境插画资产（assets/demoSpace/）双模式工具测试：
///
/// **默认（回归测试）**：3 张 PNG 必须存在且不空白——资产被误删/损坏时
/// 默认 `flutter test` 套件会红，挡掉「演示秘境画面空白」这类回归
/// （2026-10-24 根因：Intel iMac x86_64+Impeller 上 `Picture.toImage()`
/// 出全透明空图，运行时绘制方案在全设备不可靠，改预生成资产）。
///
/// **生成模式**：`GEN_DEMO_ASSETS=1 flutter test --tags generator`
/// （或 `npm run demo-assets`）——重画 3 张 PNG 覆盖写入 assets/demoSpace/，
/// 生成后的 PNG 要随代码一起提交。在 arm64 机器（macbook 等）上跑最稳；
/// Intel iMac 上引擎栅格化坏了会出空图，本测试的覆盖率校验会直接失败。
void main() {
  // (资产文件名, 生成函数, 不透明度覆盖率下限)——头像底色圆占满画布 ~78%，
  // 照片渐变铺满全幅
  final targets = <String, (Future<Uint8List> Function(), double)>{
    'avatarMe.png': (paintDemoAvatarMe, 0.40),
    'avatarPeer.png': (paintDemoAvatarPeer, 0.40),
    'photoSunrise.png': (paintDemoPhoto, 0.90),
  };

  test(
    'demoSpace 资产存在且非空白（GEN_DEMO_ASSETS=1 可重新生成）',
    () async {
      final generating = Platform.environment['GEN_DEMO_ASSETS'] == '1';
      if (generating) {
        final outDir = Directory('assets/demoSpace');
        if (!outDir.existsSync()) outDir.createSync(recursive: true);
        for (final entry in targets.entries) {
          final bytes = await entry.value.$1();
          await File('${outDir.path}/${entry.key}').writeAsBytes(bytes);
        }
      }
      for (final entry in targets.entries) {
        final file = File('assets/demoSpace/${entry.key}');
        expect(file.existsSync(), isTrue,
            reason: '缺演示资产 ${entry.key}（生成：npm run demo-assets）');
        final coverage = await _opaqueCoverage(file.readAsBytesSync());
        expect(coverage, greaterThanOrEqualTo(entry.value.$2),
            reason: '${entry.key} 疑似空白（覆盖率 '
                '${(coverage * 100).toStringAsFixed(1)}%）——'
                '若刚重新生成，说明本机引擎栅格化可能坏掉（Intel x86_64+Impeller '
                '已知出空图），换 arm64 机器（macbook）重新生成');
      }
    },
    tags: ['generator'],
  );
}

/// 解码 PNG，统计不透明像素占比（逐像素 RGBA 采样）。
Future<double> _opaqueCoverage(Uint8List pngBytes) async {
  final codec = await ui.instantiateImageCodec(pngBytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final pixels = data!.buffer.asUint8List();
  var total = 0;
  var opaque = 0;
  for (var i = 0; i < image.width * image.height; i++) {
    total++;
    if (pixels[i * 4 + 3] > 16) opaque++;
  }
  return opaque / total;
}
