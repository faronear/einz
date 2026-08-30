// OnlySpace 交互式聊天 TUI —— 方案 A（分栏界面 + WS 实时接收 + 附件收发）。
//
// 与 onlyspace_chat.dart（方案 B，纯文本 REPL）不同，本文件提供：
//   - 分栏布局：消息区（滚动）+ 输入区（底部）+ 状态栏（顶部，含 WS 状态）
//   - 手写 ANSI 渲染（零新依赖；pub 缓存无 TUI 库且国内网络下载不稳）
//   - 后台 WS 实时监听（复用 shared WsClient，断线自动重连）
//   - 命令：/auth /sync /history /attach <file> /help /exit
//   - 逐键输入（raw 模式），Ctrl+C 或 /exit 退出
//
// 用法：
//   dart run bin/onlyspace_tui.dart --store demo/store-a.json --server http://127.0.0.1:3901
//
// 前置：store 已 init + config/import（已导入 Space Key）；未认证时先 /auth。
// 定位：测试端明文落盘（同 store.dart），不上生产。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:onlyspace_shared/onlyspace_shared.dart';
import 'package:onlyspace_cli/store.dart';
import 'package:onlyspace_cli/chat_core.dart';

// ---------- ANSI 转义 ----------
const _esc = '\x1B';
const _reset = '$_esc[0m';
const _green = '$_esc[32m';
const _yellow = '$_esc[33m';
const _cyan = '$_esc[36m';
const _gray = '$_esc[90m';
const _bold = '$_esc[1m';

const _clearHome = '$_esc[2J$_esc[H';
const _hideCursor = '$_esc[?25l';
const _showCursor = '$_esc[?25h';

/// 全局界面状态（单会话 TUI，简化处理）。
class _TuiState {
  _TuiState(this.session);

  final ChatSession session;

  /// 输入缓冲区（逐键追加）。
  final StringBuffer input = StringBuffer();

  /// 系统提示行（命令结果 / 错误），显示在状态栏下方。
  String status = '';

  /// 退出标志。
  bool running = true;
}

_TuiState? _state;

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
    stderr.writeln('$e');
    stderr.writeln('先运行: dart run bin/onlyspace.dart init --store $storePath --device-id <id>');
    exitCode = 1;
    return;
  }

  // 终端能力检测：TUI 需要可交互 stdin（raw 逐键）；stdout 非终端时渲染降级但不致命
  final term = Platform.environment['TERM'] ?? '';
  if (!stdin.hasTerminal || term == 'dumb') {
    stderr.writeln('未检测到交互终端，请用: dart run bin/onlyspace_chat.dart --store $storePath ${server.isEmpty ? '' : '--server $server'}');
    exitCode = 1;
    return;
  }

  final session = ChatSession(store, storePath, server);
  await session.loadHistory();
  _state = _TuiState(session);

  // 启动前先增量同步一次：补齐启动前错过的消息（本地历史只含上次落盘内容，
  // WS 只推连接建立之后的实时事件；不先 sync 的话，对方刚发的消息要手动 /sync 才出现）
  if (session.hasSession && server.isNotEmpty) {
    try {
      final fresh = await session.sync();
      if (fresh.isNotEmpty) {
        _state!.status = '启动同步：新增 ${fresh.length} 条';
      }
    } on Exception catch (e) {
      _state!.status = '启动同步跳过: $e（可稍后 /sync）';
    }
  }

  // 启动 WS 实时监听（已认证且配置了 server 时）；新消息到达或连接状态变化即重绘
  if (session.hasSession && server.isNotEmpty) {
    session.startWs(
      onMessage: (_) => _render(),
      onStatus: (_) => _render(),
    );
  }

  _render();
  await _runInputLoop(session);
  _exitRaw();
  session.stopWs();
  _printFarewell(session);
}

// ---------- raw 模式 ----------
void _enterRaw() {
  stdin.echoMode = false;
  stdin.lineMode = false;
}

/// 恢复终端为 cooked 模式（回显 + 行缓冲）。
/// 必须在 stdin 订阅 cancel **之前**调用：一旦 sub.cancel() 后 stdin 底层
/// fd 会失效，此时设 echoMode 会抛 Bad file descriptor（终端停在 raw 模式）。
void _restoreTerminal() {
  try {
    stdin.echoMode = true;
    stdin.lineMode = true;
  } catch (_) {
    // pty/重定向环境下 fd 可能已失效；真实终端无此问题。兜底不打断退出链路。
  }
}

void _exitRaw() {
  _restoreTerminal();
}

// ---------- 渲染 ----------

