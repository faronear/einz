// 回归测试（老板要求 2026-10-12）：图片全屏后，点击屏幕**任何地方**都应返回
// 聊天页，而不是必须点右上角的关闭 ✕。同时守住三条边界：
// ① 双指缩放/拖动（pan）不能误触关闭——只有"轻触"才关；
// ② 右上角 ✕ 仍负责显式关闭（不被轻触层抢走）；
// ③ ✕ 带黑 54% 圆底——内容偏白时纯白叉会融进背景，圆底保证任何底色都醒目。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'real_async_settle.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/message_repository.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 2x2 PNG（红）——足够小又能被 Flutter 解码。
final Uint8List _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==');

/// 消息流里的图片气泡（180 见方、cover 裁剪）。
Finder _bubbleImage() =>
    find.byWidgetPredicate((w) => w is Image && w.width == 180);

Finder _dialogCloseButton() => find.descendant(
    of: find.byType(Dialog), matching: find.byIcon(Icons.close));

/// fake：不发真实网络。sync 空（消息由 seedRepo 直接落库），postMessage 成功。
class _ImageFakeApi extends ApiClient {
  _ImageFakeApi() : super('http://fake');

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async =>
      (
        messages: const <MessageEnvelope>[],
        attachmentsMeta: const <Map<String, dynamic>>[],
        lastSequence: 0,
        hasMore: false,
      );

  @override
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async =>
      PostMessageResult(
          messageId: env.messageId, serverSequence: 1, createdAt: 1000);

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-test',
        entrances: const [
          SpaceEntrance(entranceId: 'dev-a', memberId: 'member-a', status: 'active'),
        ],
      );

  @override
  Future<List<ReceiptRow>> getReceipts(String token) async => const [];

  @override
  Future<({int deliveredUptoSeq, int readUptoSeq})> postReceipts(
    String token, {
    int? deliveredUptoSeq,
    int? readUptoSeq,
  }) async =>
      (deliveredUptoSeq: deliveredUptoSeq ?? 0, readUptoSeq: readUptoSeq ?? 0);
}

void main() {
  setUpAll(() async {
    await sodium(); // 附件加解密需要 libsodium
    // withImmersiveFullscreen 里的 SystemChrome.setEnabledSystemUIMode 走
    // flutter/platform 通道，测试环境没有引擎、调用永不回调——不 mock 的话
    // await 挂住，全屏 Dialog 根本打不开（真机不受影响，通道有系统回）。
    // 统一回 null：与"平台不支持时静默降级"的生产行为一致。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SystemChannels.platform, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// 种一条本机发出的图片消息（带本地密文副本，离线也能显示）+ 打开聊天页。
  Future<WidgetTester> pumpWithImage(WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _ImageFakeApi();
    // token: null → 只落库不上传（测试不需要真实上传）
    final seedRepo = MessageRepository(
      db: db,
      api: api,
      spaceKey: spaceKey,
      spaceId: 'space-test',
      entranceId: 'dev-a',
      keyVersion: 1,
      token: null,
    );
    await seedRepo.sendAttachment(
        fileBytes: _tinyPng, fileName: 'photo.png', type: 'image');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-test',
        entranceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等本地历史载入
    // 附件解密（FFI）与图片解码是真实异步，fake 时钟推不动——见 settleRealAsync 注释
    await settleRealAsync(tester);
    return tester;
  }

  /// 点开图片全屏，等路由动画走完。
  Future<void> openFullscreen(WidgetTester tester) async {
    await tester.tap(_bubbleImage());
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget,
        reason: '全屏大图应已打开');
    expect(_dialogCloseButton(), findsOneWidget, reason: '右上角 ✕ 应仍在');
  }

  testWidgets('图片全屏：点屏幕任何地方（含图片外压边）都返回聊天页',
      (WidgetTester tester) async {
    await pumpWithImage(tester);
    await openFullscreen(tester);

    // 左上角 (60,60)：既不在右上角 ✕ 上，也不在底部「保存」上，且在大图
    // （contain 居中，2x2 图放大到 600x600，x 从 100 起）左侧的渐变压边上
    await tester.tapAt(const Offset(60, 60));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing, reason: '轻触后全屏应关闭');
    expect(_bubbleImage(), findsOneWidget,
        reason: '关闭后应回到聊天页（气泡仍在）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片全屏：点大图本体也能关闭', (WidgetTester tester) async {
    await pumpWithImage(tester);
    await openFullscreen(tester);

    // 大图正中央（600x600 大图铺在屏幕中间）
    await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing, reason: '轻触大图也应关闭');
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片全屏：拖动（缩放/平移手势）不会误触关闭',
      (WidgetTester tester) async {
    await pumpWithImage(tester);
    await openFullscreen(tester);

    // 放大看细节时拖一下看看别处——不能一松手就把大图关了
    await tester.drag(find.byType(InteractiveViewer), const Offset(0, -80));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget,
        reason: '拖动是平移手势，不应触发轻触关闭');
    await tester.tap(_dialogCloseButton());
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing, reason: '✕ 仍负责显式关闭');
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片全屏：关闭键是白叉+深灰圆底（浅色图片上也醒目）',
      (WidgetTester tester) async {
    await pumpWithImage(tester);
    await openFullscreen(tester);

    // 老板 2026-10-12：内容偏白时纯白 ✕ 会融进背景——圆底必须真的画上，
    // 且是圆形（不是方块/椭圆）
    final circledClose = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate((w) {
        if (w is! IconButton) return false;
        final states = const <WidgetState>{};
        return w.style?.backgroundColor?.resolve(states) == Colors.black54 &&
            w.style?.shape?.resolve(states) is CircleBorder;
      }),
    );
    expect(circledClose, findsOneWidget,
        reason: '关闭键应为白叉 + 黑 54% 圆形底（任何底色都衬得出）');
    expect(tester.takeException(), isNull);
  });
}
