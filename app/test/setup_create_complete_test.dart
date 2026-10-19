// create 流完成路径回归测试：口令页「下一步」= 自举登记 + 落盘 + 完成页 + 欢迎弹窗。
//
// 背景（2026-10-19 真机 bug，commit f12f659f 修复）：PIN 步骤从向导移除后，
// create 口令页首次「下一步」只跑自举（_enroll == null → _runBootstrap），旧
// 实现成功后落到 _nextStep 尾部的 _step++——空壳 done 页。欢迎弹窗只由
// _completeWizard 触发，自举路径没经过它，表现为「只有背景没有欢迎弹窗」。
// join/offline 无自举环节所以当时正常；本测试站岗 create 这条路径
// （join 流的同款断言见 setup_join_passphrase_test.dart）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart';

import 'package:einz/data/local_database.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/setup_page.dart';
import 'package:einz/data/server_config.dart';

/// 文案断言一律从 l10n 取（与页面同一份生成代码），改文案不会弄红测试。
final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

void main() {
  setUpAll(() async {
    await sodium(); // _runBootstrap/_runPinSetup 生成 Space Key 需要 libsodium
    // PIN 步骤已移除（老板 2026-10-19）：口令页「下一步」直接 savePlain 落盘
    // （SecureStore/Keychain）——测试环境必须给 mock，否则写入挂起、欢迎弹窗不出现
    FlutterSecureStorage.setMockInitialValues({});
  });

  setUp(() {
    // savePlain 会 publish 全局 VaultSession（内存会话跨用例残留）：不清掉的
    // 话，后续用例被「本机已有通道」闸门拦截
    VaultSession.publish(null);
  });

  testWidgets('create：口令页下一步 → 自举 + 落盘 + 完成页弹欢迎窗',
      (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: SetupPage(
        db: db,
        probeServer: (_) async => const ServerHealth(
            ok: true, protocolVersion: 'v2-multiverse', capabilities: <String>[]),
        // create 口令页「下一步」触发自举登记（_runBootstrap → createSpace），
        // fake 返回成功结果（与 wizard_envelope_entry_test 同款）
        createOverride: () async => const SpaceCreateResult(
          spaceId: 'space-test',
          spaceAddress: '0x00',
          joinToken: 'tok-1',
          link: 'https://einz.tic.cc/join/tok-1',
          expiresAt: 9999999999,
          entranceId: 'dev1',
          creatorMemberId: 'memberA',
          sessionToken: 'tok',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 入口页 → 新建 → 名字（+性别）→ 类型（双人秘境）→ 口令页
    await tester.tap(find.text(_zh.setupEntryCreate));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Lukas');
    await tester.tap(find.byIcon(Icons.male));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.wizardNext));
    await tester.pumpAndSettle(); // → 类型页（2026-10-04 起 create 第 2 步）
    await tester.tap(find.text(_zh.wizardSpaceKindDuo));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_zh.wizardNext));
    await tester.pumpAndSettle(); // → 口令页（最后输入页，无 PIN 步）

    // create 口令需二次输入一致（老板 2026-09-12）：两个输入框都填
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2), reason: 'create 口令页应为口令 + 确认两个输入框');
    await tester.enterText(fields.first, 'abc12345');
    await tester.enterText(fields.last, 'abc12345');
    await tester.tap(find.text(_zh.wizardNext));
    await tester.pumpAndSettle();

    // 核心断言：自举成功后直接走完成路径——欢迎弹窗必须出现
    // （f12f659f 前的 bug：落空壳 done 页，屏幕上什么都没有）
    expect(find.text(_zh.welcomeDialogTitleCreate), findsOneWidget,
        reason: 'create 走完口令页必须弹欢迎窗（自举路径不得落空壳 done 页）');
    expect(find.text(_zh.welcomeDialogMessage), findsOneWidget);
    expect(find.text(_zh.welcomeDialogStart), findsOneWidget,
        reason: '唯一「开始聊天」按钮（点外面不关闭）');
  });
}
