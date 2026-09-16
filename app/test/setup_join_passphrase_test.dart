// join 接入口令验证回归测试：口令页必须是「验证」语义——
// 输入口令必须与首台设备创建时一致（解密 escrow 口令密保箱成功）才放行进 PIN 步骤；
// 错误口令提示并停留口令页（不得"随便输都能过"）。
// Multiverse（2026-09-10）：join 流程 = 入口页 → token（preflight）→ 名字 → 口令。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart';

import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';

/// 假 escrow：口令匹配返回 payload，不匹配抛 FormatException（模拟解密失败），
/// payload 为 null 表示未托管。
class _FakeEscrow extends KeyEscrowService {
  _FakeEscrow(this.correctPass, this.payload) : super(ApiClient('http://fake'));

  final String correctPass;
  final EscrowPayload? payload;

  @override
  Future<PassphraseEnvelope?> fetchSpaceEscrow(String spaceId, String passphrase) async {
    if (payload == null) return null;
    if (passphrase != correctPass) throw const FormatException('口令错误');
    // salt/nonce/ciphertext 必须是合法 base64（PassphraseEnvelope.fromJson 会解码校验）
    return PassphraseEnvelope.fromJson(const {
      'format': 'einz-backup-v1',
      'salt': 'c2FsdA==',
      'nonce': 'bm9uY2U=',
      'ciphertext': 'Y2lwaGVy',
    });
  }

  @override
  Future<EscrowPayload> openPackage(
      {required String passphrase, required PassphraseEnvelope envelope}) async {
    if (passphrase != correctPass) throw const FormatException('口令错误');
    return payload!;
  }
}

/// 打开 join 向导并走到 token 页（入口页 → 加入）。
Future<void> pumpToJoinToken(
  WidgetTester tester, {
  Future<SpaceJoinPreflight> Function(String token)? preflight,
  Future<SpaceJoinResult> Function(String token)? join,
  String correctPass = '正确口令-abc',
  EscrowPayload? payload,
}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: SetupPage(
      db: db,
      probeServer: (_) async => (true, 'v2-multiverse', const <String>[]),
      preflightOverride: preflight ??
          (token) async => const SpaceJoinPreflight(
              spaceId: 'space-test',
              status: 'waiting',
              memberCount: 1,
              slots: [
                SpaceMemberSlot(slot: 0, displayName: 'Lukas', gender: 'male', status: 'active'),
                SpaceMemberSlot(slot: 1, displayName: 'Alice', gender: 'female', status: 'pending'),
              ]),
      joinOverride: join ??
          (token) async => const SpaceJoinResult(
              spaceId: 'space-test',
              personId: 'personB',
              partnerSlot: 1,
              sessionToken: 'tok',
              deviceId: 'dev2',
              spaceAddress: '0x00'),
      escrowOverride: (server) => _FakeEscrow(correctPass, payload),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('加入秘境')); // 入口页 → 加入
  await tester.pumpAndSettle();
}

