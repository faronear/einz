// 界面渲染截图（golden）：用 flutter test 渲染界面生成 PNG，
// 供无真机时查看 UI 效果（模拟器 screencap 的替代方案）。
//
// 运行：flutter test --update-goldens test/golden_render_test.dart
// 产物：test/goldens/{setup_step1_*,lock_page,chat_page}.png
// 向导步骤编号规则（老板确认）：1=首页角色选择；1.1/1.2/1.3=create/join/advanced
// 三个并列分流；分流内按页面出现顺序 1.1.1、1.1.2、…（如 1.1.1_device=create 设备名）。
//
// 说明：golden 测试默认 Ahem 字体（中文显示为方块），此处加载系统中文字体
// （macOS Hiragino / Windows simhei / Linux Noto，见 _loadChineseFont）
// 覆盖默认 'Roboto' family 使文字可读。基准图按生成平台渲染，换平台
// 测试前用 --update-goldens 重新生成。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/lock_page.dart';
import 'package:einz/setup_page.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回编排好的消息页（渲染聊天界面用）。
class _FakeApi extends ApiClient {
  _FakeApi(this.page) : super('http://fake');
  final ({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore}) page;

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    return page;
  }
}

/// 加载系统中文字体（覆盖 golden 默认 Ahem，否则中文渲染为方块）。
/// 跨平台候选：macOS Hiragino/STHeiti、Windows simhei、Linux Noto/文泉驿；
/// 全部不存在则跳过（仅影响截图文字可读性，不影响断言结构）。
Future<void> _loadChineseFont() async {
  const candidates = <String>[
    '/System/Library/Fonts/Hiragino Sans GB.ttc',
    '/System/Library/Fonts/STHeiti Light.ttc',
    r'C:\Windows\Fonts\simhei.ttf',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final bytes = f.readAsBytesSync();
    final loader = FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
}

/// 手机尺寸（390x844）下渲染，截图更接近真机观感。
void _usePhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 跳过像素比较的 golden 列表：生成密钥类截图含真实随机公钥
/// （sodium 2.x Randombytes 无 setImplementation 可注入），像素必然不同；
/// 截图仍随 --update-goldens 生成，供人工审核，仅全量测试时跳过比较。
class _SkipListGoldenComparator implements GoldenFileComparator {
  _SkipListGoldenComparator(this._inner, this._skip);

  final GoldenFileComparator _inner;
  final Set<String> _skip;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) {
    final name = golden.pathSegments.last;
    if (_skip.contains(name)) return Future.value(true);
    return _inner.compare(imageBytes, golden);
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) =>
      _inner.update(golden, imageBytes);

  @override
  Uri getTestUri(Uri golden, int? testUri) => _inner.getTestUri(golden, testUri);
}

void main() {
  setUpAll(() async {
    await _loadChineseFont();
    await sodium();
    // 生成密钥类截图含随机公钥 → 全量测试时跳过像素比较
    goldenFileComparator = _SkipListGoldenComparator(
      goldenFileComparator,
      {'setup_step1.1.1_keygen.png'},
    );
  });

  // 测试注入：登记（真实路径走 ApiClient.enrollDevice；此处绕开网络，返回固定结果）。
  Future<EnrollResult> fakeEnroll(String? inviteCode) async =>
      const EnrollResult(deviceId: 'dev1', personId: 'personA', spaceId: 'space-test');

  // 测试注入：生成邀请码（真实路径走 ApiClient.createInvite）。
  Future<InviteResult> fakeInvite(String personId) async => InviteResult(
        inviteCode: 'invite-test-123',
        personId: personId,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 86400000,
      );

  testWidgets('golden: 首页-角色选择（1）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(db: db, probeServer: (_) async => true),
    ));
    await tester.pump();
    await expectLater(find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1_roles.png'));
  });

  testWidgets('golden: 锁屏页 LockPage', (WidgetTester tester) async {
    _usePhoneSize(tester);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: LockPage(db: db),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(find.byType(LockPage), matchesGoldenFile('goldens/lock_page.png'));
  });

  testWidgets('golden: 聊天页 ChatPage（含两条消息）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    final peer = await encryptMessage(
      plaintext: '你好，这是我加密发送的第一条消息',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderDeviceId: 'dev-b',
      messageId: 'msg-0001',
      keyVersion: 1,
    );
    final mine = await encryptMessage(
      plaintext: '收到！第二条消息（我发送的）',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderDeviceId: 'dev-a',
      messageId: 'msg-0002',
      keyVersion: 1,
    );
    final api = _FakeApi((
      messages: [peer, mine],
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: 2,
      hasMore: false,
    ));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-demo',
        deviceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false, // 测试环境不连真实 WS（避免重连 Timer 挂起）
      ),
    ));
    // 等 sync + history 异步完成（fake api 返回 2 条消息，落库后解密显示）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(find.byType(ChatPage), matchesGoldenFile('goldens/chat_page.png'));
  });

  // ---------- 向导步骤渲染（真实交互路径走到目标步骤再截图）----------

  Future<void> pumpSetup(
    WidgetTester tester, {
    Future<EnrollResult> Function(String? inviteCode)? enroll,
    Future<InviteResult> Function(String personId)? invite,
  }) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        probeServer: (_) async => true,
        enrollOverride: enroll,
        createInviteOverride: invite,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 创建路径：进入向导并生成设备密钥（真实 sodium 生成）。
  Future<void> enterCreateWithKey(WidgetTester tester) async {
    await tester.tap(find.text('我是第一个使用者，创建新空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('① 生成设备密钥'));
    await tester.pumpAndSettle();
  }

  testWidgets('golden: 向导1.1.1-设备名称步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester);
    await tester.tap(find.text('我是第一个使用者，创建新空间'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.1_device.png'));
  });

  testWidgets('golden: 向导1.1.1-生成密钥后反馈（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester);
    await enterCreateWithKey(tester);
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.1_keygen.png'));
  });

  testWidgets('golden: 向导1.1.2-登记设备步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester);
    await enterCreateWithKey(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.2_enroll.png'));
  });

  testWidgets('golden: 向导1.1.3-接入口令步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, enroll: fakeEnroll);
    await enterCreateWithKey(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记本设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.3_passphrase.png'));
  });

  testWidgets('golden: 向导1.1.4-PIN 步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, enroll: fakeEnroll);
    await enterCreateWithKey(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记本设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.4_pin.png'));
  });

  testWidgets('golden: 向导1.1.5-二维码分享步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, enroll: fakeEnroll, invite: fakeInvite);
    await enterCreateWithKey(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记本设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    // 生成邀请码后展示含邀请码的二维码（注入绕开网络）
    await tester.tap(find.text('生成邀请码并显示二维码'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.5_share.png'));
  });

  testWidgets('golden: 向导1.1.6-完成步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, enroll: fakeEnroll);
    await enterCreateWithKey(tester);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记本设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.6_done.png'));
  });

  testWidgets('golden: 向导1.2.2-加入步骤（join）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester);
    await tester.tap(find.text('我要加入对方的空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('① 生成设备密钥'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.2.2_join.png'));
  });

  testWidgets('golden: 向导1.3.2-高级 sealed 步骤（advanced）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester);
    // 展开折叠入口（此刻只有一个同名文本：ExpansionTile 标题）
    await tester.tap(find.text('高级：导入 sealed 密钥副本'));
    await tester.pumpAndSettle();
    // 展开后的角色卡（ListTile 列表最后一个）
    await tester.tap(find.byType(ListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('① 生成设备密钥'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.3.2_sealed.png'));
  });
}