/// 显示宽度：东亚全角字符（中文/日文/谚文/全角符号/emoji）算 2 列，其余 1 列。
/// 用于截断防超宽换行（终端按显示列数折行，Dart 的 String.length 是 UTF-16 计数）。
int _displayWidth(String s) {
  var w = 0;
  for (final r in s.runes) {
    final wide = (r >= 0x1100 && r <= 0x115F) || // 谚文字母
        (r >= 0x2E80 && r <= 0xA4CF) || // CJK 部首/笔画/注音/假名/谚文/汉字等
        (r >= 0xAC00 && r <= 0xD7A3) || // 谚文音节
        (r >= 0xF900 && r <= 0xFAFF) || // CJK 兼容
        (r >= 0xFE30 && r <= 0xFE4F) || // CJK 兼容形式
        (r >= 0xFF00 && r <= 0xFF60) || // 全角形式
        (r >= 0xFFE0 && r <= 0xFFE6) || // 全角符号
        (r >= 0x1F300 && r <= 0x1FAFF); // emoji
    w += wide ? 2 : 1;
  }
  return w;
}

/// 从尾部截取不超过 [maxWidth] 显示宽度的子串。
/// [maxWidth] <= 0 时返回空串（防止窄终端下 substring 越界抛 RangeError）。
String _tailByWidth(String s, int maxWidth) {
  if (maxWidth <= 0) return '';
  final runes = s.runes.toList();
  var w = 0;
  for (var i = runes.length - 1; i >= 0; i--) {
    w += _displayWidth(String.fromCharCode(runes[i]));
    if (w > maxWidth) {
      return String.fromCharCodes(runes.sublist(i + 1));
    }
  }
  return s;
}

/// 终端行数（非终端/pty 下 terminalLines 可能抛异常，兜底 24）。
int _termLines() {
  try {
    return stdout.terminalLines;
  } catch (_) {
    return 24;
  }
}

/// 终端列数（非终端/pty 下 terminalColumns 可能抛异常，兜底 80）。
int _termCols() {
  try {
    return stdout.terminalColumns;
  } catch (_) {
    return 80;
  }
}

void _render() {
  final s = _state;
  if (s == null) return;
  final rows = _termLines();
  final cols = _termCols();
  final msgArea = rows - 2; // 顶部状态栏 1 行 + 底部输入行 1 行

  final buf = StringBuffer();
  buf.write(_hideCursor);
  buf.write(_clearHome);

  // 状态栏（第 1 行）
  final ws = s.session.wsClient?.status ?? WsStatus.stopped;
  final wsName = switch (ws) {
    WsStatus.connected => 'WS:${_green}●${_reset}',
    WsStatus.connecting => 'WS:${_yellow}↻${_reset}',
    WsStatus.reconnecting => 'WS:${_yellow}↻重连${_reset}',
    WsStatus.stopped => 'WS:${_gray}○${_reset}',
  };
  buf.write('${_bold}OnlySpace TUI${_reset}  ${s.session.store.deviceId} @ ${s.session.store.spaceId ?? '-'}  $wsName');
  if (s.status.isNotEmpty) {
    buf.write('  ${_gray}${s.status}${_reset}');
  }
  buf.write('\r\n');

  // 消息区：拼接本地历史 + 系统提示，取末尾 msgArea 行
  final lines = <String>[];
  for (final m in s.session.messages) {
    lines.add(_formatMessage(m, cols));
  }
  final start = lines.length > msgArea ? lines.length - msgArea : 0;
  for (var i = start; i < lines.length; i++) {
    buf.write(lines[i]);
    buf.write('\r\n');
  }

  // 输入行（最后一行）
  final prompt = '${_cyan}you>${_reset} ';
  final visible = _tailByWidth(s.input.toString(), cols - _displayWidth(prompt));
  buf.write(prompt);
  buf.write(visible);
  buf.write(_showCursor);

  // 渲染可能因终端环境抛异常（如 pty 下 Dart stdout 与 stdin 共享 StreamSink，
  // stdin.listen 后 write 报 "StreamSink is bound to a stream"；真实终端无此问题）。
  // 兜底：渲染失败不崩溃，业务逻辑（发送/同步/WS 落盘）照常。
  try {
    stdout.write(buf.toString());
    stdout.flush();
  } catch (_) {
    // 忽略渲染异常（终端能力不足时降级为不刷新界面）
  }
}

String _formatMessage(ChatMessage m, int cols) {
  final who = m.isMine ? '我' : '对方';
  final color = m.isMine ? _green : _yellow;
  final seq = m.seq == null ? '' : ' seq=${m.seq}';
  final prefix = '$color[$who$seq v${m.keyVersion}]$_reset ';
  final body = m.plain.replaceAll('\n', ' ');
  final maxW = cols - _displayWidth(prefix);
  final trimmed = maxW > 0 && _displayWidth(body) > maxW ? _tailByWidth(body, maxW) : body;
  return '$prefix$trimmed';
}

/// 只重绘输入行（不清屏）：打字时用，避免全量 \x1B[2J 清屏打断
/// 输入法（IME）预编辑——中文/长文字输入"没有回显"的根因。
void _renderInputLine() {
  final s = _state;
  if (s == null) return;
  final rows = _termLines();
  final cols = _termCols();
  final prompt = '${_cyan}you>${_reset} ';
  final visible = _tailByWidth(s.input.toString(), cols - _displayWidth(prompt));

  final buf = StringBuffer();
  buf.write('\x1B[${rows};1H'); // 定位到最后一行第 1 列
  buf.write('\x1B[K'); // 清除该行
  buf.write(prompt);
  buf.write(visible);
  buf.write(_showCursor);
  try {
    stdout.write(buf.toString());
    stdout.flush();
  } catch (_) {}
}

