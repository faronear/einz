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
const _red = '$_esc[31m';
const _green = '$_esc[32m';
const _yellow = '$_esc[33m';
const _cyan = '$_esc[36m';
const _gray = '$_esc[90m';
const _bold = '$_esc[1m';
const _bgPink = '$_esc[105m'; // 亮品红背景：对方消息正文底色（区分收发双方）

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

  /// 输入区当前折行行数（>=1）：超长输入自动多行时消息区动态让位。
  int inputLines = 1;

  /// 退出标志。
  bool running = true;
}

_TuiState? _state;

/// SIGWINCH 防抖计时器（窗口尺寸变化 120ms 内合并为一次全量重绘）。
Timer? _resizeTimer;

/// 首次使用引导（cooked 模式逐行问答，进入 raw 模式前）。
/// 返回 (就绪的 store, 生效的 server 地址)；引导中选择 sealed 导入时置
/// exitCode=1（main 据此退出，提示用户改用 onlyspace.dart import）。
Future<(DeviceStore, String)> _onboard(String storePath, String server) async {
  var store = File(storePath).existsSync() ? DeviceStore.load(storePath) : null;

  if (store == null) {
    stdout.writeln('=== OnlySpace TUI 首次使用引导 ===');
    stdout.writeln('本机还没有设备身份，现在生成（私钥保存在本机: $storePath）');
    stdout.write('设备名称（如 dev-mac，回车默认 dev-auto）: ');
    final deviceId = (stdin.readLineSync() ?? '').trim();
    store = await DeviceStore.create(deviceId.isEmpty ? 'dev-auto' : deviceId);
    store.save(storePath);
    stdout.writeln('✅ 设备身份已生成: device_id=${store.deviceId}');
    stdout.writeln('   公钥: ${store.publicKey}');

    // 邀请码动态登记：新设备凭创建者给的邀请码自动登记（免人工加白名单/重启 server）
    if (server.isEmpty) {
      stdout.write('服务器地址（如 https://only.tic.cc）: ');
      server = (stdin.readLineSync() ?? '').trim();
    }
    if (server.isNotEmpty) {
      stdout.write('邀请码（空间创建者提供，可留空跳过）: ');
      final inviteCode = (stdin.readLineSync() ?? '').trim();
      if (inviteCode.isNotEmpty) {
        try {
          final r = await ApiClient(server).enrollDevice(
            deviceId: store.deviceId,
            publicKey: store.publicKey,
            inviteCode: inviteCode,
          );
          stdout.writeln('✅ 邀请码登记成功: person_id=${r.personId} space_id=${r.spaceId}');
        } on Exception catch (e) {
          stdout.writeln('⚠️ 邀请码登记失败: $e（无效/已用/过期或网络问题）');
          stdout.writeln('   可联系创建者重新生成邀请码，或人工加入白名单后重试');
        }
      } else {
        stdout.writeln('未输入邀请码：请把上面的公钥发给空间创建者加入白名单');
      }
    } else {
      stdout.writeln('未提供服务器地址，稍后可在 TUI 内用 /auth 补配');
    }
  }

  if (server.isEmpty) {
    stdout.write('服务器地址（如 https://only.tic.cc，回车跳过）: ');
    server = (stdin.readLineSync() ?? '').trim();
  }

  final session = ChatSession(store, storePath, server);

  // 无 Space Key → 引导接入：口令托管（推荐）或 sealed 导入（高级，提示用 CLI）
  if (store.spaceKey == null || store.spaceId == null) {
    stdout.writeln();
    stdout.writeln('本设备还没有 Space Key，无法收发消息。接入方式：');
    stdout.writeln('  1) 口令接入（推荐）：输入空间创建者给你的 space_id + 口令');
    stdout.writeln('  2) sealed 导入（高级）：dart run bin/onlyspace.dart import --store $storePath --sealed-file <文件>');
    stdout.write('选择 [回车=1 / 2] : ');
    final choice = (stdin.readLineSync() ?? '1').trim();
    if (choice == '2') {
      stdout.writeln('请先退出本程序，用 onlyspace.dart import 导入 sealed 文件后再运行。');
      exitCode = 1;
      return (store, server);
    }
    if (server.isEmpty) {
      stdout.writeln('⚠️ 未提供服务器地址，跳过口令接入（之后可 /auth 后手动 escrow download）');
    } else {
      stdout.writeln('口令由空间创建者告知（escrow 托管包按空间一份，凭口令即可解出 Space Key）');
      final passphrase = _readPassphrase('口令:（输入不回显）');
      try {
        await session.accessByEscrow(passphrase);
        stdout.writeln('✅ 口令接入成功: space_id=${store.spaceId} key_version=${store.keyVersion}');
      } catch (e) {
        // 注意：accessByEscrow 抛 StateError（Error 子类），on Exception 捕获不到
        stdout.writeln('⚠️ 口令接入失败: $e');
        stdout.writeln('   请确认：公钥已加入白名单？Server 已由创建者上传托管包？口令正确？');
      }
    }
  }

  // 未认证 → 引导认证（白名单已登记时 challenge-response 成功）
  if (store.sessionToken == null && server.isNotEmpty) {
    try {
      await session.auth();
      stdout.writeln('✅ 认证成功: space_id=${store.spaceId ?? '-'}');
    } catch (e) {
      // auth 抛 StateError（如 server 无效）也是 Error 子类，用 catch (e) 兜底
      stdout.writeln('⚠️ 认证失败: $e（可进入 TUI 后用 /auth 重试）');
    }
  }
  return (store, server);
}

