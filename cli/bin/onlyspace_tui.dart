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

  /// 等待邀请码输入（/auth 未登记引导）：输入循环的下一次输入按邀请码处理。
  bool pendingInvite = false;
}

_TuiState? _state;

/// SIGWINCH 防抖计时器（窗口尺寸变化 120ms 内合并为一次全量重绘）。
Timer? _resizeTimer;
StreamSubscription<ProcessSignal>? _sigwinchSub; // 终端尺寸监听订阅（退出前必须取消，否则进程挂起）

/// 默认服务器地址：优先读 cli/config.json 的 server 字段（本地可改），
/// 文件缺失/格式异常时回退硬编码 https://only.tic.cc。
String _defaultServer() {
  try {
    final f = File('config.json');
    if (f.existsSync()) {
      final v = (jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)['server'];
      if (v is String && v.isNotEmpty) return v;
    }
  } catch (_) {
    // 配置缺失/损坏：回退默认值
  }
  return 'https://only.tic.cc';
}

/// 默认 store 目录：$HOME/.onlyspace（Windows 用 USERPROFILE）。
String _defaultStoreDir() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home/.onlyspace';
}

/// 自动发现设备并返回选定的 store 路径；无可用设备返回 ''（引导 init）。
/// - 合法设备（DeviceStore.load 成功）→ 1 台直接用，多台列出选择；
/// - 损坏/非 store 文件 → 自动备份为 .bak（保留现场）后继续。
String _resolveAutoStore() {
  final dir = _defaultStoreDir();
  final valid = <({String path, DeviceStore store})>[];
  final corrupt = <String>[];
  final d = Directory(dir);
  if (d.existsSync()) {
    for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      try {
        valid.add((path: f.path, store: DeviceStore.load(f.path)));
      } catch (_) {
        corrupt.add(f.path); // 格式损坏或非 store 文件
      }
    }
  }

  // 损坏文件：提示 + 备份 .bak（保留现场，不丢私钥数据）
  if (corrupt.isNotEmpty) {
    stdout.writeln('⚠️ 发现损坏的设备文件: ${corrupt.map((p) => p.split('/').last).join(', ')}');
    for (final c in corrupt) {
      try {
        File(c).renameSync('$c.bak');
      } catch (_) {}
    }
    stdout.writeln('   已备份为 .bak（可在目录查看现场）');
  }

  if (valid.isEmpty) return ''; // 无可用设备 → _onboard 引导 init

  if (valid.length == 1) {
    stdout.writeln('✅ 使用设备: ${valid.first.store.deviceId ?? '(未登记)'}');
    return valid.first.path;
  }

  // 多台设备：列出选择（cooked 数字选择）
  stdout.writeln('发现 ${valid.length} 台设备:');
  for (var i = 0; i < valid.length; i++) {
    stdout.writeln('  ${i + 1}) ${valid[i].store.deviceId ?? '(未登记)'}');
  }
  stdout.write('选择 [回车=1]: ');
  final input = (stdin.readLineSync() ?? '').trim();
  final idx = (int.tryParse(input) ?? 1).clamp(1, valid.length);
  return valid[idx - 1].path;
}

