import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

/// 演示秘境插画生成器（2026-10-24 由 [DemoSpace] 的运行时绘制抽离而来）：
/// 卡通头像 ×2 + 日出风景照片，纯 Dart 绘制（ui.PictureRecorder → PNG bytes）。
///
/// **为什么不再运行时绘制**：Intel iMac（x86_64 引擎 + Impeller-Metal）上
/// `Picture.toImage()` 产出全透明空图（Flutter 上游 x86_64+Impeller 已知 bug
/// 类，flutter/flutter#134399 等）——2026-10-24 实证：iMac 上种入的演示照片
/// 解密后是 1024×768 全透明 PNG，演示头像同法绘制故也空白。演示秘境是 App
/// Store 审核演示通道，画面必须全设备可靠 → 改为**预生成 PNG 资产**
/// （`assets/demoSpace/*.png`），本文件只作为**重新生成资产的唯一画法来源**：
/// 改卡通设计后跑 `npm run demo-assets`（= `flutter test --tags generator`）
/// 重新出图并提交资产即可。
///
/// 生成器在 arm64 机器（macbook 等）上运行最稳；Intel iMac 上引擎栅格化坏
/// 了，出图会是空白的——生成器自带 sanity 校验（解回像素查不透明度），
/// 空图会直接 test 失败，不会把空白资产提交进库。

/// 我的演示头像（女，粉）。256×256 圆形构图，输出 PNG bytes。
Future<Uint8List> paintDemoAvatarMe() => paintDemoAvatar(girl: true);

/// 对方演示头像（男，蓝，Einz）。256×256 圆形构图，输出 PNG bytes。
Future<Uint8List> paintDemoAvatarPeer() => paintDemoAvatar(girl: false);

