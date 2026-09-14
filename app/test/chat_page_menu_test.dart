// 回归测试：顶栏菜单 → PIN 菜单项 → 返回 不应触发
// `InheritedElement.debugDeactivated` 的 `_dependents.isEmpty` 断言崩溃
// （MenuRoute 与 DialogRoute 在 Overlay 中交叉卸载导致，见 git 记录）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回编排好的加密消息（模拟 Server 分配
/// server_sequence；默认空——只测菜单交互，不涉网络）。
class _FakeApi extends ApiClient {
  _FakeApi({this.messages = const [], this.escrowFile}) : super('http://fake');

  final List<MessageEnvelope> messages;

  /// 假口令密保箱 + 上传捕获（修改口令测试用）。
  /// 上传成功后 getKeyEscrow 返回新上传的包且 updatedAt 推进
  /// （模拟服务端 rotated 推进；普通重传不推进）。
  final PassphraseEnvelope? escrowFile;
  PassphraseEnvelope? uploadedPackage;
  bool? uploadedRotated;
  String? uploadedPassphraseHash;

  @override
  Future<({PassphraseEnvelope? file, int? updatedAt})> getKeyEscrow(String token) async {
    return (
      file: uploadedPackage ?? escrowFile,
      updatedAt: uploadedPackage == null ? 1000 : 2000,
    );
  }

  @override
  Future<void> uploadKeyEscrow(
    PassphraseEnvelope package,
    String token, {
    String? passphraseHash,
    bool rotated = false,
  }) async {
    uploadedPackage = package;
    uploadedRotated = rotated;
    uploadedPassphraseHash = passphraseHash;
  }

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    var seq = after;
    final withSeq = <MessageEnvelope>[
      for (final env in messages)
        () {
          seq++;
          return MessageEnvelope.fromJson({...env.toJson(), 'server_sequence': seq});
        }(),
    ];
    return (
      messages: withSeq,
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: seq,
      hasMore: false,
    );
  }

  @override
  Future<void> updatePersonName(String personName, String token) async {
    // 改名成功（无网络，供保存路径测试）
  }

  @override
  Future<void> updateDeviceName(String deviceName, String token) async {
    // 改设备名成功（无网络，供保存路径测试）
  }
}

// ── 修改口令：辅助（弹窗打开/输入/确认）──

/// 造一个"服务器已有密保箱"的 fake：该箱用 [passphrase] 加密 [spaceKey]。
/// 不调用（`_FakeApi()`）即模拟"服务器无密保箱"的重建路径。
Future<_FakeApi> _fakeWithEscrow(Uint8List spaceKey, String passphrase) async =>
    _FakeApi(
      escrowFile: await KeyEscrowService(ApiClient('http://fake')).createPackage(
        passphrase: passphrase,
        spaceKeyB64: base64Encode(spaceKey),
        spaceId: 'space-demo',
        keyVersion: 1,
      ),
    );

/// 聊天页 + 密保口令弹窗打开（返回 fake api 供断言）。
/// [spaceKey] 传入以便调用方断言「上传包解出的 Space Key 一致」。
/// [oldPassphrase] 为空 = 服务器无密保箱（走"用新口令重建"路径）。
Future<_FakeApi> _openChangePassphraseDialog(WidgetTester tester, LocalDatabase db,
    {String? oldPassphrase, required Uint8List spaceKey}) async {
  final api = oldPassphrase == null
      ? _FakeApi()
      : await _fakeWithEscrow(spaceKey, oldPassphrase);
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
      enableWs: false,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
  await tester.tap(find.text('密保口令'));
  await tester.pumpAndSettle();
  return api;
}

/// 弹窗内输入（3 框：旧/新/确认）。
Future<void> _enterDialogFields(WidgetTester tester,
    {String oldPass = '', String newPass = ''}) async {
  final fields =
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
  await tester.enterText(fields.at(0), oldPass);
  await tester.enterText(fields.at(1), newPass);
  await tester.enterText(fields.at(2), newPass);
}

