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
    expect(find.text('EINZ 1+1 私密领地'), findsOneWidget);
    expect(find.text('离线'), findsNothing); // AppBar 红绿灯文字已随红绿灯移除
    // 顶部条「我的」灯三态：未连接服务（ws null）→ 灰色
    final myDot = tester.widget<Icon>(find.byIcon(Icons.circle).last);
    expect(myDot.color, Colors.grey);
    // 对话顶部条：名字为空时不显示文本（未传 personName/peerName → 只留在线圆点）
    expect(find.text('未设置'), findsNothing);

    // 打开顶栏菜单
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // 菜单应包含各功能项（含「导出完整备份」与「修改口令」）
    expect(find.text('导出完整备份'), findsOneWidget);
    // 我的名字/设备名称（未传 → 显示「未设置」）+ 退出应用
    expect(find.text('我的名字: 未设置'), findsOneWidget);
    expect(find.text('设备名称: 未设置'), findsOneWidget);
    expect(find.text('退出应用'), findsOneWidget);
    expect(find.text('头像'), findsOneWidget); // 头像菜单项
    expect(find.text('修改口令'), findsOneWidget);
    expect(find.text('PIN: 未设置'), findsOneWidget);
    // 点"PIN: 未设置"菜单项
    await tester.tap(find.text('PIN: 未设置'));
    await tester.pumpAndSettle();
    // 弹窗应出现（设置启动锁）
    expect(find.text('设置 PIN 锁屏密码'), findsOneWidget);
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
    await tester.tap(find.text('PIN: 未设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置 PIN 锁屏密码'), findsOneWidget);

    // 输入有效 PIN（两次一致）——限定在弹窗内查找，避免匹配聊天页消息输入框
    final pinFields =
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(pinFields.at(0), '123456');
    await tester.enterText(pinFields.at(1), '123456');
    // 点"设置 PIN"
    await tester.tap(find.text('设置 PIN'));
    await tester.pumpAndSettle();

    // 不应有任何异常（若 setPin/async UI 竞态触发 _dependents.isEmpty 则此处失败）
    expect(tester.takeException(), isNull);
    // 弹窗应已关闭，锁已落盘
    expect(find.text('设置 PIN 锁屏密码'), findsNothing);
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

    // 打开菜单 → 点「我的名字」（未传 personName → 显示"我的名字: 未设置"）
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('我的名字'));
    await tester.pumpAndSettle();
    // 改名对话框输入新名字 → 保存（成功 → 关闭对话框）
    await tester.enterText(find.byType(TextField).last, '新名字');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    // 推进虚拟时间触发 400ms 延迟 dispose（TextField 已卸载 → 不再触发红屏断言）
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    // 顶部条我的名字已刷新为新名字
    expect(find.text('新名字'), findsOneWidget);
  });

  testWidgets('退出应用：确认弹窗显示（不触发 exit）', (WidgetTester tester) async {
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

    // 打开菜单 → 点「退出应用」
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出应用'));
    await tester.pumpAndSettle();
    // 确认弹窗显示（不点确认——exit(0) 会终止测试进程）
    expect(find.text('退出应用？'), findsOneWidget);
    expect(find.text('将彻底关闭应用，下次启动需输入 PIN 解锁。'), findsOneWidget);
    // 点取消关闭弹窗（不触发 exit）
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('退出应用？'), findsNothing);
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
    await tester.tap(find.text('PIN: 未设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置 PIN 锁屏密码'), findsOneWidget); // 弹窗标题
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
    expect(find.text('设置 PIN 锁屏密码'), findsNothing);
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
    await tester.tap(find.text('PIN: 未设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置 PIN'));
    await tester.pumpAndSettle();
    expect(find.text('清除 PIN 锁屏？'), findsOneWidget); // 确认弹窗出现
    // 点「取消」→ 不执行清除：设置弹窗仍在、无 SnackBar
    // （"取消"同时存在于设置弹窗与确认弹窗——用叠在最上的确认弹窗定位）
    final confirmDialog = find.byType(AlertDialog).last;
    await tester.tap(find.descendant(of: confirmDialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(find.text('设置 PIN 锁屏密码'), findsOneWidget); // 设置弹窗未关闭
    expect(find.text('已清除 PIN 锁屏（下次启动直接进入）'), findsNothing);
  });
}
