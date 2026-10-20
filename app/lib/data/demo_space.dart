import 'dart:convert';
import 'dart:ui' as ui;

import 'package:drift/drift.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'local_database.dart';

/// 演示秘境（2026-10-19，App Store 上架准备——审核演示通道方案 A）：
///
/// 双人邀请制 + 无注册流程，App Store 审核员装上 app 后进不了聊天主界面
/// （Guideline 2.1 最常见被拒点）。本文件提供**本地生成的演示秘境**：
/// 不连服务器、不入 Vault/`spaces` 表（空间列表与切换器看不到它），
/// 仅从向导入口页「先看看演示」进入；消息内容为硬编码演示文案，
/// 走**真实的**本地加密/解密/展示代码路径（encryptMessage/decryptMessage）。
///
/// **密钥说明（红线澄清）**：演示密钥是硬编码常量——它保护的全部内容就是
/// 本文件里的演示文案，无任何真实用户数据，无保密价值；真实空间的 Space Key
/// 仍只存在于 Vault，本机制不触碰锁包/PIN/SecureStore 结构。
class DemoSpace {
  DemoSpace._();

  /// 演示空间固定 spaceId（不占服务端 UUID 命名空间，也不会与真实空间冲突）。
  static const String spaceId = 'demo-space-00000000-0000-0000-0000-000000000001';

  /// 演示空间内「我」的通道标识（senderEntranceId）。
  /// 演示消息按 entrance 维度判归属（_isMineMessage 离线回退路径），
  /// 自己发的用本值、对方发的用 [peerEntranceId]。
  static const String myEntranceId = 'demo-entrance-me';

  /// 演示空间内「对方」的通道标识。
  static const String peerEntranceId = 'demo-entrance-peer';

  /// 演示空间固定密钥（32B，AES 类对称密钥长度；XChaCha20 子密钥由此派生）。
  /// 只保护下方硬编码演示文案——见类头红线澄清。
  static final Uint8List spaceKey =
      Uint8List.fromList(base64Decode('ZGVtb0RlbW9EZW1vRGVtb0RlbW9EZW1vRGVtbw=='));

  /// seeding 是否已完成的 app_state 键（v1 = 内容结构版本，改演示内容时递增）。
  static const String _kSeeded = 'demo_space.seeded_v1';

  /// 我的/对方的演示显示名（走 l10n，见 setup 进入点传入）。
  static const String demoMemberName = 'Einz';
  static const String demoPeerName = 'Demo';

