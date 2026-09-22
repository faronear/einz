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
import 'package:einz/lock_page.dart';
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
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  // 口令入口现在收在「高级」底部弹层里（对话页菜单 → 高级 → 修改口令）
  await tester.tap(find.text('高级'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('修改口令'));
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

/// 点「修改」即生效——**不再有第二个确认弹窗**（老板 2026-09-15：两个叠着累赘）。
Future<void> _confirmChange(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '修改'));
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

    // 抬头为品牌名（不显示空间 ID）；红绿灯已移入顶部条「我的」灯三态
    // （enableWs:false → ws 未建立 → 我的灯为灰色「未连接服务」）
    expect(find.text('我的秘境'), findsOneWidget);
    expect(find.text('离线'), findsNothing); // AppBar 红绿灯文字已随红绿灯移除
    // 顶部条「我的」灯三态：未连接服务（ws null）→ 灰色
    final myDot = tester.widget<Icon>(find.byIcon(Icons.circle).last);
    expect(myDot.color, Colors.grey);
    // 对话顶部条：身份名字为空时不显示文本（未传 personName/peerName → 只留在线圆点）
    expect(find.text('未设置'), findsNothing);

    // 打开顶栏菜单
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    // 菜单应包含各功能项（「导出完整备份」已按老板决策移除）
    // 口令/重置收在「高级」二级弹层里，菜单里只出现「高级」
    expect(find.text('高级'), findsOneWidget);
    // 我的身份/设备名称（未传 → 显示「未设置」）+ 退出秘境
    expect(find.text('我的身份'), findsOneWidget);
    expect(find.text('本机名称'), findsOneWidget);
    expect(find.text('退出秘境'), findsOneWidget);
    expect(find.text('我的头像'), findsOneWidget); // 头像菜单项
    expect(find.text('高级'), findsOneWidget);
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
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsOneWidget);

    // 输入有效 PIN（两次一致）——限定在弹窗内查找，避免匹配聊天页消息输入框
    // （本机未设 PIN → 弹窗只有两框：新 PIN / 确认 PIN）
    final pinFields =
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(pinFields.at(0), '123456');
    await tester.enterText(pinFields.at(1), '123456');
    // 点"提交"→ 直接设置（不再有二次确认弹窗——老板 2026-09-14 删除）
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();

    // 不应有任何异常（若 setPin/async UI 竞态触发 _dependents.isEmpty 则此处失败）
    expect(tester.takeException(), isNull);
    // 弹窗应已关闭，锁已落盘
    expect(find.text('设置锁屏码'), findsNothing);
    expect(await AppLockService(db).isSetup, true);
  });

  testWidgets('有 PIN 时改码：不填/填错旧码都报错不动锁；相同新码也不设置', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();
    // 先设好一个 PIN（改码场景的前提）
    await AppLockService(db).setPin('123456',
        payload: AppLockPayload(
          spaceKeyB64: base64Encode(spaceKey),
          spaceId: 'space-demo',
          deviceId: 'dev-a',
          token: 'tok',
        ));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    // 已设 PIN → 多出「当前锁屏码」框（共 3 框：旧/新/确认）
    final fields =
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    expect(fields.evaluate().length, 3);

    // 1) 旧码留空 → 红字要求先输入旧码，不动锁
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('请先输入当前锁屏码'), findsOneWidget);
    expect(await AppLockService(db).isSetup, true);

    // 2) 旧码填错 → 红字"当前锁屏码错误"，不动锁
    await tester.enterText(fields.at(0), '000000');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('当前锁屏码错误'), findsOneWidget);
    expect(await AppLockService(db).isSetup, true);

    // 3) 旧码正确、新码与旧码相同 → 红字提示，不真去设置
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), '123456');
    await tester.enterText(fields.at(2), '123456');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('新锁屏码与当前锁屏码相同，未作修改'), findsOneWidget);
    expect(await AppLockService(db).isSetup, true);

    // 4) 旧码正确 + 新码留空 → 才进清空确认；点取消不动锁
    await tester.enterText(fields.at(1), '');
    await tester.enterText(fields.at(2), '');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('清空锁屏码？'), findsOneWidget);
    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsOneWidget); // 设置弹窗仍在
    expect(await AppLockService(db).isSetup, true, reason: '取消不清锁');
  });

  testWidgets('有 PIN 时清空锁屏码：菜单项立即刷新（不再显示「已设置」）', (WidgetTester tester) async {
    // 回归：清空成功后弹窗也 pop(true)，调用方此前写死 _hasPin=true——
    // 锁已清但菜单仍显示「锁屏码 已设置」（老板 2026-09-15 实测）。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();
    await AppLockService(db).setPin('123456',
        payload: AppLockPayload(
          spaceKeyB64: base64Encode(spaceKey),
          spaceId: 'space-demo',
          deviceId: 'dev-a',
          token: 'tok',
        ));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    final fields =
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    // 旧码正确 + 新码两栏留空 → 清空确认 → 确认
    await tester.enterText(fields.at(0), '123456');
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('确认')));
    await tester.pumpAndSettle();

    expect(find.text('设置锁屏码'), findsNothing, reason: '清空成功后设置弹窗应关闭');
    expect(await AppLockService(db).isSetup, false, reason: '锁包应已删除');
    // 打开菜单：锁屏码项不应再有「已设置」尾缀（回归点——此前仍显示已设置）
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('已设置'), findsNothing,
        reason: '清空后菜单项应只显示「锁屏码」，不带「已设置」尾缀');
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
    await tester.tap(find.byIcon(Icons.menu));
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

    // 菜单项较多（12 项 + 分隔线）会超出默认 800×600 测试视口，「退出秘境」落在
    // y≈616 点不到；真机屏高（852）能完整显示，所以这里也把测试视口调高。
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 打开菜单 → 点「退出秘境」
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出秘境'));
    await tester.pumpAndSettle();
    // 确认弹窗显示（不点确认——exit(0) 会终止测试进程）
    expect(find.text('退出秘境？'), findsOneWidget);
    expect(find.text('即将在本机上退出秘境。'), findsOneWidget);
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

  testWidgets('无 PIN 时两空提交：不报至少6位、不写盘，只顶部提示一句', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsOneWidget); // 弹窗标题
    // 两空点「提交」：本来就没设 PIN → 直接返回（老板 2026-09-14）——不弹清空确认、
    // 不调后台、不做任何写盘，只在顶部通知里说一句
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('清空锁屏码？'), findsNothing);
    expect(find.text('锁屏码为空，下次启动可直接进入秘境'), findsOneWidget); // 顶部通知
    expect(find.text('设置锁屏码'), findsOneWidget); // 弹窗保持原样
    final lock = AppLockService(db);
    expect(await lock.isSetup, false);
    expect(await lock.hasConfig, false, reason: '本来就没锁可清：不做任何写盘');
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

  testWidgets('修改口令：提交即执行，不再弹第二个确认弹窗', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 服务器已有密保箱 → 走普通"修改"口径（非重建）
    await _openChangePassphraseDialog(tester, db,
        oldPassphrase: 'oldpass1', spaceKey: spaceKey);

    // 输入新口令 + 确认（匹配）；旧口令留空 → 应红字"旧口令错误"，不改、不弹二次确认
    await _enterDialogFields(tester, newPass: 'newpass123');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('修改密保口令？'), findsNothing, reason: '不应再弹第二个确认弹窗');
    expect(find.text('旧口令错误'), findsOneWidget, reason: '旧口令没填应红字报出');
  });

  testWidgets('修改口令：新口令不满足强度（长度/字母数字）→ 红字拦截，不弹显性确认', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 服务器已有密保箱 → 走普通"修改"口径（非重建）
    await _openChangePassphraseDialog(tester, db,
        oldPassphrase: 'oldpass1', spaceKey: spaceKey);

    // 7 位（不足 8）：点提交 → 红字拦截，不弹第二个确认弹窗
    await _enterDialogFields(tester, newPass: 'short7!');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('口令不得少于 8 位'), findsOneWidget, reason: '不足 8 位应红字提醒');
    expect(find.text('修改密保口令？'), findsNothing, reason: '校验未过不应进确认');

    // 8 位纯数字：放行（老板 2026-09-15：只卡长度，不卡字符种类）
    await _enterDialogFields(tester, newPass: '12345678');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('口令不得少于 8 位'), findsNothing, reason: '够 8 位就不该再报长度');

    // 满足策略：不再有第二个确认弹窗——点「修改」即执行（旧口令没填会在执行时报红字）
    await _enterDialogFields(tester, newPass: 'new-pass-2026');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect(find.text('口令不得少于 8 位'), findsNothing, reason: '满足策略后旧红字不应残留');
    expect(find.text('修改密保口令？'), findsNothing, reason: '不再弹第二个确认弹窗');
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
    await tester.tap(find.byIcon(Icons.menu));
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

    // profile 应已更新（改名后 _saveProfile 按当前空间写入）
    final p = await AppLockService(db).loadProfile(spaceId: 'space-demo');
    expect(p['personName'], 'Alice', reason: '改名应同步写本地 profile');

    // 模拟重启：新 ChatPage 实例（不带名字）→ 从 profile 恢复新名字
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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

  testWidgets('本机信息弹窗：标题/公钥标签带「本秘境」限定、公钥置顶+复制、空名保存红字警示', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    final api = _FakeApi();

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本机名称'));
    await tester.pumpAndSettle();

    // 多空间（老板 2026-09-22）：名称与公钥都是**本秘境**的（同一台设备每个秘境一套），
    // 标题/标签都必须带这个限定，弹窗顶部还要有一行说明
    expect(find.text('本机信息（本秘境）'), findsOneWidget, reason: '弹窗标题应限定在本秘境');
    expect(find.text('名称与公钥都属于当前秘境——同一台设备在别的秘境是另一套。'), findsOneWidget,
        reason: '应说明该名称/公钥只属于本秘境');
    expect(find.text('本秘境里的公钥'), findsOneWidget, reason: '公钥标签应限定在本秘境');
    expect(find.text('dGVzdC1wdWJrZXk='), findsOneWidget, reason: '公钥值应显示在只读框内');
    expect(find.byIcon(Icons.copy), findsOneWidget, reason: '公钥框右侧应有复制按钮');
    expect(find.text('本秘境里的名称'), findsWidgets, reason: '输入框标签应限定在本秘境');

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

    // 不合规字符（空格、标点）→ 红字警示并停留（老板 2026-09-16：设备名只允许
    // 中文字/英文字母/数字/`_`/`-`）
    await tester.enterText(dialogField, 'My Phone!');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('只能用中文字、英文字母、数字、下划线(_)、中划线(-)'), findsOneWidget,
        reason: '含空格/感叹号的设备名保存应红字警示');

    // 超长（>32）→ 红字警示
    await tester.enterText(dialogField, 'a' * 33);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('最多 32 个字符'), findsOneWidget, reason: '超长设备名应红字警示');

    // 开始填写即消红字
    await tester.enterText(dialogField, '我的手机');
    await tester.pumpAndSettle();
    expect(find.text('名称不能为空'), findsNothing, reason: '开始填写后红字应消失');

    // 有效名称 → 保存成功关闭弹窗（400ms 延迟 dispose 不红屏）
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('本机信息（本秘境）'), findsNothing, reason: '保存成功应关闭弹窗');
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
    await tester.tap(find.byIcon(Icons.menu));
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

    // 不合规字符（空格、@）→ 红字警示并停留（老板 2026-09-16：名字只允许
    // 中文字/英文字母/数字/`_`/`-`/emoji）
    await tester.enterText(dialogField, 'Mr Lukas');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('只能用中文字、英文字母、数字、下划线(_)、中划线(-)和表情符'), findsOneWidget,
        reason: '含空格的名字保存应红字警示');

    // 超长（>32）→ 红字警示
    await tester.enterText(dialogField, 'a' * 33);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('最多 32 个字符'), findsOneWidget, reason: '超长名字应红字警示');

    // 填写即消红字 → 保存成功关窗（名字用带 emoji 的——与设备名规则的差别：
    // 表情符在人名里是允许的）
    await tester.enterText(dialogField, '阿猪\u{1F437}_01');
    await tester.pumpAndSettle();
    expect(find.text('名字不能为空'), findsNothing, reason: '开始填写后红字应消失');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('我的个人资料'), findsNothing, reason: 'emoji 名字应保存成功并关闭弹窗');
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

  testWidgets('改口令：新口令与旧口令相同 → 红字，不进确认、不上传', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    final api = await _openChangePassphraseDialog(
        tester, db,
        oldPassphrase: 'oldpass1234',
        spaceKey: spaceKey);

    await _enterDialogFields(tester, oldPass: 'oldpass1234', newPass: 'oldpass1234');
    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();

    expect(find.text('新口令与旧口令相同，未作修改'), findsOneWidget, reason: '新旧相同应红字');
    expect(find.text('修改密保口令？'), findsNothing, reason: '新旧相同不该进显性确认');
    expect(api.uploadedPackage, isNull, reason: '新旧相同不得上传');
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

    // 无密保箱 = 重建路径：同样不再弹第二个确认（原来是"重建密保箱？"确认框）
    expect(find.text('重建密保箱？'), findsNothing, reason: '不再弹第二个确认弹窗');
    expect(find.text('修改密保口令？'), findsNothing);

    // 旧口令为空也放行：直接上传 rotated 包重建
    expect(api.uploadedRotated, isTrue, reason: '重建同样传 rotated: true（广播口令变更）');
    expect(api.uploadedPackage, isNotNull, reason: '应上传重建后的密保箱');

    final reopened = await KeyEscrowService(ApiClient('http://fake'))
        .openPackage(passphrase: 'newpass123', envelope: api.uploadedPackage!);
    expect(reopened.spaceKeyB64, base64Encode(spaceKey), reason: '箱子仍是同一把 Space Key');
    expect(find.text('修改口令'), findsNothing, reason: '成功应关闭弹窗');
  });

  testWidgets('未设 PIN：顶栏无锁屏入口，切后台再回前台也不进锁屏页', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync + _hasPin 读取完成

    // 手动锁屏入口：没设 PIN 就不摆（按了也只能进"尚未设置锁屏码"的死胡同）
    expect(find.byIcon(Icons.lock_outline), findsNothing);

    // 自动锁屏入口：切后台再回前台 → 不锁（老板 2026-09-20：没 PIN 就不进锁屏页）
    // 注：测试用假时钟，LockTimer 读的是真实 DateTime.now()，此处不便造"离开够久"；
    // 本例断言的是"无 PIN 时无论计时如何都不进锁屏页"。
    // 生命周期状态机有合法转移约束（resumed 只能由 inactive/detached 转来），
    // 按真实序列走：paused → hidden → inactive → resumed
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(LockPage), findsNothing);
    expect(find.text('尚未设置锁屏码（为空时不启用）'), findsNothing);
  });

  testWidgets('已设 PIN：顶栏锁屏入口进的是严格锁屏（返回箭头/返回手势都挡掉）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    await AppLockService(db).setPin('123456',
        payload: AppLockPayload(
          spaceKeyB64: base64Encode(spaceKey),
          spaceId: 'space-demo',
          deviceId: 'dev-a',
          token: 'tok',
        ));

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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
    await tester.pump(const Duration(milliseconds: 300)); // 等 _hasPin 刷新出锁屏入口

    await tester.tap(find.byIcon(Icons.lock_outline));
    await tester.pumpAndSettle();

    expect(find.byType(LockPage), findsOneWidget);
    // 与冷启动锁屏、切后台自动锁同口径：必须输对 PIN 才回聊天
    expect(find.byType(BackButton), findsNothing);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, false);
  });

  testWidgets('高级：破坏性入口改为空间级「退出并清除这个空间」（不再整机重置）',
      (WidgetTester tester) async {
    // 老板 2026-09-22：多空间下站在某个空间里点破坏性入口，用户想的是"结束这个空间"，
    // 不该顺手抹掉本机上的其他空间 → 聊天页这格降级为空间级，整机清理由空间列表负责。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();
    // 预置 profile（含设备名——闸门第一道要它，否则退化为固定确认词）
    await AppLockService(db).saveProfile(
        spaceId: 'space-demo', personName: 'Lukas', peerName: 'Alice', deviceName: 'iPhone');

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
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
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();
    expect(find.text('退出并清除这个空间'), findsOneWidget, reason: '空间级文案');
    expect(find.text('重置设备'), findsNothing, reason: '整机重置不该出现在单个空间里');

    await tester.tap(find.text('退出并清除这个空间'));
    await tester.pumpAndSettle(); // 弹层关闭 → 300ms 错开 → 确认弹窗
    expect(find.text('退出并清除这个空间？'), findsOneWidget, reason: '闸门弹窗（设备名 + 锁屏码）');
    expect(find.text('输入「iPhone」以确认'), findsOneWidget, reason: '闸门要求输入本机设备名');
  });
}