// ---------- 输入循环（逐键，异步流）----------
// 注意：readByteSync 在 pty/重定向环境下与 stdout.write 存在 StreamSink 冲突
// （Dart 已知行为），故改用 stdin.listen 异步字节流 + busy 锁防并发。
Future<void> _runInputLoop(ChatSession session) async {
  _enterRaw();
  final completer = Completer<void>();
  var busy = false;
  late final StreamSubscription<String> sub;
  // utf8.decoder：raw 模式下多字节字符（如中文）可能被拆成多个字节到达，
  // 由解码器缓冲拼合后再逐字符处理（避免中文乱码）。
  sub = stdin.transform(utf8.decoder).listen((chunk) {
    for (final ch in chunk.split('')) {
      if (!(_state?.running ?? false)) break;
      final code = ch.codeUnitAt(0);
      if (code == 3) {
        // Ctrl+C → 退出（先恢复终端，再取消监听，见 _restoreTerminal 注释）
        _state!.running = false;
        _restoreTerminal();
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (code == 13 || code == 10) {
        // 回车：提交输入
        final line = _state!.input.toString().trim();
        _state!.input.clear();
        if (line.isEmpty) {
          _renderInputLine();
          continue;
        }
        if (busy) continue; // 上一条命令/消息还在处理
        busy = true;
        final future = line.startsWith('/') ? _execCommand(line) : _sendText(line);
        future.whenComplete(() {
          busy = false;
          if (!(_state?.running ?? false)) {
            // /exit 或 /quit：先恢复终端（必须在 sub.cancel 之前，否则 fd 失效
            // 无法设 echoMode），再取消监听并结束主流程（否则 await 永远挂起）
            _restoreTerminal();
            sub.cancel();
            if (!completer.isCompleted) completer.complete();
          } else {
            _render();
          }
        });
        continue;
      }
      if (code == 127 || code == 8) {
        // 退格：只重绘输入行（不清屏，避免打断 IME）
        final cur = _state!.input.toString();
        if (cur.isNotEmpty) {
          _state!.input.clear();
          _state!.input.write(cur.substring(0, cur.length - 1));
        }
        _renderInputLine();
        continue;
      }
      if (code >= 32) {
        _state!.input.writeCharCode(code);
        _renderInputLine();
      }
    }
  }, onDone: () {
    if (!completer.isCompleted) {
      _state!.running = false;
      completer.complete();
    }
  });
  await completer.future;
}

Future<void> _sendText(String text) async {
  final s = _state!;
  try {
    final ok = await s.session.sendText(text);
    s.status = ok ? '已发送' : '已入队（离线，恢复后自动补发）';
  } on Exception catch (e) {
    s.status = '发送失败: $e';
  }
}

Future<void> _execCommand(String line) async {
  final s = _state!;
  final parts = line.split(RegExp(r'\s+'));
  final cmd = parts[0];
  final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';

  switch (cmd) {
    case '/help':
      s.status = '命令: /auth [server] /sync /history /attach <file> /exit';
    case '/auth':
      try {
        await s.session.auth(serverOverride: arg.isEmpty ? null : arg);
        s.status = '✅ 认证成功: space_id=${s.session.store.spaceId}';
        // 认证成功后启动 WS 实时监听
        if (s.session.wsClient == null && s.session.hasSession) {
          s.session.startWs(
            onMessage: (_) => _render(),
            onStatus: (_) => _render(),
          );
        }
      } on Exception catch (e) {
        s.status = '认证失败: $e';
      }
    case '/sync':
      try {
        final fresh = await s.session.sync();
        s.status = '同步完成: 新增=${fresh.length} 队列剩余=${s.session.store.pendingCount}';
      } on Exception catch (e) {
        s.status = '同步失败: $e';
      }
    case '/history':
      s.status = '本地消息 ${s.session.messages.length} 条（上方滚动区）';
    case '/attach':
      if (arg.isEmpty) {
        s.status = '用法: /attach <文件路径> [描述]';
      } else {
        try {
          final r = await s.session.attachFile(arg);
          s.status = '✅ 附件已上传: ${r.caption} (id=${r.attachmentId.substring(0, 8)})';
        } on Exception catch (e) {
          s.status = '附件上传失败: $e';
        }
      }
    case '/exit':
    case '/quit':
      s.running = false;
    default:
      s.status = '未知命令: $cmd（/help 查看）';
  }
}

void _printFarewell(ChatSession session) {
  stdout.writeln();
  stdout.writeln('${_gray}已退出 OnlySpace TUI（最后同步锚点 ${session.store.lastServerSequence}）${_reset}');
}
