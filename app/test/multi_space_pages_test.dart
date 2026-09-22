// 多空间页面测试（M2）：启动门分支 + 空间列表渲染与删除。
//
// 聊天页本身的重活（WS/同步）不在这里拉起——只验证"落点对不对"，
// 交互细节由真机自测（老板 2026-09-13 的 UI 验证分工）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/chat_page.dart';
import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/main.dart';
import 'package:einz/setup_page.dart';
import 'package:einz/space_list_page.dart';
import 'package:einz/widgets/reset_device.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake：不发网络——/space 只回本设备（对方尚未加入），同步空；退役调用只记录。
/// 用于验证「名字只能来自当前空间的 profile」与「移除空间会通知服务端退役那一行」。
class _SoloDeviceApi extends ApiClient {
  _SoloDeviceApi() : super('http://fake');

  /// 收到退役请求的 token（断言"移除空间顺手退役服务端那一行"用）。
  final List<String> retiredTokens = [];

  /// 各空间的未读数（GET /messages/unread）：按 token 给值，缺省 0。
  final Map<String, int> unreadByToken = {};

  @override
  Future<int> unreadCount(String token) async => unreadByToken[token] ?? 0;

  @override
  Future<void> retireDevice(String token) async {
    retiredTokens.add(token);
  }

  @override
  Future<SpaceResult> getSpace(String token) async => const SpaceResult(
        spaceId: 'space-b',
        devices: [
          SpaceDevice(deviceId: 'dev-b', personId: 'person-b', status: 'active'),
        ],
      );

  @override
  Future<({
    List<MessageEnvelope> messages,
    List<Map<String, dynamic>> attachmentsMeta,
    int lastSequence,
    bool hasMore,
  })> sync(String token, {int after = 0, int limit = 100}) async => (
        messages: <MessageEnvelope>[],
        attachmentsMeta: <Map<String, dynamic>>[],
        lastSequence: after,
        hasMore: false,
      );
}

const _payloadA = AppLockPayload(
  spaceKeyB64: 'a2V5LWE=',
  spaceId: 'space-a',
  deviceId: 'dev-a',
  token: 'tok-a',
);
const _payloadB = AppLockPayload(
  spaceKeyB64: 'a2V5LWI=',
  spaceId: 'space-b',
  deviceId: 'dev-b',
  token: 'tok-b',
);

Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 6; round++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  }
}

Widget _app(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: home,
    );

