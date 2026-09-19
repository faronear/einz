// 消息发送状态（pending / sent / delivered）回归 —— 直接驱动 ChatSession。
//
// 验证老板 2026-09-13 要的「TUI 像 App 一样显示我发出消息的状态」的数据层：
//   1) 刚发出、对方未确认 → sent
//   2) 对方 sync（补拉）上报 delivered → 我 refreshReceipts 后 → delivered
//   3) 离线（无 server/session）发出 → pending（留在离线队列）
//
// 运行：dart run test/message_status_check.dart（需 cd server && npm run build）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:einz_shared/einz_shared.dart';
import 'package:einz_cli/chat_core.dart';
import 'package:einz_cli/store.dart';

const kPassphrase = 'pass123';

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

Future<Process> _startServer(int port, String workDir) async {
  final root = Directory.current.parent.path;
  final p = await Process.start(
    'node',
    ['${root}/server/dist/app.js'],
    environment: {
      ...Platform.environment,
      'PORT': '$port',
      'EINZ_DB': '$workDir/einz.sqlite.db',
      'EINZ_FILES': '$workDir/files',
    },
  );
  final client = HttpClient();
  for (var i = 0; i < 60; i++) {
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final res = await req.close();
      await res.drain<void>();
      client.close();
      return p;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  client.close();
  throw StateError('服务端未就绪');
}

DeviceStore _store({
  required String publicKey,
  required String privateKey,
  required String spaceKeyB64,
  required String spaceId,
  required String deviceId,
  required String personId,
  required String sessionToken,
  required String server,
}) {
  final st = DeviceStore(
    publicKey: publicKey,
    privateKey: privateKey,
    spaceKey: spaceKeyB64,
    spaceId: spaceId,
    keyVersion: 1,
    sessionToken: sessionToken,
  );
  st.deviceId = deviceId;
  st.personId = personId;
  return st;
}

ChatMessage? _find(ChatSession s, String plain) {
  for (final m in s.messages) {
    if (m.plain == plain) return m;
  }
  return null;
}

Future<int> _run() async {
  final work = await Directory.systemTemp.createTemp('einz-status-');
  final port = await _freePort();
  final server = 'http://127.0.0.1:$port';
  final proc = await _startServer(port, work.path);
  try {
    final api = ApiClient(server);
    final created = await api.createSpace(
      publicKey: 'pk-a',
      personName: 'Lukas',
      partnerName: 'Alice',
      escrowPassphrase: kPassphrase,
      sealedSpaceKey: PassphraseEnvelope(
        salt: Uint8List.fromList(List.filled(16, 1)),
        nonce: Uint8List.fromList(List.filled(24, 2)),
        ciphertext: Uint8List.fromList(List.filled(8, 3)),
      ),
    );
    final joined = await api.joinSpace(
      token: created.joinToken,
      publicKey: 'pk-b',
      partnerSlot: 1,
      deviceName: 'b',
    );

    final spaceKey = base64Encode(Uint8List.fromList(
        List<int>.generate(32, (_) => DateTime.now().microsecond % 256)));
    final storeA = _store(
      publicKey: 'pk-a',
      privateKey: 'sk-a',
      spaceKeyB64: spaceKey,
      spaceId: created.spaceId,
      deviceId: created.deviceId,
      personId: created.creatorPersonId,
      sessionToken: created.sessionToken,
      server: server,
    );
    final storeB = _store(
      publicKey: 'pk-b',
      privateKey: 'sk-b',
      spaceKeyB64: spaceKey,
      spaceId: joined.spaceId,
      deviceId: joined.deviceId,
      personId: joined.personId,
      sessionToken: joined.sessionToken,
      server: server,
    );
    final sessionA = ChatSession(storeA, '${work.path}/a.json', server);
    final sessionB = ChatSession(storeB, '${work.path}/b.json', server);

    // 1) A 发出 → 对方未确认 → sent（服务端已收下）
    if (!await sessionA.sendText('status-probe')) {
      stderr.writeln('❌ A 发送失败');
      return 1;
    }
    final ma = _find(sessionA, 'status-probe');
    if (ma == null) {
      stderr.writeln('❌ A 展示缓存里没有刚发的消息');
      return 1;
    }
    if (sessionA.sentStatusOf(ma) != 'sent') {
      stderr.writeln('❌ 期望 sent，实际 ${sessionA.sentStatusOf(ma)}');
      return 1;
    }

    // 2) B 补拉（上报 delivered）→ A 刷新回执 → delivered
    await sessionB.sync();
    await sessionA.refreshReceipts();
    if (sessionA.sentStatusOf(ma) != 'delivered') {
      stderr.writeln('❌ 期望 delivered，实际 ${sessionA.sentStatusOf(ma)}'
          '（peerDeliveredUpto=${sessionA.peerDeliveredUpto}）');
      return 1;
    }

    // 2.5) B 已读（App 在前台贴底时上报 read）→ A 刷新 → read（TUI 标蓝）
    await api.postReceipts(storeB.sessionToken!, readUptoSeq: 1);
    await sessionA.refreshReceipts();
    if (sessionA.sentStatusOf(ma) != 'read') {
      stderr.writeln('❌ 期望 read，实际 ${sessionA.sentStatusOf(ma)}'
          '（peerReadUpto=${sessionA.peerReadUpto}）');
      return 1;
    }

    // 3) 载荷 meta 解析：手动构造一条 voice 消息（含 audioDurationSeconds）经
    //    服务端往返 → sync 解密后 ChatMessage.meta 应带出时长（TUI 渲染喇叭+秒数）
    final voiceEnv = await encryptMessage(
      plaintext: encodeMessagePayload('语音', meta: {kMetaAudioDurationSeconds: 18}),
      spaceKey: base64Decode(spaceKey),
      spaceId: created.spaceId,
      senderDeviceId: storeA.deviceId!,
      senderPersonId: storeA.personId,
      messageId: 'voice-${DateTime.now().microsecondsSinceEpoch}',
      type: 'voice',
    );
    await api.postMessage(voiceEnv, storeA.sessionToken!);
    await sessionA.sync();
    final mv = _find(sessionA, '语音');
    if (mv == null || mv.meta?[kMetaAudioDurationSeconds] != 18) {
      stderr.writeln('❌ 语音 meta 时长未解析：meta=${mv?.meta}');
      return 1;
    }

    // 4) 离线发出 → pending（进入离线队列，未确认）
    final storeOffline = DeviceStore(
      publicKey: 'pk-c',
      privateKey: 'sk-c',
      spaceKey: spaceKey,
      spaceId: created.spaceId,
    )
      ..deviceId = 'dev-offline'
      ..personId = 'person-offline';
    final sessionOffline = ChatSession(storeOffline, '${work.path}/c.json', '');
    if (await sessionOffline.sendText('offline-probe')) {
      stderr.writeln('❌ 离线发送不应返回成功');
      return 1;
    }
    final mo = _find(sessionOffline, 'offline-probe');
    if (mo == null || sessionOffline.sentStatusOf(mo) != 'pending') {
      stderr.writeln('❌ 期望 pending，实际 ${mo == null ? '(未上屏)' : sessionOffline.sentStatusOf(mo)}');
      return 1;
    }

    stdout.writeln('✅ 消息状态：发出=sent、对方补拉后=delivered、已读=read、离线=pending；'
        '语音 meta 时长=18s 解析通过');
    return 0;
  } finally {
    proc.kill();
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  }
}

Future<void> main() async {
  await sodium();
  exit(await _run());
}