  /// 首次进入演示秘境时预铺消息（幂等：已铺过直接返回）。
  ///
  /// [chinese]：按设备语言选演示文案（seeding 时就加密落库，事后无法切换，
  /// 故在种入时定稿）。全部消息 status='sent'/'read'（免投递状态动画）、
  /// serverSequence 顺序递增、createdAt 摊在过去 3 天——聊天气泡/时间分组/
  /// 回执勾全部按真实历史消息渲染。
  static Future<void> ensureSeeded(LocalDatabase db, {bool chinese = false}) async {
    final flag = await (db.select(db.appState)
          ..where((s) => s.key.equals(_kSeeded)))
        .getSingleOrNull();
    if (flag != null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final day = const Duration(days: 1).inMilliseconds;
    // (文本, 发送方, 相对天数, 是否撤回)——撤回条保留时间行、隐藏内容（墓碑渲染）
    const scriptEn = <(String, String, int, bool)>[
      ('Hi! Welcome to Einz 👋', peerEntranceId, 3, false),
      ('Hi! Is this really end-to-end encrypted?', myEntranceId, 3, false),
      ('Yes — messages are encrypted on your device. '
          'The server only ever sees ciphertext.', peerEntranceId, 2, false),
      ('Great for private conversations 🙂', myEntranceId, 2, false),
      ('You can also quote a message like this 👇', peerEntranceId, 1, false),
      ('Nice! And messages can disappear after a timer.', myEntranceId, 1, false),
      ('This one was recalled — try it yourself: long-press a bubble.', peerEntranceId, 0, true),
      ('Everything here lives only on this device. Enjoy exploring!', peerEntranceId, 0, false),
    ];
    const scriptZh = <(String, String, int, bool)>[
      ('你好！欢迎来到秘境 👋', peerEntranceId, 3, false),
      ('你好！这里的消息真的是端到端加密吗？', myEntranceId, 3, false),
      ('是的——消息在你的设备上加密，服务器只能看到密文。', peerEntranceId, 2, false),
      ('很适合私密聊天 🙂', myEntranceId, 2, false),
      ('还可以像这样引用一条消息 👇', peerEntranceId, 1, false),
      ('不错！消息还能定时阅后即焚。', myEntranceId, 1, false),
      ('这条已撤回——长按气泡可以自己试试。', peerEntranceId, 0, true),
      ('这里的一切都只保存在本机，随意逛逛吧！', peerEntranceId, 0, false),
    ];
    final script = chinese ? scriptZh : scriptEn;
    const quotePreviewEn = 'Everything here lives only on this device...';
    const quotePreviewZh = '这里的一切都只保存在本机……';
    const quoteReplyEn = 'Got it — this is a quoted reply.';
    const quoteReplyZh = '明白了——这就是一条引用回复。';
    final quotePreview = chinese ? quotePreviewZh : quotePreviewEn;
    final quoteReply = chinese ? quoteReplyZh : quoteReplyEn;

    var seq = 1;
    for (final (text, sender, daysAgo, recalled) in script) {
      final messageId = 'demo-msg-${seq.toString().padLeft(4, '0')}';
      final createdAt = now - daysAgo * day - (script.length - seq) * 60000;
      final env = await encryptMessage(
        plaintext: text,
        spaceKey: spaceKey,
        spaceId: spaceId,
        senderEntranceId: sender,
        messageId: messageId,
      );
      final envWithMeta = MessageEnvelope(
        v: env.v,
        type: env.type,
        keyVersion: env.keyVersion,
        messageId: env.messageId,
        senderEntranceId: env.senderEntranceId,
        nonce: env.nonce,
        ciphertext: env.ciphertext,
        serverSequence: seq,
        createdAt: createdAt,
      );
      await db.into(db.localMessages).insert(
            LocalMessagesCompanion.insert(
              messageId: messageId,
              spaceId: spaceId,
              senderEntranceId: sender,
              type: 'text',
              keyVersion: 1,
              nonce: env.nonce,
              ciphertext: jsonEncode(envWithMeta.toJson()),
              createdAt: createdAt,
              localCreatedAt: createdAt,
              // 对方消息恒 'sent'；我方消息 'read'（双勾已读，免 pending 重试）
              status: Value(sender == myEntranceId ? 'read' : 'sent'),
              serverSequence: Value(seq),
              // 撤回墓碑：内容隐藏、时间行显示撤回图标（deletedKind='recall'）
              deletedAt: recalled ? Value(createdAt + 30000) : const Value.absent(),
              deletedKind: recalled ? const Value('recall') : const Value.absent(),
            ),
          );
      seq++;
    }
    // 引用回复示例：引用上一条，展示引用条/引用块渲染（载荷带 quote）
    final quoteTarget = script.length; // 上一条
    final quoteEnv = await encryptMessage(
      plaintext: encodeMessagePayload(
          quoteReply,
          quote: {
            'messageId': 'demo-msg-${quoteTarget.toString().padLeft(4, '0')}',
            'preview': quotePreview,
          }),
      spaceKey: spaceKey,
      spaceId: spaceId,
      senderEntranceId: myEntranceId,
      messageId: 'demo-msg-${seq.toString().padLeft(4, '0')}',
    );
    final quoteEnvFinal = MessageEnvelope(
      v: quoteEnv.v,
      type: quoteEnv.type,
      keyVersion: quoteEnv.keyVersion,
      messageId: quoteEnv.messageId,
      senderEntranceId: quoteEnv.senderEntranceId,
      nonce: quoteEnv.nonce,
      ciphertext: quoteEnv.ciphertext,
      serverSequence: seq,
      createdAt: now,
    );
    await db.into(db.localMessages).insert(
          LocalMessagesCompanion.insert(
            messageId: 'demo-msg-${seq.toString().padLeft(4, '0')}',
            spaceId: spaceId,
            senderEntranceId: myEntranceId,
            type: 'text',
            keyVersion: 1,
            nonce: quoteEnv.nonce,
            ciphertext: jsonEncode(quoteEnvFinal.toJson()),
            createdAt: now,
            localCreatedAt: now,
            status: const Value('read'),
            serverSequence: Value(seq),
          ),
        );

    await db.into(db.appState).insert(
          AppStateCompanion.insert(key: _kSeeded, value: '1'),
          mode: InsertMode.insertOrReplace,
        );
  }

  // ---------- 演示头像（老板 2026-10-20：截图要有头像，两个卡通头像即可） ----------
  //
  // 纯 Dart 运行时绘制（ui.PictureRecorder → PNG bytes），不引入二进制资源：
  // 演示空间没有服务端 memberId（api.getAvatar 走不通），ChatPage 的
  // _loadMyAvatar/_loadPeerAvatar 在 isDemo 下改为取这里的 bytes。

  static Uint8List? _myAvatarCache;
  static Uint8List? _peerAvatarCache;

  /// 我的头像（女，粉）。结果缓存在内存——聊天页多次进出不重复绘制。
  static Future<Uint8List> myAvatar() async =>
      _myAvatarCache ??= await _paintAvatar(girl: true);

  /// 对方头像（男，蓝，Einz）。
  static Future<Uint8List> peerAvatar() async =>
      _peerAvatarCache ??= await _paintAvatar(girl: false);

  /// 画一个卡通头像：圆脸 + 头发 + 五官 + 上衣，女孩加蝴蝶结、留长发。
  /// 256×256 圆形构图（底色圆裁掉四角），输出 PNG bytes。
  static Future<Uint8List> _paintAvatar({required bool girl}) async {
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
}
