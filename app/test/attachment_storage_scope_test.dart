// 附件存储模式切换的**作用域**回归（老板 2026-10-14）。
//
// 两件事必须同时成立：
// ① 模式是 per-space 设置（`space.<spaceId>.attachment_storage`，见
//    multi_space_isolation_test.dart「per-space 设置互不干扰」）——只对当前秘境生效；
// ② 切回「远程托管」时只清**当前空间**已留存的明文。此前 chat_page 误用全局
//    AttachmentStore.clear()，会把其它空间的明文缓存一并删掉，与那些空间自己的
//    「本地保存」设置矛盾（不是数据丢失——消息按需重下，但设置名不副实）。
//
// 本测试守住 ② 的调用点（菜单 → 附件存储 → 选远程托管 → 提交）：
// 当前空间的明文被清、其它空间的原样保留、两端设置各自不变。
//
// 另一面（本地性）：模式只存本设备 app_state，**不上传秘境服务器**——服务端没有
// 任何相关端点（PROTOCOL.md 无此接口），一台设备一个选择，伴侣那台可以不一样。
//
// 实现注意：AttachmentStore 走 MethodChannel（'einz/store'），而 testWidgets 的
// FakeAsync 区域里 channel 响应不流动——种子落盘与最终断言都必须包在
// `tester.runAsync` 里（否则 await 直接死锁，10 分钟超时；2026-10-15 实测教训，
// 同 chat_quote_video_test 的 settleRealAsync 套路）。

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/attachment_storage_settings.dart';
import 'package:einz/data/attachment_store.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/space_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
// disableAnimationsInTests 也住在这个 helper 里（本文件不再用 settleRealAsync）
import 'real_async_settle.dart';

/// 最小 fake：只补 ChatPage 启动/刷新会打的端点（其余真连 http://fake 也是
/// widget 测试下秒返 400，被各处 try/catch 吃掉）。
class _FakeApi extends ApiClient {
  _FakeApi() : super('http://fake');

  @override
  Future<
          ({
            List<MessageEnvelope> messages,
            List<Map<String, dynamic>> attachmentsMeta,
            int lastSequence,
            bool hasMore,
          })>
      sync(String token, {int after = 0, int limit = 100}) async =>
          (
            messages: const <MessageEnvelope>[],
            attachmentsMeta: const <Map<String, dynamic>>[],
            lastSequence: 0,
            hasMore: false,
          );

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => [
        {
          'entrance_id': 'dev-a',
          'entrance_name': 'iPhone',
          'member_id': 'member-a',
          'connected_at': DateTime.now().millisecondsSinceEpoch,
          'status': 'active',
        },
      ];

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-a',
        entrances: const [
          SpaceEntrance(entranceId: 'dev-a', memberId: 'member-a', status: 'active'),
        ],
      );

  @override
  Future<NotifyEmailStatus> getNotifyEmail(String token) async =>
      NotifyEmailStatus(state: 'none');
}

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

/// 打开「附件存储」选择器：菜单 → 更多设置 → 附件存储行（老板 2026-10-15 起
/// 附件存储从顶层菜单迁进「更多设置」二级弹层；两段都有错峰延迟）。
Future<void> _openStorageSheet(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(_zh.chatPageMenuMoreSettings));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_zh.chatPageMenuMoreSettings));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_zh.chatPageMoreSettingsStorage));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

/// 提交「远程托管」后应弹出确认弹窗（老板 2026-10-15）：标题=选项名「远程托管」、
/// 内容=删除警示；点确认才放行。返回前把弹窗点掉。
Future<void> _confirmSecuredDialog(WidgetTester tester) async {
  // 弹层关闭后有 300ms 错峰才开 dialog——pumpAndSettle 推不到定时器，显式推过去
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  expect(find.text(_zh.chatPageAttachmentStorageSecured), findsOneWidget,
      reason: '确认弹窗标题应为选项名「远程托管」');
  expect(find.text(_zh.chatPageAttachmentStorageWarnClear), findsOneWidget,
      reason: '确认弹窗内容应为删除警示');
  await tester.tap(find.text(_zh.confirm));
  await tester.pumpAndSettle();
}

/// onApply 的 clearSpace 是**在 fake 区发起的真实文件 I/O**——完成量要靠
/// runAsync（真实事件 loop，I/O 在此交付）与 pump（fake 微任务，续体在此
/// 运行）交替几轮才能推回来。不能直接用 settleRealAsync：它见没有转圈就
/// 第一轮 break，窗口不够（2026-10-15 实测：onApply 永远完不成、弹层不关）。
Future<void> _settleFileIo(WidgetTester tester) async {
  for (var round = 0; round < 5; round++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
  }
  await tester.pumpAndSettle();
}

