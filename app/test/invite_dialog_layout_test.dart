import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'real_async_settle.dart';

/// 通道码弹窗布局回归测试（2026-09-08 老板真机报告：app 使用一段时间后点
/// 菜单生成通道码，经常整个屏幕变暗但弹窗不出现，flutter run 报
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
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => [
    {
      'entrance_id': 'dev-a',
      'entrance_name': 'iPhone',
      'member_id': 'member-me',
      'connected_at': DateTime.now().millisecondsSinceEpoch,
      'status': 'active',
    },
  ];

  @override
  Future<JoinTokenResult> createJoinToken(
    String spaceId,
    String token, {
    required String purpose,
    String? targetMemberId,
    String? passphrase,
  }) async =>
      const JoinTokenResult(
        joinToken: 'e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
        link: 'https://einz.tic.cc/join/e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
        expiresAt: 0,
      );
}

/// 文案断言一律从 l10n 取（与页面用的是同一份生成代码）：改文案不会再让测试腐烂。
final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

void main() {
  // 菜单里的翻转沙漏（_HourglassFlip）是常驻动画，关掉它免得 pumpAndSettle 超时
  disableAnimationsInTests();
  testWidgets('通道码弹窗：首帧不抛布局异常且二维码真实可见', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-demo',
        entranceId: 'dev-a',
        spaceKey: Uint8List(32),
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _InviteFakeApi(),
        enableWs: false, // 测试环境不连真实 WS
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100)); // 初始加载（空历史）

    // 菜单 → 我的通道 → 新建通道（2026-09-25 起菜单不再有「生成通道码」项，
    // 入口移到「我的通道」弹层里的「新建通道」按钮）
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(_zh.chatPageMenuEntranceList));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageMenuEntranceList));
    // _menuAction 有 300ms 错峰延迟（等菜单收起再开弹层）：pumpAndSettle 推不到它
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    // 点「新建通道」：通道列表弹层收起，300ms 错峰后才打开弹窗（chat_page
    // _menuAction 设计），随后 createJoinToken（fake 瞬时返回）→ showDialog
    await tester.tap(find.text(_zh.chatPageEntranceListNew));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(); // 弹窗首帧（原 bug：此帧抛固有尺寸异常 → 遮罩变暗）
    expect(tester.takeException(), isNull,
        reason: '弹窗首帧不应抛布局异常（真机表现为屏幕变暗但弹窗不出现）');
    await tester.pumpAndSettle();

    // 弹窗内容齐全
    expect(find.text(_zh.chatPageInviteDialogTitleAttachSelf), findsOneWidget);
    // token（次级小字，在上）+ 邀请链接（主展示，在下）——顺序见 chat_page 注释
    expect(find.text('https://einz.tic.cc/join/e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789'),
        findsWidgets);
    expect(find.text('e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789'), findsWidgets);

    // 顺序（老板 2026-09-22）：**纯通道码在上、邀请链接在下**——多数人直接复制通道码，
    // 链接留给"点开看邀请页"的场景。用几何位置钉住，防止以后又被调回去。
    final tokenY = tester
        .getTopLeft(find.text('e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789').first)
        .dy;
    final linkY = tester
        .getTopLeft(find
            .text('https://einz.tic.cc/join/e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789')
            .first)
        .dy;
    expect(tokenY, lessThan(linkY), reason: '纯通道码应在邀请链接上方');

    // 二维码真实可见（原 bug：CustomPaint 绘制面 0x0，从未显示）
    final qrPaint = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is QrPainter);
    expect(qrPaint, findsOneWidget);
    final qrSize = tester.getSize(qrPaint);
    expect(qrSize.width, 160);
    expect(qrSize.height, 160);

    // 弹层化（老板 2026-10-15）：底部弹层而非 AlertDialog；无输入框 → 点遮罩/
    // 下滑即关，底部不放「关闭」按钮
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text(_zh.close), findsNothing, reason: '弹层不该再有「关闭」按钮');

    // 只要一个「重新生成」：居中、且**不占满宽度**（可按可不按，不像附件存储
    // 的提交按钮那样满宽——那是"必须做决定"的口气）
    final regenerate =
        find.widgetWithText(TextButton, _zh.chatPageInviteRegenerate);
    expect(regenerate, findsOneWidget);
    final sheetWidth = tester.getSize(find.byType(BottomSheet)).width;
    expect(tester.getSize(regenerate).width, lessThan(sheetWidth * 0.6),
        reason: '重新生成是可选操作：不该占满宽度');
    expect((tester.getCenter(regenerate).dx - sheetWidth / 2).abs(), lessThan(2),
        reason: '重新生成应水平居中');
    expect(tester.takeException(), isNull);
  });

  testWidgets('通道码弹层：屏幕高度不够时中部内部滚动、不溢出（老板 2026-10-15 实测）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-demo',
        entranceId: 'dev-a',
        spaceKey: Uint8List(32),
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _InviteFakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // 菜单 → 我的通道（默认 800x600 里走：菜单本身有近 500px 高，矮窗口开不全）
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(_zh.chatPageMenuEntranceList));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageMenuEntranceList));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    // 弹层开着呢，把窗口压矮（默认高度装得下全部内容，320 才复现"底部溢出
    // 且无法滚动"——原 Column 直接 overflow）
    tester.view.physicalSize = const Size(420, 320);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
        of: find.byType(BottomSheet), matching: find.text(_zh.chatPageEntranceListNew)));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: '矮窗口里弹层首帧不应抛溢出异常（RenderFlex overflow）');
    await tester.pumpAndSettle();

    // 中部是 ListView（可滚；聊天页消息列表也是 ListView，限定在弹层内找）。
    // 矮窗口下链接行在滚动视口外——ListView 懒加载，这会儿还不在树里；往下拖
    // 滚才该出现（这正证明中部是可滚的、内容没被裁掉）。
    final link = find.text('https://einz.tic.cc/join/e1-ABCDEFGHJKLMNPQRSTUVWXYZ23456789');
    final middleList = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(ListView));
    expect(middleList, findsOneWidget);
    // 备注归标题组：固定不随中部滚动（老板 2026-10-15：与 OptionPickerSheet
    // 等弹层口径一致，滚动区不包括备注）
    final hint = find.text(_zh.chatPageInviteDialogHintAttachSelf);
    final hintBefore = tester.getTopLeft(hint).dy;
    expect(link, findsNothing,
        reason: '链接行初始应在滚动视口外（矮窗口装不下全部内容）');
    await tester.drag(middleList, const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(hint).dy, hintBefore,
        reason: '备注应固定在标题下方，不随中部滚动');
    expect(link, findsWidgets, reason: '拖滚后链接行应滚进视口');

    // 「重新生成」固定在底部：不随中部滚走，一直在视口内
    final regenerate =
        find.widgetWithText(TextButton, _zh.chatPageInviteRegenerate);
    expect(tester.getCenter(regenerate).dy, lessThan(320),
        reason: '重新生成应固定在弹层底部，矮窗口也看得见');
    expect(tester.takeException(), isNull);
  });
}
