// 空间卡片的对方头像：memberId 是**异步**才到位的（弹层先读 Spaces 表、再逐空间读
// per-space 资料），首帧建卡片时它还是空串。
//
// 老板 2026-09-25 实测：对方明明设了头像，卡片却永远是默认人形图标。根因就是首帧那次
// 拉取拿到空串直接 return，之后 memberId 到位、父级重建，State 复用不会再走 initState
// → 再没人去拉头像（未读角标不受影响，因为它每次 build 现读 map）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart';

import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/space_switcher.dart';

/// 1×1 透明 PNG（够 MemoryImage 解码，不引额外依赖）。
final Uint8List _kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==');

class _AvatarFakeApi extends ApiClient {
  _AvatarFakeApi() : super('http://fake');

  /// 记录被拉过的 member_id（断言"真的去拉了"）。
  final List<String> avatarCalls = [];

  @override
  Future<Uint8List?> getAvatar(String memberId) async {
    avatarCalls.add(memberId);
    return _kTinyPng;
  }

  @override
  Future<int> unreadCount(String token) async => 0;
}

/// 建一个只有 `space-test` 的空间库 + 内存 Vault，并打开「切换我的秘境」弹层。
Future<void> _pumpPicker(
  WidgetTester tester, {
  required LocalDatabase db,
  required ApiClient api,
}) async {
  await db.into(db.spaces).insert(SpacesCompanion.insert(spaceId: 'space-test'));
  VaultSession.publish(const VaultPayload(spaces: [
    AppLockPayload(
      spaceKeyB64: 'a2V5',
      spaceId: 'space-test',
      entranceId: 'dev-a',
      keyVersion: 1,
      token: 'tok',
    ),
  ]));
  addTearDown(() => VaultSession.publish(null));

  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () => showSpacePicker(ctx, db: db, api: api),
        child: const Text('开'),
      ),
    ),
  ));
  await tester.tap(find.text('开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('memberId 异步到位后，卡片补拉头像（不永远停在默认人形）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final api = _AvatarFakeApi();

    await AppLockService(db)
        .savePeerPresence(spaceId: 'space-test', peerMemberId: 'peer-1');
    await _pumpPicker(tester, db: db, api: api);

    expect(api.avatarCalls, ['peer-1'], reason: 'memberId 到位后必须补拉一次');
    // 头像到位 → CircleAvatar 不再画那个默认人形图标（背景图是 DecorationImage，
    // 测试里没有 Image widget 可找，故用"默认图标消失"来断言真的贴上去了）
    expect(find.byIcon(Icons.person), findsNothing, reason: '应换成真实头像');
    expect(find.text('待加入'), findsNothing, reason: '对方已加入就不该报状态');
    expect(tester.takeException(), isNull);
  });

  testWidgets('对方尚未加入（peerJoined=false）→ 卡片名字下显示「待加入」',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final api = _AvatarFakeApi();

    // 服务端通道表里除我之外没有别的成员 → ChatPage 落的确定性结论
    await AppLockService(db)
        .savePeerPresence(spaceId: 'space-test', peerMemberId: null);
    await _pumpPicker(tester, db: db, api: api);

    expect(find.text('待加入'), findsOneWidget);
    expect(api.avatarCalls, isEmpty, reason: '没有 member_id 就不该去拉头像');
    expect(tester.takeException(), isNull, reason: '多一行不能把固定尺寸的卡片撑破');
  });

  testWidgets('状态未知（从没判断过）→ 不显示「待加入」（不误报）',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final api = _AvatarFakeApi();

    // 空资料：本机还没在聊天页刷新过
    await _pumpPicker(tester, db: db, api: api);

    expect(find.text('待加入'), findsNothing);
  });
}
