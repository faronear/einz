import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

import 'package:onlyspace_cli/client.dart';
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
    ..addOption('after', defaultsTo: '0', help: '同步起点 server_sequence');
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
  final store = DeviceStore.load(_require(opts, 'store'));
  store.requireSpace();
  final server = _require(opts, 'server');
  final message = _require(opts, 'message');
  if (store.sessionToken == null) {
    throw StateError('未认证，先运行 auth');
  }
  final api = ApiClient(server);
  final messageId = await _uuidv7();
  final env = await encryptMessage(
    plaintext: message,
    spaceKey: base64Decode(store.spaceKey!),
    spaceId: store.spaceId!,
    senderDeviceId: store.deviceId,
    messageId: messageId,
  );
  final result = await api.postMessage(env, store.sessionToken!);
  store.lastServerSequence = result.serverSequence;
  store.save(_require(opts, 'store'));
  stdout.writeln('✅ 已发送: message_id=${result.messageId} seq=${result.serverSequence}');
}

Future<void> _cmdSync(ArgResults opts) async {
  final store = DeviceStore.load(_require(opts, 'store'));
  store.requireSpace();
  final server = _require(opts, 'server');
  if (store.sessionToken == null) {
    throw StateError('未认证，先运行 auth');
  }
  final api = ApiClient(server);
  final after = int.parse(opts['after'] as String);
  final result = await api.sync(store.sessionToken!, after: after);

  for (final env in result.messages) {
    final plain = await decryptMessage(
      env: env,
      spaceKey: base64Decode(store.spaceKey!),
      spaceId: store.spaceId!,
      keyVersion: env.keyVersion,
    );
    final sender = env.senderDeviceId == store.deviceId ? '我' : '对方';
    stdout.writeln('[$sender seq=${env.serverSequence}] $plain');
  }
  store.lastServerSequence = result.lastSequence;
  store.save(_require(opts, 'store'));
  stdout.writeln('ℹ️  同步完成: last_sequence=${result.lastSequence} has_more=${result.hasMore}');
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
