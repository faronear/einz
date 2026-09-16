import 'package:flutter/material.dart';

/// 「加入秘境」入口卡片上的可爱小房子（老板 2026-09-16）：
/// 加入之后两个人就组成了一个窝/家，所以这里不用通用的"门/房子"字形，而是画一个
/// 圆角屋顶 + 烟囱冒心形的小屋——心形是"家"的隐喻，圆角是"可爱"的关键
/// （尖角屋顶在小尺寸下会显得冷硬）。
///
/// 为什么自绘而不是用 Material 的 `Icons.cottage` / `home_rounded`：
/// 字形在浅色品牌卡片上偏"系统图标感"，且大小/重心固定；自绘能跟随卡片底色挖空门窗
/// （[background] 传卡片底色，让门窗"透出底色"而不是糊上一块白）、并且整体重心可以
/// 比字形更大更靠下，和旁边"创建秘境"的锤子图标在视觉重量上配平。
class CuteHouseIcon extends StatelessWidget {
  const CuteHouseIcon({
    super.key,
    required this.color,
    required this.background,
    this.size = 46,
  });

  /// 房子主色（跟随入口卡片的品牌色）。
  final Color color;

  /// 门窗的"挖空"色：传卡片底色，洞口透出底色。
  final Color background;

  /// 图标边长（正方形）。
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _CuteHousePainter(color: color, background: background),
      ),
    );
  }
}

/// 画法全部在 100×100 的坐标稿上定义，再按 [size] 等比缩放——这样调形状时只看一套数字。
class _CuteHousePainter extends CustomPainter {
  _CuteHousePainter({required this.color, required this.background});

  final Color color;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 100.0; // 坐标稿单位 → 实际像素
    Offset p(double x, double y) => Offset(x * u, y * u);
    final body = Paint()
      ..color = color
      ..isAntiAlias = true;
    final hole = Paint()
      ..color = background
      ..isAntiAlias = true;

    // 烟囱冒出的爱心：先画（下半截随后被屋顶/烟囱压住，接缝自然）
    canvas.drawPath(_heart(p(74, 15), 9 * u), body);
    // 烟囱
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromPoints(p(62, 26), p(74, 48)),
        Radius.circular(3 * u),
      ),
      body,
    );
    // 屋顶：填充 + 同色粗描边（描边把三个角磨圆 = 可爱化；单靠 fill 是尖角）
    final roof = Path()
      ..moveTo(50 * u, 20 * u)
      ..lineTo(92 * u, 56 * u)
      ..lineTo(8 * u, 56 * u)
      ..close();
    canvas.drawPath(roof, body);
    canvas.drawPath(
      roof,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9 * u
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    // 房身（比屋顶窄，形成屋檐外挑）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromPoints(p(18, 52), p(82, 88)),
        Radius.circular(8 * u),
      ),
      body,
    );
    // 门（拱形，落到房身底边）+ 圆窗：用卡片底色挖空
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromPoints(p(42, 66), p(58, 88)),
        topLeft: Radius.circular(8 * u),
        topRight: Radius.circular(8 * u),
      ),
      hole,
    );
    canvas.drawCircle(p(32, 68), 4.5 * u, hole);
  }

  /// 心形：两段三次贝塞尔 + 底部尖角（[c] 为心形中心，[s] 为半宽量级）。
  Path _heart(Offset c, double s) {
    final path = Path()
      ..moveTo(c.dx, c.dy + s * 0.9)
      ..cubicTo(c.dx - s * 1.4, c.dy + s * 0.1, c.dx - s * 0.7, c.dy - s,
          c.dx, c.dy - s * 0.25)
      ..cubicTo(c.dx + s * 0.7, c.dy - s, c.dx + s * 1.4, c.dy + s * 0.1,
          c.dx, c.dy + s * 0.9)
      ..close();
    return path;
  }

  @override
  bool shouldRepaint(_CuteHousePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.background != background;
}
