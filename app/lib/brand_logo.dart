import 'package:flutter/material.dart';

/// 品牌 Logo（assets/logo.png 粉蓝图标）。
///
/// [size] 正方形展示尺寸，[radius] 圆角；默认值适合顶栏小尺寸展示。
/// 按展示尺寸降采样解码（cacheWidth），避免顶栏小图也解码 1024 大图。
class BrandLogo extends StatelessWidget {
  const BrandLogo({super.key, this.size = 28, this.radius = 7});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        'assets/logo.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * dpr).round(),
      ),
    );
  }
}
