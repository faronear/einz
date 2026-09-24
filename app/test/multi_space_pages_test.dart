// 多空间页面测试（M2/M3）：启动落点、空间选择弹层、切换秘境。
//
// 2026-09-22 重构：空间列表**独立页面已删除**，改为聊天页菜单里的「选择秘境」弹层
// （小卡片瀑布流 + 底部「添加秘境」）；冷启动**直接进上次用的空间**。
// 聊天页本身的重活（WS/同步）不在这里拉起——只验证"落点对不对"，
// 交互细节由真机自测（老板 2026-09-13 的 UI 验证分工）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/space_switcher.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake：不发网络——未读按 token 给值，退役调用只记录。
class _SoloEntranceApi extends ApiClient {
  _SoloEntranceApi() : super('http://fake');

  /// 各空间的未读数（GET /messages/unread）：按 token 给值，缺省 0。
  final Map<String, int> unreadByToken = {};

  /// 收到退役请求的 token（退出空间时用）。
  final List<String> retiredTokens = [];

  @override
  Future<int> unreadCount(String token) async => unreadByToken[token] ?? 0;

  @override
  Future<void> retireEntrance(String token) async {
    retiredTokens.add(token);
  }
}

const _payloadA = AppLockPayload(
  spaceKeyB64: 'a2V5LWE=',
  spaceId: 'space-a',
  entranceId: 'dev-a',
  token: 'tok-a',
);
const _payloadB = AppLockPayload(
  spaceKeyB64: 'a2V5LWI=',
  spaceId: 'space-b',
  entranceId: 'dev-b',
  token: 'tok-b',
);
const _payloadC = AppLockPayload(
  spaceKeyB64: 'a2V5LWM=',
  spaceId: 'space-c',
  entranceId: 'dev-c',
  token: 'tok-c',
);
const _payloadD = AppLockPayload(
  spaceKeyB64: 'a2V5LWQ=',
  spaceId: 'space-d',
  entranceId: 'dev-d',
  token: 'tok-d',
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
    VaultSession.publish(null); // 进程级解锁态是静态的，逐用例复位
  });

  testWidgets('冷启动落点：两个空间 → 上次用的那个（不再按数量先落一个选择页）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall(); // 否则启动门会按"全新安装"清掉安全存储
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    await lock.setActiveSpace('space-a'); // 上次用的是 A

    // 断言"落点决策"而不是真起 ChatPage（它会拉 WS/同步，用例间互相干扰；真机验证交互）。
    // 变化点：StartupGate 不再 `spaces.length > 1 → 列表页`，而是**总是进 vault.active**。
    final vault = (await lock.loadVault())!;
    expect(vault.spaces.length, 2);
    expect((await lock.resolveActivePayload(vault))!.spaceId, 'space-a');
  });

  testWidgets('选择秘境弹层：小卡片瀑布流显示各空间 + 未读角标 + 新建入口', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall();
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    await lock.saveProfile(spaceId: 'space-a', partnerName: '我A', peerName: '对方A', entranceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-b', partnerName: '我B', peerName: '对方B', entranceName: 'iPhone');
    await lock.loadVault(); // 解锁态进内存会话（弹层从这里读空间列表）

    final api = _SoloEntranceApi()..unreadByToken['tok-a'] = 3;
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showSpacePicker(ctx, db: db, api: api),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await _settle(tester);

    // 瀑布流：每个空间一张小卡片，卡片上是**对方的名字**
    expect(find.text('对方A'), findsOneWidget);
    expect(find.text('对方B'), findsOneWidget);
    expect(find.text('3'), findsOneWidget, reason: 'space-a 有 3 条未读');
    expect(find.text('添加秘境'), findsOneWidget, reason: '底部通往第一屏');
    // 「添加秘境」常态就有淡灰底（提示可点）；与卡片之间不再要分隔线
    final addBg = tester.widget<Material>(
        find.ancestor(of: find.text('添加秘境'), matching: find.byType(Material)).first);
    expect(addBg.color, isNotNull, reason: '常态底色，不是按下去才有');
    expect(find.byType(Divider), findsNothing, reason: '分隔线已去掉');
  });

  testWidgets('空间卡片：长名字不撑破卡片（省略号 + 不溢出）', (WidgetTester tester) async {
    // 老板 2026-09-24：头像调大、名字字号调大后，要防止长名字撑破卡片。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall();
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    final longName = '对方名字被改得特别特别长以至于一定会撑破卡片' * 2;
    await lock.saveProfile(
        spaceId: 'space-a', partnerName: '我', peerName: longName, entranceName: 'iPhone');
    await lock.loadVault();

    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showSpacePicker(ctx, db: db, api: _SoloEntranceApi()),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await _settle(tester);

    expect(tester.takeException(), isNull, reason: '长名字不应撑破卡片');
    expect(find.textContaining('对方名字被改得特别特别长'), findsOneWidget,
        reason: '名字仍在（仅省略号截断，而非隐藏）');
  });

  testWidgets('空间卡片：按屏幕宽度反算，一行正好 3 张（iPhone 16 尺寸）',
      (WidgetTester tester) async {
    // 老板 2026-09-24：固定 120 时 2 张空太多、3 张放不下 → 边长按可用宽度反算。
    tester.view.physicalSize = const Size(393, 852); // iPhone 16
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall();
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    await lock.addSpace(_payloadC);
    await lock.addSpace(_payloadD);
    // 名字等长（都是 2 字）：卡片里名字居中，两卡名字左边缘之差 = 卡宽 + 间距
    await lock.saveProfile(spaceId: 'space-a', partnerName: '我', peerName: '甲一', entranceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-b', partnerName: '我', peerName: '乙二', entranceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-c', partnerName: '我', peerName: '丙三', entranceName: 'iPhone');
    await lock.saveProfile(spaceId: 'space-d', partnerName: '我', peerName: '丁四', entranceName: 'iPhone');
    await lock.loadVault();

    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showSpacePicker(ctx, db: db, api: _SoloEntranceApi()),
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await _settle(tester);
    expect(tester.takeException(), isNull);

    final p1 = tester.getTopLeft(find.text('甲一'));
    final p2 = tester.getTopLeft(find.text('乙二'));
    final p3 = tester.getTopLeft(find.text('丙三'));
    final p4 = tester.getTopLeft(find.text('丁四'));

    // 前 3 张同一行，第 4 张换行且与第 1 张左对齐（不满 3 张靠左）
    expect(p1.dy, p2.dy);
    expect(p2.dy, p3.dy);
    expect(p4.dy, greaterThan(p1.dy), reason: '第 4 张应换到下一行');
    expect(p4.dx, closeTo(p1.dx, 0.5), reason: '不满 3 张的行靠左对齐');

    // 卡宽 + 间距 = 弹层可用宽度 361 平分成 3 份（(393-32-24)/3 = 112.33 → 向下取整 112）
    expect(p2.dx - p1.dx, closeTo(112 + 12, 0.5), reason: '卡片边长按可用宽度反算');
    expect(p3.dx - p2.dx, closeTo(112 + 12, 0.5));
  });

  testWidgets('在弹层里选另一个空间 → 当前空间切换（不需要锁屏码）', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final lock = AppLockService(db);
    await lock.ensureFreshInstall();
    await lock.savePlain(_payloadA);
    await lock.addSpace(_payloadB);
    await lock.setActiveSpace('space-a');

    await lock.loadVault();
    SpacePick? picked;
    await tester.pumpWidget(_app(Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            // 弹层只负责"回传选择"，真正的切换由调用方执行（switchToSpace）
            picked = await showSpacePicker(ctx, db: db, api: _SoloEntranceApi());
          },
          child: const Text('开'),
        ),
      ),
    )));
    await tester.tap(find.text('开'));
    await _settle(tester);
    await tester.tap(find.text('space-b')); // 卡片没名字时显示 spaceId（本用例未写资料）
    await _settle(tester);

    expect(picked, isNotNull);
    expect(picked!.spaceId, 'space-b', reason: '弹层应回传所选的空间 id');
  });
}
