// 切换界面语言（中文 → English）的回归守卫。
//
// 背景（2026-10-05 老板 iOS 真机）：从中文切到英文时红底黄字。
// ⚠️ **本测试当时没能复现那个红屏**（在修完 re-invite 的两个 bug 之后的代码上跑是绿的）。
// 两个待验证的猜测：
//  1. 那次红屏是**前面 re-invite 崩溃的余波**——异常发生在某条 route 的卸载/重建期，
//     留下了不再成立的 InheritedWidget 依赖；而"切语言"会更新 `Localizations` →
//     `notifyClients` 遍历**全部**依赖者 → 于是断言在这里才炸出来。若如此，前两个 bug
//     修掉后这里自然就好（本测试即守护它不再回归）。
//  2. 触发还需要本测试没有的东西（真 WS、真实会话状态…）。
// 谁若再看到这个红屏：把 `flutter run` 控制台的完整报错（含
// "The relevant error-causing widget was" 与 stack）贴出来，就能定位。
//
// 之所以仍保留本测试：这条链路此前**零覆盖**，而它的形态确实特殊——
// `_showLocalePicker` 的 onApply 会 `settings.save()` → `localeNotifier.value = ...`
// → EinzApp 监听后 `setState` → **MaterialApp 带着新 locale 整棵树重建**，
// 而此刻**选项弹层还开着**（`OptionPickerSheet._apply` 要等 onApply 返回才 pop）。
//
// `_LocaleHost` 刻意照抄 EinzApp 的接线（initState 载入 + 监听 localeNotifier +
// 用 locale 重建 MaterialApp），从而在测试里忠实复现那一刻。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/locale_settings.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'real_async_settle.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

/// 最小 fake：只有两个成员，够页面正常渲染即可。
class _Api extends ApiClient {
  _Api() : super('http://fake');

  @override
  Future<SpaceResult> getSpace(String token) async => const SpaceResult(
        spaceId: 'space-demo',
        entrances: [],
        memberNames: {'member-me': 'Lukas'},
        memberGenders: {'member-me': 'male'},
        memberSlots: {'member-me': 0},
        mode: 'duo',
        maxMembers: 0,
      );

  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async => const [];

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})>
      sync(String token, {int after = 0, int limit = 100}) async => (
            messages: <MessageEnvelope>[],
            attachmentsMeta: <Map<String, dynamic>>[],
            lastSequence: after,
            hasMore: false,
          );

  @override
  Future<NotifyEmailStatus> getNotifyEmail(String token) async =>
      NotifyEmailStatus(state: 'none');
}

/// 照抄 EinzApp 的语言接线：监听 localeNotifier → 用新 locale 重建 MaterialApp。
class _LocaleHost extends StatefulWidget {
  const _LocaleHost({required this.db, required this.child});

  final LocalDatabase db;
  final Widget child;

  @override
  State<_LocaleHost> createState() => _LocaleHostState();
}

class _LocaleHostState extends State<_LocaleHost> {
  String _pref = 'zh';

  @override
  void initState() {
    super.initState();
    _reload();
    localeNotifier.addListener(_reload);
  }

  @override
  void dispose() {
    localeNotifier.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final pref = await LocaleSettings(widget.db).load();
    if (!mounted) return;
    setState(() => _pref = pref);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(_pref == 'en' ? 'en' : 'zh'),
      home: widget.child,
    );
  }
}

void main() {
  disableAnimationsInTests();

  testWidgets('语言切到 English：全程不报错', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await LocaleSettings(db).save('zh'); // 先固定成中文（否则 system 在测试里是 en）
    final spaceKey = await generateSpaceKey();

    await tester.pumpWidget(_LocaleHost(
      db: db,
      child: ChatPage(
        spaceId: 'space-demo',
        entranceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _Api(),
        enableWs: false,
        memberId: 'member-me',
        memberName: 'Lukas',
        entranceName: 'iPhone',
        peerName: 'Alice',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 菜单 → 语言 → 弹层里选 English
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tapDeferred(tester, find.text(_zh.chatPageMenuLocaleLabel));
    expect(find.text('English'), findsOneWidget, reason: '语言选项弹层应已打开');

    await tester.tap(find.text('English'));
    // locale 变 + 弹层退出这一段最容易出事：逐帧盯着
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull,
          reason: '切换语言期间不应报错（真机上表现为红底黄字）');
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 切完应确实是英文界面
    expect(find.text('English'), findsNothing, reason: '选项弹层应已关闭');
    expect(find.text(_zh.chatPageMenuLocaleLabel), findsNothing,
        reason: '中文菜单文案应已被英文替换');
  });
}