/// 隐藏回显读取口令（逐键渲染星号，Windows PowerShell 也有输入反馈）：
/// - ① raw 逐键：echo/line 关，非回车键输出 '*'（退格擦除一个），口令 ASCII 场景可靠；
/// - ② 逐键失败（pty/重定向不支持 readByteSync）→ 回退整行隐藏读取；
/// - try/finally 确保 echoMode/lineMode 无论成功/异常都恢复，避免终端停在无回显状态。
String _readPassphrase(String prompt) {
  stdout.write(prompt);
  stdout.flush();
  try {
    stdin.echoMode = false;
    stdin.lineMode = false;
    final buf = StringBuffer();
    while (true) {
      final b = stdin.readByteSync();
      if (b == -1 || b == 13 || b == 10) break; // EOF 或回车
      if (b == 127 || b == 8) {
        // 退格：删除最后一个字符并擦掉一个星号
        if (buf.isNotEmpty) {
          final s = buf.toString();
          buf.clear();
          buf.write(s.substring(0, s.length - 1));
          stdout.write('\b \b');
          stdout.flush();
        }
        continue;
      }
      if (b < 32) continue; // 忽略其他控制字符
      buf.writeCharCode(b);
      stdout.write('*');
      stdout.flush();
    }
    stdout.writeln();
    return buf.toString();
  } catch (_) {
    // pty/重定向等不支持逐键：退回整行隐藏读取
    final v = stdin.readLineSync() ?? '';
    stdout.writeln();
    return v;
  } finally {
    try {
      stdin.echoMode = true;
    } catch (_) {}
    try {
      stdin.lineMode = true;
    } catch (_) {}
  }
}

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

  // 终端能力检测：TUI 需要可交互 stdin（raw 逐键）；stdout 非终端时渲染降级但不致命
  final term = Platform.environment['TERM'] ?? '';
  if (!stdin.hasTerminal || term == 'dumb') {
    stderr.writeln('未检测到交互终端，请用: dart run bin/onlyspace_chat.dart --store $storePath ${server.isEmpty ? '' : '--server $server'}');
    exitCode = 1;
    return;
  }

  // 上次异常退出（如 raw 模式下直接 Ctrl+C）可能残留无回显终端状态；
  // 引导（cooked 问答）前先恢复终端回显+行缓冲，否则输入文字看不见。
  _restoreTerminal();

  // 首次使用引导（cooked 逐行问答，进入 raw 模式前）：store 不存在 → 生成设备身份；
  // 无 Space Key → 口令接入（escrow）；未认证 → auth。全部就绪后才进入 TUI。
  final onboard = await _onboard(storePath, server);
  if (exitCode != 0) return; // 引导中选择 sealed 导入 → 提示后退出
  final store = onboard.$1;
  server = onboard.$2;

  final session = ChatSession(store, storePath, server);
  await session.loadHistory();
  _state = _TuiState(session);

  // 启动前先增量同步一次：补齐启动前错过的消息（本地历史只含上次落盘内容，
  // WS 只推连接建立之后的实时事件；不先 sync 的话，对方刚发的消息要手动 /sync 才出现）。
  // 未接入空间（无 Space Key）时跳过——历史无法解密，且 _decrypt 会兜底占位。
  if (session.hasSession && session.hasSpace && server.isNotEmpty) {
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

  // 终端窗口尺寸变化（SIGWINCH，macOS/Linux）→ 防抖后全量重绘：
  // 否则缩窗后旧折行仍残留（终端物理重排了显示内容，但我们的布局未按新列数重算）。
  // Windows 无 SIGWINCH，watch 会抛 UnsupportedError → try-catch 兜底。
  try {
    ProcessSignal.sigwinch.watch().listen((_) {
      _resizeTimer?.cancel();
      _resizeTimer = Timer(const Duration(milliseconds: 120), () {
        if ((_state?.running ?? false)) _render();
      });
    });
  } catch (_) {
    // 非 POSIX 平台忽略：尺寸变化不自动重绘，下次输入/消息会触发
  }

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

/// 按显示宽度把 [s] 折成不超过 [maxWidth] 的多行（从头开始，自动换行）。
/// 消息展示用：长消息完整显示为多行，而不是截断成一行丢尾部/头部。
List<String> _wrapByWidth(String s, int maxWidth) {
  if (maxWidth <= 0) return [s];
  final result = <String>[];
  final buf = StringBuffer();
  var w = 0;
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final cw = _displayWidth(ch);
    if (w + cw > maxWidth && buf.isNotEmpty) {
      result.add(buf.toString());
      buf.clear();
      w = 0;
    }
    buf.write(ch);
    w += cw;
  }
  if (buf.isNotEmpty || result.isEmpty) result.add(buf.toString());
  return result;
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

/// 输入内容折行：每行最大宽度 = cols - prompt 显示宽度（最后一行行首带 prompt）。
List<String> _wrapInput(String input, int cols) {
  final prompt = '${_cyan}you>${_reset} ';
  return _wrapByWidth(input, cols - _displayWidth(prompt));
}

void _render() {
  final s = _state;
  if (s == null) return;
  final rows = _termLines();
  final cols = _termCols();
  // 输入区折行行数：超长输入自动多行，消息区高度动态让位
  final inputWrapped = _wrapInput(s.input.toString(), cols);
  s.inputLines = inputWrapped.length;
  final msgArea = rows - 1 - s.inputLines; // 顶部状态栏 1 行 + 输入区 N 行

  final buf = StringBuffer();
  buf.write(_hideCursor);
  buf.write(_clearHome);

  // 状态栏（第 1 行）：WS 红绿灯状态（绿=在线，红=断线重连，黄=连接中，灰=离线）
  final ws = s.session.wsStatus;
  final wsName = switch (ws) {
    WsStatus.connected => 'WS:${_green}● 在线${_reset}',
    WsStatus.connecting => 'WS:${_yellow}↻ 连接中${_reset}',
    WsStatus.reconnecting =>
      'WS:${_red}✗ 断线重连中 (${s.session.wsDownSeconds}s)${_reset}',
    WsStatus.stopped => 'WS:${_gray}○ 离线${_reset}',
  };
  buf.write('${_bold}OnlySpace TUI${_reset}  ${s.session.store.deviceId} @ ${s.session.store.spaceId ?? '-'}  $wsName');
  if (s.status.isNotEmpty) {
    buf.write('  ${_gray}${s.status}${_reset}');
  }
  buf.write('\r\n');

  // 消息区：拼接本地历史 + 系统提示，取末尾 msgArea 行（长消息折行多行）
  final lines = <String>[];
  for (final m in s.session.messages) {
    lines.addAll(_formatMessage(m, cols));
  }
  final start = lines.length > msgArea ? lines.length - msgArea : 0;
  for (var i = start; i < lines.length; i++) {
    buf.write(lines[i]);
    buf.write('\r\n');
  }

  // 输入区（多行）：首行带 prompt，续行缩进对齐；超长输入自动换行
  final prompt = '${_cyan}you>${_reset} ';
  for (var i = 0; i < inputWrapped.length; i++) {
    if (i == 0) {
      buf.write(prompt);
    } else {
      buf.write('      '); // 缩进对齐 prompt（'you> ' 宽度）
    }
    buf.write(inputWrapped[i]);
    if (i < inputWrapped.length - 1) {
      buf.write('\r\n');
    }
  }
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

/// 格式化消息为多行（第一行带归属前缀，续行裸正文，自动按列宽折行）。
/// 自己的消息：绿色前缀 + 普通正文；对方消息：正文加粉红背景（一眼区分收发双方）。
List<String> _formatMessage(ChatMessage m, int cols) {
  final who = m.isMine ? '我' : '对方';
  final color = m.isMine ? _green : _yellow;
  final seq = m.seq == null ? '' : ' seq=${m.seq}';
  final prefix = '$color[$who$seq v${m.keyVersion}]$_reset ';
  final body = m.plain.replaceAll('\n', ' ');
  final maxW = cols - _displayWidth(prefix);
  final wrapped = _wrapByWidth(body, maxW);
  if (m.isMine) {
    return [
      '$prefix${wrapped.first}',
      ...wrapped.skip(1).map((line) => '$line'),
    ];
  }
  final pink = (String line) => '$_bgPink$line$_reset';
  return [
    '$prefix${pink(wrapped.first)}',
    ...wrapped.skip(1).map(pink),
  ];
}

/// 只重绘输入区（不清屏）：打字时用，避免全量 \x1B[2J 清屏打断
/// 输入法（IME）预编辑——中文/长文字输入"没有回显"的根因。
/// 输入区行数变化（超长切多行/退回单行）时消息区高度随之变化，需全量重绘。
void _renderInputLine() {
  final s = _state;
  if (s == null) return;
  final rows = _termLines();
  final cols = _termCols();
  final inputWrapped = _wrapInput(s.input.toString(), cols);
  if (inputWrapped.length != s.inputLines) {
    _render(); // 行数变化 → 消息区让位 → 全量重绘
    return;
  }
  final prompt = '${_cyan}you>${_reset} ';
  final top = rows - inputWrapped.length + 1; // 输入区顶部行号

  final buf = StringBuffer();
  for (var i = 0; i < inputWrapped.length; i++) {
    buf.write('\x1B[${top + i};1H'); // 定位到输入区各行第 1 列
    buf.write('\x1B[K'); // 清除该行
    if (i == 0) {
      buf.write(prompt);
    } else {
      buf.write('      ');
    }
    buf.write(inputWrapped[i]);
  }
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
    var inputChanged = false;
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
          inputChanged = true; // 清空输入行，等待下方统一重绘
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
        // 退格
        final cur = _state!.input.toString();
        if (cur.isNotEmpty) {
          _state!.input.clear();
          _state!.input.write(cur.substring(0, cur.length - 1));
        }
        inputChanged = true;
        continue;
      }
      if (code >= 32) {
        _state!.input.writeCharCode(code);
        inputChanged = true;
      }
    }
    // 整个 chunk 处理完统一渲染一次：若逐字符渲染（含 stdout.write+flush），
    // 连续输入多个字符（如 IME 一次提交一串中文）时后续输出会因 flush 竞态
    // 丢失——表现为"只有第一个字回显、其余要等下一次输入才出现"。
    if (inputChanged && (_state?.running ?? false)) {
      _renderInputLine();
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
