import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:onlyspace_shared/onlyspace_shared.dart';

import 'package:onlyspace_cli/store.dart';

/// OnlySpace CLI 测试端（无 UI，Phase 0–4 测试驱动）。
///
/// 用法示例：
///   dart run bin/onlyspace.dart init --store store-a.json --device-id dev-a1
///   dart run bin/onlyspace.dart pubkey --store store-a.json
///   dart run bin/onlyspace.dart config --store store-a.json --peer-pubkey <B公钥> \
///       --space-id space-1 --out-config config.json --out-sealed-peer sealed-b.json
///   dart run bin/onlyspace.dart import --store store-b.json --sealed-file sealed-b.json --space-id space-1
///   dart run bin/onlyspace.dart auth --store store-a.json --server http://localhost:3000
///   dart run bin/onlyspace.dart send --store store-a.json --server ... --message "你好"
///   dart run bin/onlyspace.dart sync --store store-b.json --server ...
Future<void> main(List<String> args) async {
  await sodium();
  final parser = ArgParser()
    ..addOption('store', abbr: 's', help: '设备状态存储文件')
    ..addOption('device-id', help: '设备 ID（init 用）')
    ..addOption('server', help: '服务器地址，如 http://localhost:3000')
    ..addOption('message', abbr: 'm', help: '要发送的消息文本')
    ..addOption('peer-pubkey', help: '对方设备公钥（base64，config 用）')
    ..addOption('space-id', help: 'Space ID')
    ..addOption('out-config', help: '输出服务器 config.json 路径')
    ..addOption('out-sealed-peer', help: '输出给对方设备的密封 Space Key 文件')
    ..addOption('sealed-file', help: '导入的密封 Space Key 文件（import 用）')
    ..addOption('after', help: '同步起点 server_sequence（默认: 本地锚点 last_server_sequence）')
    ..addOption('file', help: '要上传的本地文件路径（attach 用）')
    ..addOption('type', help: '附件类型: image|video|voice（attach 用，默认按扩展名推断）')
    ..addOption('caption', help: '附件消息描述文本（attach 用，默认文件名）')
    ..addOption('attachment-id', help: '要下载的附件 ID（fetch 用）')
    ..addOption('out', help: '下载输出的本地文件路径（fetch 用，默认当前目录）');
  final cmd = args.isEmpty ? 'help' : args.first;
  final rest = args.length > 1 ? args.sublist(1) : <String>[];
  final opts = parser.parse(rest);

  switch (cmd) {
    case 'init':
      _cmdInit(opts);
    case 'pubkey':
      _cmdPubkey(opts);
    case 'config':
      await _cmdConfig(opts);
    case 'import':
      await _cmdImport(opts);
    case 'auth':
      await _cmdAuth(opts);
    case 'send':
      await _cmdSend(opts);
    case 'sync':
      await _cmdSync(opts);
    case 'listen':
      await _cmdListen(opts);
    case 'attach':
      await _cmdAttach(opts);
    case 'fetch':
      await _cmdFetch(opts);
    case 'help':
    default:
      stdout.writeln(parser.usage);
  }
}

String _require(ArgResults opts, String key) {
  final v = opts[key] as String?;
  if (v == null || v.isEmpty) {
    throw StateError('缺少参数 --$key');
  }
  return v;
}

Future<void> _cmdInit(ArgResults opts) async {
  final path = _require(opts, 'store');
  final deviceId = opts['device-id'] as String? ?? 'dev-auto';
  if (File(path).existsSync()) {
    throw StateError('存储已存在: $path（如需重建请先删除）');
  }
  final store = await DeviceStore.create(deviceId);
  store.save(path);
  stdout.writeln('✅ init: device_id=${store.deviceId}');
  stdout.writeln('   public_key=${store.publicKey}');
}

void _cmdPubkey(ArgResults opts) {
  final store = DeviceStore.load(_require(opts, 'store'));
  stdout.writeln(store.publicKey);
}

