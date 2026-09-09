// 回归测试：顶栏菜单 → PIN 菜单项 → 返回 不应触发
// `InheritedElement.debugDeactivated` 的 `_dependents.isEmpty` 断言崩溃
// （MenuRoute 与 DialogRoute 在 Overlay 中交叉卸载导致，见 git 记录）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回空消息页（只测菜单交互，不涉网络）。
class _FakeApi extends ApiClient {
  _FakeApi() : super('http://fake');

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
    String token, {
    int after = 0,
    int limit = 100,
  }) async {
    return (
      messages: <MessageEnvelope>[],
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: 0,
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

void main() {
  setUpAll(() async {
    await sodium(); // setPin 的 Argon2id/XChaCha20 需要 libsodium
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
    // 点"设置 PIN"→ 先弹显性确认对话框（设非空 PIN 也要求确认）
    await tester.tap(find.text('设置 PIN'));
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
    // 两空点「设置 PIN」→ 先弹显性确认对话框（防误触——老板要求）
    await tester.tap(find.text('设置 PIN'));
    await tester.pumpAndSettle();
    expect(find.text('清除 PIN 锁屏？'), findsOneWidget); // 确认弹窗标题
    expect(find.text('PIN 至少4位'), findsNothing);
    // 点「确认」→ 才执行清除锁（转明文）
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('已清除 PIN 锁屏（下次启动直接进入）'), findsOneWidget); // SnackBar
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

    // 打开菜单 → PIN: 未设置 → 设置 PIN 弹窗（两空）→ 点「设置 PIN」→ 确认弹窗
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('锁屏码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置 PIN'));
    await tester.pumpAndSettle();
    expect(find.text('清除 PIN 锁屏？'), findsOneWidget); // 确认弹窗出现
    // 点「取消」→ 不执行清除：设置弹窗仍在、无 SnackBar
    // （"取消"同时存在于设置弹窗与确认弹窗——用叠在最上的确认弹窗定位）
    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsOneWidget); // 设置弹窗未关闭
    expect(find.text('已清除 PIN 锁屏（下次启动直接进入）'), findsNothing);
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
    await tester.pump(const Duration(milliseconds: 300));

    // 打开菜单 → 密保口令
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('密保口令'));
    await tester.pumpAndSettle();
    // 输入新口令 + 确认（匹配）；旧口令留空（确认弹窗在校验后、旧口令验证前）
    final fields =
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(1), 'newpass');
    await tester.enterText(fields.at(2), 'newpass');
    // 提交（按钮文本与弹窗标题同为"修改口令"——用 FilledButton 精确定位）
    await tester.tap(find.widgetWithText(FilledButton, '修改口令'));
    await tester.pumpAndSettle();
    expect(find.text('修改密保口令？'), findsOneWidget); // 显性确认弹窗
    // 点取消 → 不执行修改（改口令弹窗仍在）
    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.text('修改口令'), findsWidgets); // 改口令弹窗未关闭
    expect(find.text('修改密保口令？'), findsNothing);
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
    expect(find.text('公钥'), findsOneWidget, reason: '公钥框左上角应有「公钥」标签');
    expect(find.text('dGVzdC1wdWJrZXk='), findsOneWidget, reason: '公钥值应显示在只读框内');
    expect(find.byIcon(Icons.copy), findsOneWidget, reason: '公钥框右侧应有复制按钮');
    expect(find.text('设备名称'), findsWidgets, reason: '输入框标签应为「设备名称」');

    // 空名点保存 → 红字警示并停留（不静默）；对话框含两个输入框：只读公钥在前、
    // 可编辑设备名在后 → 取 .last
    final dialogField = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(TextField))
        .last;
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
}
