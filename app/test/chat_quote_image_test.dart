// 回归测试（老板要求 2026-09-13）：图片消息被引用/长按时，显示的应是**缩略图**
// 而不是文件名——① 长按菜单顶部的简略气泡；② 发送后新消息气泡里的引用块
// （顺带覆盖输入栏引用条）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/message_repository.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 2x2 PNG（红）——足够小又能被 Flutter 解码。
final Uint8List _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==');

/// 图片查找器：气泡 180 / 菜单预览 48 / 输入栏引用条 24 / 引用块 40。
Finder _imageOf(double size) =>
    find.byWidgetPredicate((w) => w is Image && w.width == size);

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
        devices: const [
          SpaceDevice(deviceId: 'dev-a', personId: 'person-a', status: 'active'),
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
      deviceId: 'dev-a',
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
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等本地历史载入
    await tester.pumpAndSettle(); // 等图片解码
    return tester;
  }

  testWidgets('长按图片消息：菜单预览行显示缩略图（不是文件名）', (WidgetTester tester) async {
    await pumpWithImage(tester);
    expect(_imageOf(180), findsOneWidget, reason: '消息流应显示图片本体');

    await tester.longPress(_imageOf(180));
    await tester.pumpAndSettle();
    final previewRow = find.byKey(const ValueKey('messagePreviewRow'));
    expect(
      find.descendant(of: previewRow, matching: _imageOf(48)),
      findsOneWidget,
      reason: '菜单顶部简略气泡应显示图片缩略图',
    );
    expect(
      find.descendant(of: previewRow, matching: find.byType(Text)),
      findsNothing,
      reason: '预览行不应再显示文件名文本',
    );

    await tester.tapAt(const Offset(20, 20)); // 关闭弹窗
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('引用图片并发送：新消息气泡的引用块显示缩略图（不是文件名）',
      (WidgetTester tester) async {
    await pumpWithImage(tester);

    // 长按 → 引用
    await tester.longPress(_imageOf(180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(_imageOf(24), findsOneWidget, reason: '输入栏引用条也应显示缩略图');

    await tester.enterText(find.byType(TextField), '看这个');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('看这个'), findsOneWidget, reason: '新消息应已发出');
    expect(_imageOf(40), findsOneWidget, reason: '引用块应显示原图缩略图');
    expect(find.textContaining('photo.png'), findsNothing,
        reason: '引用块不再显示文件名');
    expect(_imageOf(24), findsNothing, reason: '发送后输入栏引用条应清空');
  });
}
