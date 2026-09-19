// Einz 交互式聊天 CLI —— 方案 B 雏形（轻量 REPL：发送 + 同步 + 彩色输出）。
//
// 与 einz.dart（子命令式测试端）不同，本文件提供持续对话体验：
//   - 启动即同步历史，直接输入文本即发送
//   - ANSI 彩色输出（我=绿色、对方=黄色、系统=灰、错误=红）
//
// 用法：
//   dart run bin/einz_chat.dart --store store-a.json --server http://localhost:3000
//
// 前置：store 已 init + config/import（已导入 Space Key），若未认证先 /auth。
// 说明：这是 Phase 0–4 的交互验证端，密钥仍以明文 JSON 落盘（同 store.dart 的测试定位）。

import 'dart:convert';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:einz_cli/store.dart';

// ---------- ANSI 颜色 ----------
const _reset = '\x1B[0m';
const _red = '\x1B[31m';
const _green = '\x1B[32m';
const _yellow = '\x1B[33m';
const _cyan = '\x1B[36m';
const _gray = '\x1B[90m';

void _info(String s) => stdout.writeln('$_gray$s$_reset');
void _ok(String s) => stdout.writeln('$_green$s$_reset');
void _err(String s) => stdout.writeln('$_red$s$_reset');
String _paint(String text, String color) => '$color$text$_reset';

Future<void> main(List<String> args) async {
  await sodium();

  var storePath = 'store.json';
  var server = '';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--store':
        storePath = args[++i];
      case '--server':
        server = args[++i];
    }
  }

  DeviceStore store;
  try {
    store = DeviceStore.load(storePath);
  } on StateError catch (e) {
    _err('$e');
    _info('先用 TUI 引导创建/加入秘境: dart run bin/einz_tui.dart --store $storePath --server <url>');
    exitCode = 1;
    return;
  }

  _ok('Einz 聊天 CLI（方案 B 雏形）');
  _info('设备: ${store.deviceId}  空间: ${store.spaceId ?? '（未导入 Space Key）'}');
  if (server.isNotEmpty) _info('服务器: $server');

  await _repl(store, storePath, server);
}

Future<void> _repl(DeviceStore store, String storePath, String server) async {
  // 启动即同步一次历史（离线或无 server 时跳过）
  if (server.isNotEmpty && store.spaceKey != null) {
    try {
      await _cmdSync(store, storePath, server);
    } catch (e) {
      _info('启动同步跳过（$e），可稍后 /sync');
    }
  }

  _printHelp();
  while (true) {
    stdout.write(_paint('you> ', _cyan));
    final line = stdin.readLineSync();
    if (line == null) {
      _info('再见 👋');
      return; // EOF (Ctrl+D)
    }
    final text = line.trim();
    if (text.isEmpty) continue;

    if (text.startsWith('/')) {
      final parts = text.split(RegExp(r'\s+'));
      final cmd = parts[0];
      final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      switch (cmd) {
        case '/help':
          _printHelp();
        case '/auth':
          try {
            await _cmdAuth(store, storePath, arg.isEmpty ? server : arg);
            _ok('✅ 认证成功: space_id=${store.spaceId}');
          } on Exception catch (e) {
            _err('认证失败: $e');
          }
        case '/sync':
          try {
            await _cmdSync(store, storePath, server);
          } on Exception catch (e) {
            _err('同步失败: $e');
          }
        case '/history':
          await _cmdHistory(store);
        case '/exit':
        case '/quit':
          _info('再见 👋');
          return;
        default:
          _err('未知命令: $cmd（/help 查看）');
      }
    } else {
      await _sendText(store, storePath, server, text);
      // 发送后顺带同步一次，能立即看到对方回复（在线时）
      if (server.isNotEmpty && store.sessionToken != null) {
        try {
          await _cmdSync(store, storePath, server);
        } on Exception catch (e) {
          _info('（发送后同步跳过: $e）');
        }
      }
    }
  }
}

void _printHelp() {
  _info('--- 命令 ---');
  _info('  直接输入文本         发送消息（加密后经 server 投递）');
  _info('  /auth [server]       （重新）认证设备');
  _info('  /sync                增量同步并显示新消息');
  _info('  /history             显示本地历史消息');
  _info('  /help                显示本帮助');
  _info('  /exit                退出（或 Ctrl+D）');
}

// ---------- 认证：challenge → sealOpen → verify ----------
Future<void> _cmdAuth(DeviceStore store, String storePath, String server) async {
  if (server.isEmpty) throw StateError('缺少服务器地址（/auth <server> 或启动时 --server）');
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
  store.save(storePath);
}