void main() {
  disableAnimationsInTests();
  setUpAll(() async {
    await sodium();
  });
  // 会话注册表是进程级静态的：逐用例复位
  setUp(() => SpaceSessions.clear());

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('einz_storage_scope');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // AttachmentStore 的目录由自定义通道 'einz/store' 提供（原生侧返回"不备份"目录）
    messenger.setMockMethodCallHandler(
      const MethodChannel('einz/store'),
      (call) async => call.method == 'getStoredDir' ? tempDir.path : null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('einz/store'), null);
      AttachmentStore.resetForTest();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    AttachmentStore.resetForTest();
  });

  testWidgets('切回远程托管只清当前空间的明文，其它空间的原样保留', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final spaceKey = await generateSpaceKey();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-a',
        entranceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeApi(),
        enableWs: false,
        memberId: 'member-a',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 两个空间都选「本地保存」，并各留一份明文。
    // channel/IO 的 await 必须在 runAsync 里跑（见文件头注释）。
    late File fileA;
    late File fileB;
    await tester.runAsync(() async {
      await AttachmentStorageSettings(db, spaceId: 'space-a').save('stored');
      await AttachmentStorageSettings(db, spaceId: 'space-b').save('stored');
      fileA = (await AttachmentStore.pathFor('space-a', 'msg-a', 'jpg'))!;
      fileB = (await AttachmentStore.pathFor('space-b', 'msg-b', 'jpg'))!;
      await fileA.writeAsString('plaintext-a');
      await fileB.writeAsString('plaintext-b');
    });

    await _openStorageSheet(tester);
    // 选「远程托管」→ 提交 → **确认弹窗**（标题=选项名、内容=警示）→ 确认
    await tester.tap(find.text(_zh.chatPageAttachmentStorageSecured));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageAttachmentStorageSubmit));
    await _confirmSecuredDialog(tester);
    await _settleFileIo(tester);

    await tester.runAsync(() async {
      // ① 当前空间（space-a）的明文被清、设置变 secured
      expect(await fileA.exists(), isFalse,
          reason: '当前空间切回远程托管应清掉它的留存明文');
      expect(await AttachmentStorageSettings(db, spaceId: 'space-a').load(),
          'secured');
      // ② 其它空间（space-b）的明文原样保留、设置不变
      expect(await fileB.exists(), isTrue,
          reason: '其它空间的明文缓存不该被误删（它的设置仍是本地保存）');
      expect(await AttachmentStorageSettings(db, spaceId: 'space-b').load(),
          'stored');
    });
  });

  testWidgets('勾选「应用于本机所有秘境」：所有空间的明文都被清、设置都变',
      (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final spaceKey = await generateSpaceKey();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-a',
        entranceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeApi(),
        enableWs: false,
        memberId: 'member-a',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    // 两个空间都选「本地保存」，并各留一份明文
    late File fileA;
    late File fileB;
    await tester.runAsync(() async {
      await AttachmentStorageSettings(db, spaceId: 'space-a').save('stored');
      await AttachmentStorageSettings(db, spaceId: 'space-b').save('stored');
      fileA = (await AttachmentStore.pathFor('space-a', 'msg-a', 'jpg'))!;
      fileB = (await AttachmentStore.pathFor('space-b', 'msg-b', 'jpg'))!;
      await fileA.writeAsString('plaintext-a');
      await fileB.writeAsString('plaintext-b');
    });

    await _openStorageSheet(tester);
    // 勾「应用于本机所有秘境」→ 选「远程托管」→ 提交 → 确认弹窗 → 确认
    await tester.tap(find.text(_zh.settingsScopeAll));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageAttachmentStorageSecured));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageAttachmentStorageSubmit));
    await _confirmSecuredDialog(tester);
    // onApply 里清的是**全部空间**的真实文件 I/O（同上一用例）
    await _settleFileIo(tester);

    await tester.runAsync(() async {
      // 两端明文都被清、设置都变 secured（b 的 per-space 覆盖被清除，读全局）
      expect(await fileA.exists(), isFalse, reason: '当前空间明文应被清');
      expect(await fileB.exists(), isFalse,
          reason: '勾选所有秘境后其它空间的明文也应被清（全局 clear）');
      expect(await AttachmentStorageSettings(db, spaceId: 'space-a').load(),
          'secured');
      expect(await AttachmentStorageSettings(db, spaceId: 'space-b').load(),
          'secured');
    });
  });

  testWidgets('确认弹窗点取消：什么都不做（设置与明文原样）', (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final spaceKey = await generateSpaceKey();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-a',
        entranceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _FakeApi(),
        enableWs: false,
        memberId: 'member-a',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    late File fileA;
    await tester.runAsync(() async {
      await AttachmentStorageSettings(db, spaceId: 'space-a').save('stored');
      fileA = (await AttachmentStore.pathFor('space-a', 'msg-a', 'jpg'))!;
      await fileA.writeAsString('plaintext-a');
    });

    await _openStorageSheet(tester);
    await tester.tap(find.text(_zh.chatPageAttachmentStorageSecured));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageAttachmentStorageSubmit));
    // 确认弹窗出现 → 点**取消**
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text(_zh.chatPageAttachmentStorageSecured), findsOneWidget,
        reason: '应弹出确认弹窗');
    await tester.tap(find.text(_zh.cancel));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      // 取消 = 什么都没做：设置仍是 stored、明文还在
      expect(await AttachmentStorageSettings(db, spaceId: 'space-a').load(),
          'stored');
      expect(await fileA.exists(), isTrue, reason: '取消后明文不应被清');
    });
    expect(find.byType(AlertDialog), findsNothing, reason: '弹窗应已关闭');
  });
}