/// 画一个卡通头像：圆脸 + 头发 + 五官 + 上衣，女孩加蝴蝶结、留长发。
/// 256×256 圆形构图（底色圆裁掉四角），输出 PNG bytes。
Future<Uint8List> paintDemoAvatar({required bool girl}) async {
  const size = 256.0;
  final c = Offset(size / 2, size / 2);
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);

  Paint fill(String hex) =>
      Paint()..color = Color(int.parse('FF$hex', radix: 16))..style = PaintingStyle.fill;

  // 底色圆（背景）
  canvas.drawCircle(c, size / 2, fill(girl ? 'FDD6ED' : 'E3F2FD'));

  // 上衣（底部梯形圆肩，先画、让脸盖在上面）
  final shirt = RRect.fromRectAndCorners(
    Rect.fromCenter(center: Offset(size / 2, size + 42), width: 132, height: 120),
    topLeft: const Radius.circular(56),
    topRight: const Radius.circular(56),
  );
  canvas.drawRRect(shirt, fill(girl ? 'D6529C' : '2271F7'));

  // 头发：后层（女孩长两侧，男孩只露一圈边）
  final hairBack = fill(girl ? '6D4C41' : '5D4037');
  if (girl) {
    canvas.drawOval(Rect.fromCenter(center: c - const Offset(0, 18), width: 150, height: 170), hairBack);
  } else {
    canvas.drawCircle(c - const Offset(0, 14), 70, hairBack);
  }

  // 脸
  canvas.drawCircle(c - const Offset(0, 10), 58, fill('FFE3D0'));

  // 前刘海：上半圆盖住额头
  canvas.drawArc(
    Rect.fromCenter(center: c - const Offset(0, 22), width: 124, height: 108),
    3.34, // ~191°（左水平偏下）
    2.94, // 到 ~359°（右水平偏下）——只盖上半
    true,
    fill(girl ? '6D4C41' : '5D4037'),
  );

  // 眼睛 + 微笑 + 腮红
  final eye = fill('4E342E');
  canvas.drawCircle(c - const Offset(20, 6), 5, eye);
  canvas.drawCircle(c + const Offset(20, -6), 5, eye);
  final smile = Paint()
    ..color = const Color(0xFF4E342E)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 4
    ..strokeCap = StrokeCap.round;
  canvas.drawArc(Rect.fromCenter(center: c + const Offset(0, 6), width: 40, height: 32), 0.35, 2.45, false, smile);
  final blush = fill(girl ? 'F8BBD0' : 'FFCCBC');
  canvas.drawCircle(c - const Offset(38, 8), 8, blush);
  canvas.drawCircle(c + const Offset(38, -8), 8, blush);

  // 女孩：头顶蝴蝶结（两瓣 + 中心结）
  if (girl) {
    final bow = fill('EC407A');
    final knot = c - const Offset(30, 74);
    final path = ui.Path()
      ..moveTo(knot.dx, knot.dy)
      ..quadraticBezierTo(knot.dx - 30, knot.dy - 18, knot.dx - 26, knot.dy + 4)
      ..quadraticBezierTo(knot.dx - 12, knot.dy + 12, knot.dx, knot.dy)
      ..close();
    canvas.drawPath(path, bow);
    final path2 = ui.Path()
      ..moveTo(knot.dx, knot.dy)
      ..quadraticBezierTo(knot.dx + 30, knot.dy - 18, knot.dx + 26, knot.dy + 4)
      ..quadraticBezierTo(knot.dx + 12, knot.dy + 12, knot.dx, knot.dy)
      ..close();
    canvas.drawPath(path2, bow);
    canvas.drawCircle(knot, 7, fill('F06292'));
  }

  final image = await rec.endRecording().toImage(size.toInt(), size.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 演示"照片"：纯 Dart 画的日出风景。
/// 1024×768（4:3 随手拍比例）：渐变晨空 + 太阳光晕 + 云 + 两层山剪影 +
/// 水面与太阳倒影。配色与 app 品牌粉蓝渐变呼应。
Future<Uint8List> paintDemoPhoto() async {
  const w = 1024.0, h = 768.0;
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  final rect = Rect.fromLTWH(0, 0, w, h);

  // 晨空：上冷下暖（晨蓝 → 粉 → 暖橙）
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, h),
        const [Color(0xFF7FA7E8), Color(0xFFF2A9B8), Color(0xFFFFD08A)],
        const [0.0, 0.55, 1.0],
      ),
  );

  // 太阳：光晕（大半透明圆）+ 亮核
  final sun = Offset(w * 0.62, h * 0.46);
  canvas.drawCircle(sun, 120, Paint()..color = const Color(0x66FFE9B8));
  canvas.drawCircle(sun, 84, Paint()..color = const Color(0x99FFF0C8));
  canvas.drawCircle(sun, 58, Paint()..color = const Color(0xFFFFF3C4));

  // 云（半透明白椭圆组）
  final cloud = Paint()..color = const Color(0x66FFFFFF);
  canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.25, h * 0.22), width: 300, height: 58), cloud);
  canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.32, h * 0.18), width: 180, height: 44), cloud);
  canvas.drawOval(
      Rect.fromCenter(center: Offset(w * 0.78, h * 0.30), width: 240, height: 48), cloud);

  // 远山（淡紫）与近山（深紫）剪影
  final back = ui.Path()
    ..moveTo(0, h * 0.62)
    ..quadraticBezierTo(w * 0.18, h * 0.46, w * 0.36, h * 0.60)
    ..quadraticBezierTo(w * 0.52, h * 0.70, w * 0.68, h * 0.58)
    ..quadraticBezierTo(w * 0.84, h * 0.48, w, h * 0.60)
    ..lineTo(w, h * 0.74)
    ..lineTo(0, h * 0.74)
    ..close();
  canvas.drawPath(back, Paint()..color = const Color(0xFF9B7EB8));
  final front = ui.Path()
    ..moveTo(0, h * 0.70)
    ..quadraticBezierTo(w * 0.30, h * 0.58, w * 0.55, h * 0.70)
    ..quadraticBezierTo(w * 0.78, h * 0.79, w, h * 0.68)
    ..lineTo(w, h * 0.76)
    ..lineTo(0, h * 0.76)
    ..close();
  canvas.drawPath(front, Paint()..color = const Color(0xFF6D5A8E));

  // 水面：湖蓝渐变 + 高光提亮
  const waterTop = 0.74;
  canvas.drawRect(
    Rect.fromLTWH(0, h * waterTop, w, h * (1 - waterTop)),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, h * waterTop),
        Offset(0, h),
        const [Color(0xFF8E9BD8), Color(0xFF5C6BC0)],
      ),
  );
  canvas.drawRect(Rect.fromLTWH(0, h * waterTop, w, h * (1 - waterTop)),
      Paint()..color = const Color(0x26FFFFFF));

  // 太阳倒影：一列渐短的横向亮条
  final glint = Paint()..color = const Color(0x88FFE9B8);
  for (var i = 0; i < 5; i++) {
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromCenter(
            center: Offset(sun.dx, h * waterTop + 22.0 + i * 34),
            width: 150 - i * 22,
            height: 10),
        topLeft: const Radius.circular(5),
        topRight: const Radius.circular(5),
        bottomLeft: const Radius.circular(5),
        bottomRight: const Radius.circular(5),
      ),
      glint,
    );
  }

  final image = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
