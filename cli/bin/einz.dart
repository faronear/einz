import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:einz_shared/einz_shared.dart';

import 'package:einz_cli/store.dart';

/// Einz CLI 测试端（无 UI，Phase 0–4 测试驱动）。
///
/// 用法示例：
///   dart run bin/einz.dart init --store store-a.json --device-id dev-a1
///   dart run bin/einz.dart pubkey --store store-a.json
///   dart run bin/einz.dart config --store store-a.json --peer-pubkey <B公钥> \
///       --space-id space-1 --out-config config.json --out-sealed-peer sealed-b.json
///   dart run bin/einz.dart import --store store-b.json --sealed-file sealed-b.json --space-id space-1
///   dart run bin/einz.dart auth --store store-a.json --server http://localhost:3000
///   dart run bin/einz.dart send --store store-a.json --server ... --message "你好"
///   dart run bin/einz.dart sync --store store-b.json --server ...
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
    ..addOption('person', help: '创建者 person id（config 用，默认 person-a）')
    ..addOption('peer-person', help: '对方 person id（config 用，默认 person-b）')
    ..addOption('sealed-file', help: '导入的密封 Space Key 文件（import 用）')
    ..addOption('after', help: '同步起点 server_sequence（默认: 本地锚点 last_server_sequence）')
    ..addOption('file', help: '要上传的本地文件路径（attach 用）')
    ..addOption('type', help: '附件类型: image|video|voice（attach 用，默认按扩展名推断）')
    ..addOption('caption', help: '附件消息描述文本（attach 用，默认文件名）')
    ..addOption('attachment-id', help: '要下载的附件 ID（fetch 用）')
    ..addOption('out', help: '下载输出的本地文件路径（fetch 用）/ 备份输出文件（backup 用）')
    ..addOption('in', help: '备份输入文件（restore 用）')
    ..addOption('recovery-code', help: '12 词恢复码（restore 用；backup 会自动生成并打印）')
    ..addOption('key-version', help: '导入的 Space Key 版本号（import 用，默认 1；轮换导入时用新版本）')
    ..addOption('action', help: 'escrow 子命令: upload|download')
    ..addOption('passphrase', help: '口令托管密钥的口令（escrow 用）')
    ..addOption('invite-code', help: '邀请码（enroll 用；留空=首设备自举，登记为创建者）')
    ..addOption('hours', help: '邀请码有效期小时数（invite 用，默认 24）')
    ..addOption('device-name', help: '设备自定义名称（enroll 用，显示层，如 MacBook）')
    ..addOption('name', help: '对方自定义名称（invite 用，如 steffi；person_id 为规范 id）');
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
    case 'backup':
      await _cmdBackup(opts);
    case 'restore':
      await _cmdRestore(opts);
    case 'rotate':
      await _cmdRotate(opts);
    case 'seal':
      await _cmdSeal(opts);
    case 'history':
      _cmdHistory(opts);
    case 'escrow':
      // 口令托管（KEY_ESCROW.md §4）：upload = 口令加密 Space Key 包上传；
      // download = 拉取并解出写回 store（新设备凭口令接入）
      if (opts['action'] == 'upload') {
        await _cmdEscrowUpload(opts);
      } else {
        await _cmdEscrowDownload(opts);
      }
    case 'enroll':
      // 设备登记：首个设备免邀请码自举（=创建者），之后凭邀请码加入
      await _cmdEnroll(opts);
    case 'invite':
      // 创建者生成邀请码（POST /invites）
      await _cmdInvite(opts);
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
  final store = await DeviceStore.create(deviceId: deviceId);
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
          'person_id': (opts['person'] as String?) ?? 'person-a',
          'public_key': store.publicKey,
          'status': 'active',
        },
        {
          'device_id': 'dev-b1',
          'person_id': (opts['peer-person'] as String?) ?? 'person-b',
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
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  final sealedFile = _require(opts, 'sealed-file');
  final spaceId = _require(opts, 'space-id');
  final keyVersion = int.tryParse(opts['key-version'] as String? ?? '1') ?? 1;
  final s = await sodium();

  final sealed = base64Decode(File(sealedFile).readAsStringSync().trim());
  final opened = await sealOpen(s, sealed, store.publicKeyBytes, store.privateKeyBytes);

  // 轮换导入（--key-version > 当前）：旧密钥归档（E2EE.md §9.2），写入新版本密钥
  if (keyVersion > store.keyVersion && store.spaceKey != null) {
    store.archivedSpaceKeys.add({'key_version': store.keyVersion, 'space_key': store.spaceKey});
  }
  store.spaceKey = base64Encode(opened);
  store.spaceId = spaceId;
  store.keyVersion = keyVersion;
  store.save(path);
  stdout.writeln('✅ Space Key 导入成功: ${store.deviceId}（key_version=$keyVersion）');
}

