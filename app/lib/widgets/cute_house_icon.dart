import 'package:flutter/material.dart';

/// 「加入秘境」入口卡片上的可爱小房子（老板 2026-09-16）：
/// 加入之后两个人就组成了一个窝/家，所以这里不用通用的"门/房子"字形，而是画一个
/// 圆角屋顶 + 烟囱冒心形的小屋——心形是"家"的隐喻，圆角是"可爱"的关键
/// （尖角屋顶在小尺寸下会显得冷硬）。
///
/// 为什么自绘而不是用 Material 的 `Icons.cottage` / `home_rounded`：
/// 字形在浅色品牌卡片上偏"系统图标感"，且大小/重心固定；自绘能跟随卡片底色挖空门窗
/// （[background] 传卡片底色，让门窗"透出底色"而不是糊上一块白）、并且整体高度可以
/// 精确对齐旁边"创建秘境"的图标。
///
/// 尺寸标定（老板 2026-09-16 反馈"房子比锤子矮"后改为量着做）：把两个图标各栅格化一次、
/// 量"墨迹"包围盒——`Icon(Icons.build_outlined, size: 44)` 的墨迹是 **42×42px**，而原来
/// 那版房子本体只有约 31px（确实矮了 11px）。现在房子本体占本稿 75/100 单位，
/// 默认 [size] = 56 → 本体墨迹 **42px**，与锤子持平；连爱心整体 51×56px。
class CuteHouseIcon extends StatelessWidget {
  const CuteHouseIcon({
    super.key,
    required this.color,
    required this.background,
    // 默认 56：让**房子本体**（屋顶→底座）的墨迹高度对齐旁边 `Icon(size: 44)` 的锤子。
    // 实测（栅格化量墨迹包围盒）：Material 字形几乎占满 em，锤子在 size 44 时墨迹 42×42px；
    // 本稿房子本体占 75/100 单位 → 0.75×56 ≈ 42px ✓（老板 2026-09-16：原先房子比锤子矮，
    // 要求等高）。爱心另在房子上方约 10px，是刻意的"烟囱冒心"，所以整体会比锤子略高。
    this.size = 56,
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

    // 烟囱冒出的爱心：先画（下半截随后被烟囱接住，接缝自然）
    canvas.drawPath(_heart(p(72, 13), 12 * u), body);
    // 烟囱：加宽（68..82）并探出屋面（屋顶右坡在 x=68 处约 y=43），让"冒烟"这件事
    // 一眼看得出来（老板 2026-09-16：烟囱更明显一点点）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromPoints(p(68, 24), p(82, 54)),
        Radius.circular(3 * u),
      ),
      body,
    );
    // 屋顶：填充 + 同色粗描边（描边把三个角磨圆 = 可爱化；单靠 fill 是尖角）
    final roof = Path()
      ..moveTo(50 * u, 28 * u)
      ..lineTo(94 * u, 64 * u)
      ..lineTo(6 * u, 64 * u)
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
        Rect.fromPoints(p(14, 58), p(86, 98)),
        Radius.circular(9 * u),
      ),
      body,
    );
    // 门（拱形，落到房身底边）+ 圆窗：用卡片底色挖空
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromPoints(p(42, 74), p(58, 98)),
        topLeft: Radius.circular(9 * u),
        topRight: Radius.circular(9 * u),
      ),
      hole,
    );
    canvas.drawCircle(p(33, 76), 5 * u, hole);
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
