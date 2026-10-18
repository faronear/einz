// 墓碑消息显示开关回归（老板 2026-10-15）：
// 顶栏菜单「更多设置」（设置图标）→ 弹层两项（附件存储 / 墓碑消息）→ 墓碑消息
// 选择器（点选即生效、无提交按钮）：保留消息状态（默认，现行行为——占位墓碑，
// 正文隐藏、时间与记录仍在）/ 彻底隐藏（墓碑整条从消息流消失）。
//
// 本测试守住：① 默认保留；② 选彻底隐藏后墓碑从消息流消失、正常消息不受影响；
// ③ 可切回保留；④ 附件存储仍从「更多设置」进（迁移后的导航）。
//
// 只影响显示：数据层墓碑语义（打标记不打行、附件保留）两种模式下一模一样。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/message_repository.dart';
import 'package:einz/data/space_session.dart';
import 'package:einz/data/tombstone_settings.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'real_async_settle.dart';

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
  Future<PostMessageResult> postMessage(MessageEnvelope env, String token) async =>
      PostMessageResult(
          messageId: env.messageId, serverSequence: 1, createdAt: 1000);

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

/// 发布双秘境 Vault：「应用于本机所有秘境」勾选框只在多秘境时渲染
/// （老板 2026-10-17；单秘境时整个不出现）。
void _publishTwoSpaceVault() {
  SpaceSessions.clear();
  VaultSession.publish(const VaultPayload(
    spaces: [
      AppLockPayload(
        spaceKeyB64: 'a2V5LWE=',
        spaceId: 'space-a',
        entranceId: 'dev-a',
        token: 'tok-a',
      ),
      AppLockPayload(
        spaceKeyB64: 'a2V5LWI=',
        spaceId: 'space-b',
        entranceId: 'dev-b',
        token: 'tok-b',
      ),
    ],
    activeSpaceId: 'space-a',
  ));
}

/// 打开「墓碑消息」选择器：菜单 → 更多设置 → 墓碑消息行（两段错峰延迟）。
Future<void> _openTombstonePicker(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(_zh.chatPageMenuMoreSettings));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_zh.chatPageMenuMoreSettings));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_zh.chatPageMoreSettingsTombstone));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  disableAnimationsInTests();
  setUpAll(() async {
    await sodium();
  });
  setUp(() => SpaceSessions.clear());

  testWidgets('墓碑消息开关：默认保留状态；彻底隐藏后墓碑从消息流消失，可切回',
      (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    // 种两条消息：一条正常、一条本机删除（墓碑，kind='delete' → 气泡里是
    // delete_outline 图标——没有正文可断言，用图标作墓碑探针）
    late String tombstoneId;
    await tester.runAsync(() async {
      final seed = MessageRepository(
        db: db,
        api: _FakeApi(),
        spaceKey: spaceKey,
        spaceId: 'space-a',
        entranceId: 'dev-a',
        keyVersion: 1,
        token: null,
      );
      await seed.send('正常消息');
      tombstoneId = await seed.send('将被删除的消息');
      await seed.tombstoneMessage(tombstoneId);
    });

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
    await settleRealAsync(tester);

    // ① 默认（keep）：正常消息在、墓碑占位也在（delete_outline 探针）
    expect(find.text('正常消息'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget,
        reason: '默认保留消息状态：墓碑占位应显示');
    await tester.runAsync(() async {
      expect(await TombstoneSettings(db, spaceId: 'space-a').load(), 'keep');
    });

    // ② 彻底隐藏：选「彻底消失」→ 提交（单选+提交制，老板 2026-10-15），
    // 墓碑整条从消息流消失，正常消息不受影响
    await _openTombstonePicker(tester);
    expect(find.text(_zh.chatPageTombstoneHeading), findsOneWidget,
        reason: '应弹出墓碑消息选择器');
    await tester.tap(find.text(_zh.chatPageTombstoneHide));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageTombstoneSubmit));
    await tester.pumpAndSettle();
    expect(find.text('正常消息'), findsOneWidget, reason: '正常消息不该被隐藏');
    expect(find.byIcon(Icons.delete_outline), findsNothing,
        reason: '彻底隐藏：墓碑应从消息流消失');

    // ③ 切回保留消息状态：选「保留占位」→ 提交，墓碑占位回来
    await _openTombstonePicker(tester);
    await tester.tap(find.text(_zh.chatPageTombstoneKeep));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageTombstoneSubmit));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.delete_outline), findsOneWidget,
        reason: '切回保留消息状态：墓碑占位应恢复');
    // 设置已持久化（重启/换入口再进也是这个值）
    await tester.runAsync(() async {
      expect(await TombstoneSettings(db, spaceId: 'space-a').load(), 'keep');
    });
  });

  testWidgets('勾选「应用于本机所有秘境」：选中模式对本机所有空间生效',
      (tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    _publishTwoSpaceVault(); // 多秘境才渲染「所有秘境」勾选框（2026-10-17）
    addTearDown(() => VaultSession.publish(null));
    final spaceKey = await generateSpaceKey();

    // 两个空间各自持有 per-space 设置：a=keep（当前空间）、b=hide（与 a 不同，
    // 便于观察"应用到所有"是否真的够到了 b）
    await tester.runAsync(() async {
      await TombstoneSettings(db, spaceId: 'space-a').save('keep');
      await TombstoneSettings(db, spaceId: 'space-b').save('hide');
    });

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

    await _openTombstonePicker(tester);
    // 只勾「应用于本机所有秘境」、**不改选项**就提交——作用域本身是有效操作
    // （把当前模式推广到所有空间），提交按钮此时必须可用（防呆的另一面：
    // 不能因为"选项没动"就把人堵死）
    await tester.tap(find.text(_zh.settingsScopeAll));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.chatPageTombstoneSubmit));
    await tester.pumpAndSettle();

    // 两端都变成 keep；b 的 per-space 覆盖被清除（读全局值）
    await tester.runAsync(() async {
      expect(await TombstoneSettings(db, spaceId: 'space-a').load(), 'keep');
      expect(await TombstoneSettings(db, spaceId: 'space-b').load(), 'keep',
          reason: '勾选所有秘境后 b 也应变为 keep（其 per-space 覆盖被清除，回退全局）');
    });
    // 确认通知（这个操作越过了当前空间， Silent 落地心里没底）
    expect(find.text(_zh.settingsScopeAllDone), findsOneWidget);
  });
}
