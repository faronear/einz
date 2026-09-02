// Einz 交互式聊天 TUI —— 方案 A（分栏界面 + WS 实时接收 + 附件收发）。
//
// 与 einz_chat.dart（方案 B，纯文本 REPL）不同，本文件提供：
//   - 分栏布局：消息区（滚动）+ 输入区（底部）+ 状态栏（顶部，含 WS 状态）
//   - 手写 ANSI 渲染（零新依赖；pub 缓存无 TUI 库且国内网络下载不稳）
//   - 后台 WS 实时监听（复用 shared WsClient，断线自动重连）
//   - 命令：/auth /sync /history /attach <file> /help /exit
//   - 逐键输入（raw 模式），Ctrl+C 或 /exit 退出
//
// 用法：
//   dart run bin/einz_tui.dart --store demo/store-a.json --server http://127.0.0.1:3901
//
// 前置：store 已 init + config/import（已导入 Space Key）；未认证时先 /auth。
// 定位：测试端明文落盘（同 store.dart），不上生产。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:einz_shared/einz_shared.dart';
import 'package:einz_cli/store.dart';
import 'package:einz_cli/chat_core.dart';

// ---------- ANSI 转义 ----------
const _esc = '\x1B';
const _reset = '$_esc[0m';
const _red = '$_esc[31m';
const _green = '$_esc[32m';
const _yellow = '$_esc[33m';
const _cyan = '$_esc[36m';
const _gray = '$_esc[90m';
const _black = '$_esc[30m'; // 黑字（粉红底上的对方标签：人名/时间戳）
const _white = '$_esc[37m'; // 白字（粉红底上的对方消息正文；标准码，VSCode 等终端映射一致）
const _bold = '$_esc[1m';
const _bgPink = '$_esc[45m'; // 品红背景：对方消息整条底色（标准码 45；亮色 105 在 VSCode 集成终端不渲染）

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

  /// 输入缓冲区光标位置（0..input.length 之间的字符偏移，供 ←→ 编辑）。
  int cursor = 0;

  /// 已提交输入历史（升序、最旧在前；供 ↑↓ 箭头浏览复用）。
  final List<String> inputHistory = [];

  /// 历史浏览下标：-1 = 未浏览（编辑当前输入）；>=0 = 正在浏览 history[index]。
  int historyIndex = -1;

  /// 进入历史浏览前暂存的当前输入草稿（↓ 越过最新一条时恢复）。
  String historyDraft = '';

  /// 系统提示行（命令结果 / 错误），显示在状态栏下方。
  String status = '';

  /// 输入区当前折行行数（>=1）：超长输入自动多行时消息区动态让位。
  int inputLines = 1;

  /// 退出标志。
  bool running = true;

  /// 等待邀请码输入（/auth 未登记引导）：输入循环的下一次输入按邀请码处理。
  bool pendingInvite = false;

  /// 等待私密空间口令输入（/space 重新接入引导）：输入循环的下一次输入按口令处理。
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
/// 文件缺失/格式异常时回退硬编码 https://einz.tic.cc。
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
  return 'https://einz.tic.cc';
}

/// 默认 store 目录：$HOME/.einz（Windows 用 USERPROFILE）。
String _defaultStoreDir() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home/.einz';
}