Future<void> _cmdConfig(ArgResults opts) async {
  final store = DeviceStore.load(_require(opts, 'store'));
  final peerPubkey = _require(opts, 'peer-pubkey');
  final spaceId = _require(opts, 'space-id');
  final outConfig = opts['out-config'] as String?;
  final outSealedPeer = opts['out-sealed-peer'] as String?;

  final s = await sodium();
  final spaceKey = await generateSpaceKey();
  final sealedPeer = await sealFor(s, base64Decode(peerPubkey), spaceKey);

  // 写入本机 Space Key（测试存储）
  store.spaceKey = base64Encode(spaceKey);
  store.spaceId = spaceId;
  store.save(_require(opts, 'store'));

  // 服务器 config.json（白名单）
  if (outConfig != null) {
    final cfg = {
      'space_id': spaceId,
      'devices': [
        {
          'device_id': store.deviceId,
          'person_id': 'person-a',
          'public_key': store.publicKey,
          'status': 'active',
        },
        {
          'device_id': 'dev-b1',
          'person_id': 'person-b',
          'public_key': peerPubkey,
          'status': 'active',
        },
      ],
    };
    File(outConfig).writeAsStringSync(JsonEncoder.withIndent('  ').convert(cfg));
    stdout.writeln('✅ config.json 已写入: $outConfig');
  }

  // 对方的密封 Space Key 文件
  if (outSealedPeer != null) {
    File(outSealedPeer).writeAsStringSync(base64Encode(sealedPeer));
    stdout.writeln('✅ 对方密封副本已写入: $outSealedPeer');
  }
  stdout.writeln('✅ Space Key 已生成并密封（key_version=1）');
}

Future<void> _cmdImport(ArgResults opts) async {
  final store = DeviceStore.load(_require(opts, 'store'));
  final sealedFile = _require(opts, 'sealed-file');
  final spaceId = _require(opts, 'space-id');
  final s = await sodium();

  final sealed = base64Decode(File(sealedFile).readAsStringSync().trim());
  final opened = await sealOpen(s, sealed, store.publicKeyBytes, store.privateKeyBytes);
  store.spaceKey = base64Encode(opened);
  store.spaceId = spaceId;
  store.save(_require(opts, 'store'));
  stdout.writeln('✅ Space Key 导入成功: ${store.deviceId}');
}

Future<void> _cmdAuth(ArgResults opts) async {
  final store = DeviceStore.load(_require(opts, 'store'));
  final server = _require(opts, 'server');
  final api = ApiClient(server);
  final s = await sodium();

  final challenge = await api.challenge(store.deviceId);
  final opened = await sealOpen(
    s,
    base64Decode(challenge.sealedChallenge),
    store.publicKeyBytes,
    store.privateKeyBytes,
  );
  final session = await api.verify(challenge.challengeId, base64Encode(opened));
  store.sessionToken = session.sessionToken;
  store.save(_require(opts, 'store'));
  stdout.writeln('✅ 认证成功: space_id=${session.spaceId}');
}

Future<void> _cmdSend(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();
  final message = _require(opts, 'message');

  final messageId = await _uuidv7();
  final env = await encryptMessage(
    plaintext: message,
    spaceKey: base64Decode(store.spaceKey!),
    spaceId: store.spaceId!,
    senderDeviceId: store.deviceId,
    messageId: messageId,
  );

  // 1) 先入队（幂等），保证离线不丢
  store.enqueuePending(jsonEncode(env.toJson()));
  store.save(path);

  // 2) 尝试立即发送；--server 可省略（纯离线模式：只入队）
  final server = opts['server'] as String?;
  if (server == null || store.sessionToken == null) {
    stdout.writeln('📤 已入队（离线，待恢复后自动补发）: message_id=$messageId');
    return;
  }
  final sent = await _flushPending(store, path, server);
  if (sent > 0) {
    stdout.writeln('✅ 已发送并出队: message_id=$messageId');
  } else {
    stdout.writeln('⚠️ 发送失败，已留在队列，恢复网络后自动补发: message_id=$messageId');
  }
}