Future<void> _confirmChange(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '修改'));
  await tester.pumpAndSettle();
  final confirmDialog = find.byType(AlertDialog).last;
  await tester.tap(find.descendant(of: confirmDialog, matching: find.text('确认')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await sodium(); // setPin 的 Argon2id/XChaCha20 需要 libsodium
  });

  setUp(() {
    // PIN 设置/清除走 SecureStore（Keychain/Keystore），测试环境用插件 mock
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('顶栏菜单→本机PIN→返回 不崩溃（_dependents.isEmpty 回归）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        enableWs: false, // 测试环境不连真实 WS
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 抬头为品牌名+slogan（不显示空间 ID）；红绿灯已移入顶部条「我的」灯三态
    // （enableWs:false → ws 未建立 → 我的灯为灰色「未连接服务」）
    expect(find.text('Einz 秘境'), findsOneWidget);
    expect(find.text('离线'), findsNothing); // AppBar 红绿灯文字已随红绿灯移除
    // 顶部条「我的」灯三态：未连接服务（ws null）→ 灰色
    final myDot = tester.widget<Icon>(find.byIcon(Icons.circle).last);
    expect(myDot.color, Colors.grey);
    // 对话顶部条：身份名字为空时不显示文本（未传 personName/peerName → 只留在线圆点）
    expect(find.text('未设置'), findsNothing);

    // 打开顶栏菜单
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // 菜单应包含各功能项（「导出完整备份」已按老板决策移除）
    expect(find.text('密保口令'), findsOneWidget);
    // 我的身份/设备名称（未传 → 显示「未设置」）+ 退出秘境
    expect(find.text('我的身份'), findsOneWidget);
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('退出秘境'), findsOneWidget);
    expect(find.text('我的头像'), findsOneWidget); // 头像菜单项
    expect(find.text('密保口令'), findsOneWidget);
    expect(find.text('锁屏码'), findsOneWidget);
    // 点"PIN: 未设置"菜单项
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    // 弹窗应出现（设置启动锁）
    expect(find.text('设置锁屏码'), findsOneWidget);
    // 返回：模拟系统返回键（与真机"返回"一致；barrier/取消按钮均走 Navigator.pop）
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // 不应有任何异常（复现 _dependents.isEmpty 崩溃则此处失败）
    expect(tester.takeException(), isNull);
  });

  testWidgets('本机PIN→输入有效PIN→点设置 不崩溃且锁已落盘', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 打开菜单 → PIN 菜单项
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsOneWidget);

    // 输入有效 PIN（两次一致）——限定在弹窗内查找，避免匹配聊天页消息输入框
    final pinFields =
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(pinFields.at(0), '123456');
    await tester.enterText(pinFields.at(1), '123456');
    // 点"提交"→ 先弹显性确认对话框（设非空 PIN 也要求确认）
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('设置 PIN 锁屏？'), findsOneWidget); // 确认弹窗标题
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 不应有任何异常（若 setPin/async UI 竞态触发 _dependents.isEmpty 则此处失败）
    expect(tester.takeException(), isNull);
    // 弹窗应已关闭，锁已落盘
    expect(find.text('设置锁屏码'), findsNothing);
    expect(await AppLockService(db).isSetup, true);
  });

  testWidgets('改名对话框保存后无红屏（controller 延迟 dispose）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 打开菜单 → 点「我的身份」（未传 personName → 显示"我的身份: 未设置"）
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('我的身份'));
    await tester.pumpAndSettle();
    // 改名对话框输入新名字 → 保存（成功 → 关闭对话框）；
    // 弹窗内含两个输入框：可编辑名字在前、只读性别在后 → 取 .first
    await tester.tap(find.byIcon(Icons.edit)); // 初始只读：先点「编辑」进入可编辑态
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit), findsNothing, reason: '点编辑后按钮应消失');
    await tester.enterText(
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)).first,
        '新名字');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    // 推进虚拟时间触发 400ms 延迟 dispose（TextField 已卸载 → 不再触发红屏断言）
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    // 顶部条我的名字已刷新为新名字
    expect(find.text('新名字'), findsOneWidget);
  });

  testWidgets('退出秘境：确认弹窗显示（不触发 exit）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 打开菜单 → 点「退出秘境」
    await tester.tap(find.byIcon(Icons.more_vert));
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

  testWidgets('回车发送后输入框焦点保持（与图标发送一致）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 聚焦输入框并输入文本
    await tester.enterText(find.byType(TextField), '你好');
    // 回车发送（模拟键盘 done 动作——触发 onSubmitted）
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    // 焦点应保持在输入框（回车发送后 requestFocus 补回）
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('设置 PIN 两空提交 = 设为空（不报"至少4位"，转明文取消锁）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 打开菜单 → PIN: 未设置 → 设置 PIN 弹窗（两个输入框都不输入 = 设为空）
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsOneWidget); // 弹窗标题
    // 两空点「提交」→ 先弹显性确认对话框（防误触——老板要求）
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('清空锁屏码？'), findsOneWidget); // 确认弹窗标题
    expect(find.text('PIN 至少4位'), findsNothing);
    // 点「确认」→ 才执行清除锁（转明文）
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('已清空锁屏码（下次启动直接进入）'), findsOneWidget); // SnackBar
    // 弹窗已关闭；无加密包（isSetup false），明文配置仍在（hasConfig true）
    expect(find.text('设置锁屏码'), findsNothing);
    final lock = AppLockService(db);
    expect(await lock.isSetup, false, reason: '两空提交不设加密锁');
    expect(await lock.hasConfig, true, reason: 'Space Key 明文保留（下次启动直接进入）');
  });

  testWidgets('两空提交：确认弹窗点取消不执行清除（防误触）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 打开菜单 → PIN: 未设置 → 设置 PIN 弹窗（两空）→ 点「提交」→ 确认弹窗
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('清空锁屏码？'), findsOneWidget); // 确认弹窗出现
    // 点「取消」→ 不执行清除：设置弹窗仍在、无 SnackBar
    // （"取消"同时存在于设置弹窗与确认弹窗——用叠在最上的确认弹窗定位）
    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsOneWidget); // 设置弹窗未关闭
    expect(find.text('已清空锁屏码（下次启动直接进入）'), findsNothing);
  });

  testWidgets('解锁重进：ChatPage 不带名字时从 profile 恢复顶部条名字', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 模拟向导完成时已写入 profile（setup _finish 的 saveProfile）
    await AppLockService(db).saveProfile(personName: 'Lukas', peerName: 'Alice', deviceName: 'iPhone');

    // 不带 personName/peerName——模拟 PIN 解锁重进（lock_page._enterChat 不传名字）
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
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pumpAndSettle();
    // 顶部条应恢复两个人的名字（loadProfile 补名）
    expect(find.text('Lukas'), findsOneWidget, reason: '本人名字应从 profile 恢复（顶部条右侧）');
    expect(find.text('Alice'), findsOneWidget, reason: '对方名字应从 profile 恢复（顶部条左侧）');
  });

  testWidgets('修改口令：提交前弹显性确认（取消不执行）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 服务器已有密保箱 → 走普通"修改"口径（非重建）
    await _openChangePassphraseDialog(tester, db,
        oldPassphrase: 'oldpass1', spaceKey: spaceKey);

    // 输入新口令 + 确认（匹配）；旧口令留空（确认弹窗在旧口令验证之前）
    await _enterDialogFields(tester, newPass: 'newpass123');
    // 提交（按钮文本「修改」，弹窗标题「修改口令」）
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('修改密保口令？'), findsOneWidget); // 显性确认弹窗
    // 点取消 → 不执行修改（改口令弹窗仍在）
    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.text('修改口令'), findsWidgets); // 改口令弹窗未关闭
    expect(find.text('修改密保口令？'), findsNothing);
  });

  testWidgets('修改口令：新口令不满足强度（长度/字母数字）→ 红字拦截，不弹显性确认', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 服务器已有密保箱 → 走普通"修改"口径（非重建）
    await _openChangePassphraseDialog(tester, db,
        oldPassphrase: 'oldpass1', spaceKey: spaceKey);

    // 7 位（不足 10）：点提交 → 红字拦截，不弹显性确认弹窗
    await _enterDialogFields(tester, newPass: 'short7!');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('口令不得少于 10 位'), findsOneWidget, reason: '不足 10 位应红字提醒');
    expect(find.text('修改密保口令？'), findsNothing, reason: '校验未过不应进入显性确认');

    // 长度够但只有数字：同样拦截（策略：字母 + 数字）
    await _enterDialogFields(tester, newPass: '1234567890');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('口令需同时包含字母与数字'), findsOneWidget, reason: '缺字母应红字提醒');

    // 满足策略：放行到显性确认
    await _enterDialogFields(tester, newPass: 'new-pass-2026');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('口令不得少于 10 位'), findsNothing, reason: '满足策略后旧红字不应残留');
    expect(find.text('修改密保口令？'), findsOneWidget, reason: '满足策略应进入显性确认');
  });

  testWidgets('菜单改名后写 profile（重启后从 profile 恢复新名字）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();
    // 预置 profile（向导完成时的旧名 personB——老板实测场景）
    await AppLockService(db).saveProfile(personName: 'personB', peerName: 'TUI', deviceName: 'iPhone');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-demo',
        deviceId: 'dev-b',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    // initState loadProfile 补名（personB——顶部条/菜单显示）
    expect(find.text('personB'), findsWidgets);

    // 菜单 → 修改我的身份（菜单项标签：我的身份）→ 输入新名字 → 保存
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的身份'));
    await tester.pumpAndSettle();
    final renameField = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
        .first; // 弹窗内可编辑名字框在前、只读性别框在后
    await tester.tap(find.byIcon(Icons.edit)); // 初始只读：先点「编辑」进入可编辑态
    await tester.pumpAndSettle();
    await tester.enterText(renameField, 'Alice');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // profile 应已更新（改名后 _saveProfile 写入）
    final p = await AppLockService(db).loadProfile();
    expect(p['personName'], 'Alice', reason: '改名应同步写本地 profile');

    // 模拟重启：新 ChatPage 实例（不带名字）→ 从 profile 恢复新名字
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        server: 'https://einz.tic.cc',
        spaceId: 'space-demo',
        deviceId: 'dev-b',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsWidgets, reason: '重启后应从 profile 恢复新名字');
    expect(find.text('personB'), findsNothing, reason: '不应回到旧名 personB');
  });

  testWidgets('我的设备弹窗：标题「我的设备信息」、公钥置顶+复制、空名保存红字警示', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

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
        publicKeyB64: 'dGVzdC1wdWJrZXk=',
        privateKeyB64: 'dGVzdC1wcml2a2V5',
        db: db,
        api: api,
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync 异步完成

    // 菜单 → 我的设备
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的设备'));
    await tester.pumpAndSettle();

    // 标题「我的设备信息」；公钥只读展示（左上角「公钥」标签 + 值）+ 复制按钮；输入框标签「设备名称」
    expect(find.text('我的设备信息'), findsOneWidget, reason: '弹窗标题应为「我的设备信息」');
    expect(find.text('设备公钥'), findsOneWidget, reason: '公钥框左上角应有「公钥」标签');
    expect(find.text('dGVzdC1wdWJrZXk='), findsOneWidget, reason: '公钥值应显示在只读框内');
    expect(find.byIcon(Icons.copy), findsOneWidget, reason: '公钥框右侧应有复制按钮');
    expect(find.text('设备名称'), findsWidgets, reason: '输入框标签应为「设备名称」');

    // 空名点保存 → 红字警示并停留（不静默）；对话框含两个输入框：只读公钥在前、
    // 可编辑设备名在后 → 取 .last
    final dialogField = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
        .first; // 设备名称已排到公钥之前：可编辑设备名框在前、只读公钥在后
    expect(find.byIcon(Icons.edit), findsOneWidget, reason: '初始只读态应有「编辑」按钮');
    await tester.tap(find.byIcon(Icons.edit)); // 点编辑 → 白底可编辑、按钮消失
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit), findsNothing, reason: '点编辑后按钮应消失');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('名称不能为空'), findsOneWidget, reason: '空设备名保存应红字警示');

    // 全空格同样警示
    await tester.enterText(dialogField, '   ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('名称不能为空'), findsOneWidget, reason: '全空格设备名保存应红字警示');

    // 开始填写即消红字
    await tester.enterText(dialogField, '我的手机');
    await tester.pumpAndSettle();
    expect(find.text('名称不能为空'), findsNothing, reason: '开始填写后红字应消失');

    // 有效名称 → 保存成功关闭弹窗（400ms 延迟 dispose 不红屏）
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('我的设备信息'), findsNothing, reason: '保存成功应关闭弹窗');
  });

  testWidgets('我的个人资料弹窗：标题/标签新文案、名字框下性别图标高亮、空名保存红字', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();
    // 预置 profile 带本人性别（模拟向导完成时写入）
    await AppLockService(db).saveProfile(
        personName: 'Lukas', peerName: 'Alice', deviceName: 'Phone', myGender: 'male');

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync + profile load 完成

    // 菜单 → 我的身份（打开个人资料弹窗）
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的身份'));
    await tester.pumpAndSettle();

    // 标题「我的个人资料」、输入框标签「我的名字」、名字框下性别彩色图标（男高亮）
    expect(find.text('我的个人资料'), findsOneWidget, reason: '弹窗标题应为「我的个人资料」');
    expect(find.text('我的名字'), findsWidgets, reason: '输入框标签应为「我的名字」');
    expect(find.text('性别'), findsOneWidget, reason: '名字框下应显示性别标签');
    expect(find.byIcon(Icons.female), findsNothing,
        reason: '只显示本人性别图标，不应显示女图标');
    final maleIcon = tester.widget<Icon>(find.byIcon(Icons.male));
    expect(maleIcon.color, const Color(0xFF3BAFFD), reason: '本人为男：显示天蓝色男图标');

    // 清空名字 → 保存 → 红字警示并停留（弹窗内含两个输入框：可编辑名字在前、
    // 只读性别在后 → 取 .first）
    final dialogField = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
        .first;
    await tester.tap(find.byIcon(Icons.edit)); // 初始只读：先点「编辑」进入可编辑态
    await tester.pumpAndSettle();
    await tester.enterText(dialogField, '');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('名字不能为空'), findsOneWidget, reason: '空名字保存应红字警示（人名专用提示）');

    // 填写即消红字 → 保存成功关窗
    await tester.enterText(dialogField, 'Lukas');
    await tester.pumpAndSettle();
    expect(find.text('名字不能为空'), findsNothing, reason: '开始填写后红字应消失');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('我的个人资料'), findsNothing, reason: '保存成功应关闭弹窗');
  });

  testWidgets('长按菜单预览行对齐：我的消息靠右、对方消息靠左', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi(messages: [
      await encryptMessage(
        plaintext: '我的消息',
        spaceKey: spaceKey,
        spaceId: 'space-demo',
        senderDeviceId: 'dev-a', // 本人
        messageId: 'msg-1',
        keyVersion: 1,
      ),
      await encryptMessage(
        plaintext: '对方消息',
        spaceKey: spaceKey,
        spaceId: 'space-demo',
        senderDeviceId: 'dev-b', // 对方
        messageId: 'msg-2',
        keyVersion: 1,
      ),
    ]);

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 长按我的消息 → 弹窗预览行靠右（与消息流一致）
    await tester.longPress(find.text('我的消息'));
    await tester.pumpAndSettle();
    final mineRow =
        tester.widget<Row>(find.byKey(const ValueKey('messagePreviewRow')));
    expect(mineRow.mainAxisAlignment, MainAxisAlignment.end,
        reason: '我的消息预览行应靠右对齐');
    expect(find.text('引用'), findsOneWidget, reason: '菜单应已弹出');
    // 关闭弹窗（点击遮罩）
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // 长按对方消息 → 预览行靠左
    await tester.longPress(find.text('对方消息'));
    await tester.pumpAndSettle();
    final peerRow =
        tester.widget<Row>(find.byKey(const ValueKey('messagePreviewRow')));
    expect(peerRow.mainAxisAlignment, MainAxisAlignment.start,
        reason: '对方消息预览行应靠左对齐');
    // 关闭弹窗，避免测试结束时挂起的 Route
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
  });

  testWidgets('长按语音消息：菜单预览行显示 播放键+波形+时长 且播放键可点', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 语音消息：载荷 meta 带 25s 时长（无附件——只测菜单预览行的渲染与可点性）
    final voice = await encryptMessage(
      plaintext: encodeMessagePayload('', meta: {kMetaAudioDurationSeconds: 25}),
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderDeviceId: 'dev-a',
      messageId: 'msg-voice-1',
      keyVersion: 1,
      type: 'voice',
    );
    final api = _FakeApi(messages: [voice]);

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
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('25s'), findsOneWidget, reason: '消息流语音气泡应显示时长');

    // 长按 → 菜单预览行与消息流一致：播放键（+波形）+ 时长
    await tester.longPress(find.text('25s'));
    await tester.pumpAndSettle();
    final previewRow = find.byKey(const ValueKey('messagePreviewRow'));
    expect(
      find.descendant(of: previewRow, matching: find.byIcon(Icons.play_circle)),
      findsOneWidget,
      reason: '菜单预览行应显示播放键（与消息流一致）',
    );
    expect(
      find.descendant(of: previewRow, matching: find.text('25s')),
      findsOneWidget,
      reason: '菜单预览行应显示时长',
    );
    expect(find.text('voice'), findsNothing,
        reason: '语音消息不应退化成类型占位文字');
    // 播放键真的可点（走 _playAudioMessage：此处无附件 → 提示元数据缺失）
    final playButton = tester.widget<IconButton>(
        find.descendant(of: previewRow, matching: find.byType(IconButton)));
    expect(playButton.onPressed, isNotNull, reason: '预览行播放键应可点按播放');

    await tester.tapAt(const Offset(20, 20)); // 关闭弹窗
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('改口令：旧口令错 → 红字，不上传', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    final api = await _openChangePassphraseDialog(
        tester, db,
        oldPassphrase: 'oldpass1',
        spaceKey: spaceKey);

    await _enterDialogFields(tester, oldPass: 'wrongpass', newPass: 'newpass123');
    await _confirmChange(tester);

    expect(find.text('旧口令错误'), findsOneWidget, reason: '旧口令错应红字');
    expect(find.text('修改密保口令？'), findsNothing, reason: '未过口令验证不应进显性确认');
    expect(api.uploadedPackage, isNull, reason: '旧口令错不得上传');
  });

  testWidgets('改口令：全流程成功 → 上传 rotated 包（本地不落新口令）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    final api = await _openChangePassphraseDialog(
        tester, db,
        oldPassphrase: 'oldpass1',
        spaceKey: spaceKey);

    await _enterDialogFields(tester, oldPass: 'oldpass1', newPass: 'newpass123');
    await _confirmChange(tester);

    // 成功：上传 rotated 包 + 附新口令哈希；弹窗关闭 + SnackBar
    expect(api.uploadedRotated, isTrue, reason: '修改口令必须传 rotated: true');
    expect(api.uploadedPassphraseHash, isNotNull);
    expect(find.text('修改口令'), findsNothing, reason: '成功应关闭弹窗');
    expect(find.textContaining('口令已修改'), findsOneWidget, reason: '成功 SnackBar');

    // 上传的包：新口令可解开、Space Key 一致、旧口令解不开
    final uploaded = api.uploadedPackage!;
    final reopened = await KeyEscrowService(ApiClient('http://fake'))
        .openPackage(passphrase: 'newpass123', envelope: uploaded);
    expect(reopened.spaceKeyB64, base64Encode(spaceKey));
    expect(() async =>
        await KeyEscrowService(ApiClient('http://fake'))
            .openPackage(passphrase: 'oldpass1', envelope: uploaded),
        throwsFormatException,
        reason: '旧口令不应再解开新密保箱');
  });

  testWidgets('改口令：服务器无密保箱 → 跳过旧口令校验，直接用新口令重建',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    // oldPassphrase 不传 → fake 的 getKeyEscrow 返回 file=null（服务端数据丢失）
    final api = await _openChangePassphraseDialog(tester, db, spaceKey: spaceKey);

    // 只填新口令（旧口令留空——用户可能已不知道旧口令）
    await _enterDialogFields(tester, newPass: 'newpass123');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();

    // 确认文案走"重建"口径，不是普通"修改密保口令？"
    expect(find.text('重建密保箱？'), findsOneWidget, reason: '无密保箱应提示重建');
    expect(find.text('修改密保口令？'), findsNothing);

    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('确认')));
    await tester.pumpAndSettle();

    // 旧口令为空也放行：直接上传 rotated 包重建
    expect(api.uploadedRotated, isTrue, reason: '重建同样传 rotated: true（广播口令变更）');
    expect(api.uploadedPackage, isNotNull, reason: '应上传重建后的密保箱');

    final reopened = await KeyEscrowService(ApiClient('http://fake'))
        .openPackage(passphrase: 'newpass123', envelope: api.uploadedPackage!);
    expect(reopened.spaceKeyB64, base64Encode(spaceKey), reason: '箱子仍是同一把 Space Key');
    expect(find.text('修改口令'), findsNothing, reason: '成功应关闭弹窗');
  });
}
