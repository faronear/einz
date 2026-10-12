import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:einz/chat_page.dart';
import 'package:einz/data/local_database.dart';
import 'package:einz/l10n/app_localizations.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super('http://fake');
  @override
  Future<
      ({
        List<MessageEnvelope> messages,
        List<Map<String, dynamic>> attachmentsMeta,
        int lastSequence,
        bool hasMore,
      })> sync(String token, {int after = 0, int limit = 100}) async =>
      (
        messages: const <MessageEnvelope>[],
        attachmentsMeta: const <Map<String, dynamic>>[],
        lastSequence: 0,
        hasMore: false,
      );
  @override
  Future<List<Map<String, dynamic>>> listEntrances(String token) async =>
      const <Map<String, dynamic>>[];
}

void main() {
  testWidgets('附件弹层高度探针：不得顶天立地', (tester) async {
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
        api: _FakeApi(),
        enableWs: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final rect = tester.getRect(find.byType(BottomSheet).first);
    // ignore: avoid_print
    print('PROBE screen=$screenH sheetTop=${rect.top} sheetH=${rect.height}');
    expect(rect.height, lessThan(screenH * 0.7),
        reason: '附件弹层应内容自适应，不得占满全屏');
  });
}