// ---------- 发送：加密 → 入队 → 补发 ----------
Future<void> _sendText(DeviceStore store, String storePath, String server, String text) async {
  store.requireSpace();
  final messageId = await _uuidv7();
  final env = await encryptMessage(
    plaintext: text,
    spaceKey: base64Decode(store.spaceKey!),
    spaceId: store.spaceId!,
    senderDeviceId: store.deviceId!,
    messageId: messageId,
    keyVersion: store.keyVersion,
  );

  // 1) 先入队（幂等，离线不丢）
  store.enqueuePending(jsonEncode(env.toJson()));
  store.save(storePath);

  // 2) 在线则立即补发
  if (server.isEmpty || store.sessionToken == null) {
    _info('📤 已入队（离线，待恢复后自动补发）: message_id=$messageId');
    return;
  }
  final sent = await _flushPending(store, storePath, server);
  if (sent > 0) {
    _ok('✅ [我] $text');
  } else {
    _info('⚠️ 发送失败，已留在队列: message_id=$messageId');
  }
}

/// 补发离线队列：成功一条出队一条并写入历史；网络失败停止本轮（下次再试）。
Future<int> _flushPending(DeviceStore store, String storePath, String server) async {
  store.requireSession();
  final api = ApiClient(server);
  var sent = 0;
  for (final env in store.pendingEnvelopes) {
    try {
      final result = await api.postMessage(env, store.sessionToken!);
      store.dequeuePending(env.messageId);
      store.upsertHistory(env, serverSequence: result.serverSequence, createdAt: result.createdAt);
      sent++;
    } on Exception catch (e) {
      _info('  ↳ 补发失败（留队）: message_id=${env.messageId} → $e');
      break;
    }
  }
  if (sent > 0) store.save(storePath);
  return sent;
}

// ---------- 同步：增量拉取 → 落盘历史 → 解密打印新增 ----------
Future<void> _cmdSync(DeviceStore store, String storePath, String server) async {
  if (server.isEmpty) throw StateError('缺少服务器地址（--server）');
  store.requireSpace();
  store.requireSession();
  final api = ApiClient(server);

  var cursor = store.lastServerSequence;
  final added = <MessageEnvelope>[];
  while (true) {
    final result = await api.sync(store.sessionToken!, after: cursor);
    for (final env in result.messages) {
      final seq = env.serverSequence ?? cursor;
      store.upsertHistory(env, serverSequence: seq, createdAt: seq);
      added.add(env);
      cursor = seq;
    }
    if (result.lastSequence > cursor) cursor = result.lastSequence;
    store.advanceAnchor(result.lastSequence);
    if (!result.hasMore || result.messages.isEmpty) break;
  }
  store.save(storePath);

  // 补发离线队列
  final flushed = await _flushPending(store, storePath, server);
  if (added.isNotEmpty || flushed > 0) {
    _info('📥 同步完成: last_sequence=${store.lastServerSequence} 新增=${added.length} 补发=$flushed');
  }

  // 解密并打印新增消息（按 key_version 选密钥，轮换后旧消息用归档密钥）
  for (final env in added) {
    await _printEnvelope(store, env);
  }
}

// ---------- 历史：解密打印本地全部消息 ----------
Future<void> _cmdHistory(DeviceStore store) async {
  final envs = store.historyEnvelopes;
  if (envs.isEmpty) {
    _info('ℹ️  本地暂无消息');
    return;
  }
  for (final env in envs) {
    await _printEnvelope(store, env);
  }
  _info('ℹ️  共 ${envs.length} 条本地消息（队列剩余 ${store.pendingCount}）');
}

Future<void> _printEnvelope(DeviceStore store, MessageEnvelope env) async {
  final keyB64 = store.spaceKeyForVersion(env.keyVersion) ?? store.spaceKey!;
  final plain = await decryptMessage(
    env: env,
    spaceKey: base64Decode(keyB64),
    spaceId: store.spaceId!,
  );
  final isMine = env.senderPersonId != null && store.personId != null
      ? env.senderPersonId == store.personId
      : env.senderDeviceId == store.deviceId;
  final sender = isMine ? '我' : '你';
  final color = isMine ? _green : _yellow;
  final seq = env.serverSequence;
  final seqTag = seq == null ? '未同步' : 'seq=$seq';
  stdout.writeln(_paint('[$sender $seqTag v${env.keyVersion}] $plain', color));
}

/// 简易 UUIDv7（与 einz.dart 一致的近似实现）。
Future<String> _uuidv7() async {
  final s = await sodium();
  final rand = s.randombytes.buf(10);
  final t = DateTime.now().millisecondsSinceEpoch;
  final hex = rand.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final tHex = t.toRadixString(16).padLeft(12, '0');
  return '${tHex.substring(0, 8)}-${tHex.substring(8)}-7${hex.substring(0, 3)}-9${hex.substring(3, 7)}-${hex.substring(7)}';
}
