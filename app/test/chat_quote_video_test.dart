// 回归测试（老板要求 2026-09-15）：视频消息被引用/长按时，显示的应是**首帧缩略图**
// 而不是「别针 + 文件名」——① 长按菜单顶部的简略气泡；② 输入栏引用条（缩略图 +
// 文件名）；③ 发送后新消息气泡里的引用块。
//
// 测试环境没有原生实现，故 mock 两条通道：path_provider（取帧前要把明文视频落盘）
// 与 video_thumbnail（原生取帧）→ 后者直接返回一张小 PNG，于是三处的缩略图都能
// 和图片消息一样按尺寸断言。

import 'dart:convert';
import 'dart:io';

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

/// 2x2 PNG（红）——充当"取帧"结果，足够小又能被 Flutter 解码。
final Uint8List _fakeFrame = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==');

/// 假的 mp4 字节：测试只走加密/解密，不真解码。
final Uint8List _fakeMp4 = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);

/// 缩略图查找器：菜单预览 48 / 输入栏引用条 24 / 引用块 40。
Finder _thumbOf(double size) =>
    find.byWidgetPredicate((w) => w is Image && w.width == size);

/// fake：不发真实网络。sync 空（消息由 seedRepo 直接落库），postMessage 成功。
class _VideoFakeApi extends ApiClient {
  _VideoFakeApi() : super('http://fake');

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
  });

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('einz_video_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 取帧前要把解密后的视频落盘（MediaCache），测试环境 path_provider 无实现
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getTemporaryDirectory' ? tempDir.path : null,
    );
    // 原生取帧：直接回一张小 PNG
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.justsoft.xyz/video_thumbnail'),
      (call) async => call.method == 'data' ? _fakeFrame : null,
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.justsoft.xyz/video_thumbnail'), null);
    tempDir.deleteSync(recursive: true);
  });

  /// 种一条本机发出的视频消息（带本地密文副本，离线也能解密）+ 打开聊天页。
  Future<WidgetTester> pumpWithVideo(WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _VideoFakeApi();
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
        fileBytes: _fakeMp4, fileName: 'video.mp4', type: 'video');

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
    await settleRealAsync(tester); // 等附件解密（真实异步，见 helper 注释）
    return tester;
  }

  /// 消息流里的视频气泡：`_VideoPreview` 三种状态（加载中 / 失败 / 成功）都带
  /// `ValueKey('videoPreview')`，按 key 定位不依赖具体控件类型（此前按 180×100
  /// 的 SizedBox 找，失败态改成带图标的 Container 后就找不到了）。占位本身不参与
  /// 命中测试，故长按点取包住它的气泡 GestureDetector。
  Finder videoBubble() => find.ancestor(
        of: find.byKey(const ValueKey('videoPreview')),
        matching: find.byType(GestureDetector),
      );

  testWidgets('长按视频消息：菜单预览行显示首帧缩略图（不是文件名）',
      (WidgetTester tester) async {
    await pumpWithVideo(tester);
    expect(videoBubble(), findsOneWidget, reason: '消息流应显示视频预览');

    await tester.longPress(videoBubble());
    await settleRealAsync(tester);
    await tester.pumpAndSettle();
    final previewRow = find.byKey(const ValueKey('messagePreviewRow'));
    expect(
      find.descendant(of: previewRow, matching: _thumbOf(48)),
      findsOneWidget,
      reason: '菜单顶部简略气泡应显示视频首帧缩略图',
    );
    expect(
      find.descendant(of: previewRow, matching: find.byType(Text)),
      findsNothing,
      reason: '预览行不应再显示「📎 video.mp4」这类文件名文本',
    );

    await tester.tapAt(const Offset(20, 20)); // 关闭弹窗
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('引用视频并发送：引用条是缩略图 + 文件名，引用块是缩略图',
      (WidgetTester tester) async {
    await pumpWithVideo(tester);

    // 长按 → 引用
    await tester.longPress(videoBubble());
    await settleRealAsync(tester);
    await tester.tap(find.text('引用'));
    await settleRealAsync(tester);
    await tester.pumpAndSettle();
    expect(_thumbOf(24), findsOneWidget, reason: '输入栏引用条应显示视频缩略图');
    expect(find.text('video.mp4'), findsOneWidget,
        reason: '引用条在缩略图右侧仍显示文件名');

    await tester.enterText(find.byType(TextField), '看这个');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleRealAsync(tester);
    await tester.pumpAndSettle();

    expect(find.text('看这个'), findsOneWidget, reason: '新消息应已发出');
    expect(_thumbOf(40), findsOneWidget, reason: '引用块应显示视频首帧缩略图');
    expect(find.textContaining('video.mp4'), findsNothing,
        reason: '引用块不再显示文件名');
    expect(_thumbOf(24), findsNothing, reason: '发送后输入栏引用条应清空');
  });
}
