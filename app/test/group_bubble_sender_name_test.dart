// 回归：**群聊**左侧消息的发言人名字，位置与截断（老板 2026-10-05 定）。
//
// 老板要求：名字**从气泡里去掉**，改放**头像下方**；太长就截断成省略号。
//
// 两件事都要钉住，否则很容易改回去：
//  ① 名字在**气泡外**（气泡左缘的左边）——气泡里只剩内容本身；
//  ② 名字在**头像下方**，且**列宽固定 = 头像直径**——所以再长的名字也只在自己那一列
//     里省略，**不会把气泡推歪**（气泡左缘在每条消息上都对齐）。
//
// 用几何断言（矩形位置）而不是"去找某个 Container"，这样断言的是**视觉结果**。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';

/// 名字故意很长（一定超出头像列宽 32），才能验证"截断成省略号"。
const String kLongName = 'A Very Long Sender Name';

class _GroupApi extends ApiClient {
  _GroupApi(this.messages) : super('http://fake');

  final List<MessageEnvelope> messages;

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})>
      sync(String token, {int after = 0, int limit = 100}) async {
    var seq = after;
    final withSeq = <MessageEnvelope>[
      for (final env in messages)
        () {
          seq++;
          return MessageEnvelope.fromJson({...env.toJson(), 'server_sequence': seq});
        }(),
    ];
    return (
      messages: withSeq,
      attachmentsMeta: <Map<String, dynamic>>[],
      lastSequence: seq,
      hasMore: false,
    );
  }

  @override
  Future<SpaceResult> getSpace(String token) async => SpaceResult(
        spaceId: 'space-demo',
        entrances: const [
          SpaceEntrance(entranceId: 'dev-a', memberId: 'member-me', status: 'active'),
          SpaceEntrance(entranceId: 'dev-b', memberId: 'member-a', status: 'active'),
        ],
        memberNames: const {'member-me': 'Lukas', 'member-a': kLongName},
        memberGenders: const {'member-me': 'male', 'member-a': 'female'},
        memberSlots: const {'member-me': 0, 'member-a': 1},
        mode: 'group',
        maxMembers: 5,
      );
}

void main() {
  setUpAll(() async {
    await sodium();
  });

  testWidgets('群聊：发言人名字在头像下方、气泡之外，过长则省略', (WidgetTester tester) async {
    final db = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final spaceKey = await generateSpaceKey();

    final fromPeer = await encryptMessage(
      plaintext: 'hello',
      spaceKey: spaceKey,
      spaceId: 'space-demo',
      senderEntranceId: 'dev-b',
      messageId: 'msg-peer-1',
      keyVersion: 1,
    );

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: ChatPage(
        spaceId: 'space-demo',
        entranceId: 'dev-a',
        spaceKey: spaceKey,
        keyVersion: 1,
        token: 'tok',
        db: db,
        api: _GroupApi([fromPeer]),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300)); // 等 sync + getSpace
    await tester.pump(const Duration(milliseconds: 100)); // 渲染消息帧

    expect(find.text('hello'), findsOneWidget, reason: '消息正文应渲染');

    // ⚠️ 一切都要**限定在消息列表里**：顶部状态条的第一行**也是**其他成员的名字
    // （群组里只有他一个时，那行文字与这里**完全相同**），头像也另有一个
    // （状态条左侧那枚）。不限定就会撞成 2 个。
    Finder inMessages(Finder f) =>
        find.descendant(of: find.byType(ListView), matching: f);

    final nameFinder = inMessages(find.text(kLongName));
    expect(nameFinder, findsOneWidget, reason: '群聊应在消息旁标出发言人名字');

    // 省略号：单行 + ellipsis（老板要求"长就切割成省略符"）
    final nameText = tester.widget<Text>(nameFinder);
    expect(nameText.maxLines, 1);
    expect(nameText.overflow, TextOverflow.ellipsis);

    final nameRect = tester.getRect(nameFinder);
    final avatarRect = tester.getRect(inMessages(find.byType(CircleAvatar)));
    // 气泡本体（与 chat_bubble_gender_test 同一取法：正文最近的 Container）
    final bubbleRect = tester.getRect(
      find
          .ancestor(
              of: inMessages(find.text('hello')),
              matching: find.byType(Container))
          .first,
    );

    // ① 在头像**下方**
    expect(nameRect.top, greaterThanOrEqualTo(avatarRect.bottom),
        reason: '名字应在头像下方');
    // ② 在气泡**之外**（气泡左缘的左边）——气泡里不再有署名
    expect(nameRect.right, lessThanOrEqualTo(bubbleRect.left),
        reason: '名字应在气泡左侧、气泡之外');
    // ③ 列宽 = 头像直径：名字被压在这一列里（这正是"不把气泡推歪"的机制）
    expect(nameRect.width, lessThanOrEqualTo(kMessageAvatarDiameter + 1),
        reason: '名字列宽应受头像直径约束');
    // ④ 在头像正下方居中
    expect((nameRect.center.dx - avatarRect.center.dx).abs(), lessThan(1.0),
        reason: '名字应对齐头像中轴');
  });
}
