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

// \x1B[2J 清屏 + \x1B[3J 清除回滚缓冲 + \x1B[H 光标回家：全屏重绘应用（类似 vim/htop）
// 不保留滚动历史——否则每次渲染的内容在终端回滚缓冲里累积成"重复渲染"
const _clearHome = '$_esc[2J$_esc[3J$_esc[H';
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

  /// 等待空间口令输入（/space 重新接入引导）：输入循环的下一次输入按口令处理。
  bool pendingSpaceKey = false;

  /// person_id → display_name（GET /space 拉取，消息前缀显示 person_name 用）。
  Map<String, String> personNames = {};

  /// 引导问答等待类型（非 null 时输入循环的下一次输入按此问答处理）。
  String? pendingGuidance;

  /// 机密输入模式（口令等）：输入行回显 *（而非原文）。
  bool hiddenInput = false;

  /// 引导问答等待（_prompt 用）：输入循环提交回答时 complete。
  Completer<String>? pendingGuideCompleter;
  bool pendingGuideRequired = false; // 当前引导问答是否必填（留空回车不提交）
  bool processing = false; // 后台处理中（如口令打包上传）：忽略输入、隐藏光标
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

/// 启动探测 + 获取系统信息（GET {server}/health，3s 超时，不重试）：
/// 能连（HTTP 200）→ (true, personNames)；连接失败/超时 → (false, {})。
/// 探测顺带取回 person 名称表（消息前缀显示 person_name，一举两得）；
/// 不用 ApiClient（其 connectionTimeout 10s + 3 次重试，探测太慢）。
Future<(bool, Map<String, String>)> _probeServer(String server) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse('$server/health'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) return (false, <String, String>{});
    final json = jsonDecode(body) as Map<String, dynamic>;
    final raw = json['person_names'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final names = <String, String>{for (final e in raw.entries) e.key: e.value as String};
    return (true, names);
  } catch (_) {
    return (false, <String, String>{});
  } finally {
    client.close(force: true);
  }
}

/// 首次使用引导（cooked 模式逐行问答，进入 raw 模式前）。
/// 返回 (就绪的 store, 生效的 server 地址, 生效的 store 路径)；引导中选择
/// sealed 导入时置 exitCode=1（main 据此退出，提示用户改用 onlyspace.dart import）。
Future<(DeviceStore, String, String)> _onboard(String storePath, String server) async {
  var store = storePath.isNotEmpty && File(storePath).existsSync() ? DeviceStore.load(storePath) : null;

  // ① 服务器地址：--server 参数 > store 持久化值 > config 默认（cli/config.json）> 硬编码
  if (server.isEmpty) {
    final saved = store?.server;
    server = (saved != null && saved.isNotEmpty) ? saved : _defaultServer();
  }
  // ② 健康探测：能连 → 直接用（不询问）；无法连接 → 引导输入新地址（回车沿用当前值）
  // 探测顺带取回 person 名称表（系统信息），供消息前缀显示 person_name
  final (probeOk, probeNames) = await _probeServer(server);
  _probePersonNames = probeNames;
  if (!probeOk) {
    stdout.writeln('⚠️ 无法连接服务器 $server（/health 探测失败）');
    stdout.write('输入新服务器地址（回车沿用 $server）: ');
    final input = (stdin.readLineSync() ?? '').trim();
    if (input.isNotEmpty) server = input;
  }

  if (store == null) {
    stdout.writeln('=== OnlySpace TUI 首次使用引导 ===');
    _guidanceNotes.add('=== OnlySpace TUI 首次使用引导 ===');
    stdout.writeln('本机还没有设备身份，现在生成（私钥保存在本机: $storePath）');
    _guidanceNotes.add('本机还没有设备身份，现在生成（私钥保存在本机: $storePath）');
    // 设备 id 由服务端在登记时分配规范 id（dev1/dev2…），本地不预设（null，
    // 与 personId 一致），无需用户输入
    store = await DeviceStore.create();
    // 自动模式（无 --store）→ 存默认目录 ~/.onlyspace/[临时].json（登记后重命名为 personA_dev1.json）
    if (storePath.isEmpty) {
      final dir = _defaultStoreDir();
      Directory(dir).createSync(recursive: true);
      storePath = '$dir/pending.json';
    }
    store.server = server; // server 已在开头解析（探测/询问），随身份一起持久化
    store.save(storePath);
    stdout.writeln('✅ 设备身份已生成');
    _guidanceNotes.add('✅ 设备身份已生成');
    stdout.writeln('   公钥: ${store.publicKey}');
    _guidanceNotes.add('   公钥: ${store.publicKey}');
  }
  // 引导问答（名称/登记/接入/口令）由 _runGuide 在 TUI 消息流中处理
  // （system 提示 + you> 输入 + 机密 *）——此处仅返回，main 负责启动引导任务与输入循环
  return (store, server, storePath);
}

