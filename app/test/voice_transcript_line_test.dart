// 回归测试：转写行来源图标全覆盖（老板 2026-10-23）——done/pending 之外，
// failed/stale/unavailable 三个可重试状态行首也要带来源图标（云=服务端
// whisper，芯片=本地 sense-voice），且行保持可点。
//
// ⚠ 查找方式：转写行自 2026-10-23/24 起改为 Text.rich + WidgetSpan（图标嵌进
// 文本 span，左缩进 8px 与播放键对齐）——find.text 找不到 TextSpan 里的文字，
// 要用 RichText 的 toPlainText() 匹配；图标是 WidgetSpan 的真实子 widget，
// find.byIcon 仍可用（作为所在 Clickable 的后代断言“同行”）。

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz/widgets/clickable.dart';
import 'package:einz_shared/einz_shared.dart';

/// 最小 fake ApiClient：sync 返回编排好的加密语音消息（带附件 meta），
/// 其余端点按 chat_page_menu_test 的同款思路 stub/放任失败（页面容错）。
class _FakeApi extends ApiClient {
  _FakeApi({this.messages = const [], this.attachmentsMeta = const []})
      : super('http://fake');

  final List<MessageEnvelope> messages;
  final List<Map<String, dynamic>> attachmentsMeta;

  @override
  Future<({PassphraseEnvelope? file, int? updatedAt})> getKeyEscrow(
          String token) async =>
      (file: null, updatedAt: null);

  @override
  Future<({List<MessageEnvelope> messages, List<Map<String, dynamic>> attachmentsMeta, int lastSequence, bool hasMore})> sync(
      String token, {int after = 0, int limit = 100}) async {
    var seq = after;
    final withSeq = <MessageEnvelope>[
      for (final env in messages)
        () {
          seq++;
          return MessageEnvelope.fromJson(
              {...env.toJson(), 'server_sequence': seq});
        }(),
    ];
    return (
      messages: withSeq,
      attachmentsMeta: attachmentsMeta,
      lastSequence: seq,
      hasMore: false
    );
  }
}

/// 把一条语音消息 + 指定状态的转写行摆到聊天页里。
///
/// 自动转写默认关闭（[_enqueueVoiceTranscripts] 直接返回），插入的行不会被
/// 覆盖；行在消息落库后插（FK 指向 LocalMessages）。
Future<void> _pumpVoiceWithTranscript(
  WidgetTester tester, {
  required String status,
  required String modelId,
  String transcript = '',
}) async {
  final db = LocalDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final spaceKey = await generateSpaceKey();
  final voice = await encryptMessage(
    plaintext:
        encodeMessagePayload('', meta: {kMetaAudioDurationSeconds: 25}),
    spaceKey: spaceKey,
    spaceId: 'space-demo',
    senderEntranceId: 'dev-a',
    messageId: 'msg-voice-1',
    keyVersion: 1,
    type: 'voice',
  );
  final api = _FakeApi(messages: [voice], attachmentsMeta: [
    {
      'attachment_id': 'att-voice-1',
      'message_id': 'msg-voice-1',
      'key_version': 1,
      'size': 1024,
      'sha256': 'fake-sha256',
      'nonce': 'fake-nonce',
    },
  ]);

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
      api: api,
      enableWs: false,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();

  await db.into(db.localVoiceTranscripts).insertOnConflictUpdate(
        LocalVoiceTranscriptsCompanion.insert(
          messageId: 'msg-voice-1',
          modelId: Value(modelId),
          transcript: Value(transcript),
          status: Value(status),
          audioSha256: const Value('fake-sha256'),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
  await tester.pump(); // watch 流推送 → 转写行重建
  await tester.pumpAndSettle();
}

/// 含指定文字（TextSpan 内）的 RichText finder——转写行是 Text.rich 结构。
Finder richTextContaining(String text) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(text));

void main() {
  testWidgets('服务端转写失败：行首带云图标 + 「转写失败，点按重试」可点',
      (WidgetTester tester) async {
    await _pumpVoiceWithTranscript(tester,
        status: 'failed', modelId: 'whisper-server');

    final retry = richTextContaining('转写失败，点按重试');
    expect(retry, findsOneWidget, reason: '失败行应显示重试入口');
    // 图标是同一 Text.rich 里的 WidgetSpan 子 widget——后代断言即“同行”
    expect(
      find.descendant(of: retry, matching: find.byIcon(Icons.cloud_outlined)),
      findsOneWidget,
      reason: '服务端失败行行首应是云图标（whisper-server）',
    );
    // 失败行可点：Clickable 祖先存在且最近的一个挂着回调
    // （外层还有气泡长按等的 Clickable，故用 findsWidgets + .first）
    final clickables = find.ancestor(of: retry, matching: find.byType(Clickable));
    expect(clickables, findsWidgets, reason: '失败行应可点按重试');
    expect(tester.widget<Clickable>(clickables.first).onTap, isNotNull,
        reason: '失败行应挂着重试回调');
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地转写失败：行首带芯片图标', (WidgetTester tester) async {
    await _pumpVoiceWithTranscript(tester,
        status: 'failed', modelId: 'sense-voice-small');

    final retry = richTextContaining('转写失败，点按重试');
    expect(retry, findsOneWidget);
    expect(
      find.descendant(of: retry, matching: find.byIcon(Icons.memory)),
      findsOneWidget,
      reason: '本地失败行行首应是芯片图标（sense-voice）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale 行带芯片图标 + 「可重新转写」文案', (WidgetTester tester) async {
    await _pumpVoiceWithTranscript(tester,
        status: 'stale', modelId: 'sense-voice-small');
    final stale = richTextContaining('可重新转写');
    expect(stale, findsOneWidget);
    expect(
      find.descendant(of: stale, matching: find.byIcon(Icons.memory)),
      findsOneWidget,
      reason: 'stale 行行首应带芯片图标',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable 行带芯片图标 + 手动入口文案', (WidgetTester tester) async {
    await _pumpVoiceWithTranscript(tester,
        status: 'unavailable', modelId: 'sense-voice-small');
    final manual = richTextContaining('点按转写文字');
    expect(manual, findsOneWidget);
    expect(
      find.descendant(of: manual, matching: find.byIcon(Icons.memory)),
      findsOneWidget,
      reason: 'unavailable 行行首应带芯片图标',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('done 行：文本前带芯片图标（本地结果）', (WidgetTester tester) async {
    await _pumpVoiceWithTranscript(tester,
        status: 'done', modelId: 'sense-voice-small', transcript: '转写出的文字');
    final done = richTextContaining('转写出的文字');
    expect(done, findsOneWidget);
    // done 行不包 Clickable（纯展示）——图标与文字同在 Text.rich 里
    expect(
      find.descendant(of: done, matching: find.byIcon(Icons.memory)),
      findsOneWidget,
      reason: 'done 行行首应带芯片图标',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('done 行文本为空 → 整行隐藏（不显示空行）', (WidgetTester tester) async {
    await _pumpVoiceWithTranscript(tester,
        status: 'done', modelId: 'sense-voice-small');
    expect(richTextContaining('转写中'), findsNothing);
    expect(find.byIcon(Icons.memory), findsNothing,
        reason: '空文本 done 行应整行隐藏');
    expect(tester.takeException(), isNull);
  });
}
