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

/// 旋转中的品牌 Logo：3D 双环渲染图持续旋转（启动屏「LOGO + 加载图标」二合一）。
///
/// 用 [RotationTransition] 让 assets/spinnerLogo.png（粉蓝双环 3D 渲染，黑底
/// 已抠为透明、带光晕）绕自身中心无限顺时针旋转。图形旋转非对称（粉环/蓝环
/// 交织方向明确），旋转动画清晰可见，兼具品牌展示与加载指示两种功能。
class SpinningBrandLogo extends StatefulWidget {
  const SpinningBrandLogo({
    super.key,
    this.size = 96,
    this.duration = const Duration(seconds: 3),
  });

  final double size;

  /// 旋转一圈的时长（越小转得越快）。
  final Duration duration;

  @override
  State<SpinningBrandLogo> createState() => _SpinningBrandLogoState();
}

class _SpinningBrandLogoState extends State<SpinningBrandLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat(); // 顺时针无限旋转

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return RotationTransition(
      turns: _controller,
      child: Image.asset(
        'assets/spinnerLogo.png',
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        cacheWidth: (widget.size * dpr).round(),
      ),
    );
  }
}
