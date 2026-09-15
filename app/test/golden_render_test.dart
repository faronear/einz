// 界面渲染截图（golden）：用 flutter test 渲染界面生成 PNG，
// 供无真机时查看 UI 效果（模拟器 screencap 的替代方案）。
//
// 运行（默认**全部跳过**）：flutter test -Dgolden=true test/golden_render_test.dart
// 出图：flutter test --update-goldens -Dgolden=true test/golden_render_test.dart
// 产物：test/goldens/**.png（**不入库**，出图时由 --update-goldens 生成；开发期
// 已默认跳过，见下方 _goldensEnabled 开关）
//
// 默认跳过的原因（老板 2026-09-13 定）：开发期 UI 改动频繁，goldens 常红；每次
// 失配要么排查日志、要么读 PNG 对比（读图 token 消耗极高），收益不抵成本。
// 等 UI 冻结（发版前/集中打磨样式）再开开关一次性重生成。
// 向导步骤编号规则（老板确认，2026-09-05 对齐 TUI 重构后）：
// 1=检测页；1.1/1.2/1.3=create/join/offline 三条自动判定流程；
// 分流内按页面出现顺序 1.1.1、1.1.2、…（如 1.1.1_name=create 身份名字）。
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

// golden 固定设备密钥对：登记/认证等步骤需要确定性密钥，真实随机密钥会使
// golden 每次渲染不同而失配；测试注入固定值保证确定性。
// （名字步骤的密钥信息卡已移除——技术细节不展示给用户。）
final DeviceKeyPair _goldenKeyPair = DeviceKeyPair(
  deviceId: 'dev-golden',
  publicKey: Uint8List(32),
  privateKey: Uint8List(32),
);

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

/// 跳过像素比较的 golden 列表：设备名步骤含真实随机公钥
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

/// goldens 开关：默认关（见文件头说明）。启用：`flutter test -Dgolden=true`。
const bool _goldensEnabled = bool.fromEnvironment('golden');