/// 走到口令页：token（preflight）→ 身份选择（选第二人 Alice）→ 口令页。
Future<void> pumpToJoinPassphrase(
  WidgetTester tester, {
  required String correctPass,
  EscrowPayload? payload,
  Future<SpaceJoinResult> Function(String token)? join,
}) async {
  await pumpToJoinToken(
      tester, correctPass: correctPass, payload: payload, join: join);
  await tester.enterText(find.byType(TextField), 'TOKEN-1'); // token
  await tester.tap(find.text('下一步')); // preflight 通过 → 直接进身份选择页（不再显示确认卡片）
  await tester.pumpAndSettle();
  // 身份选择（老板定稿：join 不再自填名字——选择是哪一个用户）
  expect(find.text('选择身份'), findsOneWidget); // 身份选择页标题
  await tester.tap(find.textContaining('Alice')); // 选第二人（伴侣）
  await tester.pumpAndSettle();
  await tester.tap(find.text('下一步'));
  await tester.pumpAndSettle(); // → 口令页
  // 口令页应为「验证」语义：标题与提示都是验证措辞
  expect(find.text('验证密保口令'), findsOneWidget); // 标题（join=验证套，create=设置套）
  expect(find.text('口令是与伴侣共享的密码，用于保护聊天内容。如果不知道口令，请询问伴侣。'),
      findsOneWidget); // hint
  // join 提交（POST /spaces/join）成功后若出 SnackBar 停留 4 秒：等其消失避免遮挡
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await sodium(); // 自动建钥需要 libsodium（macOS 经 LIBSODIUM_PATH/brew 可用）
  });

  final payload =
      const EscrowPayload(spaceKeyB64: 'a2V5', spaceId: 'space-test', keyVersion: 1);

  testWidgets('错误口令：提示口令错误并停留口令页（不进入 PIN 页）', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: payload);
    await tester.enterText(find.byType(TextField), '随便输入的口令');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('口令错误：请确认首台设备创建时设置的口令'), findsOneWidget,
        reason: '错误口令必须被拦截并提示');
    expect(find.text('口令是与伴侣共享的密码，用于保护聊天内容。如果不知道口令，请询问伴侣。'),
        findsOneWidget, reason: '应停留在口令页');
    expect(find.text('设置锁屏码'), findsNothing, reason: '不应进入 PIN 页');
  });

  testWidgets('正确口令：通过验证进入 PIN 页', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: payload);
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsWidgets, reason: '口令一致应放行进 PIN 步骤');
  });

  testWidgets('先输错再输对：token 只被消费一次，重输正确口令仍可加入', (WidgetTester tester) async {
    var joinCalls = 0;
    // 模拟一次性 token：第二次 joinSpace 即报已使用（真实服务端行为）
    Future<SpaceJoinResult> fakeJoin(String token) async {
      joinCalls++;
      if (joinCalls > 1) throw ApiException('TOKEN_USED', 'token 已使用');
      return const SpaceJoinResult(
          spaceId: 'space-test',
          personId: 'personB',
          partnerSlot: 1,
          sessionToken: 'tok',
          deviceId: 'dev2',
          spaceAddress: '0x00');
    }

    await pumpToJoinPassphrase(
        tester, correctPass: '正确口令-abc', payload: payload, join: fakeJoin);

    // 1) 先输错：应停在口令页，且**不能**已经消费 token
    await tester.enterText(find.byType(TextField), '随便输入的口令');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('口令错误：请确认首台设备创建时设置的口令'), findsOneWidget,
        reason: '错误口令必须被拦截并提示');
    expect(joinCalls, 0, reason: '验口令之前不应消费一次性 token');

    // 2) 重输正确口令：旧实现此时 joinSpace 报「token 已用」→ 永远失败
    //    （老板 2026-09-12 反馈：一直「口令验证失败。请询问秘境伴侣获得口令。」）
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsWidgets, reason: '重输正确口令应放行进 PIN 步骤');
    expect(joinCalls, 1, reason: 'token 只应被消费一次');
  });

  testWidgets('PIN 页退回口令页再前进：不重复消费 token（仍能进 PIN 页）', (WidgetTester tester) async {
    var joinCalls = 0;
    Future<SpaceJoinResult> fakeJoin(String token) async {
      joinCalls++;
      if (joinCalls > 1) throw ApiException('TOKEN_USED', 'token 已使用');
      return const SpaceJoinResult(
          spaceId: 'space-test',
          personId: 'personB',
          partnerSlot: 1,
          sessionToken: 'tok',
          deviceId: 'dev2',
          spaceAddress: '0x00');
    }

    await pumpToJoinPassphrase(
        tester, correctPass: '正确口令-abc', payload: payload, join: fakeJoin);
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('设置锁屏码'), findsWidgets, reason: '首次应放行进 PIN 步骤');
    expect(joinCalls, 1);

    // 退回口令页 → 再点下一步：不应再调 joinSpace（token 是一次性的）
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('验证密保口令'), findsOneWidget, reason: '应退回口令页');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(joinCalls, 1, reason: '重复前进不应再消费 token');
    expect(find.text('设置锁屏码'), findsWidgets, reason: '应再次放行进 PIN 步骤');
  });

  testWidgets('邀请码验证通过后即锁定：退回本页再前进不重复校验', (WidgetTester tester) async {
    var preflightCalls = 0;
    Future<SpaceJoinPreflight> fakePreflight(String token) async {
      preflightCalls++;
      // 模拟真实服务端：token 已被 joinSpace 消费后再校验必然失败
      if (preflightCalls > 1) throw ApiException('TOKEN_USED', 'token 已使用');
      return const SpaceJoinPreflight(
          spaceId: 'space-test',
          status: 'waiting',
          memberCount: 1,
          slots: [
            SpaceMemberSlot(slot: 0, displayName: 'Lukas', gender: 'male', status: 'active'),
            SpaceMemberSlot(slot: 1, displayName: 'Alice', gender: 'female', status: 'pending'),
          ]);
    }

    await pumpToJoinToken(tester, preflight: fakePreflight);
    await tester.enterText(find.byType(TextField), 'TOKEN-1');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('选择身份'), findsOneWidget, reason: '有效 token 应放行到身份选择页');
    expect(preflightCalls, 1);

    // 退回邀请码页：输入框应锁只读（防止改坏已验证的 token）
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('TOKEN-1'), findsOneWidget, reason: '退回后仍显示原邀请码');
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue,
        reason: '已验证通过的邀请码应锁为只读');

    // 再点下一步：不应再发后台校验（否则 token 被消费后必然失败，把用户卡死）
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(preflightCalls, 1, reason: '已验证过就不应重复校验');
    expect(find.text('选择身份'), findsOneWidget, reason: '应直接放行到身份选择页');
  });

  testWidgets('未托管口令（服务器无 escrow 包）：提示并停留', (WidgetTester tester) async {
    await pumpToJoinPassphrase(tester, correctPass: '正确口令-abc', payload: null);
    await tester.enterText(find.byType(TextField), '正确口令-abc');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('口令是与伴侣共享的密码，用于保护聊天内容。如果不知道口令，请询问伴侣。'),
        findsOneWidget, reason: '未托管时停留口令页');
  });

  testWidgets('错误 token：提示无效并停留 token 页（不进口令页）', (WidgetTester tester) async {
    await pumpToJoinToken(tester,
        preflight: (_) async => throw ApiException('TOKEN_INVALID', 'invalid'));
    await tester.enterText(find.byType(TextField), '错误TOKEN');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('无效的邀请码'), findsOneWidget, reason: '无效 token 必须被拦截并提示');
    expect(find.text('验证邀请码'), findsWidgets, reason: '应停留在 token 页（setupTokenTitle）');
    expect(find.text('验证密保口令'), findsNothing, reason: '不应进入口令页');
  });

  testWidgets('正确 token：preflight 通过 → 直接进入身份选择页（无确认卡片）', (WidgetTester tester) async {
    await pumpToJoinToken(tester); // 默认 preflight 成功
    await tester.enterText(find.byType(TextField), '正确TOKEN');
    await tester.tap(find.text('下一步')); // preflight 通过 → 直接进下一页
    await tester.pumpAndSettle();
    expect(find.text('选择身份'), findsOneWidget, reason: '有效 token 应直接放行到身份选择页');
    expect(find.text('加入 Lukas 的空间'), findsNothing, reason: '不再显示空间确认卡片');
    expect(find.textContaining('Lukas'), findsOneWidget, reason: '身份选择页展示第一人');
    expect(find.textContaining('Alice'), findsOneWidget, reason: '身份选择页展示第二人');
  });
}