/// 补发离线队列中的所有消息；成功一条出队一条、写入历史并推进锚点。
/// 网络失败时停止本轮补发，剩余留队（下次 sync/listen 再试）。
/// 返回本轮成功补发的条数。
Future<int> _flushPending(DeviceStore store, String path, String server) async {
  store.requireSession();
  final api = ApiClient(server);
  var sent = 0;
  for (final env in store.pendingEnvelopes) {
    try {
      final result = await api.postMessage(env, store.sessionToken!);
      store.dequeuePending(env.messageId);
      if (result.serverSequence > store.lastServerSequence) {
        store.lastServerSequence = result.serverSequence;
      }
      store.upsertHistory(env, serverSequence: result.serverSequence, createdAt: result.createdAt);
      sent++;
      stdout.writeln('  ↳ 补发成功: message_id=${env.messageId} seq=${result.serverSequence}');
    } on Exception catch (e) {
      stdout.writeln('  ↳ 补发失败（留队）: message_id=${env.messageId} → $e');
      break; // 网络层问题：停止本轮，避免空转
    }
  }
  if (sent > 0) store.save(path);
  return sent;
}

Future<void> _cmdSync(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();
  final server = _require(opts, 'server');
  final afterOpt = opts['after'] as String?;

  // 1) 增量拉取（has_more 翻页拉全量）并落盘历史
  final added = await _syncIncremental(store, server, after: afterOpt == null ? null : int.parse(afterOpt));
  store.save(path);

  // 2) 解密并打印本次新增消息
  for (final env in added) {
    final plain = await decryptMessage(
      env: env,
      spaceKey: base64Decode(store.spaceKey!),
      spaceId: store.spaceId!,
      keyVersion: env.keyVersion,
    );
    final sender = env.senderDeviceId == store.deviceId ? '我' : '对方';
    stdout.writeln('[$sender seq=${env.serverSequence}] $plain');
  }

  // 3) 补发离线队列（网络已恢复时）
  final flushed = await _flushPending(store, path, server);
  stdout.writeln(
      'ℹ️  同步完成: last_sequence=${store.lastServerSequence} 新增=${added.length} 补发=$flushed 队列剩余=${store.pendingCount}');
}

/// 下载附件：GET /attachments/:id → 校验密文 sha256 → 解密 → 写本地文件。
/// 需要本地已有该附件的元数据（nonce/sha256），否则提示先 sync。
Future<void> _cmdFetch(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();
  final server = _require(opts, 'server');
  store.requireSession();
  final attachmentId = _require(opts, 'attachment-id');

  final meta = store.attachmentMeta(attachmentId);
  if (meta == null) {
    throw StateError('本地无附件元数据: $attachmentId（先运行 sync 拉取元数据）');
  }

  final api = ApiClient(server);
  final blob = await api.getAttachment(attachmentId, store.sessionToken!);

  // 校验密文完整性（sha256 与元数据一致，PROTOCOL.md §6.1；编码与 Server 同为 base64）
  final actual = base64Encode(crypto.sha256.convert(blob).bytes);
  if (actual != meta['sha256']) {
    throw StateError('附件密文 sha256 校验失败（传输损坏或被篡改）');
  }

  final plain = await decryptAttachment(
    cipherText: blob,
    nonce: base64Decode(meta['nonce'] as String),
    spaceKey: base64Decode(store.spaceKey!),
    attachmentId: attachmentId,
    spaceId: store.spaceId!,
    keyVersion: meta['key_version'] as int,
  );

  // 输出路径：--out 指定，或当前目录下 <attachment_id>.bin
  final out = (opts['out'] as String?) ?? '${attachmentId.substring(0, 8)}.bin';
  File(out).writeAsBytesSync(plain);
  stdout.writeln('✅ 附件已下载并解密: $out（${plain.length} 字节）');
}

