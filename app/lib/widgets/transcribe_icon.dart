import 'package:flutter/material.dart';

/// 「语音转写」图标（老板 2026-10-24）：麦克风 + 文档（文档内三条横线示意"文字"），
/// 表达「语音 → 文字」。纯波形图标（Icons.graphic_eq）只有"语音"没有"文字"半边，
/// 语义不完整；自绘把两半都画上。
///
/// 矢量稿：_tmp.gitomit.sfomit/语音转写.svg（iconfont，viewBox 0 0 1280 1024，
/// 单条 path）。按项目惯例自绘而非引入 flutter_svg 依赖（同 [CuteHouseIcon]）：
/// path 数据已离线转换为 Flutter `Path` 调用序列（arcToPoint 与 SVG arc 的
/// large-arc/sweep 标志逐一核对一致，21 段弧全部对应）。
///
/// 用法：菜单操作卡片图标槽（[_buildActionCard] 的 icon 槽是 IconData，本图标
/// 走 widget 重载）。颜色跟随卡片前景（destructive 时红——本图标不会红）。
class TranscribeIcon extends StatelessWidget {
  const TranscribeIcon({super.key, required this.color, this.size = 26});

  /// 图标主色（跟随菜单卡片前景色）。
  final Color color;

  /// 图标边长。原始稿宽高比 1280:1024 = 1.25，绘制时按高度缩放、宽度自然延伸
  /// （占位盒仍是正方形，墨迹水平居中）。
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _TranscribePainter(color: color)),
    );
  }
}

/// 坐标稿 = SVG viewBox（1280×1024），按 size 高度等比缩放后水平居中。
class _TranscribePainter extends CustomPainter {
  _TranscribePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / 1024.0;
    final dx = (size.width - 1280.0 * scale) / 2.0;
    canvas.translate(dx, 0);
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(_transcribePath(), paint);
  }

  /// 「麦克风 + 文档」矢量稿（1280×1024）。由 SVG path 离线转换：
  /// M/m→moveTo、L/l/H/h/V/v→lineTo、C/c→cubicTo（相对坐标已展开为绝对）、
  /// A/a→arcToPoint（radius 取 rx/ry，largeArc/sweep 原样保留）、z→close。
  Path _transcribePath() {
    final path = Path();
    path.moveTo(384, 810.24);
    path.lineTo(384, 981.3333);
    path.arcToPoint(const Offset(298.6667, 981.3333),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: true,
        clockwise: true);
    path.lineTo(298.6667, 810.6667);
    path.lineTo(298.6667, 810.24);
    path.cubicTo(132.096, 801.9627, 0, 660.6507, 0, 488.192);
    path.arcToPoint(const Offset(85.3333, 488.192),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: true,
        clockwise: true);
    path.cubicTo(85.3333, 619.4347, 188.0747, 725.3333, 314.1973, 725.3333);
    path.lineTo(368.4693, 725.3333);
    path.cubicTo(494.592, 725.3333, 597.3333, 619.52, 597.3333, 488.192);
    path.arcToPoint(const Offset(682.6667, 488.192),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: true,
        clockwise: true);
    path.cubicTo(682.6667, 660.6507, 550.5707, 801.9627, 384, 810.24);
    path.close();
    path.moveTo(341.3333, 128);
    path.arcToPoint(const Offset(256, 213.3333),
        radius: const Radius.elliptical(85.3333, 85.3333),
        largeArc: false,
        clockwise: false);
    path.lineTo(256, 469.3333);
    path.arcToPoint(const Offset(426.6667, 469.3333),
        radius: const Radius.elliptical(85.3333, 85.3333),
        largeArc: true,
        clockwise: false);
    path.lineTo(426.6667, 213.3333);
    path.arcToPoint(const Offset(341.3333, 128),
        radius: const Radius.elliptical(85.3333, 85.3333),
        largeArc: false,
        clockwise: false);
    path.close();
    path.moveTo(341.3333, 42.6667);
    path.arcToPoint(const Offset(512, 213.3333),
        radius: const Radius.elliptical(170.6667, 170.6667),
        largeArc: false,
        clockwise: true);
    path.lineTo(512, 469.3333);
    path.arcToPoint(const Offset(170.6667, 469.3333),
        radius: const Radius.elliptical(170.6667, 170.6667),
        largeArc: false,
        clockwise: true);
    path.lineTo(170.6667, 213.3333);
    path.arcToPoint(const Offset(341.3333, 42.6667),
        radius: const Radius.elliptical(170.6667, 170.6667),
        largeArc: false,
        clockwise: true);
    path.close();
    path.moveTo(640, 938.6667);
    path.lineTo(1066.6667, 938.6667);
    path.arcToPoint(const Offset(1152, 853.3333),
        radius: const Radius.elliptical(85.3333, 85.3333),
        largeArc: false,
        clockwise: false);
    path.lineTo(1152, 170.6667);
    path.arcToPoint(const Offset(1066.6667, 85.3333),
        radius: const Radius.elliptical(85.3333, 85.3333),
        largeArc: false,
        clockwise: false);
    path.lineTo(640, 85.3333);
    path.arcToPoint(const Offset(640, 0),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: false,
        clockwise: true);
    path.lineTo(1066.6667, 0);
    path.arcToPoint(const Offset(1237.3333, 170.6667),
        radius: const Radius.elliptical(170.6667, 170.6667),
        largeArc: false,
        clockwise: true);
    path.lineTo(1237.3333, 853.3333);
    path.arcToPoint(const Offset(1066.6667, 1024),
        radius: const Radius.elliptical(170.6667, 170.6667),
        largeArc: false,
        clockwise: true);
    path.lineTo(640, 1024);
    path.arcToPoint(const Offset(640, 938.6667),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: true,
        clockwise: true);
    path.close();
    path.moveTo(768, 341.3333);
    path.lineTo(1024, 341.3333);
    path.arcToPoint(const Offset(1024, 426.6667),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: false,
        clockwise: true);
    path.lineTo(768, 426.6667);
    path.arcToPoint(const Offset(768, 341.3333),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: true,
        clockwise: true);
    path.close();
    path.moveTo(768, 512);
    path.lineTo(1024, 512);
    path.arcToPoint(const Offset(1024, 597.3333),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: true,
        clockwise: true);
    path.lineTo(768, 597.3333);
    path.arcToPoint(const Offset(768, 512),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: false,
        clockwise: true);
    path.close();
    path.moveTo(768, 682.6667);
    path.lineTo(1024, 682.6667);
    path.arcToPoint(const Offset(1024, 768),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: true,
        clockwise: true);
    path.lineTo(768, 768);
    path.arcToPoint(const Offset(768, 682.6667),
        radius: const Radius.elliptical(42.6667, 42.6667),
        largeArc: false,
        clockwise: true);
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_TranscribePainter oldDelegate) =>
      oldDelegate.color != color;
}
