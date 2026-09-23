// Einz 交互式聊天 TUI —— 方案 A（分栏界面 + WS 实时接收 + 附件收发）。
//
// 与 einz_chat.dart（方案 B，纯文本 REPL）不同，本文件提供：
//   - 分栏布局：消息区（滚动）+ 输入区（底部）+ 状态栏（顶部，含 WS 状态）
//   - 手写 ANSI 渲染（零新依赖；pub 缓存无 TUI 库且国内网络下载不稳）
//   - 后台 WS 实时监听（复用 shared WsClient，断线自动重连）
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
import 'dart:math';
import 'dart:typed_data';

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
const _blue = '$_esc[94m'; // 亮蓝字：我发出的消息「对方已读」状态（TUI 独有，App 不显示已读）
const _black = '$_esc[30m'; // 黑字（对方彩色底上的标签：人名/时间戳）
const _white = '$_esc[97m'; // 亮白字（对方彩色底上的消息正文）
const _bold = '$_esc[1m';
const _bgPink = '$_esc[105m'; // 亮品红背景：对方消息整条底色（最初方案；macOS Terminal 效果好）
const _bgBlue = '$_esc[104m'; // 亮蓝背景：男性对方消息整条底色
const _bgTeal = '$_esc[48;5;37m'; // 青绿背景（256 色 #00AFAF）：性别未知的对方消息整条底色
const _bgCyan = '$_esc[106m'; // 亮青背景：两人同性别时第二个人的消息整条底色（2026-09-17 老板要求）
const _bgBlack = '$_esc[40m'; // 黑色背景：标题栏/底部状态行整行底色

// \x1B[2J 清屏 + \x1B[3J 清除回滚缓冲 + \x1B[H 光标回家：全屏重绘应用（类似 vim/htop）
// 不保留滚动历史——否则每次渲染的内容在终端回滚缓冲里累积成"重复渲染"
const _clearHome = '$_esc[2J$_esc[3J$_esc[H';
const _hideCursor = '$_esc[?25l';
const _showCursor = '$_esc[?25h';

/// 全局界面状态（单会话 TUI，简化处理）。
class _TuiState {
  _TuiState(this.session, this.storePath);

  final ChatSession session;

  /// 存储文件路径（/pin 设置后保存用）。
  final String storePath;

  /// 对方是否在线（listEntrances last_seen<60s 轮询 + peer.online/offline 广播更新）。
  /// 判定维度是"人"：同一 partner 的多条通道是我自己的通道，不算对方。
  bool peerOnline = false;

  /// 我的**其它通道**总数（不含本机；listEntrances 轮询统计）——右段 `#n/m` 的分母。
  /// 本机由 `@通道名` 独立表示，不计入这一对数字（老板 2026-09-16）。
  int myOtherEntranceTotal = 0;

  /// 对方通道：在线数 / 总数（同一 partner 的多通道；listEntrances 轮询统计）。
  int peerEntranceOnline = 0;
  int peerEntranceTotal = 0;

  /// 通道名映射（entrance_id → entrance_name——listEntrances 轮询更新；顶部条对方 #通道名）。
  final Map<String, String> entranceNames = {};

  /// 对方**在线通道**表：entrance_id → 上线时刻（ms，`online_since`；重连不刷新）。
  /// 顶部条逐个列出这些通道（按上线时刻降序 = 最新上线紧挨名字）；离线通道不在表内，
  /// 只计入 peerEntranceOnline/Total 的分母（老板 2026-09-16）。
  final Map<String, int> peerOnlineSince = {};

  /// 我的**其它在线通道**表：entrance_id → 上线时刻（ms）——右段逐个列出
  /// （数据同样来自 /entrances，客户端对本方/对方的掌握是对称的）。
  /// **不含本机**：本机由 `@通道名` 单独表示（不论在线与否都显示），
  /// 故本表长度即 `#n/m` 里的 n，与后面列出的通道名严格一一对应。
  final Map<String, int> myOtherOnlineSince = {};

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

  /// 滚动通知（发送结果 / 同步进度 / 下载进度等瞬时状态），显示在屏幕底部
  /// 专门的状态行（[我] 输入区下方）；一次性结果/错误走消息流 system 消息。
  String status = '';

  /// 输入区当前折行行数（>=1）：超长输入自动多行时消息区动态让位。
  int inputLines = 1;

  /// 消息区滚动窗口顶部在全部消息行中的下标（0 = 最旧；= lastMaxStart 即贴底/最新）。
  /// PgUp/PgDn 与滚轮翻页时调整；新消息到达时若贴底则跟随底部，否则停留在当前浏览位置。
  int scrollTop = 0;

  /// 上次渲染时的最大窗口顶部下标（lines.length - msgArea 的下界钳制值，最小 0）。
  /// -1 = 尚未渲染过（首次渲染强制贴底）；渲染时据此判断"上次是否贴底"以决定跟随。
  int lastMaxStart = -1;

  /// 上次渲染时的消息区行数（翻页步长：一屏 = lastMsgArea 行）。
  int lastMsgArea = 0;

  /// 退出标志。
  bool running = true;

  /// 等待开通码输入（/auth 未登记引导）：输入循环的下一次输入按开通码处理。
  bool pendingJoinToken = false;

  /// 等待共享口令输入（/space 重新接入引导）：输入循环的下一次输入按口令处理。
  bool pendingSpaceKey = false;

  /// partner_id → partnerName（GET /space 拉取，消息前缀显示 partnerName 用）。
  Map<String, String> partnerNames = {};

  /// partner_id → gender（GET /health、/space 拉取，对方消息背景色用）。
  Map<String, String> partnerGenders = {};