/// 引导任务（与输入循环并发）：登记/接入/口令问答在 TUI 消息流中进行——
/// 提示作为 system 消息（_prompt），回答走 you> 输入行（机密口令回显 *）。
/// 引导完成后做启动同步 + WS；全部就绪后返回。
Future<void> _runGuide(ChatSession session, String storePath, String server) async {
  final store = session.store;
  final autoStore = storePath.startsWith(_defaultStoreDir());

  // 自动模式：enroll 拿到规范 id 后，把设备文件重命名为 personA_dev2.json（原临时名 pending.json）
  void renameToStandard(String personId, String deviceId) {
    if (!autoStore) return;
    final newPath = '${_defaultStoreDir()}/${personId}_$deviceId.json';
    if (newPath == storePath) return;
    File(storePath).renameSync(newPath);
    storePath = newPath;
    session.messages.add(_systemMessage(session, '💾 设备文件: $newPath'));
  }

  // 你的名称（显示层，如 lukas）：消息流问答（留空回车则不设置）
  if (store.personName == null || store.personName!.isEmpty) {
    final name = await _prompt(session, '你的名称（如 lukas，留空回车则不设置）');
    try {
      if (name.isNotEmpty) {
        store.personName = name;
        session.messages.add(_systemMessage(session, '✅ 已设置名称: $name'));
        _scheduleRender();
      }
    } catch (e) {
      stderr.writeln('⚠️ 名称处理异常: $e'); // 防崩 + 可诊断
    }
  }
  // 设备名称（显示用，如 MacBook，回车不设置）
  if (store.deviceName == null || store.deviceName!.isEmpty) {
    final name = await _prompt(session, '设备名称（显示用，如 MacBook，回车不设置）');
    if (name.isNotEmpty) {
      store.deviceName = name;
    }
  }
  store.save(storePath);

  // 设备登记：先尝试首设备自举（空间无设备 → 免邀请码成为创建者）；失败 → 凭邀请码加入
  if (server.isNotEmpty) {
    try {
      final r = await _busy(session, '⏳ 设备登记中......', () => ApiClient(server).enrollDevice(
        deviceId: store.deviceId,
        publicKey: store.publicKey,
        displayName: store.personName,
        deviceName: store.deviceName,
      ));
      store.deviceId = r.deviceId;
      store.personId = r.personId;
      store.spaceId = r.spaceId;
      renameToStandard(r.personId, r.deviceId);
      store.save(storePath);
      session.messages.add(_systemMessage(session, '✅ 首设备自举成功（你是空间创建者）: device=${r.deviceId} person=${r.personId}'));
      _scheduleRender();
      // 创建者：生成 Space Key + 上传口令托管包（两次确认，机密 *）
      final sk = await generateSpaceKey();
      store.spaceKey = base64Encode(sk);
      store.save(storePath);
      await _setupEscrowPassphrase(store, storePath, session);
      session.messages.add(_systemMessage(session, '💡 输入 /invite 创建邀请码以添加更多设备'));
      _scheduleRender();
    } catch (e) {
      if (e is ApiException && e.code == 'INVALID_REQUEST') {
        session.messages.add(_systemMessage(session, '空间已有设备（你不是第一个加入者），加入需要邀请码'));
        _scheduleRender();
        // 邀请码重试循环：输错/留空反复要求重输，直到登记成功（成功才结束引导）
        while (true) {
          if (!_state!.running) break; // 已退出（/exit 或 Ctrl+C）：结束引导
          final inviteCode = await _prompt(session, '邀请码（空间创建者提供，输错会反复要求重输）');
          if (inviteCode.isEmpty) {
            session.messages.add(_systemMessage(session, '未输入邀请码，请重新输入（或 Ctrl+C 退出）'));
            _scheduleRender();
            continue;
          }
          try {
            final r = await _busy(session, '⏳ 邀请码登记中......', () => ApiClient(server).enrollDevice(
              deviceId: store.deviceId,
              publicKey: store.publicKey,
              inviteCode: inviteCode,
              displayName: store.personName,
              deviceName: store.deviceName,
            ));
            store.deviceId = r.deviceId;
            store.personId = r.personId;
            store.spaceId = r.spaceId;
            renameToStandard(r.personId, r.deviceId);
            store.save(storePath);
            session.messages.add(_systemMessage(session, '✅ 邀请码登记成功: device=${r.deviceId} person=${r.personId}'));
            _scheduleRender();
            break;
          } catch (e2) {
            session.messages.add(_systemMessage(session, '⚠️ 邀请码登记失败: $e2（无效/已用/过期或网络问题），请重新输入'));
            _scheduleRender();
          }
        }
        // 登记成功后口令接入（加入者——无 Space Key）
        if (store.spaceKey == null && store.spaceId != null) {
          while (true) {
            if (!_state!.running) break; // 已退出：结束引导
            final passphrase = await _prompt(session, '口令:（输入不回显，回车提交）', hidden: true);
            try {
              await _busy(session, '⏳ 口令接入中......', () => session.accessByEscrow(passphrase));
              session.messages.add(_systemMessage(session, '✅ 口令接入成功: space_id=${store.spaceId} key_version=${store.keyVersion}'));
              _scheduleRender();
              break;
            } catch (e3) {
              session.messages.add(_systemMessage(session, '⚠️ 口令接入失败: $e3，请重新输入口令（口令由创建者 escrow 托管时设置）'));
              _scheduleRender();
            }
          }
        }
      } else {
        session.messages.add(_systemMessage(session, '⚠️ 自举失败: $e（首个设备免邀请码；请确认服务器可达后重试）'));
        _scheduleRender();
      }
    }
  }

  // 持久化最终确认的 server（探测后沿用/用户覆盖），多终端共享同一 store 只设一次
  if (store.server != server) {
    store.server = server;
    store.save(storePath);
  }

  // 已登记但口令托管包未上传（创建者引导中断）：重启再进引导设置口令
  if (store.spaceId != null && store.personId == 'personA' && !store.escrowUploaded) {
    session.messages.add(_systemMessage(session, '检测到尚未设置托管口令，现在设置（两次输入须一致；可 Ctrl+C 稍后重启再进）'));
    _scheduleRender();
    await _setupEscrowPassphrase(store, storePath, session);
  }

  // 未认证 → 引导认证（白名单已登记时 challenge-response 成功）
  if (store.sessionToken == null && server.isNotEmpty) {
    try {
      await _busy(session, '⏳ 认证中......', () => session.auth());
      session.messages.add(_systemMessage(session, '✅ 认证成功: space_id=${store.spaceId ?? '-'}'));
      _scheduleRender();
    } catch (e) {
      session.messages.add(_systemMessage(session, '⚠️ 认证失败: $e（可进入 TUI 后用 /auth 重试）'));
      _scheduleRender();
    }
  }

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
      onMessage: (_) => _scheduleRender(),
      onStatus: (_) => _scheduleRender(),
    );
  }
  _scheduleRender();
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
  _state!.personNames = Map.of(_probePersonNames); // 启动探测的名称表（首屏即可显示 person_name）
  _refreshPersonNames(_state!); // 认证后刷新（保持最新）

  // 引导任务（登记/接入/口令问答——消息流交互：system 提示 + you> 输入 + 机密 *）
  // 与输入循环并发启动；引导完成后的启动同步与 WS 由 _runGuide 负责。
  final guide = _runGuide(session, storePath, server);

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
  await guide; // 引导任务收尾（启动同步/WS 已在其内部完成；异常已内部处理）
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
/// 终端行数：stty size 优先（真实终端尺寸最可靠，raw 模式/stdout.terminalLines
/// 失效时仍准确——此前兜底 24 与用户实际行数不符时渲染定位超出屏幕导致滚动、
/// 新消息被滚出可视区），失败再退 terminalLines/默认。
int _termLines() {
  final size = _sttySize();
  if (size != null) return size.$1;
  try {
    final t = stdout.terminalLines;
    if (t > 0) return t;
  } catch (_) {}
  return 24;
}