/// 解析默认 store：固定检查 ~/.einz/myeinz.json（存在且可加载则返回路径，
/// 损坏自动备份 .bak 后返回 ''（引导 init）；不存在返回 ''。
/// 多设备身份请用 --store 显式指定其他文件（单机默认单设备，无需扫描/选择）。
String _resolveAutoStore() {
  final path = '${_defaultStoreDir()}/myeinz.json';
  final f = File(path);
  if (!f.existsSync()) return '';
  try {
    DeviceStore.load(path);
    return path;
  } catch (_) {
    // 损坏/非 store 文件：备份保留现场后引导 init（不丢私钥数据）
    try {
      f.renameSync('$path.bak');
      stdout.writeln('⚠️ $path 损坏，已备份为 .bak（可查看现场）');
    } catch (_) {}
    return '';
  }
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
/// sealed 导入时置 exitCode=1（main 据此退出，提示用户改用 einz.dart import）。
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
    stdout.writeln('=== Einz TUI 首次使用引导 ===');
    _guidanceNotes.add('=== Einz TUI 首次使用引导 ===');
    stdout.writeln('本机还没有设备身份，现在生成（私钥保存在本机: $storePath）');
    _guidanceNotes.add('本机还没有设备身份，现在生成（私钥保存在本机: $storePath）');
    // 设备 id 由服务端在登记时分配规范 id（dev1/dev2…），本地不预设（null，
    // 与 personId 一致），无需用户输入
    store = await DeviceStore.create();
    // 自动模式（无 --store）→ 存默认目录 ~/.einz/myeinz.json（固定文件名，无临时名/重命名）
    if (storePath.isEmpty) {
      final dir = _defaultStoreDir();
      Directory(dir).createSync(recursive: true);
      storePath = '$dir/myeinz.json';
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

  // 你的名称（显示层，如 lukas）：消息流问答（留空回车则不设置）——仅新空间
  // 首设备（探测无 person 名称表）；后续设备改为引导时选择 personA/personB 身份
  if ((store.personName == null || store.personName!.isEmpty) && _probePersonNames.isEmpty) {
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
  // 设备名称（如 MacBook，回车不设置，以后可修改）——仅新设备（未登记）首次配置时询问；
  // 已登记设备重启不再重复询问（首次跳过则一直不设，状态条回退规范 id dev1）
  if (store.deviceId == null && (store.deviceName == null || store.deviceName!.isEmpty)) {
    final name = await _prompt(session, '设备名称（如 MacBook，回车不设置，以后可修改）');
    if (name.isNotEmpty) {
      store.deviceName = name;
    }
  }
  store.save(storePath);

  // 设备登记：未登记才 enroll（首设备自举 / 凭邀请码加入）——已登记设备（重启
  // 进入）跳过 enroll，直接走认证/TUI（否则服务端 activeCount>0 会误判"空间
  // 已有设备"要求邀请码，创建者自己被挡在门外）
  if (server.isNotEmpty && (store.deviceId == null || store.spaceId == null)) {
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
        _scheduleRender();
        // 身份选择：询问用户是第一个人 personA 还是第二个人 personB（显示名称；
        // personB 名称为空则要求输入）
        String? chosenPerson;
        while (true) {
          if (!_state!.running) break;
          final aName = _probePersonNames['personA'] ?? '未设置';
          final bName = _probePersonNames['personB'] ?? '';
          final bShow = bName.isEmpty ? '未设置' : bName;
          final choice = await _prompt(session, '你是私密空间创建人（$aName）还是（personB：$bShow）？输入 1 或 2');
          if (choice == '1' || choice.toLowerCase() == 'persona') { chosenPerson = 'personA'; break; }
          if (choice == '2' || choice.toLowerCase() == 'personb') { chosenPerson = 'personB'; break; }
          session.messages.add(_systemMessage(session, '请输入 1（第一个人 personA）或 2（第二个人 personB）'));
          _scheduleRender();
        }
        if (chosenPerson == 'personB' && (_probePersonNames['personB'] ?? '').isEmpty) {
          // personB 还没有名称——要求输入显示名
          final name = await _prompt(session, 'personB 还没有名称，请输入显示名（如 steffi）：');
          if (name.isNotEmpty) store.personName = name;
        } else if (chosenPerson == 'personA') {
          store.personName = _probePersonNames['personA'] ?? store.personName; // 显示用
        }
        // 邀请码重试循环：输错/留空反复要求重输，直到登记成功（成功才结束引导）
        while (true) {
          if (!_state!.running) break; // 已退出（/exit 或 Ctrl+C）：结束引导
          final inviteCode = await _prompt(session, '加入私密空间需要输入邀请码（由任意一个已认证设备提供）:');
          if (!_state!.running) break; // 退出中（/exit 逃生门已触发）——立即结束引导，不进登记
          if (inviteCode.isEmpty) {
            session.messages.add(_systemMessage(session, '未输入邀请码，请重新输入（或 Ctrl+C 退出）'));
            _scheduleRender();
            continue;
          }
          try {
            final r = await _busy(session, '⏳ 邀请码验证中......', () => ApiClient(server).enrollDevice(
              deviceId: store.deviceId,
              publicKey: store.publicKey,
              inviteCode: inviteCode,
              displayName: store.personName,
              deviceName: store.deviceName,
              personId: chosenPerson, // 用户引导选择的身份（null 时服务端用邀请码绑定）
            ));
            store.deviceId = r.deviceId;
            store.personId = r.personId;
            store.spaceId = r.spaceId;
            store.save(storePath);
            session.messages.add(_systemMessage(session, '✅ 邀请码验证成功，您的新设备已加入私密空间'));
            _scheduleRender();
            break;
          } catch (e2) {
            session.messages.add(_systemMessage(session, '⚠️ 邀请码验证失败: $e2（无效/已用/过期或网络问题）'));
            _scheduleRender();
          }
        }
      } else {
        session.messages.add(_systemMessage(session, '⚠️ 自举失败: $e（首个设备免邀请码；请确认服务器可达后重试）'));
        _scheduleRender();
      }
    }
  }

  // 已登记但未接入空间（加入者无 Space Key，如重启的第二设备）：自动进入口令
  // 接入流程（输错反复重输直到成功——成功获得 Space Key 才能收发密文）
  if (store.spaceKey == null && store.spaceId != null && server.isNotEmpty) {
    while (true) {
      if (!_state!.running) break; // 已退出：结束引导
      final passphrase = await _prompt(session, '请输入私密空间口令:', hidden: true, required: true);
      if (!_state!.running) break; // 退出中（/exit 逃生门已触发——_abortPendingGuide 返回空）——立即结束引导，不执行接入
      if (passphrase.isEmpty) {
        // 防御：空口令（_abortPendingGuide 的 complete('') 等）不发送核对
        // （此前漏过 / 检查直接进 accessByEscrow——"口令对接中"卡住退不出）
        session.messages.add(_systemMessage(session, '私密空间口令不能为空，请重新输入（/exit 可退出）'));
        _scheduleRender();
        continue;
      }
      if (passphrase.startsWith('/')) {
        // / 开头的输入（输入循环 / 检查被绕过时的兜底）：/exit、/quit 按退出
        // 处理（逃生门——不能提示"非法口令"重输而困住用户）；其他 / 不当口令发送核对
        if (passphrase == '/exit' || passphrase == '/quit') {
          _state!.running = false;
          break; // running=false 后由 main 收尾 + 2 秒兜底退出（exit(0) 死代码已移除）
        }
        session.messages.add(_systemMessage(session, '私密空间口令不能以 / 开头，请重新输入（/exit 可退出）'));
        _scheduleRender();
        continue;
      }
      try {
        await _busy(session, '⏳ 私密空间口令核对中......', () => session.accessByEscrow(passphrase));
        session.messages.add(_systemMessage(session, '✅ 口令核对成功，您已进入自己的私密空间')); // (space_id=${store.spaceId} key_version=${store.keyVersion})
        store.escrowUploaded = true; // 已通过托管包接入（托管就绪），不再要求设置托管口令
        store.save(storePath);
        _scheduleRender();
        break;
      } catch (e3) {
        session.messages.add(_systemMessage(session, '⚠️ 口令核对失败: $e3，请重新输入口令（由私密空间第一创建者设置）'));
        _scheduleRender();
      }
    }
  }

  // 持久化最终确认的 server（探测后沿用/用户覆盖），多终端共享同一 store 只设一次
  if (store.server != server) {
    store.server = server;
    store.save(storePath);
  }

  // 已登记但口令托管包未上传（创建者引导中断）：重启再进引导设置口令。
  // （running 检查：口令阶段 /exit 退出后不再进入——否则退出又被要求设置口令）
  if (_state!.running && store.spaceId != null && store.personId == 'personA' && !store.escrowUploaded) {
    session.messages.add(_systemMessage(session, '检测到尚未设置私密空间口令，现在设置: '));
    _scheduleRender();
    await _setupEscrowPassphrase(store, storePath, session);
  }

  // /exit 退出后（口令/其他引导步骤触发 running=false）：立即结束引导，
  // 不再认证/同步/起 WS（由 main 收尾退出）
  if (!_state!.running) return;

  // 未认证 → 引导认证（白名单已登记时 challenge-response 成功）
  if (store.sessionToken == null && server.isNotEmpty) {
    try {
      await _busy(session, '⏳ 令牌认证中......', () => session.auth());
      session.messages.add(_systemMessage(session, '✅ 令牌认证成功'));
      _scheduleRender();
    } catch (e) {
      session.messages.add(_systemMessage(session, '⚠️ 令牌认证失败: $e（可进入 TUI 后用 /auth 重试）'));
      _scheduleRender();
    }
  }

  // 已登记设备启动时把本地设备名称同步到后台（TUI 里改名后服务端 dev1 的
  // device_name 同步更新；首设备 enroll 已带上 deviceName，此处幂等覆盖）
  if (store.deviceId != null &&
      store.spaceId != null &&
      (store.deviceName?.isNotEmpty ?? false) &&
      store.sessionToken != null &&
      server.isNotEmpty) {
    try {
      await ApiClient(server).updateDeviceName(store.deviceName!, store.sessionToken!);
    } catch (e) {
      _state!.status = '设备名称同步失败（稍后重试）: $e';
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
      onAutoSync: (_) => _scheduleRender(),
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
    stderr.writeln('未检测到交互终端，请用: dart run bin/einz_chat.dart --store $storePath ${server.isEmpty ? '' : '--server $server'}');
    exitCode = 1;
    return;
  }

  // 无显式 --store：默认目录（~/.einz）自动发现已有设备；
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
  storePath = onboard.$3; // 自动模式下 init 后的实际路径（~/.einz/[device-id].json）

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
  final it = s.runes.iterator;
  while (it.moveNext()) {
    final r = it.current;
    if (r == 0x1B) {
      // ANSI 转义序列（\x1B[...m 等）不计入显示宽度：跳过直到终止字节（0x40-0x7E）。
      // '[' 是 CSI 引入符，其后是参数字节（0x20-0x3F），最后以字母终止。
      while (it.moveNext()) {
        final c = it.current;
        if (c == 0x5B) continue; // CSI 引入符
        if (c >= 0x40 && c <= 0x7E) break; // 终止字节（字母）
      }
      continue;
    }
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
    WsStatus.connected => '${_green}● 在线${_reset}',
    WsStatus.connecting => '${_yellow}↻ 连接中${_reset}',
    WsStatus.reconnecting =>
      '${_red}✗ 断线重连中 (${s.session.wsDownSeconds}s)${_reset}',
    WsStatus.stopped => '${_gray}○ 离线${_reset}',
  };
  // 各片段用灰色竖线分隔：Einz TUI | person #device | ● 在线 | 临时通知
  final sep = '${_gray}|${_reset}';
  buf.write('${_bold}Einz TUI${_reset} $sep ${_personLabel(s.session.store, s.personNames)} $sep $wsName');
  if (s.status.isNotEmpty) {
    buf.write(' $sep ${_gray}${s.status}${_reset}');
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
  // 光标定位到输入编辑位置（与 _renderInputLine 一致，←→ 移动后光标跟随）
  buf.write(_cursorPos(inputWrapped, top, _displayWidth(prompt), s.cursor, cols));
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

/// 状态条身份标签：person_name #device_name（远程名称表优先——同 person 多设备同步
/// 显示最新名字；未拉取/未知回退本地 store，再回退规范 id）。
/// person 名加粗、device 名常规，便于在状态栏里区分两个部分。
String _personLabel(DeviceStore store, Map<String, String> personNames) {
  final pid = store.personId;
  final person = (pid != null ? personNames[pid] : null) ??
      store.personName ??
      store.personId ??
      '-';
  final device = store.deviceName ?? store.deviceId ?? '-';
  return '${_bold}$person$_reset #$device';
}

/// 消息时间标签（本地时间，参照渲染时刻）：
/// 今天 → HH:MM（如 14:30）；跨天（同年）→ MM月DD号 HH:MM（如 9月2号 14:30）；
/// 跨年 → 再补年份（如 2026年9月2号 14:30）。
String _timeLabel(int createdAt) {
  final t = DateTime.fromMillisecondsSinceEpoch(createdAt);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) return hm;
  final md = '${t.month}月${t.day}号';
  if (t.year == now.year) return '$md $hm';
  return '${t.year}年$md $hm';
}

/// 格式化消息为多行（自动按列宽折行）。
/// 自己的消息：绿色前缀 + 普通正文（左对齐）；对方消息：整块右对齐（右侧气泡风格，
/// 正文在右、末尾附 [who 时间] 标签）；系统提示（isSystem）：灰色前缀 + 普通正文。
List<String> _formatMessage(ChatMessage m, int cols) {
  final String who;
  final String color;
  if (m.isSystem) {
    who = 'system';
    color = _gray;
  } else if (m.isMine) {
    // 自己的消息：前缀用 person_name（远程名称表优先——同 person 多设备同步；
    // 未拉取回退本地 store，再回退"我"）
    final myStore = _state?.session.store;
    final myPid = myStore?.personId;
    who = (myPid != null ? _state?.personNames[myPid] : null) ??
        (myStore?.personName?.isNotEmpty ?? false ? myStore!.personName! : null) ??
        '我';
    color = _green;
  } else {
    // 对方的消息：按 senderPersonId 查名称表（未拉取/未知回退"对方"）
    final pid = m.env.senderPersonId;
    who = (pid != null && _state?.personNames.containsKey(pid) == true)
        ? _state!.personNames[pid]!
        : '对方';
    color = _yellow;
  }
  final time = _timeLabel(m.createdAt);
  final body = m.plain.replaceAll('\n', ' ');
  if (m.isMine || m.isSystem) {
    // 自己消息与系统提示：前缀 + 普通正文（system 不用粉红背景），左对齐
    final prefix = '$color[$who $time]$_reset ';
    final wrapped = _wrapByWidth(body, cols - _displayWidth(prefix));
    return [
      '$prefix${wrapped.first}',
      ...wrapped.skip(1).map((line) => '$line'),
    ];
  }
  // 对方消息：整块右对齐（右侧气泡风格），整条内容品红底——正文白字、
  // [人名 时间] 黑字；前导留白不上色（保持右对齐气泡感）
  final suffix = '$_black[$who $time]$_reset';
  final wrapped = _wrapByWidth(body, cols - _displayWidth(suffix) - 1);
  final lines = <String>[];
  for (var i = 0; i < wrapped.length; i++) {
    final content = i == wrapped.length - 1
        ? '$_bgPink$_white${wrapped[i]} $suffix'
        : '$_bgPink$_white${wrapped[i]}$_reset';
    lines.add('${' ' * (cols - _displayWidth(content))}$content');
  }
  return lines;
}

/// 只重绘输入区（不清屏）：打字时用，避免全量 \x1B[2J 清屏打断
/// 输入法（IME）预编辑——中文/长文字输入"没有回显"的根因。
/// 输入区行数变化（超长切多行/退回单行）时消息区高度随之变化，需全量重绘。
void _renderInputLine() {
  final s = _state;
  if (s == null) return;
  final rows = _termLines();
  final cols = _termCols();
  final display = s.hiddenInput ? '*' * s.input.length : s.input.toString();
  final inputWrapped = _wrapInput(display, cols);
  if (inputWrapped.length != s.inputLines) {
    _render(); // 行数变化 → 消息区让位 → 全量重绘
    return;
  }
  final prompt = '${_cyan}you>${_reset} ';
  final promptW = _displayWidth(prompt);
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
  // 光标定位到输入文本内的编辑位置（←→ 移动后终端光标跟随）
  buf.write(_cursorPos(inputWrapped, top, promptW, s.cursor, cols));
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
  // 终端转义序列缓冲：raw 模式下方向键等到达为 ESC [ A 等多个字节（可能跨 chunk），
  // 需在此拼合完整后再解释，避免 '[' 与字母被当成普通字符打进输入（曾显示 [D[C[A[B）。
  var esc = '';
  // utf8.decoder：raw 模式下多字节字符（如中文）可能被拆成多个字节到达，
  // 由解码器缓冲拼合后再逐字符处理（避免中文乱码）。
  sub = stdin.transform(utf8.decoder).listen((chunk) {
    var inputChanged = false;
    for (final ch in chunk.split('')) {
      if (!(_state?.running ?? false)) break;
      final code = ch.codeUnitAt(0);
      if ((_state?.processing ?? false) && code != 3) continue; // 处理中（如口令打包）：忽略输入，Ctrl+C 仍可退出
      // —— 终端转义序列（方向键 / Home / End / Delete）——
      if (esc.isNotEmpty || code == 27) {
        if (esc.isEmpty) {
          esc = '\x1B';
          continue;
        }
        final seq = esc + ch;
        if (esc == '\x1B' && (ch == '[' || ch == 'O')) {
          esc = seq; // CSI / SS3 序列开始，等待终止字节
          continue;
        }
        final isFinal = code >= 0x40 && code <= 0x7E; // CSI 终止字节
        if (!isFinal) {
          if (esc == '\x1B') {
            esc = ''; // ESC 后跟非 [ / O：死亡序列，整体丢弃
          } else if (seq.length >= 8) {
            esc = ''; // 兜底：异常长参数序列丢弃
          } else {
            esc = seq; // 继续累积参数（如 ESC [ 3 ~ 的中间态）
          }
          continue;
        }
        esc = '';
        final action = _escAction(seq);
        if (action == null) continue; // 未知序列：整体丢弃（不进输入）
        final s = _state!;
        switch (action) {
          case 'up':
            _historyUp(s);
          case 'down':
            _historyDown(s);
          case 'left':
            if (s.cursor > 0) s.cursor--;
          case 'right':
            if (s.cursor < s.input.length) s.cursor++;
          case 'home':
            s.cursor = 0;
          case 'end':
            s.cursor = s.input.length;
          case 'delete':
            _deleteAt(s);
        }
        inputChanged = true;
        continue;
      }
      if (code == 3) {
        // Ctrl+C → 退出（先恢复终端，再取消监听，见 _restoreTerminal 注释）
        _state!.running = false;
        _abortPendingGuide(); // 释放引导问答等待，避免 _runGuide 挂起
        _restoreTerminal();
        sub.cancel();
        if (!completer.isCompleted) completer.complete();
        // 兜底：main 收尾（await guide/stopWs）在部分场景（如重启后 WS 连接中）
        // 挂起到不了 exit(0)——2 秒后强制退出（进程退出自动关闭连接）
        Future.delayed(const Duration(seconds: 2), () => exit(0));
        return;
      }
      if (code == 13 || code == 10) {
        // 回车：提交输入
        final gc = _state!.pendingGuideCompleter;
        if (gc != null) {
          final answer = _state!.input.toString().trim();
          if (answer.startsWith('/')) {
            // / 开头的输入按命令处理，不当作口令/邀请码回答提交（用户：要求
            // 输入口令时 /exit 被当口令发送核对进"口令对接中"——应直接退出）
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
              // 兜底：main 收尾（await guide/stopWs）在部分场景（如重启后 WS 连接中）
              // 挂起到不了 exit(0)——2 秒后强制退出（进程退出自动关闭连接）
              Future.delayed(const Duration(seconds: 2), () => exit(0));
              return;
            }
            session.messages.add(_systemMessage(session, '引导中仅支持 /exit 退出（输入未提交）'));
            _scheduleRender();
            inputChanged = true;
            continue;
          }
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
          _state!.cursor = 0;
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
        _state!.cursor = 0;
        // 输入历史（↑↓ 浏览复用）：口令/邀请码等机密输入不进历史
        if (!_state!.hiddenInput &&
            !_state!.pendingInvite &&
            !_state!.pendingSpaceKey &&
            line.isNotEmpty &&
            (_state!.inputHistory.isEmpty || _state!.inputHistory.last != line)) {
          _state!.inputHistory.add(line);
          if (_state!.inputHistory.length > 200) _state!.inputHistory.removeAt(0);
        }
        _state!.historyIndex = -1;
        _state!.historyDraft = '';
        if (line.isEmpty) {
          inputChanged = true; // 清空输入行，等待下方统一重绘
          continue;
        }
        if (busy) continue; // 上一条命令/消息还在处理
        busy = true;
        final future = (_state!.pendingInvite)
            ? (line.startsWith('/') ? _execCommand(line) : _handleInviteInput(line)) // / 开头按命令（/exit 退出），否则按邀请码
            : (_state!.pendingSpaceKey)
                ? (line.startsWith('/') ? _execCommand(line) : _handleSpaceKeyInput(line)) // / 开头按命令（/exit 退出），否则按口令
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
            // 兜底：main 收尾（await guide/stopWs）在部分场景（如重启后 WS 连接中）
            // 挂起到不了 exit(0)——2 秒后强制退出（进程退出自动关闭连接）
            Future.delayed(const Duration(seconds: 2), () => exit(0));
          } else {
            _render();
          }
        });
        continue;
      }
      if (code == 127 || code == 8) {
        // 退格：删除光标前一个字符（支持光标中途编辑）
        _backspaceAt(_state!);
        inputChanged = true;
        continue;
      }
      if (code >= 32) {
        _insertAtCursor(_state!, ch);
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

/// 解释终端转义序列 → 动作（方向键 / Home / End / Delete）；未知序列返回 null（整体丢弃）。
String? _escAction(String seq) {
  return switch (seq) {
    '\x1B[A' || '\x1BOA' => 'up',
    '\x1B[B' || '\x1BOB' => 'down',
    '\x1B[C' || '\x1BOC' => 'right',
    '\x1B[D' || '\x1BOD' => 'left',
    '\x1B[H' => 'home',
    '\x1B[F' => 'end',
    '\x1B[3~' => 'delete',
    _ => null,
  };
}

/// 在光标处插入字符（光标右移；StringBuffer 无 insert，重建字符串）。
void _insertAtCursor(_TuiState s, String ch) {
  final str = s.input.toString();
  s.input.clear();
  s.input.write(str.substring(0, s.cursor));
  s.input.write(ch);
  s.input.write(str.substring(s.cursor));
  s.cursor++;
}

/// 退格：删除光标前一个字符（光标左移）。
void _backspaceAt(_TuiState s) {
  if (s.cursor <= 0) return;
  final str = s.input.toString();
  s.input.clear();
  s.input.write(str.substring(0, s.cursor - 1));
  s.input.write(str.substring(s.cursor));
  s.cursor--;
}

/// Delete：删除光标处字符（光标不动）。
void _deleteAt(_TuiState s) {
  if (s.cursor >= s.input.length) return;
  final str = s.input.toString();
  s.input.clear();
  s.input.write(str.substring(0, s.cursor));
  s.input.write(str.substring(s.cursor + 1));
}

/// 把输入替换为指定文本（光标移到末尾）。
void _setInput(_TuiState s, String text) {
  s.input.clear();
  s.input.write(text);
  s.cursor = text.length;
}

/// ↑：浏览更旧的历史。首次进入历史时暂存当前输入草稿（供 ↓ 恢复）。
void _historyUp(_TuiState s) {
  if (s.inputHistory.isEmpty) return;
  if (s.historyIndex == -1) {
    s.historyDraft = s.input.toString();
    s.historyIndex = s.inputHistory.length - 1;
  } else if (s.historyIndex > 0) {
    s.historyIndex--;
  } else {
    return; // 已到最旧一条
  }
  _setInput(s, s.inputHistory[s.historyIndex]);
}

/// ↓：浏览更新的历史；越过最新一条后恢复进入历史前的草稿。
void _historyDown(_TuiState s) {
  if (s.historyIndex == -1) return;
  if (s.historyIndex < s.inputHistory.length - 1) {
    s.historyIndex++;
    _setInput(s, s.inputHistory[s.historyIndex]);
  } else {
    s.historyIndex = -1;
    _setInput(s, s.historyDraft);
  }
}

/// 输入光标 ANSI 定位序列：按输入文本内偏移 offset 找到所在行/列。
/// 第 0 行行首有 prompt（promptW 列），续行行首 6 空格缩进；列钳制在终端宽度内。
/// offset 是 UTF-16 代码单元偏移，但列位置必须按**显示宽度**换算——全角字符
/// （中文等）占 2 列，若直接用代码单元数当列偏移，光标会落在全角字符中间。
String _cursorPos(List<String> wrapped, int top, int promptW, int offset, int cols) {
  var consumed = 0; // 已跨过的输入文本代码单元数
  for (var i = 0; i < wrapped.length; i++) {
    final line = wrapped[i];
    final lead = i == 0 ? promptW : 6;
    if (offset < consumed + line.length) {
      final within = offset - consumed; // 本行内光标前的代码单元数
      var col = lead + _displayWidth(line.substring(0, within)) + 1;
      if (col > cols) col = cols;
      return '\x1B[${top + i};${col}H';
    }
    consumed += line.length;
  }
  // offset 落在最后一行末尾（或折行边界后移到下一行）：
  // 光标位于整块输入文本之后一列
  final last = wrapped.length - 1;
  final lead = last == 0 ? promptW : 6;
  var col = lead + _displayWidth(wrapped[last]) + 1;
  if (col > cols) col = cols;
  return '\x1B[${top + last};${col}H';
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
    case '/':
      // 命令列表作为 system 消息进消息流（随消息区滚动，不占顶部状态栏）
      s.session.messages.add(_systemMessage(
        s.session,
        '可用命令: /auth [server] /server <地址> /space /invite [personA|personB] [名称] /rename <名字> /device <设备名> /sync /history /attach <file> /exit',
      ));
      s.status = '';
    case '/server':
      if (arg.isEmpty) {
        s.status = '当前服务器: ${s.session.server}；用法: /server <地址>';
      } else {
        try {
          await s.session.auth(serverOverride: arg);
          s.session.store.server = arg; // 持久化新地址
          s.session.store.save(s.session.storePath);
          if (s.session.wsClient == null && s.session.hasSession) {
            s.session.startWs(onMessage: (_) => _render(), onStatus: (_) => _render(), onAutoSync: (_) => _render());
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
        s.session.messages.add(_systemMessage(s.session, '发现未知设备，请输入私密空间邀请码（从其他已认证设备 /invite 获取）'));
        s.status = '等待邀请码输入…';
        break;
      }
      try {
        await s.session.auth(serverOverride: arg.isEmpty ? null : arg);
        // 验活结果作为 system 消息进消息流（不占顶部状态栏）
        s.session.messages.add(_systemMessage(s.session, '✅ 令牌验活成功'));
        s.status = '';
        _refreshPersonNames(s); // 刷新 person 名称表（对方消息前缀显示其 person_name）
        // 验活成功后启动 WS 实时监听
        if (s.session.wsClient == null && s.session.hasSession) {
          s.session.startWs(
            onMessage: (_) => _render(),
            onStatus: (_) => _render(),
            onAutoSync: (_) => _render(),
          );
        }
      } catch (e) {
        s.session.messages.add(_systemMessage(s.session, '⚠️ 令牌验活失败: $e'));
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
          s.session, '本设备尚未认证，请输入私密空间口令:'));
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
    case '/rename':
      // 重设个人显示名（person_name）：本地 + 服务端同步 + 刷新名称表
      if (arg.isEmpty) {
        s.status = '用法: /rename <名字>';
      } else if (s.session.store.sessionToken == null) {
        s.status = '未验活，请先 /auth';
      } else {
        try {
          final old = s.session.store.personName ?? '(未设置)';
          s.session.store.personName = arg;
          s.session.store.save(s.session.storePath);
          await ApiClient(s.session.server).updatePersonName(arg, s.session.store.sessionToken!);
          await _refreshPersonNames(s);
          s.status = '✅ 已重命名: $old → $arg';
        } catch (e) {
          s.status = '重命名失败: $e';
        }
      }
    case '/device':
      // 重设本设备名称（device_name）：本地 + 服务端同步
      if (arg.isEmpty) {
        s.status = '用法: /device <设备名>';
      } else if (s.session.store.sessionToken == null) {
        s.status = '未验活，请先 /auth';
      } else {
        try {
          final old = s.session.store.deviceName ?? '(未设置)';
          s.session.store.deviceName = arg;
          s.session.store.save(s.session.storePath);
          await ApiClient(s.session.server).updateDeviceName(arg, s.session.store.sessionToken!);
          s.status = '✅ 设备名已更新: $old → $arg';
        } catch (e) {
          s.status = '设备名更新失败: $e';
        }
      }
    case '/exit':
    case '/quit':
      s.running = false;
      // 兜底：main 收尾（await guide/stopWs）在部分场景（如重启后 WS/同步挂起）
      // 到不了末尾的 exit(0)——2 秒后强制退出（进程退出自动关闭连接）
      Future.delayed(const Duration(seconds: 2), () => exit(0));
    default:
      s.status = '未知命令: $cmd（/help 查看）';
  }
}

/// /invite [personA|personB] [对方名称]：补发一次性邀请码（默认 personB=邀请对方，
/// 给第二使用者；personA=给自己加新设备）。需先 /auth 验活。
Future<void> _execInvite(List<String> parts) async {
  final s = _state!;
  final token = s.session.store.sessionToken;
  if (token == null) {
    s.status = '未验活：先 /auth 刷新会话后再生成邀请码';
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

/// 输入循环接管的邀请码登记（/auth 未登记引导）：认证登记 → system 消息结果 → 验活 → WS。
Future<void> _handleInviteInput(String inviteCode) async {
  final s = _state!;
  s.pendingInvite = false;
  if (inviteCode.isEmpty) {
    s.session.messages.add(_systemMessage(s.session, '未输入邀请码，无法加入私密空间'));
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
    s.session.messages.add(_systemMessage(s.session, '✅ 邀请码验证成功，您已成功加入私密空间 (device=${r.deviceId} person=${r.personId})'));
    // 登记成功后继续认证
    try {
      await s.session.auth();
      s.session.messages.add(_systemMessage(s.session, '✅ 成功刷新会话'));
      s.status = '';
      _refreshPersonNames(s); // 刷新 person 名称表
      if (s.session.wsClient == null && s.session.hasSession) {
        s.session.startWs(
          onMessage: (_) => _render(),
          onStatus: (_) => _render(),
          onAutoSync: (_) => _render(),
        );
      }
    } catch (e) {
      s.session.messages.add(_systemMessage(s.session, '⚠️ 令牌验活失败: $e'));
      s.status = '';
    }
  } catch (e) {
    s.session.messages.add(_systemMessage(s.session, '⚠️ 邀请码验证失败: $e（无效/已用/过期或网络问题）'));
  }
}

/// 输入循环接管的私密空间口令接入（/space 未接入引导）：口令 → accessByEscrow。
Future<void> _handleSpaceKeyInput(String passphrase) async {
  final s = _state!;
  s.pendingSpaceKey = false;
  if (passphrase.isEmpty) {
    s.session.messages.add(_systemMessage(s.session, '未输入口令，无法进入空间'));
    return;
  }
  if (passphrase.startsWith('/')) {
    // / 开头的输入：/exit、/quit 按退出处理；其他 / 不当口令发送核对
    if (passphrase == '/exit' || passphrase == '/quit') {
      _state!.running = false;
      return;
    }
    s.session.messages.add(_systemMessage(s.session, '私密空间口令不能以 / 开头，接入取消（可再输 /space 重试）'));
    return;
  }
  try {
    await s.session.accessByEscrow(passphrase);
    s.session.messages.add(_systemMessage(
        s.session,
        '✅ 口令核对成功，您已进入私密空间')); // （space_id=${s.session.store.spaceId} key_version=${s.session.store.keyVersion}）
    s.session.store.escrowUploaded = true; // 已通过托管包接入（托管就绪），不再要求设置托管口令
    s.session.store.save(s.session.storePath);
  } catch (e) {
    // accessByEscrow 抛 StateError（Error 子类），on Exception 捕获不到
    s.session.messages.add(_systemMessage(s.session, '⚠️ 口令核对失败: $e（口令错误？Server 已有创建者托管包？）'));
  }
}

void _printFarewell(ChatSession session) {
  // /exit 后 stdout 流可能已关闭（pty 下 stdin/stdout 共享 fd，退出流程副作用），
  // 退出信息尽力而为——写入失败忽略，避免 "StreamSink is bound to a stream" 崩溃
  try {
    stdout.writeln();
    stdout.writeln('${_gray}已退出 Einz TUI（最后同步锚点 ${session.store.lastServerSequence}）${_reset}');
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
    final p1 = await _prompt(session, '设置私密空间口令（用于后续设备进入私密空间，务必牢记）：', hidden: true, required: true);
    if (p1.isEmpty) continue; // 防御：正常不会到这（输入循环 required 拦截留空回车）
    try {
      final api = ApiClient(session.server);
      // _busy：打包/上传期间插入"⏳ 口令正在加密打包您的空间......"、禁止输入、隐藏光标，
      // 完成后移除（替换为下方结果消息）——统一体验优化
      await _busy(session, '⏳ 口令正在加密打包您的空间......', () async {
        await session.auth(); // challenge-response 验活（写入 store.sessionToken）
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
      session.messages.add(_systemMessage(session, '✅ 口令加密的私密空间托管包已上传'));
      _scheduleRender();
      return;
    } catch (e) {
      session.messages.add(_systemMessage(session, '⚠️ 口令加密的私密空间托管包上传失败: $e，请重新设置（或 Ctrl+C 稍后重启再进）'));
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
