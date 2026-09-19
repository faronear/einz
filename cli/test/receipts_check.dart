// 回执（已送达/已读）端到端回归 —— 直接驱动 ChatSession，不走 TUI。
//
// 为什么不用 pty：TUI 的事件循环由键盘输入驱动，WS 投递/上报时机不确定，
// pty 版断言会偶发失败（见 worklog 2026-09-12）。这里改为直接构造两个
// ChatSession（共享同一个 spaceKey），对真实服务端跑一遍，完全确定性。
//
// 覆盖（老板 2026-09-12 定的语义）：
//  1) 收到对方消息后 sync → **上报已送达**（delivered_upto_seq = 本地锚点）
//  2) 补拉/同步**不**上报已读（read 只由 WS 实时到达推进）→ 此时服务端 read 应为 0
//  3) 服务端回读：delivered ≥ 1 且 delivered ≥ read（读隐含送达）
//
// 运行：dart run test/receipts_check.dart（需先 cd server && npm run build）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
  final root = Directory.current.parent.path; // cli/ → 仓库根
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
  // 等就绪
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

Future<Map<String, dynamic>> _getReceipts(String server, String token) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('$server/receipts'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.set('X-Protocol-Version', '1'); // 协议硬校验（PROTOCOL.md §1）
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('GET /receipts -> ${res.statusCode} $text');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<int> _run() async {
  final work = await Directory.systemTemp.createTemp('einz-rcpt-');
  final port = await _freePort();
  final server = 'http://127.0.0.1:$port';
  final proc = await _startServer(port, work.path);

  try {
    final api = ApiClient(server);
    // A 创建空间（sealedSpaceKey 仅需结构合法；本测试不跑 escrow 解密流程）
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
    // B 凭 join token 加入（拿到 space 级 session）
    final joined = await api.joinSpace(
      token: created.joinToken,
      publicKey: 'pk-b',
      partnerSlot: 1,
      deviceName: 'b',
    );

    // 两端共享同一个 spaceKey（真实流程里由 escrow 口令包传递，这里直接给定——
    // 回执链路与密钥分发无关）
    final spaceKey = Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    final keyB64 = base64Encode(spaceKey);

    final storeA = _store(
      publicKey: 'pk-a',
      privateKey: 'sk-a',
      spaceKeyB64: keyB64,
      spaceId: created.spaceId,
      deviceId: created.deviceId,
      personId: created.creatorPersonId,
      sessionToken: created.sessionToken,
      server: server,
    );
    final storeB = _store(
      publicKey: 'pk-b',
      privateKey: 'sk-b',
      spaceKeyB64: keyB64,
      spaceId: joined.spaceId,
      deviceId: joined.deviceId,
      personId: joined.personId,
      sessionToken: joined.sessionToken,
      server: server,
    );

    final sessionA = ChatSession(storeA, '${work.path}/a.json', server);
    final sessionB = ChatSession(storeB, '${work.path}/b.json', server);

    // A 发一条
    final ok = await sessionA.sendText('receipt-probe');
    if (!ok) {
      stderr.writeln('❌ A 发送失败');
      return 1;
    }

    // B 同步（补拉）→ 应上报"已送达"、**不**上报已读
    await sessionB.sync();
    if (storeB.lastReportedDeliveredSeq < 1) {
      stderr.writeln('❌ B 未上报已送达（lastReportedDeliveredSeq='
          '${storeB.lastReportedDeliveredSeq}）');
      return 1;
    }
    if (storeB.lastReportedReadSeq != 0) {
      stderr.writeln('❌ B 的补拉不应上报已读（lastReportedReadSeq='
          '${storeB.lastReportedReadSeq}）');
      return 1;
    }

    // 服务端回读
    final receipts = (await _getReceipts(server, storeB.sessionToken!))['receipts']
        as List<dynamic>;
    final row = receipts.cast<Map<String, dynamic>>().firstWhere(
          (r) => r['person_id'] == storeB.personId,
          orElse: () => <String, dynamic>{},
        );
    if (row.isEmpty) {
      stderr.writeln('❌ 服务端查不到 B 的回执行：$receipts');
      return 1;
    }
    final delivered = row['delivered_upto_seq'] as int;
    final read = row['read_upto_seq'] as int;
    if (delivered < 1) {
      stderr.writeln('❌ 服务端 delivered_upto_seq 未推进：$row');
      return 1;
    }
    if (delivered < read) {
      stderr.writeln('❌ 读隐含送达被破坏（delivered < read）：$row');
      return 1;
    }
    if (read != 0) {
      stderr.writeln('❌ 补拉后服务端 read 应为 0（read 只由 WS 实时到达推进）：$row');
      return 1;
    }

    stdout.writeln('✅ CLI 回执链路：B 补拉上报已送达=$delivered、已读=$read'
        '（补拉不标已读 ✓）');
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
  final code = await _run();
  exit(code);
}