/// 终端列数（同上：stty size 优先）。
int _termCols() {
  final size = _sttySize();
  if (size != null) return size.$2;
  try {
    final c = stdout.terminalColumns;
    if (c > 0) return c;
  } catch (_) {}
  return 80;
}

/// stty size（"rows cols"），失败返回 null。轻量 ioctl，_render 每次调用可接受。
(int, int)? _sttySize() {
  try {
    final r = Process.runSync('stty', ['size']);
    if (r.exitCode == 0) {
      final parts = (r.stdout as String).trim().split(RegExp(r'\s+'));
      if (parts.length == 2) {
        final rows = int.tryParse(parts[0]);
        final cols = int.tryParse(parts[1]);
        if (rows != null && cols != null && rows > 0 && cols > 0) {
          return (rows, cols);
        }
      }
    }
  } catch (_) {}
  return null;
}

/// 输入内容折行：每行最大宽度 = cols - prompt 显示宽度（最后一行行首带 prompt）。
List<String> _wrapInput(String input, int cols) {
  final prompt = '${_cyan}you>${_reset} ';
  return _wrapByWidth(input, cols - _displayWidth(prompt));
}

/// 渲染调度到事件循环：microtask（_runGuide continuation）里的 _render 输出
/// 在真实终端不显示（用户：提示要回车才出现）——延迟到事件循环后与输入循环
/// 同机制可靠显示。引导流程的渲染统一走这里。
void _scheduleRender() {
  Future.delayed(Duration.zero, () {
    try {
      _render();
    } catch (e) {
      stderr.writeln('⚠️ 引导渲染异常: $e');
    }
  });
}

