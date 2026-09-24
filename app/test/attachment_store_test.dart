// 回归：分片目录下的「全量清理」必须递归。
//
// 背景：留存明文（AttachmentStore）与媒体缓存（MediaCache）都按空间分片在
// `<dir>/<safe(spaceId)>/` 子目录里。此前 AttachmentStore.clear / MediaCache.deleteAll
// 只 `dir.list()` 顶层、且非 File 就跳过——分片后顶层只有目录，于是"切回安全模式"
// 与"整机重置"实际一个文件都没删：解密明文残留。这两个方法是数据销毁承诺的落点，
// 所以用真实临时目录守住"递归删 + 只删本类文件"。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:einz/data/attachment_store.dart';
import 'package:einz/data/media_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('einz_store_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // AttachmentStore 的目录由自定义通道 'einz/store' 提供（原生侧返回"不备份"目录）
    messenger.setMockMethodCallHandler(
      const MethodChannel('einz/store'),
      (call) async => call.method == 'getStoredDir' ? tempDir.path : null,
    );
    // MediaCache 走 path_provider
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getTemporaryDirectory' ? tempDir.path : null,
    );
    AttachmentStore.resetForTest();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('einz/store'), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), null);
    AttachmentStore.resetForTest();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('MediaCache.deleteAll 递归删掉空间子目录里的缓存文件', () async {
    final a = await MediaCache.pathFor('space-1', 'msg-1', 'mp3');
    final b = await MediaCache.pathFor('space-2', 'msg-2', 'mp4');
    await a.writeAsBytes(const [1, 2, 3]);
    await b.writeAsBytes(const [4, 5, 6]);

    await MediaCache.deleteAll();

    expect(await a.exists(), isFalse, reason: 'space-1 子目录里的缓存应被删掉');
    expect(await b.exists(), isFalse, reason: 'space-2 子目录里的缓存应被删掉');
  });

  test('AttachmentStore.clear 递归删掉空间子目录里的留存明文', () async {
    final a = (await AttachmentStore.pathFor('space-1', 'msg-1', 'mp3'))!;
    final b = (await AttachmentStore.pathFor('space-2', 'msg-2', 'mp4'))!;
    await a.writeAsBytes(const [1, 2, 3]);
    await b.writeAsBytes(const [4, 5, 6]);

    await AttachmentStore.clear();

    expect(await a.exists(), isFalse, reason: 'space-1 子目录里的留存明文应被删掉');
    expect(await b.exists(), isFalse, reason: 'space-2 子目录里的留存明文应被删掉');
  });

  test('只删本类文件：目录里无关文件不动', () async {
    final a = (await AttachmentStore.pathFor('space-1', 'msg-1', 'mp3'))!;
    await a.writeAsBytes(const [1, 2, 3]);
    final stranger = File('${tempDir.path}/space-1/keep_me.txt');
    await stranger.writeAsString('not ours');

    await AttachmentStore.clear();

    expect(await a.exists(), isFalse);
    expect(await stranger.exists(), isTrue, reason: '非本类文件不应被误删');
  });
}