  /// partner_id → slot（GET /space 拉取，0=第一人/创建者，1=第二人/伴侣；
  /// 同性别时第二人气泡取青色用）。
  Map<String, int> partnerSlots = {};

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

/// 首条通道 create 时询问的性别（我的/伴侣）：仅接受 男/女（否则重新询问），
/// 登记时随名字一并提交服务端（person_gender/peer_gender）。
String? myGender;
String? peerGender;

/// 性别提交规范化：中文 男/女 → 服务端规范值 male/female（与 App 一致；
/// 服务端 meta person_gender:* 以 male/female 为规范，旧 TUI 直传中文导致
/// 渲染端按 'male' 匹配不上——2026-09-10 修复）。未知返回 null（服务端不落 meta）。
String? _genderCode(String? zh) => switch (zh) {
      '男' => 'male',
      '女' => 'female',
      _ => null,
    };

/// 本次运行是否刚完成入网（create/join/口令接入）：是则进对话前询问设置 PIN。
bool _onboarded = false;

/// 入网收尾（向导态→聊天态的切换）是否已执行（只跑一次）。
bool _onboardingFinalized = false;

/// 入网向导收尾：向导完成后作为最后一条 system 消息出现，随后自动
/// 倒计时（屏幕上跳动显示剩余秒数）进入聊天态——倒计时结束清空全部 system
/// 消息、只留真实对话（老板 2026-09-15 定稿：不再要求按回车，自动倒计时更直观）。
/// 欢迎辞倒计时秒数（到点自动进入聊天态并开始同步）。
const int _kWelcomeCountdownSeconds = 5;

/// SIGWINCH 防抖计时器（窗口尺寸变化 120ms 内合并为一次全量重绘）。
Timer? _resizeTimer;
StreamSubscription<ProcessSignal>? _sigwinchSub; // 终端尺寸监听订阅（退出前必须取消，否则进程挂起）

/// 出厂主域名（候选列表的第一个，也是全不通时的兜底）。
const String _kPrimaryServer = 'https://einz.tic.cc';

/// 出厂域名候选（按优先级，第一个是主域名）——与 App 端 `kServerCandidates`
/// 同构：同一服务的**多个入口**，不是多台服务器；主域名失效时客户端自己连上备用入口
/// （如切到备案域名），用户不需要做任何操作。加备用域名 = 这里加一行（+ 重新发布）。
///
/// 两端保持同构是为了让 TUI 测试能提前暴露容灾问题（老板 2026-09-19）。
const List<String> _kServerCandidates = [
  _kPrimaryServer, // 全球入口（无备案）
  'https://einz.yuanjinx.com', // 中国入口（有备案）——同一台服务器，仅入口不同
];

/// 是否**打包好的产物**（`dart compile exe` 出来的 AOT 二进制，含 CI 编的那几份）。
///
/// `dart compile exe` 只编译 Dart 代码，**不打包任何数据文件**——localConfig.json
/// 又是 gitignore 的本地文件（模板 `localConfig.example.json`），所以产物里压根不该
/// 有它，"没找到"是预期状态而非异常。用 VM 自带的环境量判定（Flutter 的
/// `kReleaseMode` 就是这么实现的），好处是 CI 那两条 `dart compile exe` 命令不用改，
/// 自动就对。
const bool _isPackagedBuild = bool.fromEnvironment('dart.vm.product');

/// 本机配置（cli/localConfig.json 的 server 字段，不入库；模板见
/// cli/localConfig.example.json）里的服务器地址；没有或损坏 → 空列表。
///
/// **支持单个或多个地址**（App 侧只支持单值：dart-define 无法可靠地传数组）——
/// 本地要验"多入口容灾"时，把开发服务器写成数组即可：
///   { "server": "http://localhost:3000" }
///   { "server": ["http://localhost:3000", "http://127.0.0.1:3901"] }
/// 多个地址时只在**你列出的这些**地址之间并发探测，绝不回落到生产域名。
///
/// 注：路径**按当前工作目录**解析（`File('localConfig.json')`），所以只有 `cd cli`
/// 之后跑（`npm run tui*-dev` 就是这么干的）才读得到——在别的目录跑会打印一行提示
/// 后走候选域名（不静默：否则会误以为在测开发服务器，实际连的是生产）。
/// **打包产物（AOT）不打这行提示**：产物里本来就没有 localConfig.json，走出厂候选
/// 域名是预期行为，提示只是噪音（老板 2026-09-21）——见 [_isPackagedBuild]。
///
/// 查找顺序见 [_configCandidates]：cwd 优先（既有语义，必须保住），打包产物再补
/// "可执行文件同目录"。
List<String> _configuredServers() {
  for (final file in _configCandidates()) {
    try {
      if (!file.existsSync()) continue;
      final v = (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['server'];
      if (v is String && v.isNotEmpty) return [v];
      if (v is List) {
        final list = v.whereType<String>().where((e) => e.isNotEmpty).toList();
        if (list.isNotEmpty) return list;
      }
      // 文件在但没写 server：按"没配"处理（再去别处找也没意义）
      return const [];
    } catch (_) {
      // 配置损坏：回退出厂域名
      return const [];
    }
  }
  if (!_isPackagedBuild) {
    // 打包产物里没有 localConfig.json 是**默认状态**（走出厂候选域名），
    // 只在从源码跑时才提示——那时它说明 cwd 不对、连的其实不是以为的服务器
    stdout.writeln(
        '⚠ 未找到 localConfig.json（cwd=${Directory.current.path}），'
        '改用出厂候选域名（${_kServerCandidates.join(' / ')}）');
  }
  return const [];
}

/// localConfig.json 的查找位置，按序：
/// 1. **当前工作目录**——既有语义（`cd cli && dart run bin/einz_tui.dart`，即
///    `npm run tui*-dev`）依赖它，必须保住（老板 2026-09-21）；
/// 2. **可执行文件同目录**（仅打包产物）——把 localConfig.json 放在二进制旁边就生效，
///    拷到别的机器也跟着走，符合"绿色软件"直觉；源码运行没有"可执行文件"这一说，
///    `Platform.resolvedExecutable` 指向 dart 自身，故不参与。
List<File> _configCandidates() {
  final files = <File>[File('localConfig.json')];
  if (_isPackagedBuild) {
    final exeDir = File(Platform.resolvedExecutable).parent;
    files.add(File.fromUri(exeDir.uri.resolve('localConfig.json')));
  }
  return files;
}

/// 默认服务器地址（与 App 端 `resolveServer` 同构的优先级链）：
/// 本机配置（单个或多个地址）> 出厂候选域名 > 主域名。
///
/// 多地址时并发探测取第一个 `/health` 成功的；**一个都不通就回第一个**（紧接着引导
/// 会探测失败并追问地址），绝不回落到生产域名——避免"以为在测本地、实际连了生产"。
Future<String> _defaultServer() async {
  final cached = _defaultServerCache;
  if (cached != null) return cached; // 一次启动只解析一次（提示也只打一次）

  final configured = _configuredServers();
  if (configured.isNotEmpty) {
    return _defaultServerCache =
        await _pickReachable(configured, fallback: configured.first);
  }
  return _defaultServerCache =
      await _pickReachable(_kServerCandidates, fallback: _kPrimaryServer);
}

/// 并发探测候选地址，取第一个 `/health` 成功的；全不通 → [fallback]。
///
/// 只有一个候选时**短路、不探测**（保持"显式配置直接用""出厂单域名直接用"的语义，
/// 与 App 的 `resolveServer` 一致）。
Future<String> _pickReachable(List<String> candidates,
    {required String fallback}) async {
  if (candidates.length == 1) return candidates.first;
  final picked = Completer<String>();
  var pending = candidates.length;
  for (final candidate in candidates) {
    _probeServer(candidate).then((r) {
      if (r.$1 && !picked.isCompleted) picked.complete(candidate);
      pending--;
      if (pending == 0 && !picked.isCompleted) picked.complete(fallback);
    });
  }
  return picked.future;
}

/// [_defaultServer] 的缓存（见上：提示只打一次）。
String? _defaultServerCache;

/// 默认 store 目录：$HOME/.einz（Windows 用 USERPROFILE）。
String _defaultStoreDir() {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
  return '$home/.einz';
}

/// 解析默认 store：固定检查 ~/.einz/myeinz.json（存在且可加载则返回路径，
/// 损坏自动备份 .bak 后返回 ''（引导 init）；不存在返回 ''。
/// 多通道凭证请用 --store 显式指定其他文件（单机默认单通道，无需扫描/选择）。
String _resolveAutoStore() {
  final path = '${_defaultStoreDir()}/myeinz.json';
  final f = File(path);
  if (!f.existsSync()) return '';
  try {
    EntranceStore.load(path);
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

/// 启动探测（GET {server}/health，3s 超时，不重试）：
/// 能连（HTTP 200）→ (true, 协议版本, 能力清单)；连接失败/超时 → (false, '', [])。
/// Multiverse：/health 不再返回全局 partner 表——partner 名字改由空间成员信息提供，
/// 消息前缀用本地 store 的名字（自己/对方由空间成员填充）。
Future<(bool, String, List<String>)> _probeServer(String server) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse('$server/health'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      return (false, '', const <String>[]);
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    final pv = json['protocol_version'] as String? ?? '';
    final caps = (json['capabilities'] as List<dynamic>? ?? const [])
        .map((e) => e as String)
        .toList();
    return (true, pv, caps);
  } catch (_) {
    return (false, '', const <String>[]);
  } finally {
    client.close(force: true);
  }
}

/// 首次使用引导（cooked 模式逐行问答，进入 raw 模式前）。
/// 返回 (就绪的 store, 生效的 server 地址, 生效的 store 路径)；引导中选择
/// key envelope 导入时置 exitCode=1（main 据此退出，提示用户在 App 侧用密保信封导入）。
///
/// 地址**永不落盘**（与 App 端同构）：`--server` 与引导手输都只本次生效，出厂默认值
/// 每次启动重读。默认地址连不上时每次启动都会再问一次——那是"该去改 localConfig.json
/// 或硬编码托底了"的警报，不该被 store 里的旧地址悄悄盖掉。
Future<(EntranceStore, String, String)> _onboard(String storePath, String server) async {
  var store = storePath.isNotEmpty && File(storePath).existsSync() ? EntranceStore.load(storePath) : null;

  // ① 服务器地址：--server 参数（仅本次生效）> 本机默认（cli/localConfig.json）> 硬编码
  if (server.isEmpty) {
    server = await _defaultServer();
  }
  // ② 健康探测：能连 → 直接用（不询问）；无法连接 → 引导输入新地址（仅本次生效）
  // Multiverse：/health 不再返回全局 partner 表（名称表保留为空，消息前缀用本地名字）
  final (probeOk, _, _) = await _probeServer(server);
  if (!probeOk) {
    stdout.writeln('❌ 无法连接服务器 $server（/health 探测失败）');
    stdout.write('❓ 输入新服务器地址（仅本次生效；回车沿用 $server）: ');
    final input = (_readLineCompat() ?? '').trim();
    if (input.isNotEmpty) server = input;
    // 同上：readByteSync 后 stdout 共享 sink 被绑定，紧随的 writeln 会丢失
    // （如上方"已生成凭证/公钥"首启输出）——让步一个事件循环轮次恢复可写。
    await Future<void>.delayed(Duration.zero);
  }

  if (store == null) {
    // 通道 id 由服务端在登记时分配规范 id（dev1/dev2…），本地不预设（null，
    // 与 partnerId 一致），无需用户输入
    store = await EntranceStore.create();
    // 通道默认名与公私钥生成同步设置（宿主机名去 .local；可随时 /entrance 修改）——
    // store 为空即生成身份并命名，不拖到引导阶段（产品决定）
    final autoName = _defaultEntranceName();
    if (autoName.isNotEmpty) {
      store.entranceName = autoName;
    }
    // 自动模式（无 --store）→ 存默认目录 ~/.einz/myeinz.json（固定文件名，无临时名/重命名）
    if (storePath.isEmpty) {
      final dir = _defaultStoreDir();
      Directory(dir).createSync(recursive: true);
      storePath = '$dir/myeinz.json';
    }
    store.save(storePath); // 地址不落盘：只存通道身份
  }

  // 开场欢迎块：**只对新通道**（尚未绑定空间）显示——那是它第一次露面，得知道自己
  // 连的是哪台服务器、生成了什么身份。老通道（已绑定空间）**不打印**，直接进聊天；
  // 要看服务器/连接/公钥等，用户自己敲 /status（只读，不发请求）。
  // 终端逐行打印；进 TUI 后并成**一条** system 消息（\n 连接，块内紧贴、不与其他消息
  // 混在一起——与"选择秘境入口"那段 _prompt 同一写法）。
  if (store.spaceId == null) {
    final welcome = <String>['=== Einz 秘境 ===', '✅ 服务端地址: $server'];
    final entranceName = store.entranceName;
    if (entranceName != null && entranceName.isNotEmpty) {
      welcome.add('✅ 新通道名称: $entranceName');
    }
    welcome.add('✅ 新通道公钥: ${store.publicKey}');
    welcome.add('----------------');
    for (final line in welcome) {
      stdout.writeln(line);
    }
    _guidanceNotes.add(welcome.join('\n'));
  }
  // 引导问答（名称/登记/接入/口令）由 _runGuide 在 TUI 消息流中处理
  // （system 提示 + you> 输入 + 机密 *）——此处仅返回，main 负责启动引导任务与输入循环
  return (store, server, storePath);
}

/// 引导任务（与输入循环并发）：登记/接入/口令问答在 TUI 消息流中进行——
/// 提示作为 system 消息（_prompt），回答走 you> 输入行（机密口令回显 *）。
/// 引导完成后做启动同步 + WS；全部就绪后返回。
/// PIN 哈希（argon2id str，自含盐）——与 escrow 口令哈希同一算法（pwhash 需 sumo 构建）。
/// 锁屏码规则（老板 2026-09-11 定稿：与 App 一致——只允许数字，至少
/// [_kPinMinLength] 位；6 位数字约 20 bit，明显强于 4 位的 13 bit）。
const int _kPinMinLength = 6;

/// 锁屏码校验：合法返回 null，否则返回错误说明（供设置/修改处提示重输）。
String? _pinError(String pin) {
  if (!RegExp(r'^\d+$').hasMatch(pin)) return '锁屏码只能是数字';
  if (pin.length < _kPinMinLength) return '锁屏码至少 $_kPinMinLength 位数字';
  return null;
}

Future<String> _hashPin(String pin) async {
  final s = await SodiumSumoInit.init2(loadDynamicLibrary);
  return s.crypto.pwhash.str(
    password: pin,
    opsLimit: s.crypto.pwhash.opsLimitModerate,
    memLimit: s.crypto.pwhash.memLimitModerate,
  );
}

/// 校验 PIN：strVerify 返回 bool（true = 验证通过）。
Future<bool> _verifyPin(String hash, String pin) async {
  final s = await SodiumSumoInit.init2(loadDynamicLibrary);
  return s.crypto.pwhash.strVerify(passwordHash: hash, password: pin);
}

/// 入网最后一步：询问设置 锁屏码（直接回车跳过 = 不设置；以后可以 /pin 设置）。
Future<void> _askSetPin(ChatSession session, String storePath) async {
  if (!_state!.running) return;
  // 明文输入（与解锁一致——引导中也可输入 /exit）
  while (true) {
    if (!_state!.running) return;
    final pin = await _prompt(session,
        '❓ 设置锁屏码（$_kPinMinLength 位数字。以后每次进入秘境需要解锁；也可暂时留空跳过，以后随时用 /pin 重设）:',
        hidden: false);
    if (!_state!.running) return;
    if (pin.isEmpty) {
      session.messages.add(_systemMessage(session, '⚠️ 没有设置锁屏码'));
      break;
    }
    final err = _pinError(pin);
    if (err != null) {
      session.messages.add(_systemMessage(session, '⚠️ $err（留空可跳过）'));
      _scheduleRender();
      continue;
    }
    session.store.pinHash = await _hashPin(pin);
    session.store.save(storePath);
    session.messages.add(_systemMessage(session, '✅ 锁屏码 🔢 已设置'));
    break;
  }
  // 欢迎辞不在此处：由 _finalizeOnboarding 统一致欢迎辞并等待回车切换到聊天态
  _scheduleRender();
}

/// 启动进对话前：store 已设 PIN 则校验解锁（错误重试，/exit 可退出）；未设直接进。
/// 同步读一行（兼容 \r / \n / \r\n）：部分终端回车只发 \r，readLineSync 在
/// macOS/Linux 上单独 \r 不算行结束会挂起等 \n（表现"需按两次回车"）；
/// 逐字节读到任一换行符即返回。EOF 返回 null。
String? _readLineCompat() {
  final buf = StringBuffer();
  while (true) {
    final b = stdin.readByteSync();
    if (b < 0) return buf.isEmpty ? null : buf.toString(); // EOF
    if (b == 10 || b == 13) return buf.toString(); // \n 或 \r 均算行结束
    buf.writeCharCode(b);
  }
}

Future<void> _unlockPin(ChatSession session) async {
  final hash = session.store.pinHash;
  if (hash == null) return; // 未设置：直接进入
  // 解锁在 main 中提前于输入循环（_runInputLoop）——不能走 _prompt
  // （completer 由输入循环 complete，此时尚未启动会永久挂起——老板实测
  // "提示后直接退出"）：改为同步读行（明文 echo；可输入 /exit 退出）
  while (_state!.running) {
    session.messages.add(_systemMessage(session, '❓ 输入锁屏码:'));
    _render(); // 同步渲染提示（_scheduleRender 异步——readLineSync 阻塞期间不会执行）
    final line = _readLineCompat();
    if (line == null) {
      _state!.running = false; // EOF（终端关闭/重定向）：退出
      return;
    }
    // readByteSync 之后紧随的 stdout.write 会同步抛 "StreamSink is bound to a
    // stream"（Dart 已知行为：阻塞读会绑定 stdin/stdout 共享的 StreamSink），
    // 被 _render 的 try-catch 吞掉 → 错误反馈渲染丢失，界面"冻结"到下一次
    // 输入才出现（老板实测）。让步一个事件循环轮次（Timer）恢复可写再渲染。
    await Future<void>.delayed(Duration.zero);
    final pin = line.trim();
    if (pin.isEmpty) continue; // 空行（如 CRLF 残留 \n）：跳过，不判错
    if (pin == '/exit' || pin == '/quit') {
      _state!.running = false;
      return;
    }
    if (!_state!.running) return;
    // argon2id str 哈希自含盐：strVerify 返回错误消息（空 = 验证通过）
    if (await _verifyPin(hash, pin)) {
      session.messages.add(_systemMessage(session, '✅ 锁屏码验证通过'));
      _render();
      return;
    }
    session.messages.add(_systemMessage(session, '⚠️ 锁屏码验证错误，请重新输入（/exit 可退出）'));
    _render();
  }
}

Future<void> _runGuide(ChatSession session, String storePath, String server) async {
  final store = session.store;

  // v2 已无「v1 全局 partner 名称表」（/health 的 partner_names 随 2efad8c 下线）——
  // 原先据此做的 partnerA/partnerB 身份选择块是死代码（_probePartnerNames 恒为空），
  // 已移除（老板 2026-09-15）。身份现在由 /space join 的 preflight slots 选择。
  store.save(storePath);

  // Multiverse：未绑定空间的新通道第一步选择「加入伴侣的秘境」/「创建新秘境」
  //（对齐 App 入口页，老板 2026-09-10）——create→名字/性别→口令创建；
  // join→token→名字/口令加入。已绑定通道（重启）跳过。
  if (store.spaceKey == null) {
    while (true) {
      if (!_state!.running) return;
      // 一条系统消息内多行（\n 分隔）：整体被消息间空行隔开、又不会
      // 被拆成多条消息——比连发三条 _systemMessage 更紧凑（2026-09-11）
      final choice = (await _prompt(
              session, '❓ 选择秘境入口\n   c: 创建秘境\n   j: 加入秘境',
              required: true)) // 必填：留空回车不接受
          .trim()
          .toLowerCase();
      if (!_state!.running) return;
      if (choice == 'c' || choice == 'create' || choice == '1') {
        session.messages.add(_systemMessage(session, '✅ 创建秘境'));
        session.messages.add(_systemMessage(session, '----------------'));
        await _spaceCreate(session, store, storePath);
        if (_onboarded) break; // 创建成功进入会话
        continue; // 创建失败：循环可重试
      }
      if (choice == 'j' || choice == 'join' || choice == '2') {
        session.messages.add(_systemMessage(session, '✅ 加入秘境'));
        session.messages.add(_systemMessage(session, '----------------'));
        // 加入流程：token 错误被拒后直接重输 token（不回到 create/join 首问——
        // 老板 2026-09-10）
        while (true) {
          // 必填（老板 2026-09-15）：留空回车不接受，继续等待输入
          final token =
              (await _prompt(session, '❓ 输入开通码:', required: true)).trim();
          if (!_state!.running) return;
          if (token.isEmpty) {
            session.messages.add(_systemMessage(session, '⚠️ 请输入开通码（可由任意一条已开通的通道生成）'));
            _scheduleRender();
            continue;
          }
          await _spaceJoin(session, store, storePath, token);
          if (_onboarded) break; // 加入成功进入会话
        }
        if (_onboarded) break; // 跳出外层引导循环进入会话
      }
      session.messages.add(
          _systemMessage(session, '⚠️ 请输入 c（创建秘境），或 j（加入秘境）'));
      _scheduleRender();
    }
    return;
  }

  // 旧版 store（v1 时代留下：有 Space Key 但没有通道登记/空间绑定信息）不再走
  // enroll——v1 的 /entrances/enroll 已随 Multiverse 收敛下线，通道登记 + 空间会话
  // 一律由 /space create、/space join 一步完成（2026-09-15 P1）。
  if (server.isNotEmpty && (store.entranceId == null || store.spaceId == null)) {
    session.messages.add(_systemMessage(
        session,
        '⚠️ 本机 store 缺少通道登记信息（旧版遗留）\n'
        '  请用 /space create 新建秘境，或用 /space join <开通码或邀请链接> 加入已有秘境'));
    session.messages.add(_systemMessage(session, '----------------'));
    _scheduleRender();
  }

  // 已绑定但未进入空间（无 Space Key，如重启的第二条通道）：自动进入口令
  // 接入流程（输错反复重输直到成功——成功获得 Space Key 才能收发密文）
  if (store.spaceKey == null && store.spaceId != null && server.isNotEmpty) {
    while (true) {
      if (!_state!.running) break; // 已退出：结束引导
      final passphrase = await _prompt(session, '❓ 输入共享口令，才能查看秘境内容：', required: true);
      if (!_state!.running) break; // 退出中（/exit 逃生门已触发——_abortPendingGuide 返回空）——立即结束引导，不执行接入
      if (passphrase.isEmpty) {
        // 防御：空口令（_abortPendingGuide 的 complete('') 等）不发送核对
        // （此前漏过 / 检查直接进 accessByEscrow——"口令对接中"卡住退不出）
        session.messages.add(_systemMessage(session, '⚠️ 请输入共享口令（/exit 可退出）'));
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
        session.messages.add(_systemMessage(session, '⚠️ 共享口令不能以 / 开头，请重新输入（/exit 可退出）'));
        _scheduleRender();
        continue;
      }
      try {
        await _busy(session, '⏳ 共享口令核对中......', () => session.accessByEscrow(passphrase));
        session.messages.add(_systemMessage(session, '✅ 口令核对成功，本通道有权查看秘境内容')); // (space_id=${store.spaceId} key_version=${store.keyVersion})
        session.messages.add(_systemMessage(session, '----------------'));
        store.escrowUploaded = true; // 已通过口令密保箱接入（托管就绪），不再要求设置托管口令
        store.save(storePath);
        _onboarded = true; // 第二条通道口令接入完成
        _scheduleRender();
        break;
      } catch (e3) {
        session.messages.add(_systemMessage(session, '⚠️ 口令核对失败: 请重新输入口令'));
        _scheduleRender();
      }
    }
  }


  // 已登记但口令密保箱未上传（创建者引导中断）：重启再进引导设置口令。
  // （判据用 slot == 0 = 创建者/第一人；v1 时代的 partnerId == 'partnerA'
  //   在 v2 下恒不成立，会让这条恢复路径永不触发）
  // （running 检查：口令阶段 /exit 退出后不再进入——否则退出又被要求设置口令）
  if (_state!.running && store.spaceId != null && store.slot == 0 && !store.escrowUploaded) {
    // 先问服务端：本地没标记 ≠ 服务端没有箱。创建空间时密保箱是随 `POST /spaces`
    // 一并上传的（此前没记 escrowUploaded），老 store 重启后会走到这里 —— 直接再问
    // 一遍会让用户以为上次白设了（老板 2026-09-15 反馈）。查到箱就补标记并跳过。
    final hasBox = await _serverHasEscrow(store, server);
    if (hasBox == true) {
      store.escrowUploaded = true;
      store.save(storePath);
    } else if (hasBox == false && _state!.running) {
      session.messages.add(_systemMessage(session, '检测到尚未设置共享口令，现在设置: '));
      _scheduleRender();
      await _setupEscrowPassphrase(store, storePath, session);
    }
  }

  // /exit 退出后（口令/其他引导步骤触发 running=false）：立即结束引导，
  // 不再认证/同步/起 WS（由 main 收尾退出）
  if (!_state!.running) return;

  // 未认证 → 引导认证（白名单已登记时 challenge-response 成功）
  if (store.sessionToken == null && server.isNotEmpty) {
    try {
      await _busy(session, '⏳ 机密线路激活中......', () => session.auth());
      session.messages.add(_systemMessage(session, '✅ 机密线路激活成功。'));
      _scheduleRender();
    } catch (e) {
      final code = e is ApiException ? e.code : '';
      // 只有"通道被明确撤销"才清盘退出（老板 2026-09-16；此前任何 403 都当撤销，
      // 后台库被重置时用户既丢了数据、也没法看本地历史）
      if (code == 'ENTRANCE_REVOKED') {
        _exitRevoked(storePath); // 不返回
      }
      if (code == 'FORBIDDEN') {
        // 服务器不认本通道（库被清空/重置最常见，也可能是本通道未登记）：
        // 警告后继续进 TUI——本地历史照常可读，联网功能不可用
        session.messages.add(_systemMessage(session, _unrecognizedNotice));
      } else {
        session.messages.add(
            _systemMessage(session, '⚠️ 机密线路激活失败。可进入 TUI 后用 /auth 重试'));
      }
      _scheduleRender();
    }
  }

  // 绑定空间后激活会话（同步通道名 → 增量同步 → 设锁屏码 → 启动 WS）——
  // Multiverse：/space create、/space join 命令绑定成功后与启动引导共用
  await _activateAfterBind(session, store, storePath, server);
}

/// 绑定空间后激活会话。顺序随是否入网而不同：
/// - 正常启动：增量同步 → 启动 WS（立刻可收发）
/// - 新入网（[_onboarded]）：设锁屏码 → 致欢迎辞并**等用户回车**显性进入聊天态
///   → 才增量同步 + 启动 WS
///
/// **入网向导期间不 sync、不启 WS**（老板 2026-09-14）：否则对方消息会直接流进
/// 消息流、插在向导的 system 消息之间。入网期间错过的消息由回车后的那次增量同步
/// 一次性补齐。
Future<void> _activateAfterBind(ChatSession session, EntranceStore store, String storePath, String server) async {
  // 已登记通道启动时把本地通道名称同步到后台（TUI 里改名后服务端 dev1 的
  // entranceName 同步更新；首条通道 enroll 已带上 entranceName，此处幂等覆盖）
  final storedEntranceName = store.entranceName;
  if (storedEntranceName != null && storedEntranceName.isNotEmpty) {
    // 存量名（本机自动取的宿主机名可能含空格等）按新规则消毒后再上传——否则
    // 服务端会拒收不合规字符，名字永远同步不上去
    final fixed = sanitizeEntranceName(storedEntranceName);
    if (fixed != storedEntranceName) {
      store.entranceName = fixed;
      store.save(storePath);
    }
  }
  if (store.entranceId != null &&
      store.spaceId != null &&
      (store.entranceName?.isNotEmpty ?? false) &&
      store.sessionToken != null &&
      server.isNotEmpty) {
    try {
      await ApiClient(server).updateEntranceName(store.entranceName!, store.sessionToken!);
    } catch (e) {
      _state!.status = '通道名称同步失败（稍后重试）: $e';
    }
  }

  // 启动前增量同步：补齐启动前错过的消息（本地历史只含上次落盘内容，WS 只推连接
  // 建立之后的实时事件；不先 sync 的话，对方刚发的消息要手动 /sync 才出现）。
  // 未接入空间（无 Space Key）时跳过——历史无法解密，且 _decrypt 会兜底占位。
  Future<void> startupSync() async {
    if (!session.hasSession || !session.hasSpace || server.isEmpty) return;
    try {
      final fresh = await session.sync();
      if (fresh.isNotEmpty) {
        _state!.status = '启动同步：新增 ${fresh.length} 条';
      }
    } catch (e) {
      _state!.status = '启动同步跳过: $e（可稍后 /sync）';
    }
  }

  // 启动 WS 实时监听（已激活且配置了 server 时）；新消息到达或连接状态变化即重绘
  void startWs() {
    if (!session.hasSession || server.isEmpty) return;
    session.startWs(
      onMessage: (_) => _refreshGenderForLatest(_state!),
      onStatus: (_) {
        _scheduleRender();
        // 重连/上线补查：对齐 App——每次 WS 变为 connected 都探测口令是否被重设
        final s = _state;
        if (s != null && s.session.wsStatus == WsStatus.connected) {
          _checkEscrowRotated(s.session);
        }
      },
      onAutoSync: (_) => _refreshGenderForLatest(_state!),
      onPeerStatus: _onPeerStatus,
      onPassphraseRotated: (_) {
        // 口令被对方重设：只发通知不弹窗（接入 /space 或修改 /passphrase 时使用新口令）
        _state?.session.messages.add(_systemMessage(_state!.session,
            '⚠️ 对方已重设共享口令——接入或修改口令时请使用新口令'));
        _scheduleRender();
      },
      onProfileUpdated: _onProfileUpdated,
      onRevoked: _onWsRevoked,
      onUnrecognized: _onWsUnrecognized,
      // 对方送达/已读水位更新（receipt.updated）：重绘以刷新我发出消息的状态
      onReceiptUpdated: () => _scheduleRender(),
    );
  }

  // 非入网路径（正常启动）：立刻补同步 + 收实时消息
  if (!_onboarded) {
    await startupSync();
    startWs();
  }

  // 锁屏码：本次刚入网 → 询问设置（可空跳过）；重启解锁已由 main 在
  // loadHistory 前处理（_unlockPin）——此处不再重复
  if (_onboarded) {
    await _askSetPin(session, storePath);
  }

  // 认证后立即拉取 partner 名称/性别表（向导刚结束时 token 才就绪——启动时
  // main 的刷新会因 token 未就绪失败静默；此处补齐——否则向导结束直接发消息
  // 时对方气泡按未知性别回退青绿——老板 2026-09-10 实测）
  await _refreshPartnerNames(_state!);
  // 补登安装级标识（多空间：存量 store 不重走入网流程，启动时补一次；幂等）
  await _registerInstallUid(session, store, storePath, server);
  // 拉一次回执水位：我发出消息的 delivered 状态（单勾→双勾）首屏即正确
  await session.refreshReceipts();

  if (_onboarded) {
    // 入网收尾：致欢迎辞 → 等用户回车 → 清空 system 消息切到聊天态
    await _finalizeOnboarding(session);
    if (!_state!.running) return; // 回车期间 /exit：不再继续
    // 已显性进入聊天态：此时才补同步 + 启 WS（入网期间对方发的消息在此一次补齐，
    // 不再插进向导消息之间）
    await startupSync();
    startWs();
  }
  _scheduleRender();
}

/// 入网向导收尾（老板 2026-09-15 定稿）：向导完成后在消息流里致欢迎辞，随后
/// 自动倒计时（欢迎辞 system 消息上跳动显示剩余秒数，5→1）；倒计时结束作为
/// 「向导态 → 聊天态」的切换点：清空全部 system 消息（向导日志 + 欢迎辞），
/// 只留真实对话并滚到最新。此前的"等用户按回车"实测不好理解（用户不知道
/// 要按回车、也不知道按了会发生什么），自动倒计时无需学习成本。倒计时期间
/// 忽略普通按键（Ctrl+C / /exit 仍可退出），回车等输入不会变成消息。
Future<void> _finalizeOnboarding(ChatSession session) async {
  if (_onboardingFinalized) return;
  _onboardingFinalized = true;
  if (!_state!.running) return;
  // 欢迎辞即最后一条向导向导 system 消息；倒计时期间逐秒替换该消息（重渲染可见秒数跳动）
  // processing=true：倒计时期间忽略输入、隐藏光标（复用 busy 机制——此时尚未进入
  // 聊天态，敲字不应被当作消息提交；Ctrl+C 仍可退出）
  _state!.processing = true;
  session.messages.add(_systemMessage(session, '----------------'));
  // 欢迎辞与读秒拆成两条 system 消息（老板 2026-09-18）：读秒独立成条且逐秒
  // 追加数字不覆盖——"5 4 3 …"式历史可回看，最后 5 4 3 2 1 完整呈现
  session.messages.add(_systemMessage(session, '一切就绪！即将进入秘境与伴侣聊天 💞'));
  ChatMessage countdownMsg =
      _systemMessage(session, _welcomeCountdownText(null, _kWelcomeCountdownSeconds));
  session.messages.add(countdownMsg);
  _scheduleRender();
  for (var remain = _kWelcomeCountdownSeconds - 1; remain >= 1; remain--) {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!_state!.running) return; // 倒计时期间 /exit / Ctrl+C：立即结束
    // 读秒消息：不替换原消息，在文本尾部追加数字（同一条内 "5 4 3 …" 逐秒延长）
    countdownMsg = _systemMessage(
        session, _welcomeCountdownText(countdownMsg, remain));
    session.messages[session.messages.length - 1] = countdownMsg;
    _scheduleRender();
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  if (!_state!.running) return; // 倒计时期间 /exit：不再继续
  _state!.processing = false;
  // 切换到聊天态：清空全部 system 消息，只留真实对话（对方预发 / 自己发出的）
  session.messages.removeWhere((m) => m.isSystem);
  _scheduleRender();
}

/// 欢迎辞读秒文本（单独一条 system 消息，老板 2026-09-18）：首秒 "5"，此后
/// 每秒在尾部追加 " 4"、" 3"……逐秒延长成 "5 4 3 2 1"，不覆盖历史数字。
String _welcomeCountdownText(ChatMessage? current, int remain) {
  final head = current?.plain ?? '';
  return head.isEmpty ? '$remain' : '$head $remain';
}

/// 客户端生成 space_id（UUIDv4，协议 §3.4：space_id/space_key 由客户端生成——
/// 口令密封包内容需含 space_id）。
String _newCliSpaceId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Multiverse：/space create 新建空间（POST /spaces——创建者登记 + session +
/// 首个 join token 一并返回；Space Key 由客户端生成，口令加密 sealed 包随
/// 创建提交，服务端只存密文）。
Future<void> _spaceCreate(ChatSession session, EntranceStore store, String storePath) async {
  final server = session.server;
  if (server.isEmpty) {
    session.messages.add(_systemMessage(session, '⚠️ 未配置服务器地址（引导时输入）'));
    return;
  }
  if (store.spaceKey != null) {
    session.messages.add(
        _systemMessage(session, '✅ 当前通道已绑定秘境（不重复创建）——/space address 查看'));
    return;
  }
  var displayName = store.partnerName ?? '';
  if (displayName.isEmpty) {
    // 我的名字必填（老板 2026-09-10：创建空间时我和对方的名字都必填，不允许空）
    while (true) {
      displayName =
          (await _prompt(session, '❓ 我的名字（后期可改）:', required: true)).trim();
      if (!_state!.running) return;
      // 用户名称白名单（老板 2026-09-16）：中英文/数字/`_`/`-`/emoji，最长 32
      final violation = checkPartnerNamePolicy(displayName);
      if (violation == PartnerNameViolation.empty) {
        session.messages.add(_systemMessage(session, '❌ 名字必填，请输入'));
        _scheduleRender();
        continue;
      }
      if (violation != null) {
        session.messages.add(_systemMessage(session, _partnerNameRuleHint(violation)));
        _scheduleRender();
        continue;
      }
      session.messages.add(_systemMessage(session, '✅ ${displayName}'));
      session.messages.add(_systemMessage(session, '----------------'));
      break;
    }
  }
  // 我的性别（本地记录；Multiverse create 暂不提交——服务端不收 gender）。
  // 只接受数字 1/2（老板 2026-09-10：不接受"男/女/male/female"文字输入）
  while (myGender == null) {
    final g = (await _prompt(session, '❓ 我的性别是\n  1: 男\n  2: 女',
            required: true))
        .trim();
    if (!_state!.running) return;
    if (g == '1') {
      myGender = '男';
      session.messages.add(_systemMessage(session, '✅ 男'));
      session.messages.add(_systemMessage(session, '----------------'));
      _scheduleRender();
    } else if (g == '2') {
      myGender = '女';
      session.messages.add(_systemMessage(session, '✅ 女'));
      session.messages.add(_systemMessage(session, '----------------'));
      _scheduleRender();
    } else {
      session.messages.add(_systemMessage(session, '⚠️ 请输入 1（男）或 2（女）'));
      _scheduleRender();
    }
  }
  // 伴侣（第二人）名字/性别必填（老板 2026-09-10 定稿——create 录入两人身份，
  // join 时按身份选择而非自填名字）
  String peerName;
  while (true) {
    peerName = (await _prompt(session, '❓ 伴侣的名字（后期可改）:',
            required: true))
        .trim();
    if (!_state!.running) return;
    if (peerName.isEmpty) {
      session.messages.add(_systemMessage(session, '⚠️ 伴侣名字必填，请输入'));
      _scheduleRender();
      continue;
    }
    // 用户名称白名单（同"我的名字"）：不合规提示重输
    final nameViolation = checkPartnerNamePolicy(peerName);
    if (nameViolation != null) {
      session.messages.add(_systemMessage(session, _partnerNameRuleHint(nameViolation)));
      _scheduleRender();
      continue;
    }
    // 不允许和第一人同名（老板 2026-09-10）
    if (peerName == displayName) {
      session.messages.add(
          _systemMessage(session, '⚠️ 伴侣名字不能与我的名字相同（$displayName），请重新输入'));
      _scheduleRender();
      continue;
    }
    session.messages.add(_systemMessage(session, '✅ ${peerName}'));
    session.messages.add(_systemMessage(session, '----------------'));
    break;
  }
  String peerGender;
  // 只接受数字 1/2（老板 2026-09-10：不接受"男/女/male/female"文字输入）
  while (true) {
    peerGender = (await _prompt(session, '❓ 伴侣的性别是\n  1: 男\n  2: 女',
            required: true))
        .trim();
    if (!_state!.running) return;
    if (peerGender == '1') {
      peerGender = '男';
      session.messages.add(_systemMessage(session, '✅ ${peerGender}'));
      session.messages.add(_systemMessage(session, '----------------'));
      break;
    }
    if (peerGender == '2') {
      peerGender = '女';
      session.messages.add(_systemMessage(session, '✅ ${peerGender}'));
      session.messages.add(_systemMessage(session, '----------------'));
      break;
    }
    session.messages.add(_systemMessage(session, '⚠️ 请输入 1（男）或 2（女）'));
    _scheduleRender();
  }
  // 共享口令必填（老板 2026-09-11：不输入口令不能完成创建——留空会让伴侣无法
  // 凭口令加入、本机也没有口令密保箱可用）
  String passphrase;
  while (true) {
    if (!_state!.running) return; // 口令阶段 /exit：不继续创建
    passphrase = (await _prompt(session,
            '❓ 设置共享口令（务必牢记，严禁泄漏！仅可将口令分享给秘境伴侣）:',
            required: true))
        .trim();
    if (passphrase.isEmpty) continue; // 防御：输入循环 required 已拦截留空回车
    final policyError = _passphrasePolicyError(passphrase);
    if (policyError != null) {
      session.messages.add(_systemMessage(session, policyError));
      _scheduleRender();
      continue;
    }
    break;
  }
  try {
    final s = await sodium();
    final spaceKeyB64 = base64Encode(s.randombytes.buf(32));
    final spaceId = _newCliSpaceId();
    final api = ApiClient(server);
    final sealed = await KeyEscrowService(api).createPackage(
      passphrase: passphrase,
      spaceKeyB64: spaceKeyB64,
      spaceId: spaceId,
      keyVersion: 1,
    );
    session.messages.add(_systemMessage(session, '✅ 共享口令已设置，请通过安全的方式分享给伴侣。'));
    session.messages.add(_systemMessage(session, '----------------'));
    final created = await _busy(session, '⏳ 正在创建秘境...', () => api.createSpace(
      spaceId: spaceId,
      creatorName: displayName,
      creatorGender: _genderCode(myGender), // 中文 → male/female（与 enroll 一致——老板 2026-09-10）
      peerName: peerName,
      peerGender: _genderCode(peerGender),
      sealedSpaceKey: sealed,
      escrowPassphrase: passphrase,
      publicKey: store.publicKey,
      entranceName: store.entranceName,
      // 安装级标识（多空间：服务端据此认出同一台物理设备的多行）
      installUid: store.ensureInstallUid(),
    ));
    store.spaceId = created.spaceId;
    store.spaceAddress = created.spaceAddress;
    store.spaceKey = spaceKeyB64;
    store.sessionToken = created.sessionToken;
    store.entranceId = created.entranceId;
    store.partnerId = created.creatorPartnerId;
    store.slot = 0; // 创建者 = 第一人（v2 身份槽位；替代 v1 的 partnerA 判据）
    // 密保箱已随本次 POST /spaces 上传（sealed/escrowPassphrase 成对提交，口令非空才走到这）
    // → 标记托管就绪。漏了这行的话，下次启动会被判成"尚未设置共享口令"再问一遍
    // （老板 2026-09-15 反馈）。
    store.escrowUploaded = true;
    store.partnerName = displayName;
    // 伴侣名字落盘：对方尚未加入时 GET /space 的 partner 表里没有他（partner_id 未
    // 由加入者生成），顶部条左段靠这条兜底显示名字（否则刚创建后一直是 '-'）
    store.peerName = peerName;
    store.save(storePath);
    session.messages.add(_systemMessage(session, '🎉 成功创建秘境！地址: ${created.spaceAddress}'));
    // session.messages.add(_systemMessage(session, '📎 邀请新通道（24 小时有效、仅可用一次）：\n ${created.link}\n🛡️  ${created.joinToken}''));
    session.messages.add(_systemMessage(session, '----------------'));
    _onboarded = true;
    _scheduleRender();
    await _activateAfterBind(session, store, storePath, server);
  } catch (e) {
    // 空间数量上限：明确禁止提示（serverConfig.json maxSpaces——老板 2026-09-10）
    if (e is ApiException && e.code == 'SPACE_LIMIT_REACHED') {
      session.messages.add(_systemMessage(session, '⚠️ 秘境数量已达上限（服务器 maxSpaces 限制）——暂不能新建秘境'));
    } else {
      session.messages.add(_systemMessage(session, '⚠️ 创建秘境失败: $e'));
    }
    _scheduleRender();
  }
}

/// Multiverse：/space join <链接或 token> 加入已有空间（preflight 校验 →
/// join 通道登记 + 签发绑定 Space 的 session → 口令 escrow 取 Space Key）。
Future<void> _spaceJoin(ChatSession session, EntranceStore store, String storePath, String input) async {
  final server = session.server;
  if (server.isEmpty) {
    session.messages.add(_systemMessage(session, '⚠️ 未配置服务器地址（引导时输入）'));
    return;
  }
  if (store.spaceKey != null) {
    session.messages.add(
        _systemMessage(session, '✅ 当前通道已绑定秘境（不重复加入）——/space address 查看'));
    return;
  }
  // 兼容完整邀请链接：https://host/join/<token> → 提取 token
  final token = input.contains('/join/') ? input.split('/join/').last.trim() : input.trim();
  if (token.isEmpty) {
    session.messages.add(_systemMessage(session, '🔧 用法: /space join <开通码或邀请链接>'));
    return;
  }
  try {
    final api = ApiClient(server);
    final pre = await _busy(session, '⏳ 校验开通码中......', () => api.preflightJoin(token));
    session.messages.add(_systemMessage(session, '✅ 开通码验证通过'));
    session.messages.add(_systemMessage(session, '----------------'));
    session.messages.add(_systemMessage(
        session, '✅✅✅ 即将加入秘境！'));
    // 展示 create 时预置的两身份——加入者可能是第二人，也可能是第一人的其他
    // 通道，不能靠名字判别身份，必须显式选择（老板 2026-09-10 定稿）
    final slots = pre.slots;
    if (slots.isEmpty) {
      session.messages.add(_systemMessage(session, '⚠️ 该秘境未预置成员身份，无法加入'));
      return;
    }
    session.messages.add(_systemMessage(session, '❓ 我是谁'));
    session.messages.add(_systemMessage(session, '----------------'));
    for (final s in slots) {
      // 名字背景色按性别（粉/蓝——复用 _genderBubble 与消息气泡背景色一致；
      // 不显示性别/在线状态——老板 2026-09-10）
      final bg = _genderBubble(s.gender);
      session.messages.add(
          _systemMessage(session, '  $bg$_white${s.displayName ?? '（未命名）'}$_reset'));
    }
    var chosenSlot = -1;
    while (chosenSlot < 0) {
      final choice = (await _prompt(
              session, '❓ 完整输入我的名字（注意大小写）:', required: true))
          .trim();
      if (!_state!.running) return;
      final matches = <int>[];
      for (final s in slots) {
        if (s.displayName == choice) matches.add(s.slot);
      }
      if (matches.length == 1) {
        chosenSlot = matches.first;
        break;
      }
      session.messages.add(_systemMessage(session,
          matches.isEmpty ? '⚠️ 名字不匹配，请完整输入列表中的名字' : '⚠️ 存在同名成员，无法选择——请先让对方改名'));
      _scheduleRender();
    }
    final myName = slots.firstWhere((s) => s.slot == chosenSlot).displayName;
    session.messages.add(_systemMessage(session, '✅ 我是 ${myName}'));
    session.messages.add(_systemMessage(session, '----------------'));
    // 口令必填，且**先校验再 join**：joinSpace 会消费一次性 join token，旧实现先
    // join（烧掉 token）再验口令——口令一错既回不到口令环节、token 也废了，用户
    // 被踢回「输入开通码」。改为用 preflight 已拿到的 spaceId 先调
    // /spaces/{id}/key-escrow 验口令（不消费 token），错了就停在口令环节重输，
    // 直到正确或 /exit（老板 2026-09-12）。
    EscrowPayload? verified;
    while (true) {
      if (!_state!.running) return;
      final input =
          (await _prompt(session, '❓ 验证共享口令:', hidden: false, required: true))
              .trim();
      // 留空（含 /exit 中止）→ 重问；输入循环 required 已拦截留空回车
      if (input.isEmpty) continue;
      try {
        final file = await _busy(session, '⏳ 核对口令中......',
            () => api.fetchSpaceEscrow(pre.spaceId, input));
        if (file == null) {
          session.messages.add(_systemMessage(
              session, '⚠️ 找不到受托管的口令密保箱，无法凭口令加入。请尝试其他方式。'));
          return;
        }
        // 连同解包一起验：口令对但包不匹配也按口令错误处理，避免白烧 token
        verified =
            await KeyEscrowService(api).openPackage(passphrase: input, envelope: file);
        break;
      } on ApiException catch (e) {
        if (e.code != 'ESCROW_VERIFY_FAILED') rethrow;
        // 404 = 该空间根本没有托管口令密保箱（不是口令输错，重输也没用）→ 明确提示后
        // 退出；401 才是口令错 → 停在口令环节重输（老板 2026-09-12）
        if (e.httpStatus == 404) {
          session.messages.add(_systemMessage(
              session, '⚠️ 找不到受托管的口令密保箱，无法凭口令加入。请尝试其他方式。'));
          return;
        }
        session.messages.add(
            _systemMessage(session, '⚠️ 口令错误，请重新输入（或输入 /exit 退出）'));
        _scheduleRender();
      } on FormatException {
        session.messages.add(
            _systemMessage(session, '⚠️ 口令错误，请重新输入（或输入 /exit 退出）'));
        _scheduleRender();
      }
    }
    final payload = verified; // 循环内 break 前必已赋值（分析期已提升为非空）
    // 口令已通过 → 此时才真正 join（消费 token，只做一次）
    final join = await _busy(session, '⏳ 正在加入秘境...', () => api.joinSpace(
      token: token,
      publicKey: store.publicKey,
      slot: chosenSlot,
      entranceName: store.entranceName,
      // 安装级标识（多空间：服务端据此认出同一台物理设备的多行）
      installUid: store.ensureInstallUid(),
    ));
    store.spaceId = join.spaceId;
    store.spaceAddress = join.spaceAddress;
    store.spaceKey = payload.spaceKeyB64;
    store.sessionToken = join.sessionToken;
    store.entranceId = join.entranceId;
    store.partnerId = join.partnerId;
    store.slot = join.slot; // v2 身份槽位（0=第一人，1=第二人）
    // 密保箱本来就存在（刚才正是靠口令从它取回 Space Key）→ 标记托管就绪。
    // 漏了这行：若加入者选的是 slot=0（同一人的另一条通道），重启后会被判成
    // "尚未设置共享口令"再问一遍（老板 2026-09-15 反馈）。
    store.escrowUploaded = true;
    store.partnerName = myName ?? '成员';
    // 对方名字落盘：取另一身份槽位的预置名（create 录入的两人身份）。我选了
    // slot=0（同第一人的另一条通道）而第二人还没加入时，GET /space 的 partner 表里
    // 没有他 → 顶部条左段靠这条兜底显示名字，而不是 '-'
    for (final slot in slots) {
      if (slot.slot != chosenSlot && slot.displayName != null) {
        store.peerName = slot.displayName;
        break;
      }
    }
    store.save(storePath);
    session.messages.add(_systemMessage(session, '✅ 口令验证通过，成功加入秘境。'));
    session.messages.add(_systemMessage(session, '----------------'));
    _onboarded = true;
    _scheduleRender();
    await _activateAfterBind(session, store, storePath, server);
  } on FormatException {
    session.messages.add(_systemMessage(session, '⚠️ 口令错误：请确认与创建者设置的口令一致'));
    _scheduleRender();
  } on ApiException catch (e) {
    // 2026-09-15：服务端限速（同一 IP 5 分钟内的加入/认证次数上限）会返回 429。
    // 原始 ApiException 很长又不好懂，单独翻译成人话 + 给出可操作的等待时间。
    if (e.code == 'RATE_LIMITED') {
      session.messages.add(_systemMessage(
          session, '⚠️ 操作太频繁，被服务端限流了（保护机制，不是你的开通码有问题）'));
      session.messages.add(_systemMessage(
          session, '   $e —— 等提示的秒数过后再试；自用服务器也可以直接重启服务端清空计数。'));
    } else if (e.code == 'ENTRANCE_LIMIT_REACHED') {
      // 通道数量上限（serverConfig.json maxEntrancesPerSpace）：不是开通码的问题，
      // 是这个秘境的通道已经开满了（含已销毁的——销毁不退额度）
      session.messages.add(_systemMessage(
          session, '⚠️ 该秘境的通道数量已达服务器上限，无法再开通新通道（$e）'));
    } else {
      session.messages.add(_systemMessage(session, '⚠️ 加入秘境失败: $e'));
    }
    _scheduleRender();
  } catch (e) {
    session.messages.add(_systemMessage(session, '⚠️ 加入秘境失败: $e'));
    _scheduleRender();
  }
}

Future<void> main(List<String> args) async {
  // 单测守卫：设 EINZ_UNITTEST=1 时仅加载符号、不启动交互 TUI（测试 formatMessage 等
  // 纯函数用）。保持一行、无副作用，便于测试 import 本文件
  if (Platform.environment['EINZ_UNITTEST'] == '1') return;
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

  // 无显式 --store：默认目录（~/.einz）自动发现已有通道；
  // 无通道 → 引导 init（存 [device-id].json）；损坏文件自动备份 .bak 后重新初始化。
  if (!explicitStore) {
    storePath = _resolveAutoStore();
  }

  // 注：曾在引导前调用 _restoreTerminal() 以恢复"上次异常退出残留的无回显终端"，
  // 但 pty/重定向环境下 stdin 未订阅时设置 echo/lineMode 会触发未捕获异常导致
  // 进程 255 崩溃（已实测定位）。残留场景较少见（真实终端进程退出后由 shell 接管
  // termios），不做启动时强制恢复；退出路径 _exitRaw 已保证正常恢复。

  // 首次使用引导（cooked 逐行问答，进入 raw 模式前）：store 不存在 → 生成通道凭证；
  // 无 Space Key → 口令接入（escrow）；未激活 → auth。全部就绪后才进入 TUI。
  final onboard = await _onboard(storePath, server);
  if (exitCode != 0) return; // 引导中选择 sealed 导入 → 提示后退出
  final store = onboard.$1;
  server = onboard.$2;
  storePath = onboard.$3; // 自动模式下 init 后的实际路径（~/.einz/[device-id].json）

  // 启动自检：**只有服务端明确撤销本通道**才不进 TUI（清盘 + 提示 + 退出）。
  // 会话被清（/revoke 会 DELETE 该通道的 sessions）→ 清 token 走挑战重认证；挑战返回
  // 403 ENTRANCE_REVOKED 同样清盘退出、FORBIDDEN（库被重置/未登记）只警告继续（见 _runGuide）。
  final probe = await _probeRevoked(store, server);
  if (probe == 1) {
    _exitRevoked(storePath); // 不返回
  }
  if (probe == 2) {
    store.sessionToken = null;
    store.save(storePath);
  }
  if (probe == 3) {
    // 服务器不认本通道：只警告，照常进 TUI 看本地历史（数据一条不删）
    _guidanceNotes.add(_unrecognizedNotice);
  }

  final session = ChatSession(store, storePath, server);
  // 运行期任何一次认证拿到 403 ENTRANCE_REVOKED（会话过期自动续期 / /auth / 切换服务器）
  // → 立即清盘退出：撤销语义在"所有已开通的通道"上一致（老板 2026-09-16）。
  // FORBIDDEN（库被重置/未登记）不会走这里，只在消息流里警告。
  session.onEntranceRevoked = () => _exitRevoked(storePath);
  // 全局状态提前初始化：_unlockPin 内用 _state!.running——解锁必须在
  // _state 赋值之后（否则 Null check 崩溃——2026-09-08 老板实测）
  _state = _TuiState(session, storePath);
  // 展示缓存变化即重绘：离线发送时乐观上屏的消息在补发网络等待前就刷新到屏幕
  // （老板 2026-09-13：App 能立刻显示离线消息，TUI 之前要等网络超时回来才显示）
  session.onChanged = _scheduleRender;
  // 锁屏码：已有 PIN 时先解锁（历史消息在解锁前不加载/不显示——防消息泄漏；
  // 刚入网的 _askSetPin 仍在 _runGuide 内处理）
  if (store.pinHash != null) {
    await _unlockPin(session);
  }
  await session.loadHistory();
  // 引导阶段提示（自举/托管/开通码指引）作为 system 消息进入对话流——
  // 必须在 loadHistory 之后加入（loadHistory 开头会 clear messages，否则被清掉）
  for (final note in _guidanceNotes) {
    session.messages.add(_systemMessage(session, note));
  }
  _guidanceNotes.clear();
  _startPeerPolling(); // 对方在线状态：初始查询 + 30s 轮询
  _checkEscrowRotated(session); // 上线补查：离线期间口令被重设则系统消息通知
  // 成员名称/性别表：优先用上次 GET /space 落盘的本地缓存——服务器离线启动时
  // 仍能显示正确名字、气泡仍按性别配色（否则全部回退"对方"/青绿——老板 2026-09-13）。
  _state!.partnerNames = Map.of(store.partnerNames);
  _state!.partnerGenders = Map.of(store.partnerGenders);
  _state!.partnerSlots = Map.of(store.partnerSlots);
  _refreshPartnerNames(_state!); // 认证后刷新（保持最新，并回写缓存）

  // 引导任务（登记/接入/口令问答——消息流交互：system 提示 + you> 输入 + 机密 *）
  // 与输入循环并发启动；引导完成后的启动同步与 WS 由 _runGuide 负责。
  final guide =
      _runGuide(session, storePath, server);

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
  // 关闭终端鼠标事件（_runInputLoop 启用的滚轮报告），退出后终端恢复常态
  try {
    stdout.write('\x1B[?1000l\x1B[?1006l');
    stdout.flush().ignore();
  } catch (_) {}
}

void _exitRaw() {
  _restoreTerminal();
}

/// 删本机本地数据：store 文件（含同名 .bak）与附件明文缓存目录。
///
/// 两条路径共用它：`_exitRevoked`（被对方撤销后的自毁）与 `/reset`（用户主动重置）。
/// 刻意**不**删 `~/.einz` 整个目录（同机多通道共用）、其它通道的 store、以及用户
/// 导出的 `einz-backup-*.json`。
///
/// 注意 `attachmentCacheDir()` 是 `$HOME/.einz/cache`，多 store **共享**：第 2 条通道
/// 重置会连带删掉第 1 台的附件明文缓存（可重新下载重建，与 App 自毁口径一致）。
void _deleteLocalData(String storePath) {
  for (final path in [storePath, '$storePath.bak']) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
  try {
    final cache = Directory(attachmentCacheDir());
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  } catch (_) {}
}

/// 通道被**明确撤销**（认证 403 `ENTRANCE_REVOKED` / 在线 WS 广播 entrance.revoked）→
/// 同步销毁本地数据、恢复终端、提示后立即退出。
///
/// 删本地数据的路径只有两条：这一条（被对方用口令撤销后的自毁）与 `/reset`
/// （用户自己在本地确认后重置）。未登记（库被重置）/连不上只警告，绝不动本地文件
/// （老板 2026-09-16）。
///
/// 顺序很重要：`exit(0)` 会立即终止进程，之后不会再有 `store.save()` 落盘；若改成
/// 先退出后异步删、或删完还继续跑，都可能被在途写把文件重建回来——所以"同步删完→再退出"。
/// 提示写 stderr：pty 下退出瞬间 stdout flush 未决时 stdout.write 会抛
/// "StreamSink is bound to a stream"——stderr 独立 sink 必达。
void _exitRevoked(String storePath) {
  _deleteLocalData(storePath);
  _restoreTerminal();
  try {
    stderr.write('$_clearHome本通道已被撤销，本地数据已清除，请重新入网。\n');
    stderr.flush();
  } catch (_) {}
  exit(0);
}

/// `/reset` 的收尾：清完本地数据后提示并退出。用户下次启动 TUI 会走全新入网向导。
void _exitReset(String storePath) {
  _deleteLocalData(storePath);
  _restoreTerminal();
  try {
    stderr.write('$_clearHome已重置本通道，本地数据已清除，下次启动将重新入网。\n');
    stderr.flush();
  } catch (_) {}
  exit(0);
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

/// 按显示宽度把 [s] 截断到不超过 [maxWidth]（末尾加省略号 …）。
/// 底部状态行用：单行通知超宽时截断，避免撑破屏幕布局。
/// ANSI 转义序列不计宽度、原样复制整段（此前逐 rune 调 _displayWidth 会把
/// 转义序列的 [97m 等字节按普通字符计宽，标题栏彩色段截断预算被吃掉——
/// "○ - #doomship" 限 9 列被截成 "○ - …" 的根因）。
String _truncateByWidth(String s, int maxWidth) {
  if (maxWidth <= 0 || _displayWidth(s) <= maxWidth) return s;
  final buf = StringBuffer();
  var w = 0;
  final it = s.runes.iterator;
  while (it.moveNext()) {
    final r = it.current;
    if (r == 0x1B) {
      // 转义序列：连同整段（到终止字节）原样复制，不占显示宽度
      buf.writeCharCode(r);
      while (it.moveNext()) {
        final c = it.current;
        buf.writeCharCode(c);
        if (c == 0x5B) continue; // CSI 引入符
        if (c >= 0x40 && c <= 0x7E) break; // 终止字节（字母）
      }
      continue;
    }
    final ch = String.fromCharCode(r);
    final cw = _displayWidth(ch);
    if (w + cw > maxWidth - 1) break; // 预留 1 列给省略号
    buf.write(ch);
    w += cw;
  }
  return '$buf…';
}

/// 把 [text] 用 [colorSeq] 着色并铺满整行（补空格到 [cols]），末尾统一 reset。
/// 标题栏/底部状态行用：整行背景色连续覆盖，避免中间 reset 打断导致底色只盖半行。
/// 统一强制白色前景——黑底行不能依赖终端默认前景色（macOS Terminal/iTerm2
/// 默认前景为黑，黑底黑字看不见；VSCode 默认浅灰才恰好可见）。
String _barLine(String colorSeq, String text, int cols) {
  final content = '$colorSeq$_white$text';
  final pad = cols - _displayWidth(content);
  return '$content${pad > 0 ? ' ' * pad : ''}$_reset';
}

/// 三段式标题栏拼装：左/中/右**各占全宽 1/3 - 1 字符的上限，互不挤压**
/// （老板 2026-09-16）——超出的一段**自己**截断成 … 符号，既不挤掉别人、也不会
/// 被别人挤掉：品牌名同样受 1/3 上限约束（放不下时自我压缩成 "Einz …"），
/// 不存在"左右太长就把品牌整段丢掉"的行为。
/// 左段贴左缘、中段居中、右段贴右缘，窗口拉伸时三段随上限同步扩展。
/// 各段可含 ANSI 颜色（_displayWidth 会跳过转义序列）；返回已铺满整行的成品。
String _titleBarThree(String left, String center, String right, int cols) {
  final sideMax = cols ~/ 3 - 1; // 每段上限：全宽 1/3 - 1 字符
  final leftT = _truncateByWidth(left, sideMax);
  final rightT = _truncateByWidth(right, sideMax);
  final centerT = _truncateByWidth(center, sideMax);
  // 中段被截时尾部会丢掉「关粗体 + 白字」序列 → 补回，否则 bold 泄漏到其后的
  // 右段（终端把右段的绿点按亮绿渲染——老板 2026-09-10 反馈过同类问题）
  final centerSafe =
      centerT.length == center.length ? centerT : '$centerT\x1B[22m$_white';
  final lw = _displayWidth(leftT);
  final rw = _displayWidth(rightT);
  final cw = _displayWidth(centerSafe);
  final centerPos = (cols - cw) ~/ 2; // 品牌名起点：屏幕正中（中间 1/3 的正中）
  // 每段都 ≤ 全宽 1/3 - 1 ⇒ 三段总宽 < cols，不会重叠；仍取 max(0,…) 兜住
  // 极窄终端（cols < 6 时 sideMax ≤ 0 不截断）以免负数空格抛异常。
  final leftPad = centerPos - lw;
  final rightPad = (cols - rw) - (centerPos + cw);
  final content =
      '$leftT${' ' * (leftPad > 0 ? leftPad : 0)}$centerSafe${' ' * (rightPad > 0 ? rightPad : 0)}$rightT';
  return _barLine(_bgBlack, content, cols);
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
  final prompt = '${_cyan}[我]${_reset} ';
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
  final msgArea = rows - 2 - s.inputLines; // 顶部标题栏 1 行 + 底部状态行 1 行 + 输入区 N 行

  final buf = StringBuffer();
  buf.write(_hideCursor);
  buf.write(_clearHome);

  // 顶部标题栏（第 1 行）：黑色背景整行 + 白色文字，
  // 与消息流明显区分；我的灯（绿●=在线，红✗=断线重连，黄↻=连接中，白○=离线）。
  // 状态灯颜色序列后立即回到白字（不 reset，背景持续），整行铺满后统一 reset。
  final ws = s.session.wsStatus;
  final myDot = switch (ws) {
    WsStatus.connected => '$_green●$_white',
    WsStatus.connecting => '$_yellow↻$_white',
    WsStatus.reconnecting => '$_red✗$_white',
    WsStatus.stopped => '${_white}○',
  };
  final peerName = _peerNameOf(s);
  final peerDot = s.peerOnline ? '$_green●$_white' : '${_white}○';
  // 三段式标题栏：对方状态贴左缘、我的状态贴右缘（与消息左右分栏一致——
  // 对方消息在左、我的消息在右）、品牌名 "Einz TUI" 居中。
  // 三段各占全宽 1/3 上限、互不挤压，超宽的一段自己截断（含品牌名）；
  // 因此每段都是"尾部先丢"——两侧的灯与名字在前，通道名在后最先被截。
  final peerEntrances = _peerEntranceLabel(s);
  final titleText = _titleBarThree(
    '$peerDot $peerName'
        '${_entranceCountLabel(s.peerEntranceOnline, s.peerEntranceTotal)}$peerEntrances',
    // 品牌名 bold 展示后必须关闭粗体（ESC[22m）再继续——否则 bold 状态泄漏到
    // 右段，终端把右段的绿点（ESC[32m）按亮绿渲染，比左段标准绿更亮
    // （老板反馈 2026-09-10：左侧在线绿灯不如右侧明亮）
    '${_bold}Einz TUI\x1B[22m$_white',
    // 右段（我）：`灯 名字 @本机名 #n/m#其它在线通道…`（老板 2026-09-16）——
    // 本机用 @ 独立出来（它可能在线也可能离线，但总要说明"我此刻在哪台"），
    // 后面的 #n/m 与通道列表**扣除本机**，两者严格一一对应。
    '$myDot ${_partnerLabel(s.session.store, s.partnerNames)}'
        '${_myEntranceTag(s)}'
        '${_entranceCountLabel(s.myOtherOnlineSince.length, s.myOtherEntranceTotal)}'
        '${_myOtherEntrancesLabel(s)}',
    cols,
  );
  buf.write(titleText);
  buf.write('\r\n');

  // 消息区：从下往上堆叠——最新消息紧贴输入条（输入条上方），旧消息向上滚出。
  // 滚动窗口由 scrollTop 决定：贴底（scrollTop == lastMaxStart）时跟随最新，
  // 翻页浏览（PgUp/PgDn/滚轮）时停留在浏览位置，新消息到达不打断（自动跟随
  // 只发生在贴底状态）。
  final lines = <String>[];
  final msgs = s.session.messages;
  // 附件固定序号表每帧预计算一次（formatMessage 逐条复用，避免 O(n²) 扫描）
  final attachmentNos = _attachmentNos(s.session);
  for (var i = 0; i < msgs.length; i++) {
    lines.addAll(formatMessage(msgs[i], cols, attachmentNos: attachmentNos));
    // 每条消息（含末条）后都插一个空行：消息之间靠空行隔开，末条的空行
    // 给底部 [我] 输入区留出呼吸空间（老板要求——末条不插会让输入框紧贴末条）
    lines.add('');
  }
  final maxStart = lines.length > msgArea ? lines.length - msgArea : 0;
  if (s.scrollTop >= s.lastMaxStart) {
    s.scrollTop = maxStart; // 上次贴底（或首次渲染）：跟随到底部
  } else if (s.scrollTop > maxStart) {
    s.scrollTop = maxStart; // 消息变少导致越界：钳制回底部
  }
  s.lastMaxStart = maxStart;
  s.lastMsgArea = msgArea;
  final end =
      s.scrollTop + msgArea < lines.length ? s.scrollTop + msgArea : lines.length;
  final visible = lines.sublist(s.scrollTop, end);
  final bottom = rows - s.inputLines - 1; // 输入条上方第一行（消息区底部）
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

  // 输入区：**固定屏幕底部上方一行**（top = rows - inputLines），最底一行留给状态行，
  // 与 _renderInputLine 的定位计算完全一致——否则消息少时输入区被画在
  // 屏幕中间，与局部重绘的底部定位不一致 → you> 跳动、上下重复。
  // 逐行定位 + 清行（\x1B[K），避免残留旧行。
  final prompt = '${_cyan}[我]${_reset} ';
  final top = rows - inputWrapped.length; // 输入区顶部行号（状态行占最底一行）
  for (var i = 0; i < inputWrapped.length; i++) {
    buf.write('\x1B[${top + i};1H'); // 定位输入区各行第 1 列
    buf.write('\x1B[K'); // 清除该行
    if (i == 0) {
      buf.write(prompt);
    } else {
      buf.write('      '); // 续行缩进（与 prompt '[我] ' 同宽，双宽字符按 5 列对齐）
    }
    buf.write(inputWrapped[i]);
    if (i < inputWrapped.length - 1) {
      buf.write('\r\n');
    }
  }

  // 底部状态行（屏幕最底一行）：黑色背景整行 + 白色文字（与顶部标题栏同风格），
  // 滚动通知（发送结果/同步进度/下载进度等瞬时状态）独占整行显示；
  // 空状态显示常用命令提示。
  buf.write('\x1B[$rows;1H\x1B[K');
  if (s.scrollTop < s.lastMaxStart) {
    // 历史浏览模式：正在看更早的消息（未贴底），提示翻页键；到底后自动回正常状态
    buf.write(_barLine(_bgBlack, '📜 历史浏览（PgUp/PgDn 或滚轮翻页，翻到底自动回到最新）', cols));
  } else if (s.status.isNotEmpty) {
    buf.write(
        _barLine(_bgBlack, '⚙ ${_truncateByWidth(s.status, cols - 4)}', cols));
  } else {
    buf.write(_barLine(
        _bgBlack,
        '⚙ ${_truncateByWidth('/help 查看命令 /invite 开通新通道 /attach 发送文件', cols - 4)}',
        cols));
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

/// 状态条我的显示名（远程名称表优先——同 partner 多通道同步显示最新名字；
/// 未拉取/未知回退本地 store，再回退规范 id）。
/// 返回纯文本（不含颜色），由调用方（标题栏）统一着色。
String _partnerLabel(EntranceStore store, Map<String, String> partnerNames) {
  final pid = store.partnerId;
  return (pid != null ? partnerNames[pid] : null) ??
      store.partnerName ??
      store.partnerId ??
      '-';
}

/// 在线通道按上线时刻降序（最新上线在最前）——两侧共用的展示顺序
/// （老板 2026-09-16：按上线顺序排，不按"最近发过消息"）。
List<String> _byOnlineOrder(Map<String, int> sinceById) {
  final entries = sinceById.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return [for (final e in entries) e.key];
}

/// 对方显示名：partnerNames 里非我的一项 → store.peerName（create 预置的伴侣名 /
/// join 时另一身份槽位的名字）→ '-'。
/// 本通道身份未确认（新通道引导中/未登记，partnerId 为空）时对方是谁不确定——
/// 不猜测名称表第一项（此前会把 partnerA 的名字当成对方展示，引导中左右两侧
/// 甚至显示同一个人——老板实测反馈），显示中性占位「?」（老板要求，不写"对方"）。
String _peerNameOf(_TuiState s) {
  final myPid = s.session.store.partnerId;
  if (myPid == null) {
    return '?';
  }
  // v2：对方 = partnerNames 里非我的 partnerId（空间两人——多通道同身份共享同一
  // partnerId；不再用 v1 的 partnerA/partnerB 假 id 查询——老板 2026-09-10 反馈
  // 一直显示 '-'）
  for (final entry in s.partnerNames.entries) {
    if (entry.key != myPid) return entry.value;
  }
  // 对方还没加入：空间里没有他的 partner_id → GET /space 的 partner 表里没有他，
  // 回落到创建/加入时已知的名字（老板 2026-09-16：刚创建就进聊天窗口时要显示
  // 对方名字，而不是 '-'）
  final preset = s.session.store.peerName;
  if (preset != null && preset.isNotEmpty) return preset;
  return '-';
}

/// 同一身份的多通道计数（顶部条 "#n/m"）：**有通道就显示**，不省略 0/n——全离线
/// 时人名后面若什么都没有，"没有人名对应的通道"和"只是没显示"就分不清了
/// （老板 2026-09-16）。"台在线"字样去掉：以 # 引导，与紧随其后的 #通道名 同形，
/// 一眼看出这一段是通道信息而非人名。
/// totalCount ≤ 0（没有这类通道，如我的其它通道为 0 条）时整段省略——本机那台由
/// `@通道名` 表示，不参与这对数字（老板 2026-09-16）。
String _entranceCountLabel(int onlineCount, int totalCount) {
  if (totalCount <= 0) return '';
  return ' #$onlineCount/$totalCount';
}

/// 对方在线通道片段：`#A#B#C`——**逐个列出对方所有在线通道**，按上线时刻降序
/// （最新上线的紧挨名字，最早上线的在最右 = 最先被截断丢弃）。
/// 刻意不按"最近一条消息发自哪条"（老板 2026-09-16）：多通道时应展示谁在线、
/// 谁刚上线，而不是最后发言的那台（它可能早已离线）。
/// 名字取 listEntrances 的 entrance_name，未知名回退 entrance_id；无在线通道时空串。
String _peerEntranceLabel(_TuiState s) {
  final buf = StringBuffer();
  for (final id in _byOnlineOrder(s.peerOnlineSince)) {
    buf.write('#${s.entranceNames[id] ?? id}');
  }
  return buf.toString();
}

/// 我的在线通道片段：`#A#B#C`——**其它**在线通道，按上线时刻降序（与左段同构）。
/// **不含本机**：本机由 `_myEntranceTag` 的 `@通道名` 单独表示，故本表数量与
/// `#n/m` 的 n 一致。
/// 名字取 listEntrances 的 entrance_name，未知名回退 entrance_id；无其它在线通道时空串。
String _myOtherEntrancesLabel(_TuiState s) {
  final buf = StringBuffer();
  for (final id in _byOnlineOrder(s.myOtherOnlineSince)) {
    buf.write('#${s.entranceNames[id] ?? id}');
  }
  return buf.toString();
}

/// 右段本机标识：` @通道名`——把"我此刻在哪条"从通道列表里**独立**出来
/// （老板 2026-09-16）：本机可能在线也可能离线，但总要说清我坐在哪台机器前，
/// 且它不该混进后面的 `#n/m` 与在线通道列表里（否则本机离线时计数与列表对不上）。
/// 名字优先取 /entrances 的 entrance_name，缺失回退本地 store；未登记显示 `@-`。
String _myEntranceTag(_TuiState s) {
  final store = s.session.store;
  final myId = store.entranceId;
  final myName = (myId != null ? s.entranceNames[myId] : null) ??
      store.entranceName ??
      myId ??
      '-';
  return ' @$myName';
}

/// 通道上下线时刻（毫秒 epoch）→ 本地时间文本：今天 HH:mm / 昨天 HH:mm / M/d HH:mm。
///
/// **只给人一眼看**：跨时区核对另有 UTC（见 `_fmtEntranceTimeUtc`）——老板 2026-09-17
/// 要求两个都在：本地时间直观，UTC 用来保证中美两台机器看到的能互相对上。
String _fmtEntranceTimeLocal(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final hhmm =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return hhmm;
  final y = now.subtract(const Duration(days: 1));
  if (t.year == y.year && t.month == y.month && t.day == y.day) return '昨天 $hhmm';
  return '${t.month}/${t.day} $hhmm';
}

/// 通道上下线时刻（毫秒 epoch）→ 紧凑 UTC `20260226T123556Z`（去掉 `-` 与 `:`）。
///
/// 不带分隔符是老板 2026-09-17 定的：秒级精度足够，去掉分隔符后宽度小，通道列表
/// 一行里塞得下；末尾 `Z` 明说是 UTC。
String _fmtEntranceTimeUtc(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
}

/// 同空间通道列表的一行（`/entrances` 与 `/revoke` **共用同一份编号**——两个命令看到的
/// 序号必须一致，所以不可撤销的本机、已被撤销的通道也照常占号，由 `/revoke` 拒绝）。
class _EntranceRow {
  _EntranceRow({
    required this.no,
    required this.entranceId,
    required this.label,
    required this.partnerName,
    required this.online,
    required this.tag,
    required this.when,
    required this.isMe,
    required this.revoked,
  });

  final int no; // 1 基序号（与 /entrances 输出一致；/revoke 按它选通道）
  final String entranceId;
  final String label; // 通道名（缺失回退 entrance_id）
  final String partnerName; // 使用者名字（缺失回退 partner_id）
  final bool online;
  final String tag; // 本机 / 已撤销 / 在线 / 离线
  final String when; // since 上线时刻（在线）/ since 最后活跃时刻（离线，≈下线时刻）
  final bool isMe;
  final bool revoked;

  /// 列表行文本（/entrances 与 /revoke 的列表、确认提示共用，保证逐字一致）。
  String get line => '\n  $no) ${online ? '🟢' : '⚪'} $label [$partnerName] $tag$when';
}

/// 拉取**同空间全部通道**（我 + 对方，不只是自己的通道）并格式化为带序号的行。
///
/// 在线判定与顶部条同源：本机以本地 WS 状态为准；其余看 `connected_at`（旧服务端无该
/// 字段时退回 last_seen<60s）。已被撤销的通道（`status != 'active'`）也列出来并标注
/// ——服务端 /entrances 不过滤状态，藏着不显示反而会让人以为"通道凭空消失了"。
/// 网络/会话异常原样抛出，由调用方提示。
Future<List<_EntranceRow>> _fetchEntranceRows(_TuiState s) async {
  final server = s.session.server;
  final token = s.session.store.sessionToken;
  if (server.isEmpty || token == null) {
    throw StateError('未连接（缺少 server/token）');
  }
  final entrances = await ApiClient(server).listEntrances(token);
  final myId = s.session.store.entranceId;
  final now = DateTime.now().millisecondsSinceEpoch;
  final myWsOnline = s.session.wsStatus == WsStatus.connected;
  final rows = <_EntranceRow>[];
  var no = 0;
  for (final d in entrances) {
    final devId = (d['entrance_id'] ?? '-') as String;
    final devName = (d['entrance_name'] as String? ?? '');
    final partner = (d['partner_id'] ?? '-') as String;
    final last = d['last_seen'];
    final connectedAt = d['connected_at'];
    final revoked = d['status'] != null && d['status'] != 'active';
    // 上线时刻：online_since（进入在线态，重连不刷新，与顶部条同源）→ connected_at
    final sinceMs = (d['online_since'] as num?)?.toInt() ??
        (connectedAt is num ? connectedAt.toInt() : null);
    // 在线判定：本机以本地 WS 状态为准（与顶部条一致）；其余有实时连接
    // （connected_at 非 null）即在线；旧服务端无该字段时退回 last_seen<60s
    final online = !revoked &&
        (devId == myId
            ? myWsOnline
            : (d.containsKey('connected_at')
                ? connectedAt != null
                : (last is num && now - last < 60 * 1000)));
    final isMe = devId == myId;
    // 在线 → "since 上线时刻"；离线 → "上次活跃 时刻"（**不显示上线时刻**：服务端
    // 离线时 last_seen 置 0，直接格式化会变成 1970-01-01——老板 2026-09-16 实测）。
    // 在线 → 上线时刻；离线 → **最后一次活跃**时刻（≈ 下线时刻，老板 2026-09-17：
    // 两种都用 `since` 一个词就行）。两点说明：
    // - 服务端 WS 断开时把 last_seen 置 0（ws.ts），所以干净下线的通道这里 stamp=0
    //   → 不显示时间（直接格式化会变成 1970-01-01，老板 2026-09-16 实测）；
    // - 非 0 时它是最后一次心跳/认证的时刻，比真正断线早 ≤1 个心跳周期（30s）。
    final int stamp;
    if (online) {
      stamp = sinceMs ?? 0;
    } else if (!revoked && last is num) {
      stamp = last.toInt();
    } else {
      stamp = 0;
    }
    final when = stamp > 0
        ? ' since ${_fmtEntranceTimeLocal(stamp)} (${_fmtEntranceTimeUtc(stamp)})'
        : '';
    rows.add(_EntranceRow(
      no: ++no,
      entranceId: devId,
      label: devName.isNotEmpty ? devName : devId,
      partnerName: s.partnerNames[partner] ?? partner,
      online: online,
      tag: isMe ? '本机' : (revoked ? '已撤销' : (online ? '在线' : '离线')),
      when: when,
      isMe: isMe,
      revoked: revoked,
    ));
  }
  return rows;
}

/// 按序号（1 基，与 /entrances 一致）/ 通道名 / entrance_id 匹配通道行。
/// 返回全部匹配项（调用方区分"没匹配"与"同名多台"——后者不能猜，必须让用户用序号）。
List<_EntranceRow> _matchEntranceRows(List<_EntranceRow> rows, String input) {
  final key = input.trim();
  if (key.isEmpty) return const [];
  final no = int.tryParse(key);
  if (no != null) {
    return [for (final r in rows) if (r.no == no) r];
  }
  return [for (final r in rows) if (r.entranceId == key || r.label == key) r];
}

/// 撤销失败的按码提示（PROTOCOL.md §7.2 的失败码）。**每次都要说清"目标通道未受影响"**
/// ——撤销是破坏性操作，用户必须能立刻判断"刚才那下到底生效没有"。
String _revokeErrorHint(ApiException e) => switch (e.code) {
      'ESCROW_VERIFY_FAILED' =>
        '⚠️ 共享口令错误——撤销未执行，目标通道毫发无损（重试：/revoke <序号>）',
      'ESCROW_RATE_LIMITED' => '⚠️ 口令尝试过多被限流——稍等再试（目标通道未受影响）',
      'PASSPHRASE_NOT_SET' =>
        '⚠️ 本空间还没有可校验的共享口令（未设置或被清除）——先用 /passphrase 设置口令再撤销',
      'FORBIDDEN' => '⚠️ 目标通道不在本空间（可能已被移除或撤销）——未做任何改动',
      'NOT_FOUND' => '⚠️ 该通道不存在——未做任何改动',
      'INVALID_REQUEST' => '⚠️ 请求被拒（不能撤销本机）——未做任何改动',
      'UNAUTHORIZED' => '⚠️ 会话已失效——先 /auth 重新激活再试（未做任何改动）',
      _ => '⚠️ 撤销失败: ${e.message}——未做任何改动',
    };

/// 对方改名/改通道名（Server 广播 profile.updated）：立即更新名称映射。
void _onProfileUpdated(WsProfileUpdatedEvent e) {
  final s = _state;
  if (s == null) return;
  if (e.partnerId != null && e.partnerName != null && e.partnerName!.isNotEmpty) {
    s.partnerNames[e.partnerId!] = e.partnerName!;
    // 回写本地缓存：离线启动时仍显示改名后的名字
    s.session.store.partnerNames = Map.of(s.partnerNames);
    // 对方改名 → 同步预置名快照：/myname 的同名判据与顶部条兜底都用它，不跟上的话
    // 旧名字会一直卡在判据里（明明已没人叫那个名字，却仍不许我用）。与 App 的
    // _onProfileUpdated 同向（它用广播里的新名字覆盖 _peerName）。
    if (e.partnerId != s.session.store.partnerId) {
      s.session.store.peerName = e.partnerName;
    }
    s.session.store.save(s.session.storePath);
  }
  if (e.entranceName != null && e.entranceName!.isNotEmpty) {
    s.entranceNames[e.entranceId] = e.entranceName!;
  }
  _scheduleRender();
}

/// 在线期间收到 entrance.revoked（被 /revoke 撤销）→ 立刻回命令行：
/// 恢复终端、提示"本通道已被撤销。"后退出。
void _onWsRevoked(WsEntranceRevokedEvent event) {
  final s = _state;
  if (s == null) return;
  _exitRevoked(s.session.storePath);
}

/// WS 重连时重新认证失败（403 `FORBIDDEN`：后台库被重置/本通道未登记）→
/// 只提示一次，继续跑（退避重连；库复原后自动恢复）。**绝不删本地数据**。
void _onWsUnrecognized() {
  final s = _state;
  if (s == null || !s.running || _unrecognizedShown) return;
  _unrecognizedShown = true;
  s.session.messages.add(_systemMessage(s.session, _unrecognizedNotice));
  _scheduleRender();
}

/// 对端上下线广播（Server 推送——立即更新对方在线状态，不等轮询）。
void _onPeerStatus(WsPeerStatusEvent event) {
  final s = _state;
  if (s == null) return;
  // 与我同身份的通道（我自己的另一条）上下线不算"对方"——新服务端已不推这类
  // 广播，这里兜住旧服务端（旧 payload 无 partner_id 时按原行为处理）
  if (event.partnerId != null && event.partnerId == s.session.store.partnerId) return;
  final online = event.type == kWsTypePeerOnline;
  if (online != s.peerOnline) {
    s.peerOnline = online;
    _render();
    // 对方上线（join 后新成员在线）→ 立即刷新 partner 名称/性别表：第二人的
    // 性别创建时就已写入 space_members（slot 预置），join 后 partner_id 落位，
    // getSpace 即可返回——不必等收到第一条消息才按需刷新
    // （老板 2026-09-10："第二人的性别创建时就设置，应该第一个消息之前就知道"）
    if (online) {
      _refreshPartnerNames(s);
    }
  }
  // 广播只带 entrance_id（+上线时刻），通道名/总数仍来自 /entrances——立刻重拉一次，
  // 否则新上线的通道名要等 30s 轮询才出现在顶部条（老板 2026-09-16）
  _refreshPeerOnline();
}

/// 查询对方在线状态（listEntrances last_seen<60s——同 App 判定），更新顶部条。
Future<void> _refreshPeerOnline() async {
  final s = _state;
  if (s == null) return;
  final server = s.session.server;
  final token = s.session.store.sessionToken;
  if (server.isEmpty || token == null) return;
  try {
    final entrances = await ApiClient(server).listEntrances(token);
    final now = DateTime.now().millisecondsSinceEpoch;
    final myId = s.session.store.entranceId;
    final myPid = s.session.store.partnerId;
    // 本机是否在线取本地 WS 状态（首屏轮询常早于 WS 建连，此时服务端 connected_at
    // 还是 null —— 否则刚启动会先显示"0/2台在线"再跳成 1/2）
    final myWsOnline = s.session.wsStatus == WsStatus.connected;
    // 通道在线 = 有实时 WS 连接（connected_at 非 null）；旧服务器无该字段时退回
    // last_seen<60s（last_seen 会被轮询 touchLastSeen 持续刷新，不代表实时连接）
    bool entranceOnline(Map d) {
      // 本机一律以本地 WS 状态为准，**不回退服务端**：服务端要等心跳超时（最多 30s）
      // 才把本机判离线，那段时间会出现"本机灯已红/↻、而 #n/m 仍把自己算作在线"的
      // 自相矛盾（老板 2026-09-16）。
      if (d['entrance_id'] == myId) return myWsOnline;
      if (d.containsKey('connected_at')) return d['connected_at'] != null;
      final last = d['last_seen'];
      if (last is! num) return false;
      return now - last < 60 * 1000;
    }
    // 顺带维护通道名映射、对方在线通道（顶部条对方 #通道名）与双方通道计数。
    // 关键：在线是"人"维度的——同一 partner 的其它通道是我自己的通道，不能点亮
    // 对方（此前只按 entrance_id != 自己 判定 → 我的第二条通道一上线，尚未加入的
    // 对方 B 就显示绿灯——老板 2026-09-16 实测）。
    s.entranceNames.clear();
    int myOtherTotal = 0; // 我的其它通道总数（不含本机——它由 @通道名 表示）
    int peerTotal = 0;
    int peerOnline = 0;
    final peerSince = <String, int>{}; // 在线对方通道 → 上线时刻（降序展示）
    // 在线我方**其它**通道 → 上线时刻（降序展示；不含本机）
    final myOtherSince = <String, int>{};
    for (final d in entrances) {
      if (d['status'] != null && d['status'] != 'active') continue; // 已撤销不计
      final devId = (d['entrance_id'] as String?) ?? '';
      final devName = (d['entrance_name'] as String?) ?? '';
      if (devId.isNotEmpty && devName.isNotEmpty) s.entranceNames[devId] = devName;
      final pid = d['partner_id'] as String?;
      final isOnline = entranceOnline(d);
      // 上线时刻：online_since（进入在线态，重连不刷新）→ 退回 connected_at → 0
      final since = (d['online_since'] as num?)?.toInt() ??
          (d['connected_at'] as num?)?.toInt() ??
          0;
      if (pid == null || myPid == null) {
        // 身份尚未落位（新通道引导中）：退回按通道判定，不统计多通道数
        if (devId != myId && isOnline) {
          peerOnline++;
          peerSince[devId] = since;
        }
        continue;
      }
      if (pid == myPid) {
        // 本机不参与 #n/m 与通道列表（它由 @通道名 单独表示，不论在线与否）
        if (devId == myId) continue;
        myOtherTotal++;
        if (isOnline) myOtherSince[devId] = since;
        continue;
      }
      peerTotal++;
      if (isOnline) {
        peerOnline++;
        peerSince[devId] = since;
      }
    }
    final online = peerOnline > 0;
    // 通道集合变化也要重绘：A 下 B 上（在线数不变）时顶部条应换成 B 的名字
    final entrancesChanged = peerSince.length != s.peerOnlineSince.length ||
        peerSince.entries.any((e) => s.peerOnlineSince[e.key] != e.value) ||
        myOtherSince.length != s.myOtherOnlineSince.length ||
        myOtherSince.entries.any((e) => s.myOtherOnlineSince[e.key] != e.value);
    final changed = online != s.peerOnline ||
        myOtherTotal != s.myOtherEntranceTotal ||
        peerOnline != s.peerEntranceOnline ||
        peerTotal != s.peerEntranceTotal ||
        entrancesChanged;
    s.peerOnline = online;
    s.myOtherEntranceTotal = myOtherTotal;
    s.peerEntranceOnline = peerOnline;
    s.peerEntranceTotal = peerTotal;
    s.peerOnlineSince
      ..clear()
      ..addAll(peerSince);
    s.myOtherOnlineSince
      ..clear()
      ..addAll(myOtherSince);
    if (changed) _render();
  } catch (_) {
    // 查询失败保持上次状态（断网/未认证）
  }
}

Timer? _peerTimer;

/// 启动对方在线轮询（初始一次 + 每 30s 兜底；退出由 exit 兜底，无需清理）。
void _startPeerPolling() {
  _peerTimer?.cancel();
  _refreshPeerOnline();
  _peerTimer =
      Timer.periodic(const Duration(seconds: 30), (_) => _refreshPeerOnline());
}

/// 消息时间标签（本地时间，参照渲染时刻）：
/// 今天 → HH:MM（如 14:30）；跨天（同年）→ MM-DD HH:MM（如 09-02 14:30）；
/// 跨年 → 再补年份（如 2026-09-02 14:30）。
String _timeLabel(int createdAt) {
  final t = DateTime.fromMillisecondsSinceEpoch(createdAt);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  if (sameDay) return hm;
  final md = '${two(t.month)}-${two(t.day)}';
  if (t.year == now.year) return '$md $hm';
  return '${t.year}-$md $hm';
}

/// 按性别表取消息气泡背景色：男蓝 / 女品红 / 性别未知青绿（2026-09-10 老板要求）。
/// 兼容服务端两种取值：App 提交规范 male/female，旧 TUI 提交过中文 男/女。
String _genderBubble(String? rawGender) {
  if (rawGender == 'male' || rawGender == '男') return _bgBlue;
  if (rawGender == 'female' || rawGender == '女') return _bgPink;
  return _bgTeal;
}

/// 我发出的消息状态字符（标签后缀，只用于自己的消息）：
/// - pending（未被服务端确认，含离线队列）→ `⋯`
/// - sent（服务端已收下）→ `✓`
/// - delivered（对方已送达）→ `✓✓`
/// - read（对方已读）→ `✓✓` 并标蓝（[_blue]，TUI 独有——App 只到双勾）
/// 均按 1~2 列宽字符选取（避免 emoji 双宽导致气泡对不齐）。
String _statusGlyph(String status) => switch (status) {
      'pending' => '⋯',
      'sent' => '✓',
      'delivered' => '✓✓',
      'read' => '✓✓',
      _ => '',
    };

/// 语音/音频消息时长（秒）：取自载荷 meta（[kMetaAudioDurationSeconds]，App 录音/
/// 发音频文件时写入）。取不到返回 0——产品未上线，不兼容老版"明文塞时长"写法
/// （与 App 的 _audioDurationSeconds 一致）。
int _audioSeconds(ChatMessage m) {
  final raw = m.meta?[kMetaAudioDurationSeconds];
  if (raw is int) return raw;
  if (raw is num) return raw.round();
  return 0;
}

/// 附件消息类型集合（/open 判定与固定序号计数共用）。
const Set<String> _kAttachmentTypes = {'image', 'video', 'voice', 'audio', 'file'};

/// 附件消息的固定序号表（messageId → 序号，1 起）：按消息流时间序从前往后数。
/// 新附件只追加新序号、已有序号不变（时间序由 server_sequence 单调保证），重启后
/// 按历史顺序重新算出同一序号——供 `/open <序号>` 稳定指定（老板 2026-09-13：
/// 此前从最新倒数，每收一条新附件旧序号就变）。
Map<String, int> _attachmentNos(ChatSession? session) {
  final map = <String, int>{};
  if (session == null) return map;
  var n = 0;
  for (final m in session.messages) {
    if (m.isSystem || !_kAttachmentTypes.contains(m.env.type)) continue;
    map[m.env.messageId] = ++n;
  }
  return map;
}

/// 格式化消息为多行（自动按列宽折行）。
/// 自己的消息：性别气泡，整块从左侧 8 列留白起铺满屏缘（长短消息左缘统一对齐）——
/// 长消息正文在左；单行短消息正文右对齐、贴着末尾 [状态 时间] 标签（标签贴最右，
/// 不带名字）。背景按我的性别配色；对方消息：性别气泡，整块左对齐（左侧气泡风格，
/// [时间] 黑字标签嵌在气泡左缘、正文在右），背景按对方性别配色；系统提示（isSystem）：
/// 灰色前缀 + 普通正文（左对齐）。
/// 相邻消息之间以空行隔开（老板 2026-09-10 定版：`─` 线视觉干扰，改空行），
/// 区分同一人相邻消息的边界；空行由渲染层在每条消息（含末条）后插入——
/// 末条后的空行给底部 [我] 输入区留出呼吸空间；系统提示消息同样参与分隔。
/// [attachmentNos]：附件消息固定序号表（渲染层每帧预计算，避免逐条全量扫描）；
/// 省略时按当前会话现算（纯函数测试用）。
List<String> formatMessage(ChatMessage m, int cols, {Map<String, int>? attachmentNos}) {
  final time = _timeLabel(m.createdAt);
  // 系统消息保留显式换行（支持一条消息内多行——老板 2026-09-11：把一段提示
  // 分成多行显示，又能被消息间的空行整体隔开）；双方消息正文按空格折叠换行。
  // 语音消息特殊渲染：喇叭 + 「语音」+ 秒数（App 录音的明文 caption 只是「语音」，
  // 时长在载荷 meta 里）——老板 2026-09-13 要求 TUI 也能一眼看出时长。
  final String body;
  if (!m.isSystem && m.env.type == 'voice') {
    final seconds = _audioSeconds(m);
    body = '🔊 语音${seconds > 0 ? ' ${seconds}s' : ''}';
  } else {
    body = m.isSystem ? m.plain : m.plain.replaceAll('\n', ' ');
  }
  // 附件消息前缀固定序号 #N（与 /open N 对应，方便指定）——序号按时间序，
  // 新附件只追加新号、旧的序号不变（老板 2026-09-13）。[attachmentNos] 由渲染层
  // 每帧预计算一次（避免每条消息都全量扫描）；未传时按当前会话现算（测试用）。
  final String displayBody;
  final attNo = m.isSystem
      ? null
      : (attachmentNos ?? _attachmentNos(_state?.session))[m.env.messageId];
  displayBody = attNo == null ? body : '#$attNo $body';
  // 双方消息的外侧留白（同为 8 列）：对方正文右侧 / 我方气泡左侧；
  // 保证对方正文起点不比我方正文（前缀之后）更靠左
  const sideMargin = 8;
  if (m.isSystem) {
    // 系统提示：灰色前缀 + 普通正文，左对齐（信息流提示，不参与左右分栏）。
    // 正文右侧预留 sideMargin 列边距，不顶满最右（与两侧气泡的视觉留白平衡）；
    // 续行缩进 prefix 宽度，与第一行正文左缘对齐。正文保留显式 \n：每条物理行
    // 单独换行渲染（前缀只出现在第一条物理行，其余缩进对齐），空物理行保留为
    // 空白行——这样一条消息可显示成多行，又被消息间空行整体隔开
    final prefix = '$_gray[$time 秘境]$_reset ';
    final prefixW = _displayWidth(prefix);
    final indent = ' ' * prefixW;
    final out = <String>[];
    final segments = displayBody.split('\n');
    for (var si = 0; si < segments.length; si++) {
      final wrapped = _wrapByWidth(segments[si], cols - prefixW - sideMargin);
      if (si == 0) {
        out.add('$prefix${wrapped.first}');
        out.addAll(wrapped.skip(1).map((line) => '$indent$line'));
      } else if (wrapped.isEmpty) {
        out.add(indent); // 用户显式空行（连续 \n\n）：保留为空白行
      } else {
        out.add('$indent${wrapped.first}');
        out.addAll(wrapped.skip(1).map((line) => '$indent$line'));
      }
    }
    return out;
  }
  if (!m.isMine) {
    // 对方消息：左侧性别气泡——背景按对方性别配色（男蓝/女品红/未知青绿；
    // 两人同性别时第二个人取亮青——2026-09-17 老板要求），
    // [时间] 黑字标签嵌在气泡左缘（首行，长消息标签跟首行文字走）、正文白字；
    // 气泡矩形 col 1 → cols - rightPad，与右侧我方气泡（col 9 → cols）左右对称
    final bubbleBackground = _sameGenderSecondCyan(m.env.senderPartnerId) ??
        _genderBubble(_state?.partnerGenders[m.env.senderPartnerId]);
    final label = '[$time]';
    final labelW = _displayWidth(label);
    final lane = labelW + 1; // 气泡内左侧标签栏宽（含标签后一个空格）
    final rightPad = sideMargin; // 右侧留白 = 我方气泡左侧留白（8 列）
    final textWidth = cols - lane - rightPad;
    final wrapped = _wrapByWidth(displayBody, textWidth > 0 ? textWidth : cols - lane - 1);
    final lines = <String>[];
    for (var i = 0; i < wrapped.length; i++) {
      final chunk = wrapped[i];
      if (i == 0) {
        // 首行（含单行消息）：标签（黑字）嵌在气泡左缘，正文白字 + 背景色填充到
        // 右留白前——整行背景矩形与其他行完全对齐
        final fill = textWidth - _displayWidth(chunk);
        lines.add(
            '$bubbleBackground$_black$label$_white $chunk${' ' * (fill < 0 ? 0 : fill)}$_reset');
      } else {
        // 其余行（含末行）：气泡内左侧标签栏留空（背景色空格），正文右端补齐到右留白前
        final fill = textWidth - _displayWidth(chunk);
        lines.add(
            '$bubbleBackground$_white${' ' * lane}$chunk${' ' * (fill < 0 ? 0 : fill)}$_reset');
      }
    }
    return lines;
  }
  // 我的消息：气泡整块从左侧 sideMargin 列留白起铺满到屏缘（右侧区域气泡风格——
  // 长短消息左缘统一对齐；长消息正文在左，单行短消息正文右对齐贴着 [我 时间] 标签、
  // 标签贴最右），背景按我的性别配色——男蓝、女品红、性别未知（旧空间未登记/尚未拉取）
  // 青绿底；两人同性别时第二个人（我）取亮青（2026-09-17 老板要求）；前导留白不上色。
  // 兼容服务端两种取值：App 提交规范 male/female，旧 TUI 提交过中文 男/女。
  final rawGender = _state?.partnerGenders[m.env.senderPartnerId];
  final String peerBackground = _sameGenderSecondCyan(m.env.senderPartnerId) ??
      (rawGender == 'male' || rawGender == '男'
          ? _bgBlue
          : rawGender == 'female' || rawGender == '女'
              ? _bgPink
              : _bgTeal); // 性别未知：青绿底（2026-09-10 老板要求）
  // 我的消息标签：[状态 时间]（老板 2026-09-13：去掉名字、状态提到时间前面），
  // 已读（read）时状态字符标蓝——TUI 独有（App 已读只留数据档位不展示）。
  final status = _state?.session.sentStatusOf(m) ?? '';
  final statusGlyph = _statusGlyph(status);
  final statusColor = status == 'read' ? _blue : _black;
  final suffix = statusGlyph.isEmpty
      ? '$_black[$time]$_reset'
      : '$_black[$statusColor$statusGlyph$_black $time]$_reset';
  final suffixW = _displayWidth(suffix);
  // 正文每行同时保留：左侧 sideMargin 列留白（不顶左边框）+ 右侧标签栏；
  // 标签栏宽 = "空格+标签"（标签宽+1），使续行正文右缘与末行标签起点对齐
  // （末行正文与标签之间有一个空格，若只空标签宽则续行会多伸 1 列）
  final lane = suffixW + 1; // 右侧标签栏宽（含标签前一个空格）
  final leftPad = sideMargin; // 左侧留白 = 对方正文右侧留白（8 列）
  final textWidth = cols - lane - leftPad;
  // ⚠️ 用 displayBody（带附件固定序号 #N），不能用 body——否则我发的附件不显示 #N，
  // /open <序号> 就没法指定自己发的附件（老板 2026-09-15 反馈；对方分支一直是对的）。
  final wrapped = _wrapByWidth(displayBody, textWidth > 0 ? textWidth : cols - lane - 1);
  final lines = <String>[];
  for (var i = 0; i < wrapped.length; i++) {
    if (i == wrapped.length - 1 && wrapped.length > 1) {
      // 长消息末行：正文左对齐到与其他行相同的左缘（左侧留白 = leftPad），
      // 正文与标签之间用背景色空格填充、标签贴最右——整行背景色连续成矩形
      final chunk = wrapped[i];
      final fill = textWidth - _displayWidth(chunk);
      lines.add(
          '${' ' * leftPad}$peerBackground$_white$chunk${' ' * (fill < 0 ? 0 : fill)} $suffix');
    } else if (i == wrapped.length - 1) {
      // 单行短消息：气泡整块从左缘 leftPad 起铺满到屏缘（左缘与长消息统一对齐、
      // 消除锯齿），但正文右对齐、贴着 [我 时间] 标签（标签仍贴最右）——
      // 背景色空格填充在正文左侧，整行背景矩形与长消息各行对齐
      final chunk = wrapped[i];
      final fill = textWidth - _displayWidth(chunk);
      lines.add(
          '${' ' * leftPad}$peerBackground$_white${' ' * (fill < 0 ? 0 : fill)}$chunk $suffix');
    } else {
      // 非末行：固定左侧留白，正文 + 背景色填充到整行右缘（col cols）——
      // 标签栏所在的右侧留白一并上色，避免中英文折行宽度差造成气泡右缘锯齿
      final fill = (cols - leftPad) - _displayWidth(wrapped[i]);
      final content =
          '$peerBackground$_white${wrapped[i]}${' ' * (fill < 0 ? 0 : fill)}$_reset';
      lines.add('${' ' * leftPad}$content');
    }
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
  final prompt = '${_cyan}[我]${_reset} ';
  final promptW = _displayWidth(prompt);
  final top = rows - inputWrapped.length; // 输入区顶部行号（状态行占最底一行）

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

/// busy（上一条命令/消息还在处理）时回车被拦下的状态栏提示：只提示，输入行原样保留
/// （老板 2026-09-14）。操作结束后由 whenComplete 自动清掉。
const _kBusyResendHint = '⏳ 上一条还在处理中，稍后回车再发';

Future<void> _runInputLoop(ChatSession session) async {
  _enterRaw();
  // 启用终端鼠标事件（滚轮翻页用）：1000 = 按钮事件（按下/释放），1006 = SGR
  // 数字编码（坐标/按钮为纯 ASCII，与下方 CSI 累积解析器兼容）。终端不支持时
  // 静默忽略，不影响键盘操作。
  try {
    stdout.write('\x1B[?1000h\x1B[?1006h');
    stdout.flush().ignore();
  } catch (_) {}
  final completer = Completer<void>();
  var busy = false;
  late final StreamSubscription<String> sub;
  // 终端转义序列缓冲：raw 模式下方向键等到达为 ESC [ A 等多个字节（可能跨 chunk），
  // 需在此拼合完整后再解释，避免 '[' 与字母被当成普通字符打进输入（曾显示 [D[C[A[B）。
  var esc = '';
  // utf8.decoder：raw 模式下多字节字符（如中文）可能被拆成多个字节到达，
  // 由解码器缓冲拼合后再逐字符处理（避免中文乱码）。
  sub = stdin.transform(utf8.decoder).listen((chunk) {
    try {
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
          } else if (seq.length >= 32) {
            esc = ''; // 兜底：异常长参数序列丢弃（上限放宽以容纳 SGR 鼠标序列）
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
          case 'pgup':
            _scrollMessages(s, -s.lastMsgArea > 0 ? -s.lastMsgArea : -1);
          case 'pgdn':
            _scrollMessages(s, s.lastMsgArea > 0 ? s.lastMsgArea : 1);
          case 'wheelup':
            _scrollMessages(s, -3); // 滚轮上滚：向上翻 3 行
          case 'wheeldown':
            _scrollMessages(s, 3); // 滚轮下滚：向下翻 3 行
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
            // / 开头的输入按命令处理，不当作口令/开通码回答提交（用户：要求
            // 输入口令时 /exit 被当口令发送核对进"口令对接中"——应直接退出）
            _state!.input.clear();
            _state!.cursor = 0; // 同步复位光标：否则下个字符 _insertAtCursor 越界崩溃
            if (answer == '/exit' || answer == '/quit') {
              // 引导问答中的退出命令：逃生门——否则任何输入都被吞为回答，
              // 用户困在开通码/口令重试循环无法退出
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
            session.messages.add(_systemMessage(session, '⚠️ 引导中仅支持 /exit 退出（输入未提交）'));
            _scheduleRender();
            inputChanged = true;
            continue;
          }
          if (answer.isEmpty && (_state?.pendingGuideRequired ?? false)) {
            // 必填问答（口令）留空回车：不提交——提示继续输入（不弹"请重新输入"，
            // 输入行保留直接继续敲）
            _state!.input.clear();
            _state!.cursor = 0; // 同步复位光标，避免越界崩溃
            session.messages.add(_systemMessage(session, '⚠️ 请输入内容'));
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
        // busy（上一条命令/消息还在处理）：**不清输入、不提交**——此前先 input.clear()
        // 再判 busy，把敲好的字静默丢了（老板 2026-09-14 确认顺手修）。这里只提示一句，
        // 输入原样留在输入行，稍后回车即可发。
        if (busy) {
          _state!.status = _kBusyResendHint;
          _scheduleRender();
          continue;
        }
        final line = _state!.input.toString().trim();
        _state!.input.clear();
        _state!.cursor = 0;
        // 输入历史（↑↓ 浏览复用）：口令/开通码等机密输入不进历史
        if (!_state!.hiddenInput &&
            !_state!.pendingJoinToken &&
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
        busy = true;
        final future = (_state!.pendingJoinToken)
            ? (line.startsWith('/') ? _execCommand(line) : _handleJoinTokenInput(line)) // / 开头按命令（/exit 退出），否则按邀请链接
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
            // busy 期间的「稍后再发」提示退场（若还挂着——后续 handler 自己写的状态不动）
            if (_state!.status == _kBusyResendHint) _state!.status = '';
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
    } catch (e, st) {
      // 输入处理出现未捕获异常：恢复终端（echo）后退出，避免残留 raw 模式不回显
      _inputLoopCrash(e, st);
    }
  }, onDone: () {
    if (!completer.isCompleted) {
      _state!.running = false;
      completer.complete();
    }
  });
  await completer.future;
}

/// 输入处理出现未捕获异常时的兜底：先恢复终端（echo/raw），
/// 避免进程退出后终端残留 raw 模式导致后续输入不回显，再报错退出。
void _inputLoopCrash(Object e, StackTrace st) {
  try {
    _restoreTerminal();
  } catch (_) {}
  stderr.writeln('⚠️ 输入处理异常: $e');
  exit(1);
}

/// 解释终端转义序列 → 动作（方向键 / Home / End / Delete / PgUp / PgDn / 滚轮）；
/// 未知序列返回 null（整体丢弃）。
String? _escAction(String seq) {
  // SGR 鼠标滚轮事件（配合 \x1B[?1000h\x1B[?1006h 启用）：ESC [ < b ; x ; y M/m。
  // b = 64 上滚、65 下滚（可叠加修饰键位：+4 Shift、+8 Alt、+16 Ctrl）；
  // 只处理按下事件（M 结尾），释放事件（m）忽略，避免一次滚轮翻两倍。
  final wheelRe = RegExp(r'^\x1B\[<(\d+);\d+;\d+M$');
  final wheel = wheelRe.firstMatch(seq);
  if (wheel != null) {
    final b = int.parse(wheel.group(1)!);
    final base = b & ~0x1C; // 去掉 Shift/Alt/Ctrl 修饰位
    if (base == 64) return 'wheelup';
    if (base == 65) return 'wheeldown';
    return null; // 其他鼠标事件（点击/移动）：忽略
  }
  return switch (seq) {
    '\x1B[A' || '\x1BOA' => 'up',
    '\x1B[B' || '\x1BOB' => 'down',
    '\x1B[C' || '\x1BOC' => 'right',
    '\x1B[D' || '\x1BOD' => 'left',
    '\x1B[H' => 'home',
    '\x1B[F' => 'end',
    '\x1B[3~' => 'delete',
    '\x1B[5~' => 'pgup',
    '\x1B[6~' => 'pgdn',
    _ => null,
  };
}

/// 消息区翻页：delta 为正 = 向下翻（向最新），为负 = 向上翻（向更旧）。
/// 直接调整 scrollTop（渲染时按 lastMaxStart 钳制并做贴底跟随）；翻到底
/// （scrollTop 达到 lastMaxStart）即恢复贴底，此后新消息自动跟随。
void _scrollMessages(_TuiState s, int delta) {
  final maxStart = s.lastMaxStart < 0 ? 0 : s.lastMaxStart;
  final target = s.scrollTop + delta;
  s.scrollTop = target < 0 ? 0 : (target > maxStart ? maxStart : target);
  _render(); // 翻页立即重绘（_render 内部 try-catch 兜底）
}

/// 在光标处插入字符（光标右移；StringBuffer 无 insert，重建字符串）。
void _insertAtCursor(_TuiState s, String ch) {
  final str = s.input.toString();
  // 防御：光标与输入长度应一致（曾有引导分支清空输入未复位光标 → 越界崩溃）
  if (s.cursor > str.length) s.cursor = str.length;
  if (s.cursor < 0) s.cursor = 0;
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

/// 后台上传附件（老板 2026-09-14）：**不 await**——回车后立即把光标交还输入行，
/// 不等上传往返。上传耗时与文件大小/网速成正比，占住输入循环（busy）会让回车后
/// 直到传完都打不了字（老板反馈：光标像卡在状态条上）。
/// 乐观气泡（pending ⋯）由 [ChatSession.attachFile] 在网络之前就上屏，成功后原地
/// 变 ✓；失败时它自行撤下气泡，这里补一条 ❌ 提示。
Future<void> _uploadAttachmentInBackground(ChatSession session, String path) async {
  try {
    await session.attachFile(path);
  } catch (e) {
    session.messages.add(
        _systemMessage(session, '❌ 附件上传失败，可能有路径或文件类型出错，请检查再试。'));
  } finally {
    _scheduleRender();
  }
}

/// `/reset`：重置本通道——三道闸门过后清本地数据并退出（下次启动走全新入网向导）。
///
/// 闸门刻意**全离线**：通道名比对 + 本机锁屏码，不联网、不问空间口令。理由见
/// `server/src/entrances.ts` 的 `retireEntrance`：空间口令是**共享**给伴侣的加入凭证，
/// 不该获得销毁我这条通道的权力；而校验它必须联网，会让"连着一台死服务器"这个
/// 最常见的重置场景直接自锁。
///
/// 服务端退役（POST /entrances/retire）在确认之后、清数据之前尽力而为：失败了也照清，
/// 只是明确告诉用户"服务端可能还留着这条通道的记录"。顺序不能反——token 就在
/// store 里，清完就再也没有调用它的凭证了。
Future<void> _execReset(String storePath) async {
  final s = _state!;
  final session = s.session;

  // ① 通道名：确认清的是哪一条。没有名字（不降级成 entranceId——让用户抄一串 id 只会
  //    制造新的抄错机会）时退化为固定确认词 RESET：本地缺字段不该让人永远重置不了，
  //    与 app 端同一口径（reset_entrance.dart 的 fallback）。
  const fallbackWord = 'RESET';
  final entranceName = session.store.entranceName?.trim() ?? '';
  final expected = entranceName.isEmpty ? fallbackWord : entranceName;
  final prompt = entranceName.isEmpty
      ? '❓ 本通道还没有名字，请输入 $fallbackWord 以确认重置（留空取消）:'
      : '❓ 确认要重置的是本通道「$entranceName」，请输入通道名（留空取消）:';
  final typed = await _promptAction(session, prompt);
  if (!s.running) return;
  if (typed == null) {
    session.messages.add(_systemMessage(session, '✅ 已取消（未做任何改动）'));
    return;
  }
  if (typed != expected) {
    session.messages.add(_systemMessage(session, '✅ 已取消（输入不符，未做任何改动）'));
    return;
  }

  // ② 本机锁屏码（已设才验：Argon2id，走 /pin 那套；成功会清零尝试计数）
  final pinHash = session.store.pinHash;
  if (pinHash != null) {
    final pin = await _promptAction(session, '❓ 输入本机锁屏码（重置需验证；留空取消）:',
        hidden: true);
    if (!s.running) return;
    if (pin == null) {
      session.messages.add(_systemMessage(session, '✅ 已取消（未做任何改动）'));
      return;
    }
    if (!await _verifyPin(pinHash, pin)) {
      session.messages.add(_systemMessage(session, '⚠️ 锁屏码错误——已取消（未做任何改动）'));
      return;
    }
  }

  // ③ 服务端退役：尽力而为。失败不拦清算，只把"可能有残留"如实告知
  var retired = true;
  final server = session.server;
  final token = session.store.sessionToken;
  if (server.isEmpty || token == null) {
    retired = false;
    session.messages.add(_systemMessage(session, '⚠️ 未连接服务端，跳过退役（对方通道列表里可能仍留有本机记录）'));
  } else {
    try {
      await _busy(session, '⏳ 正在从服务端退役本通道......',
          () => ApiClient(server).retireEntrance(token));
    } on ApiException catch (e) {
      retired = false;
      session.messages.add(_systemMessage(session, '⚠️ 服务端退役失败（${e.message}）——本地照常清除'));
    } catch (e) {
      retired = false;
      session.messages.add(_systemMessage(session, '⚠️ 服务端退役失败（$e）——本地照常清除'));
    }
  }
  if (!s.running) return;

  if (retired) {
    session.messages.add(_systemMessage(session, '✅ 已从服务端退役本通道'));
  }
  _scheduleRender();
  _exitReset(storePath);
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
        '您可输入以下系统命令：',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/attach <文件路径> :: 上传文件',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/auth :: 激活/续期当前服务器的机密线路（换服务器用 /server）',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/status :: 查看服务器/连接/绑定/通道状态（排障用，只读）',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/entrance <通道名> :: 修改当前通道名称',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/entrances :: 查看秘境里的通道列表（同空间全部通道）',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/revoke <通道序号> :: 强制撤销某条通道（需共享口令；被撤通道将清空本地数据）',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/reset :: 重置本通道（输入通道名 + 本机锁屏码确认，清空本地数据后退出）',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/exit :: 立刻退出',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/history',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/invite :: 生成一次性开通码，24小时有效，邀请伴侣或自己开通一条新通道到本秘境。',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/passphrase <random> :: 修改共享口令；random 生成随机 12 词恢复码',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/backup <路径> :: 导出加密备份（Space Key+历史+归档密钥；恢复码打印一次，请离线保存）',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/pin <PIN> :: 查看状态、设置或清空锁屏码',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/myname <名字> :: 修改我的名字',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/server <地址> :: 查看当前服务端；带地址参数：切换服务端（仅本次生效）',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/space :: 查看当前连接的秘境',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/sync :: 同步最新消息流',
      ));
      s.session.messages.add(_systemMessage(
        s.session,
        '/open <附件序号> :: 打开 #序号 的附件消息',
      ));
      s.status = '';
    case '/server':
      // 无参数：先输出当前服务器（状态），再给出详细用法
      if (arg.isEmpty) {
        s.session.messages.add(_systemMessage(s.session, '✅ 当前服务器: ${s.session.server}\n\n'
            '🔧 用法: /server <地址> —— 切换本次会话的服务器并激活，仅本次生效，不长期保留。'));
        s.status = '';
      } else {
        try {
          await s.session.auth(serverOverride: arg);
          s.session.server = arg; // 仅本次生效：地址不落盘（与 --server 同语义）
          if (s.session.wsClient == null && s.session.hasSession) {
            s.session.startWs(onMessage: (_) => _refreshGenderForLatest(_state!), onStatus: (_) => _render(), onAutoSync: (_) => _refreshGenderForLatest(_state!),
              onRevoked: _onWsRevoked, onUnrecognized: _onWsUnrecognized);
          }
          // 名称表来自服务端：换了服务器就得重拉（否则气泡前缀还是上一台的名字）
          _refreshPartnerNames(s);
          s.session.messages.add(_systemMessage(
              s.session, '✅ 已切换本次会话的服务器并激活（仅本次生效）: $arg'));
          s.status = ''; // 一次性结果进消息流，清掉旧瞬时通知
        } catch (e) {
          s.session.messages.add(_systemMessage(s.session, '⚠️ 切换服务器失败: $e'));
          s.status = '';
        }
      }
    case '/auth':
      // 未绑定（entranceId null，如引导时跳过/加入失败）→ 引导加入秘境后再认证
      if (s.session.store.entranceId == null) {
        // 提示作为 system 消息进消息流；邀请链接由输入循环接管输入——
        // TUI 运行期 stdin 已被输入循环订阅，不能再用 readLineSync（会挂起）
        s.pendingJoinToken = true;
        s.session.messages.add(_systemMessage(
            s.session,
            '❓ 本通道尚未绑定秘境\n'
            '   输入开通码（或邀请链接）加入伴侣的秘境；\n'
            '   新建秘境请先 /space create'));
        s.status = '⌛️ 等待开通码输入…';
        break;
      }
      // 已经带了地址 = 想换服务器——那不是 /auth 的活（换服务器用 /server）
      if (arg.isNotEmpty) {
        s.session.messages.add(_systemMessage(
            s.session,
            'ℹ️ /auth 是对**当前**服务器激活/续期（不带参数）。\n'
            '   换服务器请用: /server $arg'));
        s.status = '';
        break;
      }
      // 无参数：对当前服务器执行 challenge-response 激活/续期。
      // （此前这里只打印状态与用法就 break，而 4 处提示都让用户"先 /auth 重新激活"——
      //  照着敲什么也没发生，是个既有缺口。）
      // 激活前先输出当前状态，让用户知道这次是"首次激活"还是"续期"。
      final hadSession = s.session.store.sessionToken != null;
      s.session.messages.add(_systemMessage(
          s.session,
          '📡 /auth 当前状态：\n   服务器 ${s.session.server}\n   '
          '${hadSession ? "已有会话：本次为续期" : "未激活：本次为首次激活"}'));
      try {
        await s.session.auth();
        // 激活结果作为 system 消息进消息流（不占顶部状态栏）
        s.session.messages.add(_systemMessage(s.session, '✅ 成功激活机密线路。'));
        s.status = '';
        _refreshPartnerNames(s); // 刷新 partner 名称表（对方消息前缀显示其 partnerName）
        // 激活成功后启动 WS 实时监听
        if (s.session.wsClient == null && s.session.hasSession) {
          s.session.startWs(
            onMessage: (_) => _refreshGenderForLatest(_state!),
            onStatus: (_) => _render(),
            onAutoSync: (_) => _refreshGenderForLatest(_state!),
            onRevoked: _onWsRevoked,
            onUnrecognized: _onWsUnrecognized,
          );
        }
      } catch (e) {
        s.session.messages.add(_systemMessage(s.session, '⚠️ 机密线路激活失败，请稍后再试 /auth'));
        s.status = '';
      }
    case '/status':
      // 排障快照：**只读**，不发起任何网络请求——状态取自已有轮询（WS/对方在线）
      // 与本地 store。用来回答"我到底连的是哪台服务器、激活了没、对方在不在"。
      final st = s.session.store;
      // 地址来源：等于本机默认（localConfig.json/硬编码）= 出厂配置；否则是本次覆盖
      // （--server 启动参数或 /server 命令），只本次生效。
      final origin = s.session.server == await _defaultServer()
          ? '本机默认'
          : '本次覆盖 --server 或 /server';
      final ws = switch (s.session.wsStatus) {
        WsStatus.connected => '已连接',
        WsStatus.connecting => '连接中',
        WsStatus.reconnecting => '断线重连中',
        WsStatus.stopped => '未连接',
      };
      final slot = st.slot == null ? '未定' : '#${st.slot}';
      s.session.messages.add(_systemMessage(
          s.session,
          '📊 状态\n'
              '   服务器: ${s.session.server}（$origin）\n'
              '   机密线路: ${st.sessionToken != null ? '已激活' : '未激活'}\n'
              '   实时连接 ws: $ws\n'
              '   对方: ${s.peerOnline ? '在线' : '离线'}\n'
              '   秘境 id: ${st.spaceId ?? '未绑定'}\n'
              '   秘境密钥: ${st.spaceKey != null ? '已就位' : '无'}\n'
              '   通道名称: ${st.entranceName ?? '未命名'}\n'
              '   通道 id: ${st.entranceId ?? '未登记'}\n'
              '   通道编号: $slot\n'
              '   通道公钥: ${st.publicKey}\n'
              '   消息同步: seq ${st.lastServerSequence}｜本地历史 ${st.history.length} 条\n'
              '   数据文件: ${s.storePath}'));
      s.status = '';
      break;
    case '/space':
      // Multiverse：空间绑定命令——一通道一空间。
      // /space（无参）显示状态与用法；/space address 显示空间地址；
      // /space create 新建空间（生成 Space Key + 口令密封包，打印邀请链接）；
      // /space join <邀请链接或 token> 加入已有空间（preflight → join → 口令取钥）
      if (arg.trim().isEmpty) {
        final addr = s.session.store.spaceAddress;
        if (s.session.hasSpace) {
          s.session.messages.add(_systemMessage(s.session,
              '✅ 当前通道已绑定到秘境${addr != null ? '（地址: $addr）' : ''}'));
          s.session.messages.add(_systemMessage(
              s.session, '🔧 用法: /space address | /space create | /space join <邀请链接或 token>'));
        } else {
          s.session.messages.add(_systemMessage(s.session, '⚠️ 当前通道尚未绑定秘境'));
          s.session.messages.add(_systemMessage(
              s.session, '🔧 用法: /space create 新建私密空间；/space join <邀请链接或 token> 加入已有空间'));
        }
        break;
      }
      {
        final parts = arg.trim().split(RegExp(r'\s+'));
        final sub = parts.first;
        if (sub == 'address') {
          final addr = s.session.store.spaceAddress;
          if (addr == null || addr.isEmpty) {
            s.session.messages.add(
                _systemMessage(s.session, '⚠️ 尚未绑定秘境（无秘境地址）——/space create 或 /space join 后可见'));
          } else {
            s.session.messages.add(_systemMessage(s.session, '📍 秘境地址: $addr'));
          }
          break;
        }
        if (sub == 'create') {
          await _spaceCreate(s.session, s.session.store, s.storePath);
          break;
        }
        if (sub == 'join') {
          final rest = arg.trim().substring('join'.length).trim();
          if (rest.isEmpty) {
            s.session.messages.add(_systemMessage(s.session, '🔧 用法: /space join <邀请链接或 token>'));
            break;
          }
          await _spaceJoin(s.session, s.session.store, s.storePath, rest);
          break;
        }
        s.session.messages.add(
            _systemMessage(s.session, '未知子命令: $sub —— 🔧 用法: /space [address|create|join <链接>]'));
      }
      break;
    case '/passphrase':
      // /passphrase random：生成随机 12 词助记词恢复码（离线保存，Server 不接触）
      if (arg.trim() == 'random') {
        final code = await generateRecoveryCode();
        s.session.messages.add(_systemMessage(
            s.session, '🎲 随机恢复码（12 词助记词，请离线妥善保存，Server 不接触）：\n$code'));
        break;
      }
      // 修改共享口令（escrow 托管，空间级）：旧口令验证 → 新口令重加密上传
      if (s.session.store.spaceKey == null || s.session.store.sessionToken == null) {
        s.session.messages.add(_systemMessage(s.session, '⚠️ 请先 /auth 激活线路、/space 接入领地后再修改口令'));
        break;
      }
      await _changeEscrowPassphrase(s.session.store, s.session);
      break;
    case '/pin':
      // 锁屏码：/pin 显示状态、/pin <PIN> 设置、/pin '' 重置为空
      if (arg.isEmpty) {
        s.session.messages.add(_systemMessage(s.session,
            s.session.store.pinHash == null ? '⚠️ 锁屏码：未设置' : '✅ 锁屏码：已设置'));
        // 先输出状态，再给出详细用法
        s.session.messages.add(_systemMessage(s.session,
            '🔧 用法: /pin <PIN> —— 设置锁屏码（$_kPinMinLength 位数字，如 /pin 123456）；/pin \'\' 重置为空（取消锁屏码）'));
      } else if (arg == "''") {
        s.session.store.pinHash = null;
        s.session.store.save(s.storePath);
        s.session.messages.add(_systemMessage(s.session, '⚠️ 锁屏码已重置为空（未设置）'));
      } else {
        final err = _pinError(arg);
        if (err != null) {
          s.session.messages.add(_systemMessage(s.session, '⚠️ $err（/pin \'\' 可取消锁屏码）'));
          break;
        }
        s.session.store.pinHash = await _hashPin(arg);
        s.session.store.save(s.storePath);
        s.session.messages.add(_systemMessage(s.session, '✅ 锁屏码已设置'));
      }
      break;
    case '/entrances':
      // 同空间**全部**通道（我 + 对方，不只自己的）——序号与 /revoke 的选择一致
      try {
        final rows = await _fetchEntranceRows(s);
        final sb = StringBuffer('📱 通道列表（同空间 ${rows.length} 条，/revoke <序号> 可撤销）：');
        for (final r in rows) {
          sb.write(r.line);
        }
        s.session.messages.add(_systemMessage(s.session, sb.toString()));
      } catch (e) {
        s.session.messages.add(_systemMessage(s.session, '❌ 获取通道列表失败: $e'));
      }
      break;
    case '/revoke':
      // 撤销同空间某条通道（PROTOCOL.md §7.2，老板 2026-09-16）：
      // **同 space 内可互撤**（自己的另一条 / 伴侣的通道），但每次都要校验共享口令——
      // 撤销会让对方客户端**清空本地数据**（含历史消息与附件），不可逆，故三重确认：
      // 选通道（序号/通道名）→ 输入 yes 确认目标 → 输入口令。任一步取消都不做任何改动。
      // **任一步留空回车即取消**（老板 2026-09-23：此前 required 拦空回车，用户被困，
      // 只剩"输乱码报无效"和 /exit 两条别扭的路）。
      try {
        final server = s.session.server;
        final token = s.session.store.sessionToken;
        if (server.isEmpty || token == null) {
          s.session.messages.add(_systemMessage(s.session, '⚠️ 未连接（缺少 server/token）'));
          break;
        }
        final rows = await _fetchEntranceRows(s);
        if (!s.running) break;
        _EntranceRow? picked;
        if (arg.isNotEmpty) {
          final matches = _matchEntranceRows(rows, arg);
          if (matches.isEmpty) {
            s.session.messages.add(_systemMessage(
                s.session, '⚠️ 没有匹配的通道「$arg」——用 /entrances 查看序号或通道名'));
            break;
          }
          if (matches.length > 1) {
            s.session.messages.add(_systemMessage(
                s.session, '⚠️ 有 ${matches.length} 条通道同名「$arg」——请用 /revoke <序号> 指定'));
            break;
          }
          picked = matches.first;
        } else {
          final sb = StringBuffer('📱 选择要撤销的通道（同空间 ${rows.length} 条）：');
          for (final r in rows) {
            sb.write(r.line);
          }
          s.session.messages.add(_systemMessage(s.session, sb.toString()));
          final answer =
              await _promptAction(s.session, '❓ 输入要撤销的通道序号（留空取消）:');
          if (!s.running) break;
          if (answer == null) {
            s.session.messages.add(_systemMessage(s.session, '✅ 已取消（未做任何改动）'));
            break;
          }
          final matches = _matchEntranceRows(rows, answer);
          if (matches.length != 1) {
            s.session.messages.add(_systemMessage(
                s.session,
                matches.isEmpty
                    ? '⚠️ 序号/通道名无效——已取消（未做任何改动）'
                    : '⚠️ 同名多台无法确定——已取消，请用序号重新指定'));
            break;
          }
          picked = matches.first;
        }
        final target = picked;
        if (target.isMe) {
          s.session.messages.add(_systemMessage(
              s.session, '⚠️ 不能撤销本机——请在同空间的另一条通道上撤销它（未做任何改动）'));
          break;
        }
        if (target.revoked) {
          s.session.messages.add(
              _systemMessage(s.session, '⚠️ #${target.no} ${target.label} 已经是「已撤销」状态（未做任何改动）'));
          break;
        }
        // 二次确认：必须让用户看清"撤的是哪一台"——选错序号就是不可逆的数据销毁
        s.session.messages.add(_systemMessage(
            s.session,
            '⚠️ 即将撤销 #${target.no} ${target.label}（使用者：${target.partnerName}）——\n'
            '   该通道下次联网认证时会**清空本地数据**（含历史消息与附件），不可逆。'));
        final confirm = await _promptAction(s.session, '❓ 确认请输入 yes（留空或其它任意输入取消）:');
        if (!s.running) break;
        if (confirm == null || confirm.toLowerCase() != 'yes') {
          s.session.messages.add(_systemMessage(s.session, '✅ 已取消（未做任何改动）'));
          break;
        }
        // 口令（隐藏输入）：撤销的授权因子——即使本机已持会话，也必须由口令持有者授权
        final passphrase = await _promptAction(
            s.session, '❓ 输入共享口令（撤销需校验；留空取消）:',
            hidden: true);
        if (!s.running) break;
        if (passphrase == null) {
          s.session.messages.add(_systemMessage(s.session, '✅ 已取消（未做任何改动）'));
          break;
        }
        await _busy(s.session, '⏳ 正在撤销 ${target.label}......',
            () => ApiClient(server).revokeEntrance(target.entranceId, passphrase, token));
        s.session.messages.add(_systemMessage(
            s.session,
            '✅ 已撤销 #${target.no} ${target.label}——该通道下次联网认证时会清空本地数据；'
            '已在线则立即被服务端断开（/entrances 可复查）'));
        _refreshPeerOnline(); // 顶部条的在线数/通道列表立即去掉它
      } on ApiException catch (e) {
        s.session.messages.add(_systemMessage(s.session, _revokeErrorHint(e)));
      } catch (e) {
        s.session.messages.add(_systemMessage(s.session, '❌ 撤销失败: $e（未做任何改动）'));
      }
      break;
    case '/sync':
      try {
        final fresh = await s.session.sync();
        s.session.messages.add(_systemMessage(s.session, '✅ 消息已同步: 新增=${fresh.length}，队列剩余=${s.session.store.pendingCount}'));
      } catch (e) {
        s.session.messages.add(_systemMessage(s.session, '❌ 同步失败，请稍后再试一试'));
      }
    case '/history':
      s.session.messages.add(_systemMessage(s.session, '本地消息 ${s.session.messages.length} 条（上方滚动区）'));
    case '/reset':
      // 重置本通道（老板 2026-09-21）：清掉本地 store 与附件缓存，回到全新入网向导。
      // 不可逆，故三道闸门：**全部离线**，不依赖网络、不碰共享口令——
      //   ① 输入本机通道名（确认清的是这条，挡误触/顺手回车）
      //   ② 本机锁屏码（已设才验；锁屏码只属于本机持有者，不像空间口令那样是共享凭证）
      //   ③ 服务端退役尽力而为（失败只提示残留，不拦清算——离线也必须能重置）
      // 为什么不校验空间口令：那是共享给伴侣的加入凭证，不该有销毁我这条通道的权力；
      // 而且校验必须联网。详见 docs/SECURITY.md。
      await _execReset(s.storePath);
      break;
    case '/attach':
      if (arg.isEmpty) {
        s.session.messages.add(_systemMessage(s.session, '🔧 用法: /attach <文件路径> [描述]'));
      } else {
        // 附件消息在 attachFile 里乐观上屏（pending ⋯ → sent ✓，与普通消息同款，老板
        // 2026-09-14）；这里**不 await**——回车即交还输入（否则输入循环 busy 到上传结束，
        // 中途打不了字）；结果/失败只在消息区体现，状态栏不占（老板要求状态栏保持干净）。
        unawaited(_uploadAttachmentInBackground(s.session, arg));
      }
    case '/invite':
      // Multiverse：生成绑定新通道的邀请（join token——24h 一次性；v1 开通码
      // 已废弃——新通道用 /space join <链接或 token> 绑定）
      await _execInvite();
      break;
    case '/myname':
      // 重设个人显示名（partnerName）：本地 + 服务端同步 + 刷新名称表
      if (arg.isEmpty) {
        // 先输出当前名字（状态），再给出详细用法
        final current = s.session.store.partnerName ??
            s.partnerNames[s.session.store.partnerId] ??
            '(未设置)';
        s.session.messages.add(_systemMessage(s.session, '当前名字: $current'));
        s.session.messages.add(
            _systemMessage(s.session, '🔧 用法: /myname <名字> —— 修改我的显示名字（如 /myname Lukas）'));
      } else if (s.session.store.sessionToken == null) {
        s.session.messages.add(_systemMessage(s.session, '⚠️ 会话未激活，请先 /auth'));
        s.status = '';
      } else {
        // 字符白名单 + 长度上限（老板 2026-09-16）：不合规提示重输（服务端
        // POST /partners/name 同样 400 兜底）
        final violation = checkPartnerNamePolicy(arg);
        if (violation != null) {
          s.session.messages.add(_systemMessage(s.session, _partnerNameRuleHint(violation)));
          break;
        }
        final name = arg.trim();
        // 不允许改成与对方相同的名字（老板 2026-09-10）：服务端 partner 表里的对方
        // 名字 + 预置名快照（对方还没加入时 partner 表里没有他——老板 2026-09-16）
        final peerNames = <String>[
          for (final e in s.partnerNames.entries)
            if (e.key != s.session.store.partnerId) e.value,
          if ((s.session.store.peerName ?? '').isNotEmpty) s.session.store.peerName!,
        ];
        if (peerNames.contains(name)) {
          s.session.messages.add(_systemMessage(s.session, '⚠️ 名字不能与对方相同（$name），请换个名字'));
          s.status = '';
        } else {
          try {
            final old = s.session.store.partnerName ?? '(未设置)';
            s.session.store.partnerName = name;
            s.session.store.save(s.session.storePath);
            await ApiClient(s.session.server).updatePartnerName(name, s.session.store.sessionToken!);
            await _refreshPartnerNames(s);
            s.session.messages.add(_systemMessage(s.session, '✅ 我的名字已更新: $old → $name'));
          } catch (e) {
            s.session.messages.add(_systemMessage(s.session, '❌ 我的名字修改失败: $e'));
          }
        }
      }
    case '/entrance':
      // 重设本通道名称（entranceName）：本地 + 服务端同步
      if (arg.isEmpty) {
        // 先打印当前通道名与公钥，再给出详细用法
        final current =
            s.session.store.entranceName ?? s.session.store.entranceId ?? '(未设置)';
        s.session.messages.add(_systemMessage(s.session, '当前通道名: $current'));
        s.session.messages.add(_systemMessage(s.session, '通道公钥: ${s.session.store.publicKey}'));
        s.session.messages.add(
            _systemMessage(s.session, '🔧 用法: /entrance <通道名> —— 修改本通道名称（如 /entrance MyMac）'));
      } else if (s.session.store.sessionToken == null) {
        s.session.messages.add(_systemMessage(s.session, '⚠️ 会话未激活，请先 /auth'));
        s.status = '';
      } else {
        // 字符白名单 + 长度上限（老板 2026-09-16）：不合规就提示重输，不静默改写
        // 用户的输入（服务端 POST /entrances/name 同样会 400 兜底）
        final violation = checkEntranceNamePolicy(arg);
        if (violation != null) {
          s.session.messages.add(_systemMessage(s.session, _entranceNameRuleHint()));
          break;
        }
        final name = arg.trim();
        try {
          final old = s.session.store.entranceName ?? '(未设置)';
          s.session.store.entranceName = name;
          s.session.store.save(s.session.storePath);
          await ApiClient(s.session.server).updateEntranceName(name, s.session.store.sessionToken!);
          s.session.messages.add(_systemMessage(s.session, '✅ 通道名已更新: $old → $name'));
        } catch (e) {
          s.session.messages.add(_systemMessage(s.session, '❌ 通道名修改失败: $e'));
        }
      }
    case '/open':
      // 打开附件到系统应用：/open <序号>（序号 = 消息里显示的 #N，固定不变）
      await _execOpen(parts);
    case '/backup': {
      // 备份导出（E2EE.md §10.1，与 CLI backup 同构）：Space Key + 密文历史 +
      // 附件元数据 + 离线队列 + 归档密钥 → 恢复码加密 → JSON 文件（纯本地，Server 不接触）
      if (s.session.store.spaceKey == null) {
        s.session.messages.add(_systemMessage(s.session, '⚠️ 未持有 Space Key（先 /space 接入秘境）——没有可备份的密钥'));
        break;
      }
      final outPath = arg.trim().isNotEmpty
          ? arg.trim()
          : '${File(s.storePath).parent.path}/einz-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json';
      final store = s.session.store;
      final payload = jsonEncode({
        'entrance_id': store.entranceId,
        'space_id': store.spaceId,
        'key_version': store.keyVersion,
        'space_key': store.spaceKey,
        'history': store.history,
        'attachments': store.attachments,
        'pending': store.pending,
      });
      final recoveryCode = await generateRecoveryCode();
      final file = await encryptWithPassphrase(
          payload: Uint8List.fromList(utf8.encode(payload)), passphrase: recoveryCode);
      File(outPath).writeAsStringSync(JsonEncoder.withIndent('  ').convert(file.toJson()));
      s.session.messages.add(_systemMessage(s.session, '✅ 备份已导出: $outPath'));
      s.session.messages.add(_systemMessage(
          s.session, '⚠️ 恢复码（12 词助记词，请离线妥善保存，丢失即无法恢复）：\n$recoveryCode'));
    }
    case '/exit':
    case '/quit':
      s.running = false;
      // 兜底：main 收尾（await guide/stopWs）在部分场景（如重启后 WS/同步挂起）
      // 到不了末尾的 exit(0)——2 秒后强制退出（进程退出自动关闭连接）
      Future.delayed(const Duration(seconds: 2), () => exit(0));
    default:
      s.session.messages.add(_systemMessage(s.session, '未知命令: $cmd（/help 查看）'));
  }
}

/// /invite [partnerA|partnerB] [对方名称]：补发一次性开通码（默认 partnerB=邀请对方，
/// 给第二使用者；partnerA=给自己加新通道）。需先 /auth 激活。
Future<void> _execInvite() async {
  final s = _state!;
  final store = s.session.store;
  if (store.spaceKey == null || store.spaceId == null) {
    s.session.messages.add(_systemMessage(s.session, '⚠️ 尚未绑定秘境（先 /space create 或 /space join）'));
    s.status = '';
    return;
  }
  // 签发邀请凭证要求本通道持该空间成员会话（服务端 403/401 亦可，这里先给人话）
  if (store.sessionToken == null) {
    s.session.messages.add(_systemMessage(s.session, '⚠️ 尚未认证（先 /auth 激活本通道）'));
    s.status = '';
    return;
  }
  try {
    final api = ApiClient(s.session.server);
    final r = await _busy(s.session, '⏳ 开通码生成中......', () => api.createJoinToken(store.spaceId!, store.sessionToken!));
    // 邀请作为对话流中的一条 system 消息显示（随消息区滚动，不占顶部状态栏）
    s.session.messages.add(_systemMessage(s.session, '✅ 开通码已生成（24 小时内一次性有效）：\n📎 ${r.link}\n🛡️  ${r.joinToken}'));
    s.status = ''; // 反馈在消息区，状态栏保持干净
  } catch (e) {
    s.session.messages.add(_systemMessage(s.session, '❌ 开通码生成失败: $e'));
    s.status = '';
  }
}

/// /open <序号>：打开消息流中固定序号为 N 的附件消息（消息里显示的 `#N` 即此序号，
/// 时间序从前往后、新附件只追加新号），下载解密后用系统默认应用打开。不带参默认 1。
/// 附件消息按 env.type 判定（image/video/voice/audio/file）——WS 实时收到的附件消息
/// 可能还没落附件元数据，此时先自动补一次 sync 再尝试打开。
Future<void> _execOpen(List<String> parts) async {
  final s = _state!;
  var idx = 1;
  if (parts.length > 1) {
    idx = int.tryParse(parts[1]) ?? 1;
    if (idx < 1) idx = 1;
  }
  final withAtt = <ChatMessage>[];
  for (final m in s.session.messages) {
    if (m.isSystem) continue;
    if (_kAttachmentTypes.contains(m.env.type)) withAtt.add(m);
  }
  if (withAtt.isEmpty) {
    s.session.messages.add(_systemMessage(
        s.session, '没有带附件的消息（上传用 /attach <file>）'));
    return;
  }
  if (idx > withAtt.length) {
    s.session.messages.add(_systemMessage(
        s.session, '没有 #$idx 附件消息（当前共 ${withAtt.length} 条，序号见消息里的 #N）'));
    return;
  }
  final target = withAtt[idx - 1];
  final store = s.session.store;
  // 缺附件元数据（WS 实时收到时锚点已推进，普通增量 sync 不会重发该消息的
  // attachments_meta——它只随当页消息下发）：从目标消息之前定向重拉一次
  if (store.attachmentMetaByMessage(target.env.messageId) == null) {
    s.status = '⏳ 正在定向补拉附件元数据……';
    final seq = target.env.serverSequence;
    try {
      await s.session.sync(from: (seq == null || seq < 1) ? null : seq - 1);
    } catch (_) {
      // 同步失败不阻断：下方仍会给明确提示
    }
  }
  if (store.attachmentMetaByMessage(target.env.messageId) == null) {
    s.session.messages.add(_systemMessage(s.session,
        '⚠️ 附件元数据尚未就绪（对方的上传可能未完成或本机未同步成功），请稍后再 /open'));
    return;
  }
  try {
    s.status = '⏳ 下载附件中（${target.plain}）……';
    final path = await s.session.openAttachment(target);
    s.session.messages
        .add(_systemMessage(s.session, '✅ 已打开附件(${target.plain}): $path'));
    s.status = ''; // 下载进度通知退场，结果已在消息区
  } catch (e) {
    s.session.messages.add(_systemMessage(s.session, '❌ 打开附件失败: $e'));
    s.status = '';
  }
}

/// 输入循环接管的"邀请链接加入"（/auth 未绑定时的引导）。
///
/// 走 `/space join` 的同一条路径（`_spaceJoin`）：preflight 校验 → 口令取钥 →
/// joinSpace 登记通道 + 签发空间会话 + 取 Space Key。**v1 的开通码登记已随
/// Multiverse 收敛删除**（2026-09-15 P1）：通道登记不再有单独的入口。
Future<void> _handleJoinTokenInput(String token) async {
  final s = _state!;
  s.pendingJoinToken = false;
  if (token.isEmpty) {
    s.session.messages.add(_systemMessage(s.session, '⚠️ 您尚未提供开通码，无法绑定到秘境'));
    return;
  }
  s.status = '';
  await _spaceJoin(s.session, s.session.store, s.session.storePath, token);
}

/// 输入循环接管的共享口令接入（/space 未接入引导）：口令 → accessByEscrow。
Future<void> _handleSpaceKeyInput(String passphrase) async {
  final s = _state!;
  s.pendingSpaceKey = false;
  if (passphrase.isEmpty) {
    s.session.messages.add(_systemMessage(s.session, '未输入口令，无法存取秘境内容'));
    return;
  }
  if (passphrase.startsWith('/')) {
    // / 开头的输入：/exit、/quit 按退出处理；其他 / 不当口令发送核对
    if (passphrase == '/exit' || passphrase == '/quit') {
      _state!.running = false;
      return;
    }
    s.session.messages.add(_systemMessage(s.session, '共享口令不能以 / 开头，接入取消（可再输 /space 重试）'));
    return;
  }
  try {
    await s.session.accessByEscrow(passphrase);
    s.session.messages.add(_systemMessage(
        s.session,
        '✅ 口令核对成功，本通道能够访问秘境内容')); // （space_id=${s.session.store.spaceId} key_version=${s.session.store.keyVersion}）
    s.session.store.escrowUploaded = true; // 已通过口令密保箱接入（托管就绪），不再要求设置托管口令
    s.session.store.save(s.session.storePath);
  } catch (e) {
    // accessByEscrow 抛 StateError（Error 子类），on Exception 捕获不到
    s.session.messages.add(_systemMessage(s.session, '⚠️ 口令核对失败: $e（口令错误？秘境已有口令密保箱？）'));
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

/// "服务器不认本通道"提示（403 `FORBIDDEN`：库被清空/重置、本通道未登记）。
/// 刻意写明"本地数据未清除"——老板 2026-09-16：此前客户端把这种情况当"本通道已被撤销"
/// 直接退出/抹数据，运维失误造成不可挽回的损失；现在只警告，历史照常可看。
const String _unrecognizedNotice =
    '⚠️ 本通道未被服务器识别（服务器数据可能已重置）——仍可查看本地历史，联网功能暂停；本地数据未清除';

/// 是否已提示过"服务器不认本通道"（每进程只提示一次，避免退避重连每分钟刷屏）。
bool _unrecognizedShown = false;

/// 启动自检结果：0=正常/离线（可看本地历史）；1=通道被**明确撤销**（自毁+退出）；
/// 2=会话已失效（/revoke 会 DELETE 该通道的 sessions，缓存 token 死 → 401）需清除
/// token 走引导挑战重认证——挑战阶段若通道被撤销会 403 `ENTRANCE_REVOKED`（由引导兜底
/// 识别）；3=服务器不认本通道（库被重置/未登记，403 `FORBIDDEN`）→ 只警告，继续离线可用。
Future<int> _probeRevoked(EntranceStore store, String server) async {
  if (store.entranceId == null || store.spaceId == null || store.sessionToken == null) {
    return 0;
  }
  try {
    await ApiClient(server).getSpace(store.sessionToken!);
    return 0; // 200：通道 active（会话有效）
  } on ApiException catch (e) {
    // 只有服务端**明确说"这条通道被撤销了"**才自毁（老板 2026-09-16）。
    // FORBIDDEN 表示"服务器不认本通道"——库被清空/重置是最常见原因，属运维失误，
    // 只警告，本地数据一条都不能删（此前 403 一律当撤销，把本地数据全删了）。
    if (e.code == 'ENTRANCE_REVOKED') return 1; // 被明确撤销 → 自毁 + 退出
    if (e.code == 'FORBIDDEN') return 3; // 未登记（库被重置）→ 警告，继续离线可用
    if (e.code == 'UNAUTHORIZED') return 2; // 会话被清/过期：清 token 走重认证
    return 0;
  } catch (_) {
    return 0; // 网络异常：保持离线查看历史的现状能力
  }
}

/// 全丢恢复（开发运维专用；闭环——仅凭 escrow 口令，无需 EINZ-BACKUP 文本）：
/// 修改托管口令（/passphrase）：① 服务器有密保箱 → 旧口令验证（fetch 解密）→
/// 新口令重加密上传（含新 argon2id 哈希）；② 服务器**无**密保箱（数据丢失）→
/// 无从校验旧口令，跳过校验直接用新口令重建（与 App 同口径）。
/// 口令输入**故意明文回显**（`hidden: false`）——老板 2026-09-14 要求：隐藏回显时
/// 看不见自己敲的内容（连 `/exit` 这类控制命令都看不见），而口令提交后只用于本地
/// 加密上传、不会进入消息流，明文回显的风险可接受。（对比：`_spaceJoin` 的接入
/// 口令校验用 `hidden: true`。）
/// 上线补查（离线期间口令被重设）：启动/WS 连接后对比服务端 updated_at，
/// 服务器更新 = 口令已重设——系统消息通知（插入消息流，不弹窗）。
Future<void> _checkEscrowRotated(ChatSession session) async {
  final store = session.store;
  final server = session.server;
  final token = store.sessionToken;
  if (server.isEmpty || token == null) return;
  try {
    final snap = await ApiClient(server).getKeyEscrow(token);
    final serverAt = snap.updatedAt;
    final knownAt = store.escrowUpdatedAt;
    if (serverAt != null && knownAt != null && serverAt > knownAt) {
      session.messages.add(_systemMessage(session,
          '⚠️ 离线期间共享口令已被重设——接入（/space）或修改（/passphrase）时请使用新口令'));
      // 记录本端已知更新时间（防 WS 重连/重复补查刷屏；下次真正重设再通知）
      store.escrowUpdatedAt = serverAt;
      store.save(session.storePath);
      _scheduleRender();
    }
  } catch (_) {
    // 查询失败静默（网络/未托管）
  }
}

Future<void> _changeEscrowPassphrase(EntranceStore store, ChatSession session) async {
  final api = ApiClient(session.server);
  final escrow = KeyEscrowService(api);
  // 1) 先取服务端密保箱：有包 → 必须验证旧口令；无包（服务端数据丢失）→
  //    旧口令无从校验，跳过校验直接用新口令重建（本通道已认证且持有
  //    Space Key，重建不新增权限）——与 App 同口径。
  PassphraseEnvelope? serverFile;
  // 验证通过的旧口令（无密保箱的重建路径为 null）：新口令与它相同则拒绝修改
  String? oldPass;
  try {
    serverFile = (await api.getKeyEscrow(store.sessionToken!)).file;
  } catch (e) {
    session.messages.add(_systemMessage(session, '⚠️ 读取口令密保箱失败: $e，请稍后再试'));
    return;
  }
  if (serverFile == null) {
    session.messages.add(
        _systemMessage(session, '⚠️ 服务器无密保箱（可能数据丢失）——无需旧口令，将用新口令重建'));
    _scheduleRender();
  } else {
    while (true) {
      if (!_state!.running) return; // 已退出
      final entered = await _promptAction(session, '❓ 验证老共享口令（留空取消）:');
      if (!_state!.running) return;
      if (entered == null) {
        session.messages.add(_systemMessage(session, '✅ 已取消（未修改共享口令）'));
        return;
      }
      try {
        await escrow.openPackage(passphrase: entered, envelope: serverFile);
        oldPass = entered; // 旧口令验证通过
        break;
      } on FormatException {
        session.messages.add(_systemMessage(session, '⚠️ 老口令错误，请重新输入（留空取消）'));
        continue;
      }
    }
  }
  // 2) 新口令（两次输入一致）
  while (true) {
    if (!_state!.running) return;
    final p1 = await _promptAction(session, '❓ 设置新共享口令（务必牢记，严禁泄漏！；留空取消）:');
    if (!_state!.running) return;
    if (p1 == null) {
      session.messages.add(_systemMessage(session, '✅ 已取消（未修改共享口令）'));
      return;
    }
    final policyError = _passphrasePolicyError(p1);
    if (policyError != null) {
      session.messages.add(_systemMessage(session, policyError));
      _scheduleRender();
      continue;
    }
    // 新口令与刚验证过的旧口令相同 → 不真去改（老板 2026-09-14，与 App 同口径）。
    // 放在旧口令校验之后：先验旧再比，避免把"你猜对了旧口令"当提示漏出去
    if (oldPass != null && p1 == oldPass) {
      session.messages.add(
          _systemMessage(session, '⚠️ 新口令与旧口令相同，未作修改——请换一个新口令'));
      _scheduleRender();
      continue;
    }
    // final p2 = await _prompt(session, '❓ 请再次输入新口令确认：', hidden: false, required: true);
    // if (p1 != p2) {
    //   session.messages.add(_systemMessage(session, '⚠️ 两次输入的口令不一致，请重新设置'));
    //   continue;
    // }
    // 3) 新口令重加密上传（含新哈希；_busy 期间禁止输入）
    try {
      await _busy(session, '⏳ 正在用新口令重新加密口令密保箱......', () async {
        await escrow.upload(
          passphrase: p1,
          spaceKeyB64: store.spaceKey!,
          spaceId: store.spaceId!,
          keyVersion: store.keyVersion,
          token: store.sessionToken!,
          rotated: true, // 真正重设：服务端广播口令重设通知 + 推进 updated_at
        );
      });
      // 记录本端已知口令更新时间（上传成功后服务端 updated_at 已刷新）
      try {
        final snap2 = await api.getKeyEscrow(store.sessionToken!);
        store.escrowUpdatedAt = snap2.updatedAt;
        store.save(session.storePath);
      } catch (_) {
        // 记录失败不影响结果（下次上线补查再对比）
      }
      session.messages.add(_systemMessage(
          session,
          serverFile == null
              ? '✅ 密保箱已用新口令重建（请线下告知伴侣新口令）'
              : '✅ 口令已修改（新通道绑定时请使用新口令）'));
      _scheduleRender();
      return;
    } catch (e) {
      session.messages.add(_systemMessage(session, '⚠️ 修改口令失败: $e，请稍后再试'));
      return;
    }
  }
}

/// 设置托管口令（单次输入：口令不在消息流回显，留空回车由输入循环拦截不提交、
/// 服务端是否已有本空间的口令密保箱（只问有没有，不解包）。
/// 返回 `true`=确认有箱、`false`=确认无箱、**`null`=查不到**（网络/会话失效）。
///
/// 为什么要三态（2026-09-15）：`_setupEscrowPassphrase` 上传时**不校验旧口令**
/// （它只在"确认服务端无箱"的引导分支里用）。若把"查不到"当成"没有箱"去提示用户
/// 重设，用户输入新口令就会**顶掉**原有密保箱（等于把伴侣锁在门外）。所以查不到时
/// 一律不提示，留到下次会话正常时再判定。
Future<bool?> _serverHasEscrow(EntranceStore store, String server) async {
  final token = store.sessionToken;
  if (server.isEmpty || token == null || token.isEmpty) return null;
  try {
    final res = await ApiClient(server).getKeyEscrow(token);
    return res.file != null;
  } catch (_) {
    return null;
  }
}

/// 继续输入；成功标记 store.escrowUploaded 并落盘）。中断（Ctrl+C）后重启会再进此引导。
Future<void> _setupEscrowPassphrase(EntranceStore store, String storePath, ChatSession session) async {
  while (true) {
    if (!_state!.running) break; // 已退出：结束口令设置
    final p1 = await _promptAction(
        session, '❓ 设置共享口令（务必牢记，严禁泄漏！仅可将口令分享给秘境伴侣；留空取消）:');
    if (!_state!.running) break;
    if (p1 == null) {
      session.messages.add(_systemMessage(session, '✅ 已跳过（之后可用 /passphrase 设置）'));
      break;
    }
    final policyError = _passphrasePolicyError(p1);
    if (policyError != null) {
      session.messages.add(_systemMessage(session, policyError));
      _scheduleRender();
      continue;
    }
    try {
      final api = ApiClient(session.server);
      // _busy：打包/上传期间插入"⏳ 口令正在加密打包我的空间......"、禁止输入、隐藏光标，
      // 完成后移除（替换为下方结果消息）——统一体验优化
      await _busy(session, '⏳ 正在上传托管我的口令密保箱......', () async {
        await session.auth(); // challenge-response 激活（写入 store.sessionToken）
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
      session.messages.add(_systemMessage(session, '✅ 口令密保箱已上传托管'));
      session.messages.add(_systemMessage(session, '----------------'));
      _scheduleRender();
      return;
    } catch (e) {
      session.messages.add(_systemMessage(session, '⚠️ 口令密保箱上传失败: $e，请重新设置'));
      session.messages.add(_systemMessage(session, '----------------'));
      _scheduleRender();
    } 
  }
}

/// 收到对方消息后按需刷新 partner 名称/性别表：新成员 join 后本端仍是加入时的
/// 快照（无后来加入的发送者）——不刷新则对方气泡按未知性别回退青绿
/// （老板 2026-09-10：同性别空间第二人发消息，对方 TUI 收到青色）。
Future<void> _refreshGenderForLatest(_TuiState s) async {
  final msgs = s.session.messages;
  for (var i = msgs.length - 1; i >= 0; i--) {
    final m = msgs[i];
    if (m.isSystem) continue;
    final pid = m.env.senderPartnerId;
    if (pid != null && pid != s.session.store.partnerId) {
      if (!s.partnerGenders.containsKey(pid)) {
        await _refreshPartnerNames(s);
      }
      break;
    }
  }
  _scheduleRender();
}

/// 补登安装级标识（POST /entrances/install-uid，幂等）。
///
/// 存量 store（多空间上线前入网的）不会重走入网流程，只能在启动时补一次——服务端据此
/// 把同一台物理设备在各空间的 entrance_id 认成一台。失败静默：它只是服务端侧认知，
/// 不参与任何功能（与 App 的 `_registerInstallUid` 同口径）。
Future<void> _registerInstallUid(
    ChatSession session, EntranceStore store, String storePath, String server) async {
  if (server.isEmpty) return;
  final token = store.sessionToken;
  if (token == null || token.isEmpty) return;
  final before = store.installUid;
  final uid = store.ensureInstallUid();
  // 首次生成先落盘：否则下次启动会换一个新 id（与服务端已登记的对不上）
  if (before != uid) store.save(storePath);
  try {
    await ApiClient(server).registerInstallUid(uid, token);
  } catch (_) {
    // 离线 / 老服务端（无此端点）：静默降级
  }
}

/// 拉取空间 partner 名称/性别表（GET /space）到缓存（认证后调用；失败静默——
/// 前缀回退"我/对方"）。成功后回写 store 落盘：服务器离线启动时用缓存兜底
/// （名字/性别不丢——老板 2026-09-13）。
Future<void> _refreshPartnerNames(_TuiState s) async {
  final token = s.session.store.sessionToken;
  if (token == null) return;
  try {
    final r = await ApiClient(s.session.server).getSpace(token);
    s.partnerNames = r.partnerNames;
    s.partnerGenders = r.partnerGenders;
    s.partnerSlots = r.partnerSlots;
    final store = s.session.store;
    // 对方**真实**名字（对方已加入才有——同一身份多通道共享同一 partnerId）→ 校正
    // 预置名快照：否则对方改名后旧预置名会一直留着，把 /myname 的同名判据误伤
    // （明明已没人叫那个名字，却仍不许我用）。对齐 App 的 _refreshProfileFromServer。
    final myPid = store.partnerId;
    String? peer;
    if (myPid != null) {
      for (final e in r.partnerNames.entries) {
        if (e.key != myPid) {
          peer = e.value;
          break;
        }
      }
    }
    final peerChanged = peer != null && peer.isNotEmpty && peer != store.peerName;
    // 回写本地缓存（离线启动兜底）；只有内容变化才落盘，避免频繁刷新时反复写盘
    if (!_sameStringMap(store.partnerNames, r.partnerNames) ||
        !_sameStringMap(store.partnerGenders, r.partnerGenders) ||
        !_sameIntMap(store.partnerSlots, r.partnerSlots) ||
        peerChanged) {
      store.partnerNames = Map.of(r.partnerNames);
      store.partnerGenders = Map.of(r.partnerGenders);
      store.partnerSlots = Map.of(r.partnerSlots);
      if (peerChanged) store.peerName = peer;
      store.save(s.session.storePath);
    }
    _scheduleRender();
  } catch (_) {
    // 拉取失败不影响聊天（前缀回退"我/对方"，配色用本地缓存）
  }
}

/// 两个 String→String 映射内容是否完全一致（用于避免无变化时反复落盘）。
bool _sameStringMap(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 两个 String→int 映射内容是否完全一致（同上，partnerSlots 落盘防抖用）。
bool _sameIntMap(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

/// 同性别第二人的气泡背景色（2026-09-17 老板要求）：空间两人性别都已登记且相同
/// 时，第二个人（slot=1）的消息气泡取亮青——否则两蓝/两粉无法区分谁发的。
/// [senderPid] 发言人 partner_id；槽位表 partner_slots 来自 GET /space
/// （老服务端无此键 → 空表 → 不适用）。返回 null = 不适用（性别不同/未登记/
/// 槽位未知），调用方沿用原性别配色。
String? _sameGenderSecondCyan(String? senderPid) {
  final slots = _state?.partnerSlots;
  if (senderPid == null || slots == null || slots.length < 2) return null;
  // 两人性别都必须已登记（规范值 male/female）且完全相同才启用青色
  final genders = slots.keys.map((pid) => _state?.partnerGenders[pid]).toSet();
  if (genders.length != 1) return null;
  if (genders.first != 'male' && genders.first != 'female') return null;
  return slots[senderPid] == 1 ? _bgCyan : null;
}

/// 共享口令策略校验（**设置/修改**时用；输入既有口令不校验，避免把旧短口令用户挡在门外）。
/// 策略唯一来源：shared 的 passphrase_policy.dart——现在只要求最短
/// [kPassphraseMinLength] 位，字符种类不限（老板 2026-09-15）。
String? _passphrasePolicyError(String passphrase) {
  if (checkPassphrasePolicy(passphrase) == null) return null;
  return '⚠️ 口令不得少于 $kPassphraseMinLength 位，请重新输入';
}

/// 系统提示消息的 message_id 计数器（保证唯一——此前用毫秒时间戳，同刻会产生
/// 重复 id，去重/删除按 id 操作时可能误伤）。
int _systemMessageSeq = 0;

/// 构造一条系统提示消息（sender 显示 system，随对话流滚动，不被状态条推到窗口上方）。
ChatMessage _systemMessage(ChatSession session, String text) {
  return ChatMessage(
    env: MessageEnvelope(
      v: 1,
      type: 'text',
      keyVersion: session.store.keyVersion,
      messageId: 'sys-${_systemMessageSeq++}',
      senderEntranceId: session.store.entranceId ?? '-',
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
///
/// **选哪个提示函数**（2026-09-23 定的规则）：
/// - **向导必填**（名字/性别/开通码/身份选择/口令接入）→ 用本函数 + `required: true`：
///   留空回车被拦，避免误提交空值；那里的"取消"= 不做这件事 = 离开向导，逃生门是 `/exit`。
/// - **动作内的一步**（`/revoke`、`/reset`、`/passphrase` 这类可从聊天里放弃的操作）
///   → 用 [_promptAction]：留空回车 = 放弃这个动作。
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

/// 动作内的一步问答：**留空回车 = 放弃当前动作**，返回 null（调用方打印"已取消"收场）。
///
/// 为什么单独一个函数（老板 2026-09-23 反馈）：这些问答原先借 `_prompt(required: true)`
/// 拦空回车（那是给向导必填做的），结果是**用户被困在动作里**——`/revoke` 只能输序号、
/// 输乱码（还报"无效"）或 `/exit`（杀掉整个 App）；`/passphrase` 更是 `while(true)`
/// 重试循环，提示语自己写着"（或 /exit 退出）"。
///
/// 与 [_prompt] 的差别只在意图：调用方拿到 null 就"已取消 + 不做任何改动"，无需再判空串。
/// 退出（`/exit`）时 [_abortPendingGuide] 也会 complete 空回答 → 这里同样返回 null，
/// 故调用方**必须先判 `running`**，否则退出时会多打一条"已取消"。
Future<String?> _promptAction(ChatSession session, String message, {bool hidden = false}) async {
  final answer = (await _prompt(session, message, hidden: hidden)).trim();
  return answer.isEmpty ? null : answer;
}

/// 退出时释放引导问答等待（complete 空回答），避免 _runGuide 的 await 挂起。
void _abortPendingGuide() {
  final c = _state?.pendingGuideCompleter;
  if (c != null && !c.isCompleted) c.complete('');
  _state?.pendingGuideCompleter = null;
  _state?.hiddenInput = false;
}

/// 新通道的默认名称：宿主机名去 .local 后缀（Platform.localHostname 形如
/// 'lukde-MacBook-Pro.local'），再按通道名规则消毒（不合规字符 → `_`、截断 32）；
/// 异常/空值/localhost 回退空串（不设置 entranceName，展示层用 entrance_id 兜底）。
String _defaultEntranceName() {
  try {
    var name = Platform.localHostname.trim();
    if (name.toLowerCase() == 'localhost') return '';
    if (name.endsWith('.local')) {
      name = name.substring(0, name.length - '.local'.length);
    }
    name = name.trim();
    if (name.isEmpty) return '';
    return sanitizeEntranceName(name);
  } catch (_) {
    return '';
  }
}

/// 通道名不合规时的提示（规则见 entrance_name_policy：中英文/数字/`_`/`-`，≤32）。
String _entranceNameRuleHint() {
  return '⚠️ 通道名只能用中文字、英文字母、数字、下划线(_)、中划线(-)，最长 $kEntranceNameMaxLength 个字符';
}

/// 用户名称不合规时的提示（规则见 partner_name_policy：中英文/数字/`_`/`-`/emoji，≤32）。
String _partnerNameRuleHint(PartnerNameViolation violation) {
  if (violation == PartnerNameViolation.tooLong) {
    return '⚠️ 名字最长 $kPartnerNameMaxLength 个字符（一个表情符算 1 个）';
  }
  return '⚠️ 名字只能用中文字、英文字母、数字、下划线(_)、中划线(-)和表情符';
}