Future<void> _cmdAuth(ArgResults opts) async {
  final store = DeviceStore.load(_require(opts, 'store'));
  final server = _require(opts, 'server');
  final api = ApiClient(server);
  final s = await sodium();

  final challenge = await api.challenge(store.deviceId!);
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

/// enroll：设备动态登记。
/// - 不带邀请码 → 首设备自举（空间无设备时），登记为创建者（person 用 --person 指定）；
/// - 带邀请码 → 常规登记（加入已有空间，person 由服务端按邀请码决定）。
/// 登记响应带 server 的 space_id，写入 store（后续 escrow/发消息用它，与服务端一致）。
Future<void> _cmdEnroll(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  final server = _require(opts, 'server');
  final inviteCode = opts['invite-code'] as String?;
  final displayName = opts['person'] as String?; // 你的名称（如 lukas），enroll 后写入 store
  final deviceName = opts['device-name'] as String?;
  final r = await ApiClient(server).enrollDevice(
    deviceId: store.deviceId,
    publicKey: store.publicKey,
    inviteCode: inviteCode,
    displayName: displayName,
    deviceName: deviceName,
  );
  // 登记响应带回服务端分配的规范 id：更新 store（deviceId=devN、personId=personA/B）
  store.deviceId = r.deviceId;
  store.personId = r.personId;
  if (displayName != null && displayName.isNotEmpty) store.personName = displayName;
  if (deviceName != null && deviceName.isNotEmpty) store.deviceName = deviceName;
  store.spaceId = r.spaceId;
  store.save(path);
  final isBootstrap = inviteCode == null || inviteCode.isEmpty;
  stdout.writeln('✅ 登记成功: device_id=${r.deviceId} person_id=${r.personId} space_id=${r.spaceId}');
  if (isBootstrap) {
    stdout.writeln('   （首设备自举：你是空间创建者，可 escrow upload 上传托管包、invite 生成邀请码）');
  }
}

/// invite：生成一次性邀请码（POST /invites，需先 auth 拿 session）。
/// person 为规范 id（personA=自己加设备 / personB=邀请对方）；--name 给新 person 设显示名。
Future<void> _cmdInvite(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  final server = _require(opts, 'server');
  if (store.sessionToken == null) {
    throw StateError('未认证：请先运行 auth --store $path --server $server');
  }
  final personId = _require(opts, 'person');
  if (personId != 'personA' && personId != 'personB') {
    throw StateError('--person 必须是规范 id: personA（自己加设备）或 personB（邀请对方）');
  }
  final name = opts['name'] as String?;
  final hours = int.tryParse(opts['hours'] as String? ?? '24') ?? 24;
  final r = await ApiClient(server).createInvite(
    token: store.sessionToken!,
    personId: personId,
    displayName: name,
    hours: hours,
  );
  stdout.writeln('✅ 邀请码已生成（${hours}h 有效，一次性）: ${r.inviteCode}');
}

/// escrow upload：口令加密 Space Key 包并上传托管（KEY_ESCROW.md §4）。
/// Server 只存密文，无口令不可解。
/// 创建者初始化：store 无 Space Key 时自动生成（自主模式，无 config 命令）。
Future<void> _cmdEscrowUpload(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  if (store.spaceId == null) {
    throw StateError('缺少 space_id：请先运行 enroll（登记响应会写入 server 的 space_id）');
  }
  if (store.spaceKey == null) {
    final sk = await generateSpaceKey();
    store.spaceKey = base64Encode(sk);
    store.save(path);
    stdout.writeln('✅ 已生成 Space Key（创建者初始化，key_version=1）');
  }
  final server = _require(opts, 'server');
  final passphrase = _require(opts, 'passphrase');
  final api = ApiClient(server);
  final s = await sodium();

  final challenge = await api.challenge(store.deviceId!);
  final opened = await sealOpen(
    s,
    base64Decode(challenge.sealedChallenge),
    store.publicKeyBytes,
    store.privateKeyBytes,
  );
  final session = await api.verify(challenge.challengeId, base64Encode(opened));

  final escrow = KeyEscrowService(api);
  await escrow.upload(
    passphrase: passphrase,
    spaceKeyB64: store.spaceKey!,
    spaceId: store.spaceId!,
    keyVersion: store.keyVersion,
    token: session.sessionToken,
  );
  stdout.writeln('✅ 口令托管包已上传（Server 只存密文）: space_id=${store.spaceId}');
}

/// escrow download：拉取口令托管包并解出 Space Key 写回 store。
/// 新设备接入：init（生成身份）→ 白名单登记 → escrow download（凭口令）→ send/sync。
Future<void> _cmdEscrowDownload(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  final server = _require(opts, 'server');
  final passphrase = _require(opts, 'passphrase');
  final api = ApiClient(server);
  final s = await sodium();

  final challenge = await api.challenge(store.deviceId!);
  final opened = await sealOpen(
    s,
    base64Decode(challenge.sealedChallenge),
    store.publicKeyBytes,
    store.privateKeyBytes,
  );
  final session = await api.verify(challenge.challengeId, base64Encode(opened));

  final escrow = KeyEscrowService(api);
  final payload = await escrow.fetch(passphrase: passphrase, token: session.sessionToken);
  if (payload == null) {
    stdout.writeln('⚠️ Server 无口令托管包（请先在对端执行 escrow upload）');
    return;
  }

  // 写回 store（参照 import 的归档逻辑：新版本 > 当前时归档旧密钥）
  if (payload.keyVersion > store.keyVersion && store.spaceKey != null) {
    store.archivedSpaceKeys.add({'key_version': store.keyVersion, 'space_key': store.spaceKey});
  }
  store.spaceKey = payload.spaceKeyB64;
  store.spaceId = payload.spaceId;
  store.keyVersion = payload.keyVersion;
  store.save(path);
  stdout.writeln('✅ 口令托管包已解出 Space Key: space_id=${payload.spaceId} key_version=${payload.keyVersion}');
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
    senderDeviceId: store.deviceId!,
    messageId: messageId,
    keyVersion: store.keyVersion, // 轮换后新消息必须用当前 key_version（E2EE.md §9.1）
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

/// 补发离线队列中的所有消息；成功一条出队一条、写入历史（不推进锚点）。
/// 网络失败时停止本轮补发，剩余留队（下次 sync/listen 再试）。
/// 返回本轮成功补发的条数。
/// 注意：锚点只在 /sync 响应时推进（P2 修复）——否则新设备未同步先发消息
/// 会跳过对方历史（PROTOCOL.md §5.2，锚点 = 已同步的最高 seq）。
Future<int> _flushPending(DeviceStore store, String path, String server) async {
  store.requireSession();
  final api = ApiClient(server);
  var sent = 0;
  for (final env in store.pendingEnvelopes) {
    try {
      final result = await api.postMessage(env, store.sessionToken!);
      store.dequeuePending(env.messageId);
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

  // 2) 解密并打印本次新增消息（按消息 key_version 选密钥，轮换后旧消息用归档密钥）
  for (final env in added) {
    final keyB64 = store.spaceKeyForVersion(env.keyVersion) ?? store.spaceKey!;
    final plain = await decryptMessage(
      env: env,
      spaceKey: base64Decode(keyB64),
      spaceId: store.spaceId!,
    );
    final sender = env.senderDeviceId == store.deviceId ? '我' : '对方';
    stdout.writeln('[$sender seq=${env.serverSequence} v${env.keyVersion}] $plain');
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

/// 备份导出（E2EE.md §10.1）：生成恢复码 → 加密导出密钥归档 + 消息历史。
Future<void> _cmdBackup(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  final outPath = _require(opts, 'out');

  // 备份内容：密钥归档 + 历史消息 + 附件元数据（JSON）
  final payload = jsonEncode({
    'device_id': store.deviceId,
    'space_id': store.spaceId,
    'key_version': store.keyVersion,
    'space_key': store.spaceKey, // base64（测试端明文存储；App 生产走 Keychain/Keystore）
    'history': store.history,
    'attachments': store.attachments,
  });

  final recoveryCode = await generateRecoveryCode();
  final file = await encryptBackup(payload: Uint8List.fromList(utf8.encode(payload)), recoveryCode: recoveryCode);
  File(outPath).writeAsStringSync(JsonEncoder.withIndent('  ').convert(file.toJson()));

  stdout.writeln('✅ 备份已导出: $outPath');
  stdout.writeln('⚠️  恢复码（请离线妥善保存，丢失即无法恢复）:');
  stdout.writeln('   $recoveryCode');
}

/// 恢复（E2EE.md §10.2）：输入恢复码 → 解密备份 → 展示/写回设备存储。
Future<void> _cmdRestore(ArgResults opts) async {
  final inPath = _require(opts, 'in');
  final recoveryCode = _require(opts, 'recovery-code');
  final outPath = opts['store'] as String?;

  final raw = File(inPath).readAsStringSync();
  final file = BackupFile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  final plain = await decryptBackup(file: file, recoveryCode: recoveryCode);
  final data = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;

  stdout.writeln('✅ 备份解密成功（恢复码有效）');
  stdout.writeln('   device_id=${data['device_id']} space_id=${data['space_id']}');
  stdout.writeln('   key_version=${data['key_version']} 历史消息=${(data['history'] as List).length} 条');

  // 写回设备存储（--store 指定时；测试端恢复 = 生成新 store 并填入密钥）
  if (outPath != null) {
    final restored = DeviceStore(
      deviceId: data['device_id'] as String,
      publicKey: '', // 新设备公钥未生成：恢复后需重新 init + 登记白名单（E2EE.md §10.2 步骤 4）
      privateKey: '',
      spaceKey: data['space_key'] as String?,
      spaceId: data['space_id'] as String?,
      keyVersion: (data['key_version'] as int?) ?? 1,
      // 备份内容一并还原：本地历史 / 附件元数据 / 离线队列 / 归档密钥（E2EE.md §10.1）
      history: (data['history'] as List?)?.cast<Map<String, dynamic>>() ?? [],
      attachments: (data['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? [],
      pending: (data['pending'] as List?)?.cast<String>() ?? [],
      archivedSpaceKeys: (data['archived_space_keys'] as List?)?.cast<Map<String, dynamic>>() ?? [],
    );
    restored.save(outPath);
    stdout.writeln('✅ 已恢复设备存储: $outPath（历史 ${restored.historyCount} 条 + 队列 ${restored.pendingCount} 条；提示：设备身份需重新 init 并登记白名单）');
  }
}

/// 用本机已持有的 Space Key 密封给新设备公钥，输出 sealed 副本（一次性配置：
/// 把已有 Space Key 分发给新加入的设备，如 App 真机）。E2EE.md §7。
Future<void> _cmdSeal(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();
  final peerPubkey = _require(opts, 'peer-pubkey');
  final out = _require(opts, 'out');

  final s = await sodium();
  final sealed = await sealFor(s, base64Decode(peerPubkey), base64Decode(store.spaceKey!));
  File(out).writeAsStringSync(base64Encode(sealed));
  stdout.writeln('✅ 已用本机 Space Key（v${store.keyVersion}）密封给目标设备公钥');
  stdout.writeln('   副本已写入: $out（对方用 import 或 App 粘贴导入）');
}

/// Space Key 轮换（E2EE.md §9.1）：当前密钥归档（key_version+1），生成新密钥，
/// seal 给对方设备，写 sealed 文件。对方用 `import --key-version N` 导入并归档旧密钥。
Future<void> _cmdRotate(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();
  final peerPubkey = _require(opts, 'peer-pubkey');
  final outSealedPeer = _require(opts, 'out-sealed-peer');

  final s = await sodium();
  final newKeyB64 = await store.rotateSpaceKey();
  final sealedPeer = await sealFor(s, base64Decode(peerPubkey), base64Decode(newKeyB64));
  File(outSealedPeer).writeAsStringSync(base64Encode(sealedPeer));

  store.save(path);
  stdout.writeln('✅ Space Key 已轮换: key_version=${store.keyVersion}（旧版本已归档）');
  stdout.writeln('   对方密封副本已写入: $outSealedPeer（对方执行 import --key-version ${store.keyVersion}）');
}

/// 解密本地消息历史（不依赖 Server）：按每条消息的 key_version 选密钥，
/// 轮换后旧消息用归档密钥、新消息用当前密钥（E2EE.md §9.2）。
Future<void> _cmdHistory(ArgResults opts) async {
  final path = _require(opts, 'store');
  final store = DeviceStore.load(path);
  store.requireSpace();

  final envs = store.historyEnvelopes;
  if (envs.isEmpty) {
    stdout.writeln('ℹ️  本地暂无消息历史');
    return;
  }
  for (final env in envs) {
    final keyB64 = store.spaceKeyForVersion(env.keyVersion) ?? store.spaceKey!;
    final plain = await decryptMessage(
      env: env,
      spaceKey: base64Decode(keyB64),
      spaceId: store.spaceId!,
    );
    final sender = env.senderDeviceId == store.deviceId ? '我' : '对方';
    stdout.writeln('[$sender seq=${env.serverSequence ?? '-'} v${env.keyVersion}] $plain');
  }
  stdout.writeln('ℹ️  共 ${envs.length} 条本地消息');
}

/// 上传附件：本地文件加密 → 先上传密文 blob → 再发附件消息（type=image/video/voice）。
/// 两阶段先传后链（PROTOCOL.md §6.1）：blob 就位后才发消息，避免"消息已广播但对端
/// blob 缺失"的幽灵消息；消息发送失败时孤儿 blob 由服务端定期清理。
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

  // 2) 先上传附件 blob（Server 校验 size + sha256；对应 message 此时可尚不存在）
  final env = await encryptMessage(
    plaintext: caption,
    spaceKey: base64Decode(store.spaceKey!),
    spaceId: store.spaceId!,
    senderDeviceId: store.deviceId!,
    messageId: messageId,
    type: type,
    keyVersion: store.keyVersion,
  );
  final api = ApiClient(server);
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

  // 3) 再发附件消息（正文为描述文本，密文上链）
  final msg = await api.postMessage(env, store.sessionToken!);

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
            final keyB64 = store.spaceKeyForVersion(env.keyVersion) ?? store.spaceKey!;
            final plain = await decryptMessage(
              env: env,
              spaceKey: base64Decode(keyB64),
              spaceId: store.spaceId!,
                    );
            final sender = env.senderDeviceId == store.deviceId ? '我' : '对方';
            stdout.writeln('[$sender seq=$seq v${env.keyVersion}] $plain');
          case 'key.rotation':
            final payload = frame['payload'] as Map<String, dynamic>;
            stdout.writeln('🔑 收到 Space Key 轮换通知: 建议 key_version=${payload['key_version']}');
            stdout.writeln('   请执行 rotate --peer-pubkey <对方公钥> --out-sealed-peer <文件> 后 import');
          case 'device.revoked':
            final payload = frame['payload'] as Map<String, dynamic>;
            stdout.writeln('🚫 本设备已被撤销: device_id=${payload['device_id']}');
            return; // 被撤销：退出监听
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
