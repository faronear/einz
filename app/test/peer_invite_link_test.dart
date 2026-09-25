import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 状态条「邀请加入」链接（老板 2026-09-25）：对方还没进来时才挂，挂在对方芯片右侧。
///
/// 判定口径是**在用通道**（status == 'active'），不是"通道行存在"——撤销不删行、只
/// 改 status（server/src/entrances.ts），拿"行存在"当已加入会让密友重置设备后不给邀请
/// 入口。另外**问到之前（null）不显示**：否则每次进页面先闪一下、离线时更会常驻。
class _EntranceFakeApi extends ApiClient {
  _EntranceFakeApi({this.rows, this.neverCompletes = false, this.failsToLoad = false})
      : super('http://fake');

  /// listEntrances 返回的行；null 且 [neverCompletes] 时用一个永不完成的 future。
  final List<Map<String, dynamic>>? rows;
  final bool neverCompletes;
  final bool failsToLoad;

  @override
  Future<
      ({
        List<MessageEnvelope> messages,
        List<Map<String, dynamic>> attachmentsMeta,
        int lastSequence,
        bool hasMore,
      })> sync(String token, {int after = 0, int limit = 100}) async {
    return (
      messages: const <MessageEnvelope>[],
      attachmentsMeta: const <Map<String, dynamic>>[],
      lastSequence: 0,
      hasMore: false,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) {
    if (neverCompletes) return Completer<List<Map<String, dynamic>>>().future;
    if (failsToLoad) return Future.error(Exception('offline'));
    return Future.value(rows ?? const <Map<String, dynamic>>[]);
  }
}

/// 本机（我）自己的通道行——每份数据里都有，用于反查 memberId。
Map<String, dynamic> _mine() => {
      'entrance_id': 'dev-a',
      'entrance_name': 'iPhone',
      'member_id': 'member-me',
      'connected_at': DateTime.now().millisecondsSinceEpoch,
      'status': 'active',
    };

/// 对方（伴侣）的一条通道行。
///
/// [online] 默认 false（不带 connected_at）：在线会让 ChatPage 顺带拉一次对方资料，
/// 测试里没 fake 那条接口 → 打真实网络（'http://fake'）白等超时；而"已加入但离线"
/// 本身就是要覆盖的形态。
Map<String, dynamic> _peer({required String status, bool online = false}) => {
      'entrance_id': 'dev-b',
      'entrance_name': 'Pixel',
      'member_id': 'member-peer',
      'connected_at': online ? DateTime.now().millisecondsSinceEpoch : null,
      'status': status,
    };

Future<void> _pumpChat(WidgetTester tester, ApiClient api) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: ChatPage(
      spaceId: 'space-demo',
      entranceId: 'dev-a',
      spaceKey: Uint8List(32),
      keyVersion: 1,
      token: 'tok',
      db: db,
      api: api,
      enableWs: false, // 测试环境不连真实 WS
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100)); // 初始加载 + listEntrances 回来
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('对方已加入（在用通道，离线）→ 不显示「邀请加入」', (tester) async {
    await _pumpChat(
        tester,
        _EntranceFakeApi(rows: [
          _mine(),
          _peer(status: 'active'),
        ]));
    expect(find.text('邀请加入'), findsNothing);
  });

  testWidgets('对方通道已撤销 → 显示「邀请加入」（重置设备后正是该邀请的时候）', (tester) async {
    await _pumpChat(
        tester,
        _EntranceFakeApi(rows: [
          _mine(),
          _peer(status: 'revoked'),
        ]));
    expect(find.text('邀请加入'), findsOneWidget);
  });

  testWidgets('空间里只有我自己 → 显示「邀请加入」', (tester) async {
    await _pumpChat(tester, _EntranceFakeApi(rows: [_mine()]));
    expect(find.text('邀请加入'), findsOneWidget);
  });

  testWidgets('还没问到（请求在途）→ 不显示，避免首帧闪一下', (tester) async {
    await _pumpChat(tester, _EntranceFakeApi(neverCompletes: true));
    expect(find.text('邀请加入'), findsNothing);
  });

  testWidgets('拉不到通道（离线/服务不可达）→ 不显示，不能常驻一个假邀请', (tester) async {
    await _pumpChat(tester, _EntranceFakeApi(failsToLoad: true));
    expect(find.text('邀请加入'), findsNothing);
  });
}
