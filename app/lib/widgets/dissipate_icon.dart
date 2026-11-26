import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 「云雾散点」自绘图标（老板 2026-11-26）：代表消息消失的中间过程——一团
/// 中心密实、向边缘渐疏渐小的随机散点，像正在蒸发/溶解的雾。
///
/// 用法：更多设置弹层「Removed messages / 消息留痕」条目的 leading 图标，
/// 替换原 Icons.delete_outline（墓碑=删除的语义不够「消散」）。
///
/// 散点用固定种子的伪随机数生成（同 [TranscribeIcon] 的自绘惯例，不引入
/// flutter_svg），保证每次构建/每台设备画出的形状一致。
class DissipateIcon extends StatelessWidget {
  const DissipateIcon({super.key, required this.color, this.size = 24});

  /// 图标主色（跟随列表前景色）。
  final Color color;

  /// 图标边长（正方形占位盒）。
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _DissipatePainter(color: color)),
    );
  }
}

/// 坐标稿 100×100，高斯分布的散点云：距中心越远点越小越稀。
class _DissipatePainter extends CustomPainter {
  _DissipatePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 100.0, size.height / 100.0);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final random = math.Random(7); // 固定种子：形状稳定可复现
    // 均匀散布的等大点团（老板 2026-11-26：不设中心点——高斯核心叠成
    // "一个完整黑点向外投射"）。点在半径 42 的圆内均匀采样，半径近等大，
    // 只有轻微抖动；整体是一团雾，没有致密核心。
    for (var i = 0; i < 62; i++) {
      final angle = random.nextDouble() * 2.0 * math.pi;
      final dist = math.sqrt(random.nextDouble()) * 40.0; // 圆盘内均匀
      final x = 50.0 + math.cos(angle) * dist;
      final y = 50.0 + math.sin(angle) * dist * 0.92;
      // 近等大：3.0 ± 0.8 的轻抖动，无离心衰减的巨变
      final radius = 3.0 + (random.nextDouble() - 0.5) * 1.6;
      final opacity = 0.55 + random.nextDouble() * 0.35; // 0.55–0.90
      if (x < 5 || x > 95 || y < 5 || y > 95) continue;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_DissipatePainter oldDelegate) =>
      oldDelegate.color != color;
}
