// 「切换我的秘境」弹层在**矮窗口**下不能被卡片撑破（老板 2026-09-28 实测 mac 桌面端：
// 4 个以上空间 → 卡片排到两行以上，再把整个窗口调矮，弹层底部出现黄黑斜条纹 +
// "Bottom overflowed by N pixels"，内容是死的、鼠标滚轮也滚不出看不见的卡片）。
//
// 两个关键事实（都在下面注明了来处）：
// ① 弹层能有多高**不等于窗口高度**：`showModalBottomSheet` 默认把内容限在视口高度的
//    9/16（framework `material/bottom_sheet.dart` 的 `_kDefaultScrollControlDisabledMaxHeightRatio`），
//    窗口一矮这个上限就很小——所以卡片区的上限不能按窗口高度算，得吃"剩下的那点地方"。
// ② 弹层里的 MediaQuery 是 **App 级**的（路由挂在 Navigator 的 Overlay 上），
//    在 home 里套一个 MediaQuery 改不了弹层看到的高度——要改窗口就用 `tester.view`。
//
// 「更多通道」弹层是同一个结构（Column + Wrap），改法见 widgets/scrollable_card_area.dart。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz_shared/einz_shared.dart';

import 'package:einz/data/app_lock.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/data/vault_session.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/space_switcher.dart';

class _ShortWindowFakeApi extends ApiClient {
  _ShortWindowFakeApi() : super('http://fake');

  @override
  Future<int> unreadCount(String token) async => 0;
}

/// 把一个 [count] 个空间的内存库塞进会话，并在当前窗口尺寸下打开「切换我的秘境」。
Future<void> _pumpPicker(
  WidgetTester tester, {
  required int count,
}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final spaces = <AppLockPayload>[
    for (var i = 0; i < count; i++)
      AppLockPayload(
        spaceKeyB64: 'a2V5$i',
        spaceId: 'space-$i',
        entranceId: 'dev-$i',
        keyVersion: 1,
        token: 'tok-$i',
      ),
  ];
  await db.batch((batch) => batch.insertAll(
        db.spaces,
        [for (final s in spaces) SpacesCompanion.insert(spaceId: s.spaceId)],
      ));
  VaultSession.publish(VaultPayload(spaces: spaces));
  addTearDown(() => VaultSession.publish(null));

  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: Builder(
      builder: (ctx) => TextButton(
        onPressed: () => showSpacePicker(ctx, db: db, api: _ShortWindowFakeApi()),
        child: const Text('开'),
      ),
    ),
  ));
  await tester.tap(find.text('开'));
  await tester.pumpAndSettle();
}

/// 卡片区自己的滚动位置（`Scrollable` 上没 position，要取它的 State）。
ScrollPosition _cardArea(WidgetTester tester) => tester.state<ScrollableState>(find
        .ancestor(of: find.byType(Wrap).first, matching: find.byType(Scrollable))
        .first)
    .position;

void main() {
  testWidgets('矮窗口 + 8 个空间：卡片区内部滚动，弹层不 overflow',
      (WidgetTester tester) async {
    // 真的把窗口调矮（见文件头 ②：弹层只看 App 级 MediaQuery）
    tester.view.physicalSize = const Size(640, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 8 张卡 = 3 行（一行 3 张），远超弹层留给卡片区的高度
    await _pumpPicker(tester, count: 8);

    expect(tester.takeException(), isNull, reason: '排不下也不能把弹层撑破');

    // 卡片那块确实是滚动容器，且被挡住的部分真的滚得出来
    expect(_cardArea(tester).pixels, 0);
    // 拖**视口**（ListView）而不是那张高度远超视口的 Wrap：后者中心点在屏幕外，拖不中
    await tester.drag(find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(_cardArea(tester).pixels, greaterThan(0), reason: '被遮住的卡片要能滚出来');
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片排得下时：照旧不滚动，弹层贴着内容',
      (WidgetTester tester) async {
    // 默认窗口（800×600）下两张卡只有一行：放得下 → 不该出现可滚动的余量
    await _pumpPicker(tester, count: 2);

    expect(tester.takeException(), isNull);
    expect(_cardArea(tester).maxScrollExtent, 0, reason: '内容放得下就不该能滚');
  });
}