/// 后台操作包装（网络延迟体验统一优化）：操作前插入 busyText 状态消息并置
/// processing（忽略输入、隐藏光标不闪烁），操作完成后移除 busyText（无论成败）；
/// 异常 rethrow——由调用方 try-catch 产出结果消息（"打包中"替换为结果）。
Future<T> _busy<T>(ChatSession session, String busyText, Future<T> Function() action) async {
  final busyMsg = _systemMessage(session, busyText);
  session.messages.add(busyMsg);
  _state!.processing = true;
  _scheduleRender();
  try {
    final r = await action();
    _state!.processing = false;
    session.messages.remove(busyMsg);
    return r;
  } catch (e) {
    _state!.processing = false;
    session.messages.remove(busyMsg);
    rethrow;
  }
}

void _render() {
  final s = _state;
  if (s == null) return;
  final rows = _termLines();
  final cols = _termCols();
  // 输入区折行行数：超长输入自动多行，消息区高度动态让位
  final display = s.hiddenInput ? '*' * s.input.length : s.input.toString();
  final inputWrapped = _wrapInput(display, cols);
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
  buf.write('${_bold}OnlySpace TUI${_reset}  $wsName  ${_personLabel(s.session.store)}');
  if (s.status.isNotEmpty) {
    buf.write('  ${_gray}${s.status}${_reset}');
  }
  buf.write('\r\n');

  // 消息区：从下往上堆叠——最新消息紧贴输入条（输入条上方），旧消息向上滚出，
  // 消息量变化时消息流固定在底部堆叠，避免跳来跳去
  final lines = <String>[];
  for (final m in s.session.messages) {
    lines.addAll(_formatMessage(m, cols));
  }
  final start = lines.length > msgArea ? lines.length - msgArea : 0;
  final visible = lines.sublist(start);
  final bottom = rows - s.inputLines; // 输入条上方第一行（消息区底部）
  // 先清空整个消息区（第 2 行到输入行上方）：连续渲染时旧行残留可能覆盖新消息
  // （表现为"连续两个 system 消息第二个不显示"）
  for (var r = 2; r < bottom; r++) {
    buf.write('\x1B[$r;1H\x1B[K');
  }
  var row = bottom;
  for (var i = visible.length - 1; i >= 0; i--) {
    buf.write('\x1B[$row;1H');
    buf.write(visible[i]);
    row--;
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
  if (!s.processing) buf.write(_showCursor); // 处理中（打包/上传）不显示光标（不闪烁）

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

/// 状态条身份标签：person_name@device_name（未设置回退规范 id）。
String _personLabel(DeviceStore store) {
  final person = store.personName ?? store.personId ?? '-';
  final device = store.deviceName ?? store.deviceId ?? '-';
  return '$person@$device';
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
  } else if (m.isMine) {
    // 自己的消息：前缀用 person_name（未设置回退"我"）
    who = _state?.session.store.personName ?? '我';
    color = _green;
  } else {
    // 对方的消息：按 senderPersonId 查名称表（未拉取/未知回退"对方"）
    final pid = m.env.senderPersonId;
    who = (pid != null && _state?.personNames.containsKey(pid) == true)
        ? _state!.personNames[pid]!
        : '对方';
    color = _yellow;
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
  if (!s.processing) buf.write(_showCursor); // 处理中不显示光标（不闪烁）
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
      if ((_state?.processing ?? false) && code != 3) continue; // 处理中（如口令打包）：忽略输入，Ctrl+C 仍可退出
      if (code == 3) {
        // Ctrl+C → 退出（先恢复终端，再取消监听，见 _restoreTerminal 注释）
        _state!.running = false;
        _abortPendingGuide(); // 释放引导问答等待，避免 _runGuide 挂起
        _restoreTerminal();
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (code == 13 || code == 10) {
        // 回车：提交输入
        final gc = _state!.pendingGuideCompleter;
        if (gc != null) {
          final answer = _state!.input.toString().trim();
          if (answer.isEmpty && (_state?.pendingGuideRequired ?? false)) {
            // 必填问答（口令）留空回车：不提交——提示继续输入（不弹"请重新输入"，
            // 输入行保留直接继续敲）
            _state!.input.clear();
            session.messages.add(_systemMessage(session, '此项不能为空，请继续输入'));
            _scheduleRender();
            inputChanged = true;
            continue;
          }
          _state!.input.clear();
          if (answer == '/exit' || answer == '/quit') {
            // 引导问答中的退出命令：逃生门——否则任何输入都被吞为回答，
            // 用户困在邀请码/口令重试循环无法退出
            _state!.running = false;
            _abortPendingGuide();
            _restoreTerminal();
            sub.cancel();
            if (!completer.isCompleted) completer.complete();
            inputChanged = true;
            return;
          }
          // 引导问答回答：提交（含留空——引导逻辑自行校验/重试）
          _state!.pendingGuideCompleter = null;
          _state!.hiddenInput = false;
          if (!gc.isCompleted) gc.complete(answer);
          try {
            _render(); // complete 后立即全量渲染（界面即时响应，不等 _runGuide continuation）
          } catch (e) {
            stderr.writeln('⚠️ 引导渲染异常: $e'); // 防崩 + 可诊断
          }
          // continuation（microtask）的渲染在真实终端不显示（用户：you> 无变化、
          // 要回车才变化）——延迟到事件循环（continuation 之后）再渲染一次，
          // 此时消息区已含下一步提示（事件回调渲染与输入循环同机制，可靠显示）
          Future.delayed(Duration.zero, () {
            try {
              _render();
            } catch (e) {
              stderr.writeln('⚠️ 引导渲染异常: $e');
            }
          });
          inputChanged = true;
          continue;
        }
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
            : (_state!.pendingSpaceKey)
                ? _handleSpaceKeyInput(line) // 等待口令：本次输入按口令接入
                : (line.startsWith('/') ? _execCommand(line) : _sendText(line));
        future.whenComplete(() {
          busy = false;
          if (!(_state?.running ?? false)) {
            // /exit 或 /quit：先恢复终端（必须在 sub.cancel 之前，否则 fd 失效
            // 无法设 echoMode），再取消监听并结束主流程（否则 await 永远挂起）
            _abortPendingGuide(); // 释放引导问答等待，避免 _runGuide 挂起（await guide 卡死）
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
      s.status = '命令: /auth [server] /server <地址> /space /invite [personA|personB] [名称] /sync /history /attach <file> /exit';
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
        // 认证结果作为 system 消息进消息流（不占顶部状态栏）
        s.session.messages.add(_systemMessage(s.session, '✅ 认证成功: space_id=${s.session.store.spaceId}'));
        s.status = '';
        _refreshPersonNames(s); // 刷新 person 名称表（对方消息前缀显示其 person_name）
        // 认证成功后启动 WS 实时监听
        if (s.session.wsClient == null && s.session.hasSession) {
          s.session.startWs(
            onMessage: (_) => _render(),
            onStatus: (_) => _render(),
          );
        }
      } catch (e) {
        s.session.messages.add(_systemMessage(s.session, '⚠️ 认证失败: $e'));
        s.status = '';
      }
    case '/space':
      // 重新接入空间（口令托管）：未接入时引导输入口令，已接入则提示
      if (s.session.hasSpace) {
        s.session.messages.add(_systemMessage(s.session, '已接入空间'));
        break;
      }
      s.pendingSpaceKey = true;
      s.session.messages.add(_systemMessage(
          s.session, '尚未接入空间：请输入空间口令（创建者 escrow 托管，口令在创建者初始化时设置）'));
      s.status = '等待口令输入后回车…';
      break;
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
    final r = await _busy(s.session, '⏳ 邀请码生成中......', () => api.createInvite(
      token: token,
      personId: personId,
      displayName: name,
      hours: 24,
    ));
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
      s.session.messages.add(_systemMessage(s.session, '✅ 认证成功: space_id=${s.session.store.spaceId}'));
      s.status = '';
      _refreshPersonNames(s); // 刷新 person 名称表
      if (s.session.wsClient == null && s.session.hasSession) {
        s.session.startWs(
          onMessage: (_) => _render(),
          onStatus: (_) => _render(),
        );
      }
    } catch (e) {
      s.session.messages.add(_systemMessage(s.session, '⚠️ 认证失败: $e'));
      s.status = '';
    }
  } catch (e) {
    s.session.messages.add(_systemMessage(s.session, '⚠️ 邀请码登记失败: $e（无效/已用/过期或网络问题）'));
  }
}

/// 输入循环接管的空间口令接入（/space 未接入引导）：口令 → accessByEscrow。
Future<void> _handleSpaceKeyInput(String passphrase) async {
  final s = _state!;
  s.pendingSpaceKey = false;
  if (passphrase.isEmpty) {
    s.session.messages.add(_systemMessage(s.session, '未输入口令，接入取消'));
    return;
  }
  try {
    await s.session.accessByEscrow(passphrase);
    s.session.messages.add(_systemMessage(
        s.session,
        '✅ 口令接入成功: space_id=${s.session.store.spaceId} key_version=${s.session.store.keyVersion}'));
  } catch (e) {
    // accessByEscrow 抛 StateError（Error 子类），on Exception 捕获不到
    s.session.messages.add(_systemMessage(s.session, '⚠️ 口令接入失败: $e（口令错误？Server 已有创建者托管包？）'));
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

/// 启动探测获取的 person 名称表（/health 系统信息，person_id → display_name）。
Map<String, String> _probePersonNames = {};

/// 设置托管口令（单次输入：口令不在消息流回显，留空回车由输入循环拦截不提交、
/// 继续输入；成功标记 store.escrowUploaded 并落盘）。中断（Ctrl+C）后重启会再进此引导。
Future<void> _setupEscrowPassphrase(DeviceStore store, String storePath, ChatSession session) async {
  while (true) {
    if (!_state!.running) break; // 已退出：结束口令设置
    final p1 = await _prompt(session, '设置托管口令（用于后续设备接入空间，务必牢记）：请输入口令（输入不回显，回车提交）', hidden: true, required: true);
    if (p1.isEmpty) continue; // 防御：正常不会到这（输入循环 required 拦截留空回车）
    try {
      final api = ApiClient(session.server);
      // _busy：打包/上传期间插入"⏳ 口令打包中......"、禁止输入、隐藏光标，
      // 完成后移除（替换为下方结果消息）——统一体验优化
      await _busy(session, '⏳ 口令打包中......', () async {
        await session.auth(); // challenge-response 认证（写入 store.sessionToken）
        await KeyEscrowService(api).upload(
          passphrase: p1,
          spaceKeyB64: store.spaceKey!,
          spaceId: store.spaceId!,
          keyVersion: store.keyVersion,
          token: store.sessionToken!,
        );
      });
      store.escrowUploaded = true;
      store.save(storePath);
      session.messages.add(_systemMessage(session, '✅ 口令托管包已上传: space_id=${store.spaceId}'));
      _scheduleRender();
      return;
    } catch (e) {
      session.messages.add(_systemMessage(session, '⚠️ 口令托管包上传失败: $e，请重新设置（或 Ctrl+C 稍后重启再进）'));
      _scheduleRender();
    }
  }
}

/// 拉取空间 person 名称表（GET /space）到缓存（认证后调用；失败静默——
/// 前缀回退"我/对方"）。用于消息前缀显示 person_name。
Future<void> _refreshPersonNames(_TuiState s) async {
  final token = s.session.store.sessionToken;
  if (token == null) return;
  try {
    final r = await ApiClient(s.session.server).getSpace(token);
    s.personNames = r.personNames;
  } catch (_) {
    // 拉取失败不影响聊天（前缀回退"我/对方"）
  }
}

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

/// 引导问答：提示作为 system 消息进消息流，回答由输入循环接管（you> 输入；
/// hidden=true 时输入行回显 *）。返回用户提交的回答（输入循环回车时 complete）。
Future<String> _prompt(ChatSession session, String message,
    {bool hidden = false, bool required = false}) {
  final s = _state!;
  if (!s.running) return Future.value(''); // 已退出：不再等待输入（避免 _runGuide 挂起）
  s.hiddenInput = hidden;
  s.pendingGuideRequired = required; // 必填问答：留空回车由输入循环拦截不提交
  session.messages.add(_systemMessage(session, message));
  _scheduleRender(); // 提示渲染走事件循环（microtask 渲染真实终端不显示）
  final completer = Completer<String>();
  s.pendingGuideCompleter = completer;
  return completer.future;
}

/// 退出时释放引导问答等待（complete 空回答），避免 _runGuide 的 await 挂起。
void _abortPendingGuide() {
  final c = _state?.pendingGuideCompleter;
  if (c != null && !c.isCompleted) c.complete('');
  _state?.pendingGuideCompleter = null;
  _state?.hiddenInput = false;
}