/// 快速健康探测（GET {server}/health，3s 超时，不重试）：
/// 能连（HTTP 200）→ true；连接失败/超时 → false。
/// 不用 ApiClient（其 connectionTimeout 10s + 3 次重试，探测太慢）。
Future<bool> _probeServer(String server) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse('$server/health'));
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 首次使用引导（cooked 模式逐行问答，进入 raw 模式前）。
/// 返回 (就绪的 store, 生效的 server 地址, 生效的 store 路径)；引导中选择
/// sealed 导入时置 exitCode=1（main 据此退出，提示用户改用 onlyspace.dart import）。
Future<(DeviceStore, String, String)> _onboard(String storePath, String server) async {
  var store = storePath.isNotEmpty && File(storePath).existsSync() ? DeviceStore.load(storePath) : null;
  var creator = false; // 首设备自举成功（空间创建者）标记：走创建者初始化（生成 Space Key + 托管 + 邀请码）
  var autoStore = false; // 自动模式（无 --store）：enroll 后按规范 id 重命名设备文件（personA_dev2.json）

  // 自动模式：enroll 拿到规范 id 后，把设备文件重命名为 personA_dev2.json（原临时名 [device-id].json）
  void renameToStandard(String personId, String deviceId) {
    if (!autoStore) return;
    final newPath = '${_defaultStoreDir()}/${personId}_$deviceId.json';
    if (newPath == storePath) return;
    File(storePath).renameSync(newPath);
    storePath = newPath;
    stdout.writeln('💾 设备文件: $newPath');
  }

  // ① 服务器地址：--server 参数 > store 持久化值 > config 默认（cli/config.json）> 硬编码
  if (server.isEmpty) {
    final saved = store?.server;
    server = (saved != null && saved.isNotEmpty) ? saved : _defaultServer();
  }
  // ② 健康探测：能连 → 直接用（不询问）；无法连接 → 引导输入新地址（回车沿用当前值）
  if (!await _probeServer(server)) {
    stdout.writeln('⚠️ 无法连接服务器 $server（/health 探测失败）');
    stdout.write('输入新服务器地址（回车沿用 $server）: ');
    final input = (stdin.readLineSync() ?? '').trim();
    if (input.isNotEmpty) server = input;
  }

  if (store == null) {
    stdout.writeln('=== OnlySpace TUI 首次使用引导 ===');
    stdout.writeln('本机还没有设备身份，现在生成（私钥保存在本机: $storePath）');
    // 设备 id 由服务端在登记时分配规范 id（dev1/dev2…），本地不预设（null，
    // 与 personId 一致），无需用户输入
    store = await DeviceStore.create();
    // 自动模式（无 --store）→ 存默认目录 ~/.onlyspace/[临时].json（登记后重命名为 personA_dev1.json）
    if (storePath.isEmpty) {
      autoStore = true;
      final dir = _defaultStoreDir();
      Directory(dir).createSync(recursive: true);
      storePath = '$dir/pending.json';
    }
    store.server = server; // server 已在开头解析（探测/询问），随身份一起持久化
    store.save(storePath);
    stdout.writeln('✅ 设备身份已生成');
    stdout.writeln('   公钥: ${store.publicKey}');

    // 你的名称（显示层，如 lukas）与设备昵称（如 MacBook）：登记前询问，随 enroll 上报
    if (store.personName == null || store.personName!.isEmpty) {
      stdout.write('你的名称（如 lukas，留空回车则不设置）: ');
      final name = (stdin.readLineSync() ?? '').trim();
      if (name.isNotEmpty) {
        store.personName = name;
        stdout.writeln('✅ 已设置名称: $name');
      }
    }
    if (store.deviceName == null || store.deviceName!.isEmpty) {
      stdout.write('设备名称（显示用，如 MacBook，回车不设置）: ');
      final name = (stdin.readLineSync() ?? '').trim();
      if (name.isNotEmpty) {
        store.deviceName = name;
      }
    }
    store.save(storePath);

    // 设备登记：先尝试首设备自举（空间无设备 → 免邀请码成为创建者）；
    // 失败（空间已有设备）→ 凭创建者给的邀请码加入
    if (server.isNotEmpty) {
      try {
        final r = await ApiClient(server).enrollDevice(
          deviceId: store.deviceId,
          publicKey: store.publicKey,
          displayName: store.personName,
          deviceName: store.deviceName,
        );
        store.deviceId = r.deviceId; // 服务端分配的规范 id（dev1）
        store.personId = r.personId; // 规范 person id（personA）
        store.spaceId = r.spaceId;
        renameToStandard(r.personId, r.deviceId); // 自动模式：设备文件改名为 personA_dev1.json
        store.save(storePath);
        creator = true;
        stdout.writeln('✅ 首设备自举成功（你是空间创建者）: device=${r.deviceId} person=${r.personId}');
        _guidanceNotes.add('✅ 首设备自举成功（你是空间创建者）: device=${r.deviceId} person=${r.personId}');
      } catch (e) {
        // 区分自举失败：空间已有设备（需要邀请码）vs 网络/服务器错误（首个设备免邀请码）
        if (e is ApiException && e.code == 'INVALID_REQUEST') {
          stdout.writeln('空间已有设备（你不是第一个加入者），加入需要邀请码');
          _guidanceNotes.add('空间已有设备（你不是第一个加入者），加入需要邀请码');
          stdout.write('邀请码（空间创建者提供）: ');
          final inviteCode = (stdin.readLineSync() ?? '').trim();
          if (inviteCode.isEmpty) {
            stdout.writeln('未输入邀请码：请把上面的公钥发给空间创建者加入白名单');
            _guidanceNotes.add('未输入邀请码：请把上面的公钥发给空间创建者加入白名单');
          } else {
            try {
              final r = await ApiClient(server).enrollDevice(
                deviceId: store.deviceId,
                publicKey: store.publicKey,
                inviteCode: inviteCode,
                displayName: store.personName,
                deviceName: store.deviceName,
              );
              store.deviceId = r.deviceId;
              store.personId = r.personId;
              store.spaceId = r.spaceId;
              renameToStandard(r.personId, r.deviceId); // 自动模式：设备文件改名为 personB_dev2.json
              store.save(storePath);
              stdout.writeln('✅ 邀请码登记成功: device=${r.deviceId} person=${r.personId}');
              _guidanceNotes.add('✅ 邀请码登记成功: device=${r.deviceId} person=${r.personId}');
            } catch (e2) {
              stdout.writeln('⚠️ 邀请码登记失败: $e2（无效/已用/过期或网络问题）');
              stdout.writeln('   可联系创建者重新生成邀请码，或人工加入白名单后重试');
            }
          }
        } else {
          stdout.writeln('⚠️ 自举失败: $e（首个设备免邀请码；请确认服务器可达后重试）');
        }
      }
    } else {
      stdout.writeln('未提供服务器地址，稍后可在 TUI 内用 /auth 补配');
    }
  }

  // 持久化最终确认的 server（探测后沿用/用户覆盖），多终端共享同一 store 只设一次
  if (store.server != server) {
    store.server = server;
    store.save(storePath);
  }

  final session = ChatSession(store, storePath, server);

  // 无 Space Key → 引导接入：口令托管（推荐）或 sealed 导入（高级，提示用 CLI）
  if (store.spaceKey == null || store.spaceId == null) {
    if (creator) {
      // 创建者初始化：生成 Space Key → 上传口令托管包 → 生成邀请码（对方加入用）
      stdout.writeln();
      stdout.writeln('你是空间创建者：现在生成 Space Key 并上传口令托管包（对方凭口令接入）');
      final sk = await generateSpaceKey();
      store.spaceKey = base64Encode(sk);
      store.save(storePath);
      final passphrase = _readPassphrase('设置托管口令:（输入不回显，回车提交，对方凭它接入）');
      try {
        final api = ApiClient(server);
        await session.auth(); // challenge-response 认证（写入 store.sessionToken）
        await KeyEscrowService(api).upload(
          passphrase: passphrase,
          spaceKeyB64: store.spaceKey!,
          spaceId: store.spaceId!,
          keyVersion: store.keyVersion,
          token: store.sessionToken!,
        );
        stdout.writeln('✅ 口令托管包已上传: space_id=${store.spaceId}');
        _guidanceNotes.add('✅ 口令托管包已上传: space_id=${store.spaceId}');
        // 不主动生成邀请码（避免引导繁琐）：进对话后用 /invite 随时创建
        stdout.writeln('💡 输入 /invite 创建邀请码以添加更多设备');
        _guidanceNotes.add('💡 输入 /invite 创建邀请码以添加更多设备');
        stdout.write('按回车进入对话…');
        stdout.flush().ignore(); // 无换行写入需显式 flush（终端行缓冲，否则滞留缓冲不显示）
        stdin.readLineSync(); // 等用户回车再进 TUI（提示留在屏上，不被 TUI 首屏覆盖）
      } catch (e) {
        stdout.writeln('⚠️ 创建者初始化失败: $e');
        stdout.writeln('   可进入 TUI 后手动补：escrow upload / invite（onlyspace.dart 命令）');
      }
    } else if (store.spaceId == null) {
      // 设备尚未登记成功（未输邀请码/自举失败等）：跳过口令接入引导（接入需先登记）
      stdout.writeln();
      stdout.writeln('⚠️ 设备尚未登记成功，跳过接入引导');
      stdout.writeln('   可稍后重试引导，或进入 TUI 后 /auth 补录');
      _guidanceNotes.add('⚠️ 设备尚未登记成功，跳过接入引导（可进入 TUI 后 /auth 补录）');
    } else {
      stdout.writeln();
      stdout.writeln('本设备还没有 Space Key，无法收发消息。接入方式：');
      stdout.writeln('  1) 口令接入（推荐）：输入空间创建者给你的 space_id + 口令');
      stdout.writeln('  2) sealed 导入（高级）：dart run bin/onlyspace.dart import --store $storePath --sealed-file <文件>');
      stdout.write('选择 [回车=1 / 2] : ');
      final choice = (stdin.readLineSync() ?? '1').trim();
      if (choice == '2') {
        stdout.writeln('请先退出本程序，用 onlyspace.dart import 导入 sealed 文件后再运行。');
        exitCode = 1;
        return (store, server, storePath);
      }
      if (server.isEmpty) {
        stdout.writeln('⚠️ 未提供服务器地址，跳过口令接入（之后可 /auth 后手动 escrow download）');
      } else {
        stdout.writeln('口令由空间创建者告知（escrow 托管包按空间一份，凭口令即可解出 Space Key）');
        final passphrase = _readPassphrase('口令:（输入不回显，回车提交）');
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
  }

  // 未认证 → 引导认证（白名单已登记时 challenge-response 成功）
  if (store.sessionToken == null && server.isNotEmpty) {
    try {
      await session.auth();
      stdout.writeln('✅ 认证成功: space_id=${store.spaceId ?? '-'}');
    } catch (e) {
      // auth 抛 StateError（如 server 无效）也是 Error 子类，用 catch (e) 兜底
      stdout.writeln('⚠️ 认证失败: $e（可进入 TUI 后用 /auth 重试）');
      _guidanceNotes.add('⚠️ 认证失败: $e（可进入 TUI 后用 /auth 重试）');
    }
  }
  return (store, server, storePath);
}

/// 隐藏回显读取口令：
/// - POSIX（macOS/Linux）：逐键渲染星号（echo/line 关 + readByteSync），输入有反馈；
/// - **Windows：不用逐键**（Dart SDK：Windows 上 lineMode=false 后只收到 CR，
///   逐键读会把输入吞成回车导致口令变空）→ 回退 echoMode=false + readLineSync
///   整行隐藏读取（输入字节完整，只是无星号反馈）；
/// - try/finally 确保 echoMode/lineMode 无论成功/异常都恢复，避免终端停在无回显状态；
/// - stdout 写入全部 try-catch（pty 下 StreamSink 可能抛异常，与 TUI 渲染同理）。
String _readPassphrase(String prompt) {
  // pty 下 stdout StreamSink 可能抛异常（渲染 write 需 try-catch 的教训同源）
  void safeWriteln() {
    try {
      stdout.writeln();
    } catch (_) {}
  }

  void safeWrite(String s) {
    try {
      stdout.write(s);
    } catch (_) {}
  }

  void safeFlush() {
    try {
      stdout.flush().ignore(); // Future 异常同步 catch 接不到，必须 ignore()
    } catch (_) {}
  }

  safeWrite(prompt);
  safeFlush();
  final isWindows = Platform.isWindows;
  try {
    if (isWindows) {
      // Windows：整行隐藏读取（控制台关闭 ECHO，回车提交）
      stdin.echoMode = false;
      final v = stdin.readLineSync() ?? '';
      safeWriteln();
      try {
        stdout.writeln('（已输入 ${v.length} 位口令）'); // Windows 无逐键星号，提交后给位数反馈
      } catch (_) {}
      return v;
    }
    // POSIX：逐键星号渲染
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
          safeWrite('\b \b');
          safeFlush();
        }
        continue;
      }
      if (b < 32) continue; // 忽略其他控制字符
      buf.writeCharCode(b);
      safeWrite('*');
      safeFlush();
    }
    safeWriteln();
    try {
      stdout.writeln('（已输入 ${buf.length} 位口令）');
    } catch (_) {}
    return buf.toString();
  } catch (_) {
    // pty/重定向等不支持：退回整行隐藏读取
    try {
      stdout.writeln('（终端模式不可用：口令隐藏输入、无星号回显，回车提交）');
    } catch (_) {}
    final v = stdin.readLineSync() ?? '';
    safeWriteln();
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

  var storePath = '';
  var server = '';
  var explicitStore = false; // 是否显式传 --store（自动发现 vs 手动指定）
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--store':
        storePath = args[++i];
        explicitStore = true;
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

  // 无显式 --store：默认目录（~/.onlyspace）自动发现已有设备；
  // 无设备 → 引导 init（存 [device-id].json）；损坏文件自动备份 .bak 后重新初始化。
  if (!explicitStore) {
    storePath = _resolveAutoStore();
  }

  // 注：曾在引导前调用 _restoreTerminal() 以恢复"上次异常退出残留的无回显终端"，
  // 但 pty/重定向环境下 stdin 未订阅时设置 echo/lineMode 会触发未捕获异常导致
  // 进程 255 崩溃（已实测定位）。残留场景较少见（真实终端进程退出后由 shell 接管
  // termios），不做启动时强制恢复；退出路径 _exitRaw 已保证正常恢复。

  // 首次使用引导（cooked 逐行问答，进入 raw 模式前）：store 不存在 → 生成设备身份；
  // 无 Space Key → 口令接入（escrow）；未认证 → auth。全部就绪后才进入 TUI。
  final onboard = await _onboard(storePath, server);
  if (exitCode != 0) return; // 引导中选择 sealed 导入 → 提示后退出
  final store = onboard.$1;
  server = onboard.$2;
  storePath = onboard.$3; // 自动模式下 init 后的实际路径（~/.onlyspace/[device-id].json）

  final session = ChatSession(store, storePath, server);
  await session.loadHistory();
  // 引导阶段提示（自举/托管/邀请码指引）作为 system 消息进入对话流——
  // 必须在 loadHistory 之后加入（loadHistory 开头会 clear messages，否则被清掉）
  for (final note in _guidanceNotes) {
    session.messages.add(_systemMessage(session, note));
  }
  _guidanceNotes.clear();
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
    } catch (e) {
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
    _sigwinchSub = ProcessSignal.sigwinch.watch().listen((_) {
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
  _sigwinchSub?.cancel(); // 取消终端尺寸监听：否则 event loop 不空闲，进程挂起回不到命令行
  _printFarewell(session);
  try {
    stdout.flush(); // 确保退出语输出后再退出
  } catch (_) {}
  exit(0); // 兜底强制退出（无论是否还有残留句柄）
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
  // 恢复光标显示：_render 开头写了 \x1B[?25l 隐藏光标，退出必须恢复，
  // 否则 Mac 终端看似"没回到正常命令行"，只能 Ctrl-C 强退。
  // 注意：stdout.flush() 返回 Future，异常在 Future 里（同步 try-catch 接不到），
  // 必须 .ignore() 吞掉——否则 pty 下未捕获异步异常导致进程 255 崩溃。
  try {
    stdout.write('\x1B[?25h');
    stdout.flush().ignore();
  } catch (_) {}
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
  buf.write('${_bold}OnlySpace TUI${_reset}  ${s.session.store.deviceId ?? '-'} @ ${s.session.store.spaceId ?? '-'}  $wsName');
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

  // 输入区：**固定屏幕底部**（top = rows - inputLines + 1），
  // 与 _renderInputLine 的定位计算完全一致——否则消息少时输入区被画在
  // 屏幕中间，与局部重绘的底部定位不一致 → you> 跳动、上下重复。
  // 逐行定位 + 清行（\x1B[K），避免残留旧行。
  final prompt = '${_cyan}you>${_reset} ';
  final top = rows - inputWrapped.length + 1;
  for (var i = 0; i < inputWrapped.length; i++) {
    buf.write('\x1B[${top + i};1H'); // 定位输入区各行第 1 列
    buf.write('\x1B[K'); // 清除该行
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
  // 注意：flush() 返回 Future，异常在 Future 里，同步 try-catch 接不到——
  // 必须 .ignore()，否则 pty 下发送消息触发重绘时未捕获异步异常导致进程 255 崩溃。
  try {
    stdout.write(buf.toString());
    stdout.flush().ignore();
  } catch (_) {
    // 忽略渲染异常（终端能力不足时降级为不刷新界面）
  }
}

/// 格式化消息为多行（第一行带归属前缀，续行裸正文，自动按列宽折行）。
/// 自己的消息：绿色前缀 + 普通正文；对方消息：正文加粉红背景（一眼区分收发双方）；
/// 系统提示（isSystem）：灰色前缀 + 普通正文（sender 显示为 system）。
List<String> _formatMessage(ChatMessage m, int cols) {
  final String who;
  final String color;
  if (m.isSystem) {
    who = 'system';
    color = _gray;
  } else {
    who = m.isMine ? '我' : '对方';
    color = m.isMine ? _green : _yellow;
  }
  final seq = m.seq == null ? '' : ' seq=${m.seq}';
  final prefix = '$color[$who$seq v${m.keyVersion}]$_reset ';
  final body = m.plain.replaceAll('\n', ' ');
  final maxW = cols - _displayWidth(prefix);
  final wrapped = _wrapByWidth(body, maxW);
  if (m.isMine || m.isSystem) {
    // 自己消息与系统提示：普通正文（system 不用粉红背景）
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
    stdout.flush().ignore(); // Future 异常同步 catch 接不到，必须 ignore()
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
        final future = (_state!.pendingInvite)
            ? _handleInviteInput(line) // 等待邀请码：本次输入按邀请码登记
            : (line.startsWith('/') ? _execCommand(line) : _sendText(line));
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
  } catch (e) {
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
      s.status = '命令: /auth [server] /server <地址> /invite [personA|personB] [名称] /sync /history /attach <file> /exit';
    case '/server':
      if (arg.isEmpty) {
        s.status = '当前服务器: ${s.session.server}；用法: /server <地址>';
      } else {
        try {
          await s.session.auth(serverOverride: arg);
          s.session.store.server = arg; // 持久化新地址
          s.session.store.save(s.session.storePath);
          if (s.session.wsClient == null && s.session.hasSession) {
            s.session.startWs(onMessage: (_) => _render(), onStatus: (_) => _render());
          }
          s.status = '✅ 已切换服务器并认证: $arg';
        } catch (e) {
          s.status = '切换服务器失败: $e';
        }
      }
    case '/auth':
      // 未登记（deviceId null，如引导时跳过/登记失败）→ 引导邀请码登记后再认证
      if (s.session.store.deviceId == null) {
        // 提示作为 system 消息进消息流；邀请码由输入循环接管输入——
        // TUI 运行期 stdin 已被输入循环订阅，不能再用 readLineSync（会挂起）
        s.pendingInvite = true;
        s.session.messages.add(_systemMessage(s.session, '设备尚未登记：请输入邀请码（空间创建者 /invite 获取）'));
        s.status = '等待邀请码输入后回车…';
        break;
      }
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
      } catch (e) {
        s.status = '认证失败: $e';
      }
    case '/sync':
      try {
        final fresh = await s.session.sync();
        s.status = '同步完成: 新增=${fresh.length} 队列剩余=${s.session.store.pendingCount}';
      } catch (e) {
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
        } catch (e) {
          s.status = '附件上传失败: $e';
        }
      }
    case '/invite':
      // 补发邀请码：/invite [personA|personB] [对方名称]（默认 personB=邀请对方）
      await _execInvite(parts);
    case '/exit':
    case '/quit':
      s.running = false;
    default:
      s.status = '未知命令: $cmd（/help 查看）';
  }
}

/// /invite [personA|personB] [对方名称]：补发一次性邀请码（默认 personB=邀请对方，
/// 给第二使用者；personA=给自己加新设备）。需先 /auth 认证。
Future<void> _execInvite(List<String> parts) async {
  final s = _state!;
  final token = s.session.store.sessionToken;
  if (token == null) {
    s.status = '未认证：先 /auth 再生成邀请码';
    return;
  }
  final personId = parts.length > 1 ? parts[1] : 'personB';
  if (personId != 'personA' && personId != 'personB') {
    s.status = '用法: /invite [personA|personB] [对方名称]（默认 personB）';
    return;
  }
  final name = parts.length > 2 ? parts.sublist(2).join(' ') : null;
  try {
    final api = ApiClient(s.session.server);
    final r = await api.createInvite(
      token: token,
      personId: personId,
      displayName: name,
      hours: 24,
    );
    // 邀请码作为对话流中的一条 system 消息显示（随消息区滚动，不占顶部状态栏）
    s.session.messages.add(_systemMessage(s.session, '邀请码（24 小时内一次性有效）: ${r.inviteCode}'));
    s.status = ''; // 反馈在消息区（邀请码本身），状态栏保持干净
  } catch (e) {
    s.status = '邀请码生成失败: $e';
  }
}

/// 输入循环接管的邀请码登记（/auth 未登记引导）：登记 → system 消息结果 → 认证 → WS。
Future<void> _handleInviteInput(String inviteCode) async {
  final s = _state!;
  s.pendingInvite = false;
  if (inviteCode.isEmpty) {
    s.session.messages.add(_systemMessage(s.session, '未输入邀请码，登记取消'));
    return;
  }
  try {
    final r = await ApiClient(s.session.server).enrollDevice(
      publicKey: s.session.store.publicKey,
      inviteCode: inviteCode,
      displayName: s.session.store.personName,
      deviceName: s.session.store.deviceName,
    );
    s.session.store.deviceId = r.deviceId;
    s.session.store.personId = r.personId;
    s.session.store.spaceId = r.spaceId;
    s.session.store.save(s.session.storePath);
    s.session.messages.add(_systemMessage(s.session, '✅ 邀请码登记成功: device=${r.deviceId} person=${r.personId}'));
    // 登记成功后继续认证
    try {
      await s.session.auth();
      s.status = '✅ 认证成功: space_id=${s.session.store.spaceId}';
      if (s.session.wsClient == null && s.session.hasSession) {
        s.session.startWs(
          onMessage: (_) => _render(),
          onStatus: (_) => _render(),
        );
      }
    } catch (e) {
      s.status = '认证失败: $e';
    }
  } catch (e) {
    s.session.messages.add(_systemMessage(s.session, '⚠️ 邀请码登记失败: $e（无效/已用/过期或网络问题）'));
  }
}

void _printFarewell(ChatSession session) {
  // /exit 后 stdout 流可能已关闭（pty 下 stdin/stdout 共享 fd，退出流程副作用），
  // 退出信息尽力而为——写入失败忽略，避免 "StreamSink is bound to a stream" 崩溃
  try {
    stdout.writeln();
    stdout.writeln('${_gray}已退出 OnlySpace TUI（最后同步锚点 ${session.store.lastServerSequence}）${_reset}');
  } catch (_) {}
}

/// 引导阶段产生的系统提示（进 TUI 后作为 system 消息显示在对话流）。
final List<String> _guidanceNotes = [];

/// 构造一条系统提示消息（sender 显示 system，随对话流滚动，不被状态条推到窗口上方）。
ChatMessage _systemMessage(ChatSession session, String text) {
  return ChatMessage(
    env: MessageEnvelope(
      v: 1,
      type: 'text',
      keyVersion: session.store.keyVersion,
      messageId: 'sys-${DateTime.now().millisecondsSinceEpoch}',
      senderDeviceId: session.store.deviceId ?? '-',
      nonce: '',
      ciphertext: '',
    ),
    plain: text,
    isMine: false,
    isSystem: true,
    createdAt: DateTime.now().millisecondsSinceEpoch,
  );
}
