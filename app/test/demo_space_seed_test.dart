import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:einz/data/demo_space.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:flutter_test/flutter_test.dart';

/// 演示秘境 seeding 回归（2026-10-24 图片改预生成资产后）：
///
/// 最关键的回归是「种进库的预设照片密文，解密回来是**真图**而不是空白」——
/// 根因事故：Intel iMac（x86_64+Impeller）上运行时 `Picture.toImage()` 出
/// 全透明空图，v2 种子把空白照片种进了实例库（老板实测演示头像/照片空白）。
/// 头像 bytes 同理要非空白（资产加载路径的回归）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // rootBundle 需要 binding

  late File dbFile;
  late LocalDatabase db;

  setUp(() {
    dbFile = File('${Directory.systemTemp.path}/einz_demo_space_test_$pid.sqlite');
    if (dbFile.existsSync()) dbFile.deleteSync();
    db = LocalDatabase.forTesting(NativeDatabase(dbFile));
  });

  tearDown(() async {
    await db.close();
    if (dbFile.existsSync()) dbFile.deleteSync();
  });

  test('ensureSeeded：10 条消息 + 预设照片密文解密非空白 + 幂等', () async {
    await DemoSpace.ensureSeeded(db, chinese: true);

    // 消息数：8 条脚本 + 1 条引用 + 1 条图片 = 10
    final count = await (db.select(db.localMessages)
          ..where((t) => t.spaceId.equals(DemoSpace.spaceId)))
        .get();
    expect(count.length, 10);

    // 图片附件密文用演示密钥解得开、且解出来不是空白图
    final attachments = await (db.select(db.localAttachments)
          ..where((t) => t.spaceId.equals(DemoSpace.spaceId)))
        .get();
    expect(attachments.length, 1);
    final att = attachments.single;
    final plain = await decryptAttachment(
      cipherText: att.localCipher!,
      nonce: base64Decode(att.nonce),
      spaceKey: DemoSpace.spaceKey,
      attachmentId: att.attachmentId,
      spaceId: DemoSpace.spaceId,
      keyVersion: att.keyVersion,
    );
    final coverage = await _opaqueCoverage(plain);
    expect(coverage, greaterThanOrEqualTo(0.90),
        reason: '演示照片解密结果疑似空白（覆盖率 '
            '${(coverage * 100).toStringAsFixed(1)}%）');

    // 幂等：第二次不重种（消息数不变）
    await DemoSpace.ensureSeeded(db, chinese: true);
    final count2 = await (db.select(db.localMessages)
          ..where((t) => t.spaceId.equals(DemoSpace.spaceId)))
        .get();
    expect(count2.length, 10);
  });

  test('myAvatar/peerAvatar：预生成头像资产非空白', () async {
    final myCoverage = await _opaqueCoverage(await DemoSpace.myAvatar());
    final peerCoverage = await _opaqueCoverage(await DemoSpace.peerAvatar());
    expect(myCoverage, greaterThanOrEqualTo(0.40),
        reason: '我的演示头像疑似空白');
    expect(peerCoverage, greaterThanOrEqualTo(0.40),
        reason: '对方演示头像疑似空白');
  });
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
