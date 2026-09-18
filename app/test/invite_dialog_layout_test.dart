import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 邀请码弹窗布局回归测试（2026-09-08 老板真机报告：app 使用一段时间后点
/// 菜单生成邀请码，经常整个屏幕变暗但弹窗不出现，flutter run 报
/// RenderIntrinsicWidth / RenderBox was not laid out 连锁异常；且弹窗里的
/// 二维码从未显示过）。
///
/// 根因（已用本测试复现确认，Flutter issue #46063 同款签名）：
/// 弹窗内容用的 QrImageView（qr_flutter 4.1.0）内部无条件包 LayoutBuilder，
/// 而 AlertDialog 用 IntrinsicWidth 包裹内容做固有尺寸测量——performLayout 抛
/// "LayoutBuilder does not support returning intrinsic dimensions"，弹窗首帧
/// 布局中断 → 遮罩变暗、内容不显示。时序相关性：IntrinsicWidth 仅在松约束
/// 相位触发测量，真机 vsync 下偶发命中（"使用一段时间后经常"）。
/// 另外 QrImageView 的绘制面 CustomPaint 无显式尺寸且被内部 Padding 松约束
/// 包裹 → 实际 0x0，QrPainter 直接 return，所以即使弹窗正常也看不到二维码。
///
/// 修复：chat_page.dart 改用自绘 _InviteQrCode（QrCode + QrPainter），无
/// LayoutBuilder、显式定尺寸。
class _InviteFakeApi extends ApiClient {
  _InviteFakeApi() : super('http://fake');

  @override
  Future<
      ({
        List<MessageEnvelope> messages,
        List<Map<String, dynamic>> attachmentsMeta,
        int lastSequence,
        bool hasMore,
      })> sync(String token, {int after = 0, int limit = 100}) async {
    return (
      messages: const <MessageEnvelope>[],
      attachmentsMeta: const <Map<String, dynamic>>[],
      lastSequence: 0,
      hasMore: false,
    );
  }

  @override
  Future<JoinTokenResult> createJoinToken(String spaceId, String token) async =>
      const JoinTokenResult(
        joinToken: 'e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
        link: 'https://einz.tic.cc/join/e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
        expiresAt: 0,
      );
}

void main() {
  testWidgets('邀请码弹窗：首帧不抛布局异常且二维码真实可见', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-demo',
        deviceId: 'dev-a',
        spaceKey: Uint8List(32),
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _InviteFakeApi(),
        enableWs: false, // 测试环境不连真实 WS
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100)); // 初始加载（空历史）

    // 菜单 → 邀请码
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('邀请码'));
    // 菜单 pop 后延迟 300ms 才打开弹窗（chat_page onSelected 设计），
    // 随后 createJoinToken（fake 瞬时返回）→ showDialog
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(); // 弹窗首帧（原 bug：此帧抛固有尺寸异常 → 遮罩变暗）
    expect(tester.takeException(), isNull,
        reason: '弹窗首帧不应抛布局异常（真机表现为屏幕变暗但弹窗不出现）');
    await tester.pumpAndSettle();

    // 弹窗内容齐全
    expect(find.text('邀请码已生成'), findsOneWidget);
    // 邀请链接（SelectableText 主展示）+ token（次级小字）
    expect(find.text('https://einz.tic.cc/join/e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789'),
        findsWidgets);
    expect(find.text('e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789'), findsWidgets);

    // 二维码真实可见（原 bug：CustomPaint 绘制面 0x0，从未显示）
    final qrPaint = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is QrPainter);
    expect(qrPaint, findsOneWidget);
    final qrSize = tester.getSize(qrPaint);
    expect(qrSize.width, 160);
    expect(qrSize.height, 160);
    expect(tester.takeException(), isNull);
  });
}
