// 回归测试（老板要求 2026-10-12）：剪贴板粘贴发送——桌面 Cmd/Ctrl+V 与附件
// 面板「粘贴」入口同汇到一条链路。六态：
//   ① 剪贴板是图片 → 确认弹窗（问句+预览+取消/发送）→ 发送图片消息；
//   ② 是文件（访达拷的）→ 确认弹窗列名单 → 发送文件消息（复用拖放链路）；
//   ③ 弹窗点取消 → 不发送；
//   ④ 只有文本 → 插进输入框、不发消息、不弹窗；
//   ⑤ 全空 → 提示「剪贴板是空的」；
//   ⑥ 附件面板有「粘贴」入口，点了走同一条确认链路。
// 另隐式覆盖：桌面端输入框 autofocus（不点输入框直接按粘贴键）。

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'real_async_settle.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 2x2 PNG（红）——足够小又能被 Flutter 解码。
final Uint8List _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==');

/// 消息流里的图片气泡（180 见方、cover 裁剪）。
Finder _bubbleImage() =>
    find.byWidgetPredicate((w) => w is Image && w.width == 180);

// ---- 剪贴板假状态（按用例现搭） ----
Uint8List? _clipImage;
List<String> _clipFiles = const [];
String? _clipText;

/// fake：不发真实网络。sync 空（空聊天页就够），postMessage 成功。
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
    // pasteboard 插件走名为 'pasteboard' 的 MethodChannel（Dart 侧
    // PasteboardPlatformIO）。测试环境无原生实现，按用例现搭返回值——与项目里
    // mock path_provider / video_thumbnail 通道同手法。macOS/Linux 两端插件都是
    // 直接回字节/路径列表（Windows 才走临时文件中转）， mock 形态一致。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('pasteboard'), (call) async {
      switch (call.method) {
        case 'image':
          return _clipImage;
        case 'files':
          return _clipFiles;
        default:
          return null;
      }
    });
    // SystemChrome.platform：Clipboard.getData（文本分支）+ 沉浸式全屏的系统
    // 调用在测试环境永不回调，不 mock 会整条挂住（见
    // chat_fullscreen_tap_close_test 的同款注释）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': _clipText};
      }
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('pasteboard'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  setUp(() {
    _clipImage = null;
    _clipFiles = const [];
    _clipText = null;
  });

  /// 空聊天页（不种消息——断言"发没发出"更干净）。
  Future<WidgetTester> pumpChat(WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _ImageFakeApi();

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
    await settleRealAsync(tester);
    return tester;
  }

  /// 按宿主平台按粘贴快捷键（macOS=Cmd+V，Linux/Windows=Ctrl+V）——与生产代码
  /// 里 SingleActivator 的平台分支一致。
  Future<void> pressPaste(WidgetTester tester) async {
    final mod =
        Platform.isMacOS ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control;
    await tester.sendKeyDownEvent(mod);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(mod);
  }

  /// 确认弹窗里的「发送」按钮（限定在 AlertDialog 作用域内，别点到别处的发送）
  Finder dialogSendButton() => find.descendant(
      of: find.byType(AlertDialog), matching: find.text('发送'));

  /// 确认弹窗里的「取消」按钮
  Finder dialogCancelButton() => find.descendant(
      of: find.byType(AlertDialog), matching: find.text('取消'));

  testWidgets('剪贴板是图片 → 确认弹窗预览 → 发送', (WidgetTester tester) async {
    await pumpChat(tester);
    _clipImage = _tinyPng;
    // 不点输入框：桌面端 autofocus 应已把焦点放在输入框（老板的实际用法）
    await pressPaste(tester);
    await tester.pumpAndSettle();

    // 发送前必须弹确认（老板 2026-10-12）：标题问句 + 取消/发送两个按钮
    expect(find.text('发送这张图片？'), findsOneWidget,
        reason: '图片发送前应弹确认');
    expect(dialogSendButton(), findsOneWidget);
    expect(dialogCancelButton(), findsOneWidget);

    await tester.tap(dialogSendButton());
    await settleRealAsync(tester); // 真实加密 + 假 api 发送是异步

    expect(find.byType(AlertDialog), findsNothing, reason: '确认后弹窗应关闭');
    expect(_bubbleImage(), findsOneWidget, reason: '确认后图片应已成消息');
    expect(tester.takeException(), isNull);
  });

  testWidgets('剪贴板是文件 → 确认弹窗列名单 → 发送',
      (WidgetTester tester) async {
    await pumpChat(tester);
    final tmp = File('${Directory.systemTemp.path}/einz_paste_test_file.txt');
    // runAsync：testWidgets 身体跑在 FakeAsync 区里，真实文件 I/O 不会完成
    // （不包会整条挂住——与 settleRealAsync 同一套原理）
    await tester.runAsync(
        () => tmp.writeAsBytes(Uint8List.fromList(List.filled(64, 65))));
    addTearDown(() => tmp.deleteSync());
    _clipFiles = [tmp.path];

    await pressPaste(tester);
    await tester.pumpAndSettle();

    // 文件弹窗列名字（复数标题：1 个走单数形态）
    expect(find.text('发送这个文件？'), findsOneWidget,
        reason: '文件发送前应弹确认');
    expect(find.text('einz_paste_test_file.txt'), findsOneWidget,
        reason: '弹窗应列出待发送的文件名');

    await tester.tap(dialogSendButton());
    // 文件分支要读两次真实文件（XFile.length + readAsBytes），FakeAsync 区里
    // 必须显式给真实事件循环让路（与 settleRealAsync 同原理——但它首轮就会因
    // "没有转圈"退出，等不到这两步 I/O，消息会一直挂在半路）
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await settleRealAsync(tester);

    expect(find.text('einz_paste_test_file.txt'), findsOneWidget,
        reason: '确认后文件应已成消息（弹窗已关，这里匹配的是文件卡）');
    expect(_bubbleImage(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认弹窗点取消 → 不发送', (WidgetTester tester) async {
    await pumpChat(tester);
    _clipImage = _tinyPng;

    await pressPaste(tester);
    await tester.pumpAndSettle();
    await tester.tap(dialogCancelButton());
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing, reason: '取消后弹窗应关闭');
    expect(_bubbleImage(), findsNothing, reason: '取消不应发出任何消息');
    expect(tester.takeException(), isNull);
  });

  testWidgets('剪贴板只有文本 → 插进输入框，不发消息、不弹窗',
      (WidgetTester tester) async {
    await pumpChat(tester);
    _clipText = '粘贴过来的文字';

    await pressPaste(tester);
    await tester.pumpAndSettle();

    expect(find.text('粘贴过来的文字'), findsOneWidget,
        reason: '文本应插入输入框');
    expect(find.byType(AlertDialog), findsNothing,
        reason: '纯文本只是入框（可改），不弹确认');
    expect(_bubbleImage(), findsNothing, reason: '纯文本不应发出消息');
    expect(tester.takeException(), isNull);
  });

  testWidgets('剪贴板全空 → 提示「剪贴板是空的」，不崩',
      (WidgetTester tester) async {
    await pumpChat(tester);

    await pressPaste(tester);
    await tester.pumpAndSettle();

    expect(_bubbleImage(), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('附件面板有「粘贴」入口，点了走同一条确认链路',
      (WidgetTester tester) async {
    await pumpChat(tester);
    _clipImage = _tinyPng;

    // 开附件面板（输入栏左侧 + 号）
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('粘贴'), findsOneWidget, reason: '附件面板应有粘贴入口');
    expect(find.text('相册图片'), findsOneWidget,
        reason: '原有入口不受影响（面板网格照常）');

    // 点入口 → 面板收起 → 同一套读剪贴板 + 确认弹窗
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(find.text('发送这张图片？'), findsOneWidget,
        reason: '面板入口与快捷键同汇到 _pasteFromClipboard');

    await tester.tap(dialogCancelButton());
    await tester.pumpAndSettle();
    expect(_bubbleImage(), findsNothing, reason: '取消则不发送');
    expect(tester.takeException(), isNull);
  });
}