/// 上传附件：本地文件加密 → 先发一条附件消息（type=image/video/voice）→
/// 再上传密文 blob（PROTOCOL.md §6.1：必须先有对应 message）。
Future<void> _cmdAttach(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();
  final server = _require(opts, 'server');
  store.requireSession();
  final filePath = _require(opts, 'file');

  final file = File(filePath);
  if (!file.existsSync()) {
    throw StateError('文件不存在: $filePath');
  }
  final fileBytes = file.readAsBytesSync();
  final fileName = file.path.split(RegExp(r'[\\/]')).last;

  final messageId = await _uuidv7();
  final attachmentId = await _uuidv7();
  final type = _inferAttachmentType(opts['type'] as String?, fileName);
  final caption = (opts['caption'] as String?) ?? '📎 $fileName';

  // 1) 加密文件（密文 + 元数据）
  final enc = await encryptAttachment(
    fileBytes: fileBytes,
    spaceKey: base64Decode(store.spaceKey!),
    attachmentId: attachmentId,
    spaceId: store.spaceId!,
    keyVersion: store.keyVersion,
  );

  // 2) 先发附件消息（正文为描述文本，密文上链）
  final env = await encryptMessage(
    plaintext: caption,
    spaceKey: base64Decode(store.spaceKey!),
    spaceId: store.spaceId!,
    senderDeviceId: store.deviceId,
    messageId: messageId,
    type: type,
    keyVersion: store.keyVersion,
  );
  final api = ApiClient(server);
  final msg = await api.postMessage(env, store.sessionToken!);

  // 3) 再上传附件 blob（Server 校验 size + sha256）
  final att = await api.postAttachment(
    messageId: messageId,
    attachmentId: attachmentId,
    keyVersion: store.keyVersion,
    size: enc.size,
    sha256: enc.sha256,
    nonce: base64Encode(enc.nonce),
    blob: enc.cipher,
    token: store.sessionToken!,
  );

  // 4) 落盘：附件元数据 + 消息历史 + 推进锚点
  store.upsertAttachment(
    attachmentId: attachmentId,
    messageId: messageId,
    keyVersion: store.keyVersion,
    size: enc.size,
    sha256: enc.sha256,
    nonce: base64Encode(enc.nonce),
    createdAt: att['created_at'] as int,
  );
  store.upsertHistory(env, serverSequence: msg.serverSequence, createdAt: msg.createdAt);
  store.advanceAnchor(msg.serverSequence);
  store.save(path);

  stdout.writeln('✅ 附件已上传: attachment_id=$attachmentId');
  stdout.writeln('   message_id=$messageId type=$type seq=${msg.serverSequence}');
  stdout.writeln('   密文 ${enc.size} 字节，sha256=${enc.sha256.substring(0, 16)}…');
}

/// 推断附件类型：显式指定优先，否则按扩展名（默认 image）。
String _inferAttachmentType(String? explicit, String fileName) {
  if (explicit != null) {
    const allowed = {'image', 'video', 'voice'};
    if (!allowed.contains(explicit)) throw StateError('--type 只能是 image|video|voice');
    return explicit;
  }
  final ext = fileName.split('.').last.toLowerCase();
  const videoExt = {'mp4', 'mov', 'mkv', 'avi', 'webm'};
  const voiceExt = {'mp3', 'm4a', 'wav', 'ogg', 'aac', 'flac'};
  if (videoExt.contains(ext)) return 'video';
  if (voiceExt.contains(ext)) return 'voice';
  return 'image';
}