void main() {
  setUpAll(() async {
    await sodium();
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('启动门：多空间 → 落点是空间列表（不是向导）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall(); // 否则启动门会按"全新安装"清掉安全存储
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);

    await tester.pumpWidget(_app(StartupGate(db: db)));
    await _settle(tester);

    expect(find.byType(SpaceListPage), findsOneWidget, reason: '两个空间 → 先给列表');
    expect(find.byType(SetupPage), findsNothing);
  });

  testWidgets('空间列表：显示已绑定的空间（名字取 Spaces 行）+ 底部按钮通往第一屏', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall(); // 否则启动门会按"全新安装"清掉安全存储
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    await lock.saveProfile(spaceId: 'space-a', personName: '我A', peerName: '对方A', deviceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-b', personName: '我B', peerName: '对方B', deviceName: 'iPhone');

    final vault = (await lock.loadVault())!;
    await tester.pumpWidget(_app(SpaceListPage(vault: vault, db: db, api: _SoloDeviceApi())));
    await _settle(tester);

    expect(find.text('对方A'), findsOneWidget);
    expect(find.text('对方B'), findsOneWidget);
    expect(find.text('新建/加入空间'), findsOneWidget, reason: '底部按钮通往第一屏（创建/加入）');
  });

  testWidgets('空间列表：本页不做任何破坏性操作（老板 2026-09-22 定）', (WidgetTester tester) async {
    // ①「移除某个空间」不在这里——它与聊天页菜单的「退出并清除这个空间」是同一件事；
    // ②「清除本设备全部数据」太危险，不呈现给用户。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall();
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    await lock.saveProfile(spaceId: 'space-a', personName: '我A', peerName: '对方A', deviceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-b', personName: '我B', peerName: '对方B', deviceName: 'iPhone');

    final api = _SoloDeviceApi();
    final vault = (await lock.loadVault())!;
    await tester.pumpWidget(_app(SpaceListPage(vault: vault, db: db, api: api)));
    await _settle(tester);

    // 没有溢出菜单（设备级清空入口已移除）
    expect(find.byIcon(Icons.more_vert), findsNothing, reason: '不应再有设备级清空入口');
    // 长按不弹「移除」确认，也不产生任何服务端退役调用
    await tester.longPress(find.text('对方A'));
    await tester.pumpAndSettle();
    expect(find.text('移除'), findsNothing, reason: '长按不应再提供移除');
    expect(api.retiredTokens, isEmpty, reason: '本页不应触发任何退役调用');
    expect((await lock.loadVault())!.spaces.length, 2, reason: '两个空间都应还在');
  });

  testWidgets('空间列表：未读角标只出现在有未读的空间上（服务端派生）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall();
    await lock.savePlain(_payloadA); // token: tok-a
    await lock.addSpace(_payloadB); // token: tok-b
    await lock.saveProfile(spaceId: 'space-a', personName: '我A', peerName: '对方A', deviceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-b', personName: '我B', peerName: '对方B', deviceName: 'iPhone');

    final api = _SoloDeviceApi()..unreadByToken['tok-a'] = 3;
    final vault = (await lock.loadVault())!;
    await tester.pumpWidget(_app(SpaceListPage(vault: vault, db: db, api: api)));
    await _settle(tester);

    expect(find.byKey(const ValueKey('unreadBadge-space-a')), findsOneWidget,
        reason: 'space-a 有 3 条未读 → 显示角标');
    expect(find.text('3'), findsOneWidget, reason: '角标显示条数');
    expect(find.byKey(const ValueKey('unreadBadge-space-b')), findsNothing,
        reason: 'space-b 没未读 → 不显示角标');
  });

  testWidgets('「退出并清除这个空间」（唯一破坏性路径）：闸门通过 → 退役那一行 + 本地移除',
      (WidgetTester tester) async {
    // 空间列表页不再提供"移除"，所以这条路径现在是唯一的破坏性入口，单独钉住。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall();
    await lock.savePlain(_payloadA);
    await lock.saveProfile(spaceId: 'space-a', personName: '我A', peerName: '对方A', deviceName: 'iPhone');
    expect((await db.select(db.spaces).get()).map((r) => r.spaceId), contains('space-a'));

    final api = _SoloDeviceApi();
    bool? left;
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            left = await confirmLeaveSpace(ctx,
                db: db, api: api, spaceId: 'space-a', token: 'tok-a', deviceName: 'iPhone');
          },
          child: const Text('开闸'),
        ),
      ),
    )));

    await tester.tap(find.text('开闸'));
    await tester.pumpAndSettle();
    expect(find.text('退出并清除这个空间？'), findsOneWidget, reason: '先过闸门');
    await tester.enterText(find.byType(TextField), 'iPhone');
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(left, isTrue);
    expect(api.retiredTokens, ['tok-a'], reason: '只退役这一个空间那一行');
    expect((await db.select(db.spaces).get()).map((r) => r.spaceId), isNot(contains('space-a')),
        reason: '本地 Spaces 行应被移除');
  });

  testWidgets('切换空间后顶部条显示当前空间的对方名，不串到原空间', (WidgetTester tester) async {
    // 回归（老板 2026-09-22）：新建空间对方还没加入时，ChatPage 从全局 profile
    // 读到了别的空间的对方名 → 不论怎么切空间，顶部条都停在原空间的对方名上。
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.saveProfile(
        spaceId: 'space-a', personName: '我A', peerName: '对方A', deviceName: 'iPhone');
    await lock.saveProfile(
        spaceId: 'space-b', personName: '我B', peerName: '对方B', deviceName: 'iPhone');

    await tester.pumpWidget(_app(ChatPage(
      spaceId: 'space-b',
      deviceId: 'dev-b',
      spaceKey: await generateSpaceKey(),
      keyVersion: 1,
      token: 'tok',
      db: db,
      api: _SoloDeviceApi(),
      enableWs: false,
    )));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('对方B'), findsOneWidget, reason: '应显示 space-b 自己的对方名');
    expect(find.text('对方A'), findsNothing, reason: '不能串到 space-a 的对方名');
  });
}