void main() {
  if (!_goldensEnabled) {
    test('goldens 默认跳过（加 -Dgolden=true 才真跑）', () {},
        skip: '开发期不跑 goldens，见文件头注释');
    return;
  }
  setUpAll(() async {
    await _loadChineseFont();
    await sodium();
    // 设备名步骤含随机公钥 → 全量测试时跳过像素比较
    goldenFileComparator = _SkipListGoldenComparator(
      goldenFileComparator,
      {
        'setup_step1.1.2_device.png',
        'setup_step1.2.2_device.png',
        'setup_step1.3.1_device.png',
      },
    );
  });

  // 测试注入：认证（真实路径走 ApiClient.challenge/verify；此处绕开网络）。
  Future<SessionResult> fakeAuth(DeviceKeyPair kp, String enrolledDeviceId) async =>
      SessionResult(sessionToken: 'tok-fake', spaceId: 'space-test', expiresIn: 86400);

  testWidgets('golden: 检测页（服务器不可达）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(db: db, probeServer: (_) async => (false, '', const <String>[])),
    ));
    await tester.pump();
    await expectLater(find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1_detect.png'));
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

  /// 启动 SetupPage。probeNames 空=首设备（create）；非空=后续设备（join）。
  /// probeOk=false 模拟服务器不可达（检测页）。
  Future<void> pumpSetup(
    WidgetTester tester, {
    Map<String, String> probeNames = const {},
    bool probeOk = true,
    Future<SessionResult> Function(DeviceKeyPair kp, String enrolledDeviceId)? auth,
    DeviceKeyPair? keyPair,
  }) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        probeServer: (_) async => (probeOk, '', const <String>[]),
        authOverride: auth,
        keyPairOverride: keyPair,
      ),
    ));
    await tester.pumpAndSettle();
  }

  // ---- create（首设备：探测空名称表 → 自动建钥 → 名字 → 设备名 → …）----

  testWidgets('golden: 向导1.1.1-身份名字步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, keyPair: _goldenKeyPair); // 空名称表 → create，自动进入步骤 1
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.1_name.png'));
  });

  testWidgets('golden: 向导1.1.2-对方名字步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, keyPair: _goldenKeyPair); // 空名称表 → create，自动进入步骤 1
    await tester.enterText(find.byType(TextField), 'Lukas'); // 本人名字（必填）
    await tester.tap(find.text('下一步')); // 名字 → 对方名字页
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.2_peer_name.png'));
  });

  testWidgets('golden: 向导1.1.3-接入口令步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester);
    await tester.enterText(find.byType(TextField), 'Lukas'); // 本人名字（必填）
    await tester.tap(find.text('下一步')); // 名字 → 对方名字页
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alice'); // 对方名字（必填）
    await tester.tap(find.text('下一步')); // 自动登记 → 口令页
    await tester.pumpAndSettle();
    // enroll 成功的 SnackBar 停留 4 秒：等其消失，截图不含临时通知
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.3_passphrase.png'));
  });

  testWidgets('golden: 向导1.1.4-PIN 步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester);
    await tester.enterText(find.byType(TextField), 'Lukas'); // 本人名字（必填）
    await tester.tap(find.text('下一步')); // 名字 → 对方名字页
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alice'); // 对方名字（必填）
    await tester.tap(find.text('下一步')); // 自动登记 → 口令页
    await tester.pumpAndSettle();
    // enroll 成功的 SnackBar 停留 4 秒：等其消失，避免遮挡「下一步」且截图不含临时通知
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456'); // 口令
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.4_pin.png'));
  });

  testWidgets('golden: 向导1.1.6-完成步骤（create）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, auth: fakeAuth);
    await tester.enterText(find.byType(TextField), 'Lukas'); // 本人名字（必填）
    await tester.tap(find.text('下一步')); // 名字 → 对方名字页
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alice'); // 对方名字（必填）
    await tester.tap(find.text('下一步')); // 自动登记 → 口令页
    await tester.pumpAndSettle();
    // enroll 成功的 SnackBar 停留 4 秒：等其消失，避免遮挡后续「下一步」
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456'); // 口令
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    // PIN 页两个输入框都空 → 底部按钮标签即"跳过"（不再弹确认框，老板 2026-09-13）
    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.1.6_done.png'));
  });

  testWidgets('向导完成：弹出欢迎对话框（欢迎词 + 唯一「开始聊天」按钮）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, auth: fakeAuth);
    await tester.enterText(find.byType(TextField), 'Lukas'); // 本人名字（必填）
    await tester.tap(find.text('下一步')); // 名字 → 对方名字页
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alice'); // 对方名字（必填）
    await tester.tap(find.text('下一步')); // 自动登记 → 口令页
    await tester.pumpAndSettle();
    // enroll 成功的 SnackBar 停留 4 秒：等其消失，避免遮挡后续「下一步」
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456'); // 口令
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过')); // PIN 页两空 → 底部按钮=跳过 → 完成
    await tester.pumpAndSettle();
    expect(find.text('🎉 成功创建我的领地'), findsOneWidget); // 对话框标题（create）
    expect(find.text('仅限两人，所有消息端到端加密，确保绝对隐私！进入秘境，开始聊天吧。'), findsOneWidget);
    expect(find.text('进入秘境'), findsOneWidget); // 唯一按钮（点外面不关闭）
  });

  // ---- join（后续设备：探测到 personA → 身份 → 邀请码 → …）----

  testWidgets('golden: 向导1.2.1-身份选择步骤（join）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, probeNames: {'personA': 'Lukas'}); // 非空 → join 步骤 1
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.2.1_identity.png'));
  });

  testWidgets('golden: 向导1.2.3-邀请码步骤（join）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    await pumpSetup(tester, probeNames: {'personA': 'Lukas'});
    await tester.tap(find.text('Lukas')); // 选身份（自动进邀请码页）
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.2.3_invite.png'));
  });

  // ---- offline（密保信封导入：口令页次级入口，不再走 AppBar 菜单）----

  testWidgets('golden: 向导1.3.1-密保信封步骤（offline）', (WidgetTester tester) async {
    _usePhoneSize(tester);
    // 信封入口仅 join（第二/三台设备）口令页显示：探测到 personA → 身份（自动进邀请码）→ 口令页
    await pumpSetup(tester, probeNames: {'personA': 'Lukas'});
    await tester.tap(find.text('Lukas')); // 选身份（自动进邀请码页）
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'INVITE-ABC'); // 邀请码（校验非空）
    await tester.tap(find.text('下一步')); // 邀请码 → 口令页
    await tester.pumpAndSettle();
    // 口令页底部「改用线下密保信封」→ offline 首步即密保信封粘贴页
    await tester.tap(find.text('改用线下密保信封'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SetupPage), matchesGoldenFile('goldens/setup_step1.3.1_envelope.png'));
  });

  testWidgets('向导 ⋯ 菜单：退出秘境确认弹窗（不触发 exit）', (WidgetTester tester) async {
    await pumpSetup(tester, keyPair: _goldenKeyPair); // 空名称表 → create 向导
    await tester.pumpAndSettle();
    // 打开右上角 ⋯ 菜单（语言 / 退出秘境）
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出秘境'));
    await tester.pumpAndSettle();
    // 确认弹窗显示（不点确认——exit(0) 会终止测试进程）
    expect(find.text('退出秘境？'), findsOneWidget);
    expect(find.text('将在本设备上退出 Einz 秘境。'), findsOneWidget);
    // 点取消关闭弹窗（不触发 exit）
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('退出秘境？'), findsNothing);
  });
}