/// 实时监听：连接 WS 接收 message.new，实时落盘历史并解密打印。
/// 断线自动重连，重连前先 /sync 补齐错过的消息（PROTOCOL.md §8.3）。
Future<void> _cmdListen(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();
  final server = _require(opts, 'server');
  store.requireSession();

  // 启动前先补一次同步（含补发离线队列），避免错过断线期间消息
  final added = await _syncIncremental(store, server);
  await _flushPending(store, path, server);
  store.save(path);
  if (added.isNotEmpty) {
    stdout.writeln('📥 启动前补齐 ${added.length} 条');
  }

  final wsUrl = server.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
  stdout.writeln('🔌 实时监听: $wsUrl/ws（Ctrl+C 退出）');
  while (true) {
    try {
      // token 含 base64 的 +/= 字符，必须 URL 编码（PROTOCOL.md §8.1）
      final uri = Uri.parse('$wsUrl/ws?pv=1&token=${Uri.encodeQueryComponent(store.sessionToken!)}');
      final ws = await WebSocket.connect(uri.toString());
      stdout.writeln('✅ WS 已连接');
      await for (final data in ws) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        switch (frame['type']) {
          case 'hello':
            final payload = frame['payload'] as Map<String, dynamic>;
            stdout.writeln('ℹ️  hello: device_id=${payload['device_id']} space_id=${payload['space_id']}');
          case 'message.new':
            final payload = frame['payload'] as Map<String, dynamic>;
            final env = MessageEnvelope.fromJson(payload['message'] as Map<String, dynamic>);
            final seq = payload['server_sequence'] as int;
            final createdAt = payload['message']['created_at'] as int;
            store.upsertHistory(env, serverSequence: seq, createdAt: createdAt);
            store.advanceAnchor(seq);
            store.save(path);
            final plain = await decryptMessage(
              env: env,
              spaceKey: base64Decode(store.spaceKey!),
              spaceId: store.spaceId!,
              keyVersion: env.keyVersion,
            );
            final sender = env.senderDeviceId == store.deviceId ? '我' : '对方';
            stdout.writeln('[$sender seq=$seq] $plain');
          case 'ping':
            // 忽略服务端不应下发的类型；心跳由客户端发起
          default:
          // 忽略未知帧（pong / sync.advance / key.rotation / device.revoked 等）
        }
      }
      stdout.writeln('⚠️ WS 已断开，2 秒后重连…');
    } catch (e) {
      stdout.writeln('⚠️ WS 连接失败: $e，2 秒后重连…');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    // 重连前补齐错过的消息 + 补发离线队列
    try {
      final backfilled = await _syncIncremental(store, server);
      await _flushPending(store, path, server);
      store.save(path);
      if (backfilled.isNotEmpty) {
        stdout.writeln('📥 重连补齐 ${backfilled.length} 条');
      }
    } catch (_) {
      // server 不可达，继续等待重连
    }
  }
}

/// 增量拉取：从本地锚点（或指定 after）开始，has_more 时翻页拉全量，
/// 每条落盘 history 并推进锚点。返回本次新增消息（按 server_sequence 升序）。
Future<List<MessageEnvelope>> _syncIncremental(
  DeviceStore store,
  String server, {
  int? after,
}) async {
  store.requireSession();
  final api = ApiClient(server);
  var cursor = after ?? store.lastServerSequence;
  final added = <MessageEnvelope>[];
  while (true) {
    final result = await api.sync(store.sessionToken!, after: cursor);
    for (final env in result.messages) {
      store.upsertHistory(env, serverSequence: env.serverSequence!, createdAt: env.createdAt!);
      added.add(env);
    }
    // 附件元数据落盘（供 fetch 解密，PROTOCOL.md §5.2 attachments_meta）
    for (final meta in result.attachmentsMeta) {
      store.upsertAttachment(
        attachmentId: meta['attachment_id'] as String,
        messageId: meta['message_id'] as String,
        keyVersion: meta['key_version'] as int,
        size: meta['size'] as int,
        sha256: meta['sha256'] as String,
        nonce: meta['nonce'] as String,
        createdAt: meta['created_at'] as int,
      );
    }
    if (result.messages.isNotEmpty) {
      cursor = result.lastSequence;
      store.advanceAnchor(result.lastSequence);
    }
    if (!result.hasMore || result.messages.isEmpty) break;
  }
  return added;
}

/// 简易 UUIDv7 生成（Dart 无内置，用随机 16 字节 + 时间前缀的近似实现即可满足测试）。
Future<String> _uuidv7() async {
  final s = await sodium();
  final rand = s.randombytes.buf(10);
  final t = DateTime.now().millisecondsSinceEpoch;
  final hex = rand.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final tHex = t.toRadixString(16).padLeft(12, '0');
  return '${tHex.substring(0, 8)}-${tHex.substring(8)}-7${hex.substring(0, 3)}-9${hex.substring(3, 7)}-${hex.substring(7)}';
}
