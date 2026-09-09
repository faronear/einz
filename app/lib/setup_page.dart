import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:einz_shared/einz_shared.dart';

import 'brand_logo.dart';
import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/locale_settings.dart';
import 'data/server_settings.dart';
import 'l10n/app_localizations.dart';
import 'widgets/top_notice.dart';

/// 向导角色（第 0 步选择）：创建新空间 / 加入现有空间。
enum _WizardRole { create, join, offline }

/// 设置页：一次性配置（生成设备凭证 → 自动登记入网 → 获得 Space Key → 设置启动锁）。
///
/// 服务器登记已全自动化（对齐 TUI/CLI 的 enroll 流程，不再需要 config.json 白名单）：
/// - create（第一个使用者）：首设备免邀请码自举登记 → 设接入口令托管 Space Key →
///   登记完成进聊天页（邀请码由聊天页顶栏生成，二维码只含邀请码、不编口令——
///   降级 B，与 TUI 一致；口令由加入方另行输入）；
/// - join：输入邀请码 → 凭邀请码登记 → 口令托管拉取 Space Key；
/// - offline：密保信封导入（用对方公钥密封的 Space Key，同样先凭邀请码登记）。
/// 认证统一在登记之后进行（challenge 要求设备已入网），deviceId/spaceId 用登记返回值。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, this.db, this.probeServer, this.enrollOverride, this.createInviteOverride, this.authOverride, this.keyPairOverride, this.escrowOverride});

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  /// 服务器探测回调（测试注入 fake 保 golden 稳定）；默认用真实 ServerSettings.probe。
  /// 返回 (能连, person 名称表)——空表=首设备（create），非空=后续设备（join）。
  final Future<(bool, Map<String, String>)> Function(String server)? probeServer;

  /// 测试注入：登记设备（生产走真实 ApiClient.enrollDevice；注入后不发起网络请求）。
  final Future<EnrollResult> Function(String? inviteCode)? enrollOverride;

  /// 测试注入：生成邀请码（生产走真实 ApiClient.createInvite）。
  final Future<InviteResult> Function(String personId)? createInviteOverride;

  /// 测试注入：challenge-response 认证（生产走真实 ApiClient.challenge/verify；
  /// 注入后不发起网络请求，供 golden 走 PIN/跳过路径）。
  final Future<SessionResult> Function(DeviceKeyPair kp, String enrolledDeviceId)? authOverride;

  /// 测试注入：固定设备密钥对（登记/认证需要确定性密钥；生产传 null 则自动生成。
  /// 名字步骤的密钥信息卡已移除——技术细节不展示给用户）。
  final DeviceKeyPair? keyPairOverride;

  /// 测试注入：替换 escrow 服务（join 口令验证；fake 可模拟口令对/错/未托管）。
  final KeyEscrowService Function(String server)? escrowOverride;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  String? _autoDeviceNameCache; // 登记用设备型号缓存（避免重复走平台通道）
  final _personName = TextEditingController(); // 首设备：第一个用户的名字
  final _peerNameCtrl = TextEditingController(); // create：对方（伴侣）的名字（必填）
  String? _myGender; // create 步骤 1：我的性别（'male'/'female'，登记时随 person_name 同步服务端）
  String? _peerGender; // create 步骤 2：伴侣性别（'male'/'female'）
  final _spaceId = TextEditingController(); // 真实 spaceId（enroll/扫码/托管返回后填入）
  final _envelopeKey = TextEditingController();
  final _escrowPassphrase = TextEditingController();
  final _pin = TextEditingController(); // 启动锁 PIN（内嵌表单，不再弹窗）
  final _confirm = TextEditingController();
  String? _pinError; // PIN 步骤红色提示（输入框下方）
  bool _pinSkipped = false; // 用户确认"暂不设置"：跳过 setPin，仍完成前置并进下一步
  final _inviteCode = TextEditingController(); // 加入/导入设备时的一次性邀请码

  // 服务器地址：默认 einz.tic.cc；探测失败由自动重试兜底（启动屏不展示输入框）
  String _server = kEinzServer;
  bool _probeFailed = false;
  Timer? _probeRetryTimer; // 探测失败后的自动重试定时器（连上即停止并自动进入）

  // 向导状态：角色分流 + 步骤索引 + 跨步骤共享数据
  _WizardRole? _role;
  int _step = 0;
  DeviceKeyPair? _keyPair;
  Uint8List? _spaceKey;
  String? _sessionToken;
  int _joinKeyVersion = 1; // join 口令验证时记录的 Space Key 版本（_verifyJoinPassphrase 填充）
  String _myDeviceName = ''; // 登记时的设备名（进聊天页显示/修改用）
  String? _status; // 后台报告的错误提示（红字，显示在底部按钮下方）
  String? _localError; // 本地校验错误提示（红字，显示在输入框下方）
  bool _busy = false;

  /// 探测到的 person 名称表（服务端 /health 返回）：
  /// 空 = 服务器还没有任何用户（首设备场景）；非空 = 已有用户（后续设备场景）。
  Map<String, String> _personNames = <String, String>{};

  /// 后续设备引导中选择的身份（personA/personB；null = 首设备自举或未选）。
  String? _chosenPerson;

  /// 进入密保信封页（offline）前的角色：切回口令页时恢复来源
  /// （create 回步骤 2 / join 回步骤 3），实现口令⇄信封自由互切。
  _WizardRole _preEnvelopeRole = _WizardRole.join;

  /// 设备登记结果（服务端分配的真实 deviceId/personId/spaceId）。
  /// 认证（challenge）与进聊天页一律用它，不用本地临时 deviceId。
  EnrollResult? _enroll;

  /// create 自举失败（服务器已有空间设备）时为 true → 展示改用"加入"的引导。
  bool _bootstrapFailed = false;

  @override
  void dispose() {
    _personName.dispose();
    _peerNameCtrl.dispose();
    _spaceId.dispose();
    _envelopeKey.dispose();
    _escrowPassphrase.dispose();
    _pin.dispose();
    _confirm.dispose();
    _inviteCode.dispose();
    _probeRetryTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initServer();
    _autoGenerateKey(); // 对齐 TUI：本地无设备记录即自动生成公私钥，无需用户点按钮
  }

  /// 自动生成设备密钥（本地无记录时调用；不阻塞 UI，完成后刷新设备名步骤）。
  Future<void> _autoGenerateKey() async {
    if (_keyPair != null || _busy) return;
    final override = widget.keyPairOverride;
    if (override != null) {
      setState(() => _keyPair = override);
      return;
    }
    setState(() => _busy = true);
    try {
      final pair = await DeviceKeyPair.generate(
          deviceId: 'dev-mobile'); // 本地占位 id；登记后一律以服务端分配的真实 id 为准
      if (!mounted) return;
      setState(() => _keyPair = pair);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageKeyGenFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 服务器地址初始化：读持久化值（无则默认 einz.tic.cc）→ 快速探测。
  /// 能连 → 按 person 名称表自动判定角色（空=首设备 create，非空=后续设备 join）；
  /// 无法连接 → 显示输入框引导覆盖（降低小白负担）。
  Future<void> _initServer() async {
    try {
      final db = widget.db ?? LocalDatabase();
      final settings = ServerSettings(db);
      final saved = await settings.load();
      final probe = widget.probeServer ?? ServerSettings.probe;
      final (ok, names) = await probe(saved);
      if (!mounted) return;
      setState(() {
        _server = saved;
        _probeFailed = !ok;
        _personNames = names;
        if (ok && _role == null) {
          _role = names.isEmpty ? _WizardRole.create : _WizardRole.join;
          _step = 1;
        }
      });
      // 服务端未就绪（probe 正常返回 ok=false，不抛异常）：启动自动重试，
      // 一旦就绪自动进入向导（不必等用户手动输地址）
      if (!ok) _startProbeRetry();
    } catch (e) {
      // 数据库/探测初始化异常（如 SQLite 锁竞争）→ 标记探测失败（可见），
      // 避免无限停留在检测页转环；用户可输入服务器地址重试。
      // 注意：技术细节（如 SqliteException）不展示给用户（老板要求）——
      // 本地库已配 busy_timeout/WAL 容错，此处只给友好提示 + 自动重试。
      if (!mounted) return;
      debugPrint('Einz setup init failed: $e');
      setState(() {
        _probeFailed = true;
        _status = AppLocalizations.of(context)!.setupPageInitFailed;
      });
      _startProbeRetry(); // 启动自动重试：一旦连上自动进入，不必等用户手动输地址
    }
  }

  /// 探测失败后启动自动重试：每 4 秒重新探测，一旦成功即停止并自动进入向导。
  void _startProbeRetry() {
    _probeRetryTimer?.cancel();
    _probeRetryTimer = Timer.periodic(const Duration(seconds: 4), (_) => _reprobe());
  }

  /// 周期性重试探测：成功 → 停止重试并自动进入（复用 _initServer 的角色判定）。
  Future<void> _reprobe() async {
    if (_busy || !mounted) return;
    final probe = widget.probeServer ?? ServerSettings.probe;
    final (ok, names) = await probe(_server);
    if (!mounted) return;
    if (ok) {
      _probeRetryTimer?.cancel();
      _probeRetryTimer = null;
      setState(() {
        _probeFailed = false;
        _personNames = names;
        if (_role == null) {
          _role = names.isEmpty ? _WizardRole.create : _WizardRole.join;
          _step = 1;
        }
      });
    }
    // 失败：保持失败提示，等待下一轮重试（不 setState，避免每 4 秒重建一次）
  }

  // 旧版四路径方法（_generateKey/_importAndAuth/_generateSpaceKeyAndAuth/
  // _escrowAccess 等）已重构为向导步骤（_buildStep* 系列，见下方各场景实现），
  // 认证/托管/二维码逻辑按步骤迁移重建。

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 角色未判定（正在检测服务器状态）：品牌启动屏——全屏粉蓝渐变 + 上方大 LOGO
    // + 正中旋转图标 + 状态文案；无 AppBar/菜单/服务器输入框（老板决策 2026-09-08）。
    if (_role == null) return _buildSplashScreen(l10n);
    return Scaffold(
      // AppBar 透明并浮在渐变上：body 渐变容器延伸到屏幕顶部（含 AppBar 与
      // 状态栏区域），整屏共用同一个渐变矩形——修复之前 AppBar flexibleSpace
      // 与 body 各自独立渐变导致的抬头栏/正文衔接处颜色突变
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent, // 露出 body 延伸上来的渐变
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(),
            const SizedBox(width: 10),
            Flexible(
              child: Text(_appBarTitle(l10n), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          // 右上角菜单：语言切换 + 退出（全丢恢复按老板决策已移除，仅 TUI 保留；
          // 密保信封导入在 join 口令页次级入口）
          PopupMenuButton<String>(
            tooltip: l10n.wizardRoleOffline,
            onSelected: (value) {
              // 等菜单 Route 完全关闭再动作（避免 MenuRoute/DialogRoute 交叉卸载断言）
              Future<void>.delayed(const Duration(milliseconds: 300), () {
                if (!mounted) return;
                if (value == 'locale') _showLocalePicker();
                if (value == 'exit') _showExitAppDialog();
              });
            },
            itemBuilder: (context) {
              // 行内左侧标签用稍淡色，与右侧当前值文字（默认 onSurface 深色）区分
              final labelStyle =
                  TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
              // 语言当前值：取实际生效 locale 的语言码 → 中文/English 名
              final langCode = Localizations.localeOf(context).languageCode;
              return [
                PopupMenuItem(
                  value: 'locale',
                  child: Row(
                    children: [
                      Text(l10n.chatPageMenuLocaleLabel, style: labelStyle),
                      const Spacer(),
                      Text(kLocaleLabels[langCode] ?? langCode),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'exit',
                  child: Text(l10n.chatPageMenuExit, style: labelStyle),
                ),
              ];
            },
          ),
        ],
      ),
      body: Container(
        // 与首屏启动屏同款粉蓝渐变（老板决策 2026-09-08：向导页沿用品牌渐变）
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // extendBodyBehindAppBar 下 AppBar 浮动于渐变上：内容从工具栏
                // 高度下方开始（避免与抬头 logo/标题重叠）
                const SizedBox(height: kToolbarHeight),
                _buildProgressDots(),
                // 进度条与输入区之间留白约等于大标题（30 号字，行高≈36px）的两倍
                // （顶部锚定：键盘弹出时 resizeToAvoidBottomInset 只收缩底部空白
                // 并把底部导航顶到键盘上方——输入区不会被覆盖/压缩）
                const SizedBox(height: 72),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    // 顶部锚定：默认 AnimatedSwitcher 用 Stack alignment.center 会把
                    // 输入表单垂直居中在页面正中——改为 topCenter 让表单贴着进度条，
                    // 键盘弹出时 resizeToAvoidBottomInset 只收缩底部空白，输入区不被顶起
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previousChildren, ?currentChild],
                    ),
                    child: KeyedSubtree(
                      key: ValueKey('$_role-$_step'),
                      // 渐变背景上的白色内容卡：表单可读性 + 品牌层次。
                      // 完成页（done 步骤）例外：不包白卡——直接呈现粉蓝渐变
                      // 背景（欢迎对话框盖住全页，老板决策 2026-09-08）
                      child: _step >= _stepCount
                          ? SingleChildScrollView(child: _buildStep())
                          : Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x33000000), // 柔和投影（渐变上浮起）
                                    blurRadius: 24,
                                    offset: Offset(0, 10),
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.all(20),
                              child: SingleChildScrollView(child: _buildStep()),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 后台报告的错误提示（红字；本地校验错误见输入框下方）
                if (_status != null) ...[
                  Text(_status!,
                      style: const TextStyle(color: Colors.red, fontSize: 14)),
                  const SizedBox(height: 8),
                ],
                // 底部导航：角色判定后常显（含异常退到检测页 _step==0 的兜底——
                // 此时也有"下一步"可回到步骤 1，杜绝无路可走）
                // join 步骤 1（身份选择）例外：点卡片即自动前进，整行按钮隐藏
                // （不显示误配的"下一步/完成"，避免与自动前进语义冲突）
                if (_role != null && !(_role == _WizardRole.join && _step == 1))
                  Row(
                    children: [
                      // 步骤 1 已是第一页：禁用"上一步"（避免退到检测页死胡同）
                      TextButton(
                        onPressed: _step > 1 ? _backStep : null,
                        // 渐变上白字（不可用时白色半透明）
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white54,
                        ),
                        child: Text(l10n.wizardBack),
                      ),
                      const Spacer(),
                      // 所有步骤显示"下一步"（create 步骤 2 的下一步触发自动自举登记），
                      // 完成页（_step == _stepCount）显示"完成"。
                      // join 步骤 1（身份选择）例外：点卡片即自动前进，无需"下一步"。
                      if (_step < _stepCount && !(_role == _WizardRole.join && _step == 1))
                        FilledButton(
                            onPressed: _nextStep, child: Text(l10n.wizardNext))
                      else
                        FilledButton(
                            onPressed: _finish, child: Text(l10n.wizardDone)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 向导框架 ----------

  /// 步骤总数（角色由探测自动判定：create=首设备 / join=后续设备 / offline=密保信封）。
  int get _stepCount {
    switch (_role) {
      case _WizardRole.create:
        return 5; // name/peerName/passphrase/pin/done（设备名自动设置，输入步骤已移除）
      case _WizardRole.join:
        return 5; // identity/invite/passphrase/pin/done
      case _WizardRole.offline:
        return 3; // envelope/pin/done
      case null:
        return 1;
    }
  }

  /// 页眉标题（AppBar）：系列标题（如「Einz 秘境：认领中」；第 0 步未选角色时显示引导语）。
  String _appBarTitle(AppLocalizations l10n) {
    if (_role == null || _step == 0) return l10n.wizardStartTitle;
    switch (_role!) {
      case _WizardRole.create:
        return l10n.wizardAppBarCreate;
      case _WizardRole.join:
        return l10n.wizardAppBarJoin;
      case _WizardRole.offline:
        return l10n.wizardAppBarOffline;
    }
  }

  /// 进度圆点指示器：只表示向导内部步骤——首屏服务器检测集成在启动屏完成，
  /// 不属于向导，因此圆点数 = 向导步骤数 - 1（老板决策 2026-09-08）。
  Widget _buildProgressDots() {
    final total = _stepCount - 1; // 去掉首屏（检测）对应的圆点
    if (total <= 1) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < total; i++)
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 渐变背景上的白色圆点（已完成纯白 / 未到白色半透明）
              color: i + 1 <= _step ? Colors.white : Colors.white54,
            ),
          ),
      ],
    );
  }

  void _selectRole(_WizardRole role) {
    setState(() {
      _role = role;
      _step = 1;
      _localError = null;
    });
  }

  /// join 步骤 1：选择身份（personA=创建者 / personB=伴侣），点击卡片即自动进入
  /// 邀请码步骤（不再需要「下一步」按钮）；名字按需设置后留在 join 流程继续。
  void _selectIdentity(String person) {
    setState(() {
      _chosenPerson = person;
      _step = 2; // 点卡片直接进邀请码页
      _status = null;
      _localError = null;
    });
  }

  Future<void> _nextStep() async {
    final l10n = AppLocalizations.of(context)!;
    // 按步骤前置校验（每步只要求一个信息）——本地可检测的错误 → _localError
    // （红字显示在输入框下方）；后台/网络错误 → _status（红字显示在按钮下方）
    // create 步骤 1（本人）与步骤 2（对方）的名字均不允许空白跳过
    if (_role == _WizardRole.create && _step == 1 && _personName.text.trim().isEmpty) {
      setState(() => _localError = l10n.wizardNameRequired);
      return;
    }
    if (_role == _WizardRole.create && _step == 2 && _peerNameCtrl.text.trim().isEmpty) {
      setState(() => _localError = l10n.wizardPeerNameRequired);
      return;
    }
    if (_role == _WizardRole.join && _step == 1 && _chosenPerson == null) {
      setState(() => _localError = l10n.wizardIdentityFirst);
      return;
    }
    if (_role == _WizardRole.join && _step == 2 && _inviteCode.text.trim().isEmpty) {
      setState(() => _localError = l10n.setupPageNeedInvite);
      return;
    }
    // 本地校验全部通过 → 清除本地错误提示
    setState(() => _localError = null);
    // join 邀请码页（步骤 2）：邀请码必须有效（服务端登记成功）才放行——
    // 与口令页一样即时验证，不留到口令页才登记/校验
    if (_role == _WizardRole.join && _step == 2) {
      final ok = await _verifyInviteCode();
      if (!mounted) return;
      if (!ok) return;
    }
    if (_role == _WizardRole.create && _step == 3 && _escrowPassphrase.text.trim().isEmpty) {
      setState(() => _localError = l10n.setupPageNeedPassphrase);
      return;
    }
    if (_role == _WizardRole.join && _step == 3 && _escrowPassphrase.text.trim().isEmpty) {
      setState(() => _localError = l10n.setupPageNeedPassphrase);
      return;
    }
    // join 口令页（步骤 3）：输入口令必须与首台设备创建时一致（解密 escrow
    // 口令密保箱成功）才放行进 PIN 步骤——错误口令/未托管提示后停留本页
    if (_role == _WizardRole.join && _step == 3) {
      final verified = await _verifyJoinPassphrase();
      if (!mounted) return;
      if (!verified) return;
    }
    if (_role == _WizardRole.offline && _step == 1) {
      if (_envelopeKey.text.trim().isEmpty) {
        setState(() => _localError = l10n.setupPagePasteEnvelope);
        return;
      }
      // 邀请码沿用 join 步骤 2 已填值（offline 从 join 口令页切换进入）
      // 信封必须有效（本设备私钥解封成功）才放行——不留到 PIN 页才验证
      final ok = await _verifyEnvelope();
      if (!mounted) return;
      if (!ok) return;
    }
    // PIN 步骤（create=3 / join=4 / offline=2）：底部"下一步"触发校验/跳过确认。
    // 有效 PIN → 设锁后推进；两空 → 弹窗确认"暂不设置"；其余 → 输入框下方红色提示。
    final isPinStep = (_role == _WizardRole.create && _step == 4) ||
        (_role == _WizardRole.join && _step == 4) ||
        (_role == _WizardRole.offline && _step == 2);
    if (isPinStep) {
      final pin = _pin.text;
      final confirm = _confirm.text;
      if (pin.isEmpty && confirm.isEmpty) {
        // 两空：确认是否暂不设置
        final skip = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.setupPageSkipPinTitle),
            content: Text(l10n.setupPageSkipPinMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(l10n.skip),
              ),
            ],
          ),
        );
        if (skip != true) return; // 取消：留在本页
        _pinSkipped = true;
      } else if (pin.length < 4) {
        setState(() => _pinError = l10n.setPinDialogPinTooShort);
        return;
      } else if (pin != confirm) {
        setState(() => _pinError = l10n.setPinDialogPinMismatch);
        return;
      } else {
        _pinSkipped = false;
      }
      setState(() => _pinError = null);
      // 执行对应 _run*（内部完成前置：登记/认证/Space Key；有效 PIN 则设锁）
      if (_role == _WizardRole.create) {
        await _runPinSetup();
      } else if (_role == _WizardRole.join) {
        await _runJoinAccess();
      } else {
        await _runEnvelopeImport();
      }
      return; // _run* 内部推进 _step
    }
    // create 步骤 2（对方名字）→ 自动自举登记（登记时上传本人+对方名字；
    // 设备名已自动设置不再询问），成功才进口令步骤
    if (_role == _WizardRole.create && _step == 2 && _enroll == null) {
      await _runBootstrap();
      if (!mounted) return;
      if (_enroll == null) return; // 自举失败：留在本步展示错误/改用加入
    }
    setState(() {
      if (_step < _stepCount) _step++; // done 页 = _stepCount（如 create/join 第 6 步）
    });
  }

  void _backStep() {
    setState(() {
      // 步骤 1 即向导第一页（create=名字 / join=身份 / offline=密保信封）；
      // 不允许退到第 0 步检测页（角色判定前的过渡页，无操作出口，会形成死胡同）
      if (_step > 1) _step--;
      _localError = null;
      _status = null;
    });
  }

  /// 归一化的向导输入步骤页头：大标题（大号醒目，水平居中）+ 解释说明（较小较淡，左对齐）。
  /// 全向导各输入页统一用此头部，保证视觉与结构一致。
  Widget _stepHeader(String title, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          hint,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  /// 本地校验错误提示（红字，显示在输入框下方、按钮上方）。
  Widget _localErrorHint(String error) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        error,
        style: const TextStyle(
          color: Colors.red,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// 按角色+步骤分发到对应步骤页。
  Widget _buildStep() {
    if (_role == null || _step == 0) return _buildDetectAndEnvelope();
    switch (_role!) {
      case _WizardRole.create:
        switch (_step) {
          case 1:
            return _buildStepName();
          case 2:
            return _buildStepPeerName();
          case 3:
            return _buildStepPassphrase();
          case 4:
            return _buildStepPin();
          default:
            return _buildStepDone();
        }
      case _WizardRole.join:
        switch (_step) {
          case 1:
            return _buildStepIdentity();
          case 2:
            return _buildStepInvite();
          case 3:
            return _buildStepPassphrase();
          case 4:
            return _buildStepPin();
          default:
            return _buildStepDone();
        }
      case _WizardRole.offline:
        switch (_step) {
          case 1:
            return _buildStepEnvelope();
          case 2:
            return _buildStepPin();
          default:
            return _buildStepDone();
        }
    }
  }

  /// 启动屏（角色未判定时的检测页）：全屏粉蓝品牌渐变 + 上方大 LOGO 徽章 +
  /// 正中旋转图标 + 状态文案。无 AppBar/菜单/服务器输入框——探测失败时由
  /// 自动重试兜底（每 4 秒重探，就绪即自动进入向导），全程零打扰。
  Widget _buildSplashScreen(AppLocalizations l10n) {
    return Scaffold(
      body: Container(
        // alignment 使内部 Align 撑满全屏 → 渐变 DecoratedBox 铺满整页。
        // （Scaffold body 是宽松约束，RenderProxyBox 尺寸 = child 尺寸；若不加
        // alignment，渐变容器会缩到 Column 宽度 = 最宽文案，右侧露出背景——
        // 修复 2026-09-08：断线时失败文案最长，左侧一大半渐变 + 右侧全白）
        alignment: Alignment.topCenter,
        decoration: const BoxDecoration(
          // Einz 粉蓝品牌渐变：天蓝（左上）→ 粉（右下），与顶部通知/Logo 同系
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3BAFFD), Color(0xFFD6529C)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              // 正中：旋转的嵌套圆环 Logo——品牌展示与加载指示二合一，
              // 替代原「大 LOGO 徽章 + 旋转图标」（老板决策 2026-09-08）
              const SpinningBrandLogo(size: 96, radius: 24),
              const SizedBox(height: 24),
              // 状态文案：检测中提示 / 失败（自动重试中）提示
              Text(
                _probeFailed ? l10n.wizardDetectFailed : l10n.wizardDetectTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }

  /// 第 0 步（角色未判定时）：显示探测状态（密保信封导入在口令页有次级入口）。
  /// 角色由服务器探测自动判定（person 名称表空=首设备 create，非空=后续设备 join），
  /// 不再让用户手动选择。
  Widget _buildDetectAndEnvelope() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardDetectTitle,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(_probeFailed ? l10n.wizardDetectFailed : l10n.wizardDetectHint,
            style: const TextStyle(fontSize: 13, color: Colors.grey)),
        const SizedBox(height: 12),
        if (!_probeFailed) ...[
          const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            ),
          ),
        ],
      ],
    );
  }

  // ---- 辅助：认证 / PIN 设置 / 进聊天页 ----

  /// challenge-response 认证，返回 session（PROTOCOL.md §4）。
  /// [enrolledDeviceId] 用登记后服务端分配的真实 id（challenge 要求设备已入网）。
  Future<SessionResult> _authenticate(DeviceKeyPair kp, String enrolledDeviceId) async {
    // 测试注入优先（golden 走 PIN/跳过路径时避免真实网络请求）
    if (widget.authOverride != null) {
      return widget.authOverride!(kp, enrolledDeviceId);
    }
    final s = await sodium();
    final api = ApiClient(_server);
    final challenge = await api.challenge(enrolledDeviceId);
    final opened = await sealOpen(
      s,
      base64Decode(challenge.sealedChallenge),
      kp.publicKey,
      kp.privateKey,
    );
    return api.verify(challenge.challengeId, base64Encode(opened));
  }

  /// 退出应用（等价 TUI /exit；向导任意页面可经 ⋯ 菜单退出）：
  /// 确认后彻底关闭应用（不再回 LockPage——未设 PIN 时锁屏不应激活）。
  Future<void> _showExitAppDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.chatPageExitTitle),
        content: Text(l10n.chatPageExitMessage),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.chatPageMenuExit)),
        ],
      ),
    );
    if (shouldExit == true) {
      exit(0);
    }
  }

  /// 顶栏 🌐：切换界面语言（跟随系统/中文/English，即时生效——
  /// localeNotifier 通知 EinzApp 重建 MaterialApp，整个向导刷新）。
  Future<void> _showLocalePicker() async {
    final settings = LocaleSettings(widget.db ?? LocalDatabase());
    final current = await settings.load();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('界面语言 / Language', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final option in kLocaleOptions)
              ListTile(
                title: Text(kLocaleLabels[option]!),
                trailing: option == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(option),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await settings.save(picked);
    if (!mounted) return;
    showTopNotice(context, AppLocalizations.of(context)!.chatPageLocaleSwitched(kLocaleLabels[picked]!));
  }

  /// 登记用默认设备名：设备型号（device_info_plus，如 "iPhone 15 Pro" /
  /// "SM-S918B"）；平台通道不可用（widget 测试等）时回退 'dev-mobile'。
  Future<String> _autoDeviceName() async {
    if (_autoDeviceNameCache != null) return _autoDeviceNameCache!;
    var name = 'dev-mobile';
    try {
      final info = await DeviceInfoPlugin().deviceInfo;
      final model = (info as dynamic).model?.toString().trim();
      if (model != null && model.isNotEmpty) name = model;
    } catch (_) {}
    _autoDeviceNameCache = name;
    return name;
  }

  /// 登记设备：create=首设备免邀请码自举；join/offline=凭一次性邀请码。
  /// 成功 → 记录 [_enroll]（真实 deviceId/personId/spaceId）并同步 spaceId。
  Future<void> _enrollDevice(String? inviteCode) async {
    final kp = _keyPair;
    if (kp == null) return;
    final r = widget.enrollOverride != null
        ? await widget.enrollOverride!(inviteCode)
        : await ApiClient(_server).enrollDevice(
            deviceId: null, // 服务端分配规范 id（dev1/dev2…），以登记返回为准
            publicKey: kp.publicKeyB64,
            inviteCode: inviteCode,
            personName: _personName.text.trim(), // 首设备：第一个用户的名字；后续设备按需
            partnerName: _peerNameCtrl.text.trim(), // create：对方（伴侣）的名字（必填）；join 时为空被服务端忽略
            personId: _chosenPerson, // join：用户选择的身份（personA/personB）
            personGender: _myGender, // create 步骤 1：我的性别（male/female）；join 时为空被服务端忽略
            partnerGender: _peerGender, // create 步骤 2：伴侣性别（male/female）
            // 自动填设备型号（产品决定：不再询问）；同步保存供进聊天页显示/修改。
            // 只在真实登记分支计算（测试注入 enrollOverride 时不调 device_info）
            deviceName: (_myDeviceName = await _autoDeviceName()),
          );
    if (!mounted) return;
    setState(() {
      _enroll = r;
      _spaceId.text = r.spaceId;
      _bootstrapFailed = false;
    });
    // 顶部状态通知：新设备已绑定到私密领地（老板要求——enroll 成功后显示）
    showTopNotice(context, AppLocalizations.of(context)!.setupEnrollBoundNotice);
  }

  /// 设置启动锁：内嵌表单直接执行（不再弹窗、无恢复码）——
  /// 校验 PIN 两次一致 → AppLockService.setPin 加密 Space Key 包 → 返回是否完成。
  /// （口令托管上传已与 PIN 解耦：由各 _run* 在设锁/跳过之前统一上传，见 _runPinSetup）
  Future<bool> _setupLockAndEnter({
    required String server,
    required String spaceId,
    required String deviceId,
    required String spaceKeyB64,
    required int keyVersion,
    required String token,
    String? escrowPassphrase,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final pin = _pin.text;
    if (pin.length < 4) {
      setState(() => _status = l10n.setPinDialogPinTooShort);
      return false;
    }
    if (pin != _confirm.text) {
      setState(() => _status = l10n.setPinDialogPinMismatch);
      return false;
    }
    try {
      final payload = AppLockPayload(
        server: server,
        spaceId: spaceId,
        deviceId: deviceId,
        spaceKeyB64: spaceKeyB64,
        keyVersion: keyVersion,
        token: token,
        escrowPassphrase: escrowPassphrase,
      );
      await AppLockService(widget.db ?? LocalDatabase()).setPin(pin, payload: payload);
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _status = l10n.setPinDialogSetupFailed('$e'));
      return false;
    }
  }

  /// 口令加密 Space Key 包并上传托管（Server 只存密文；失败静默，不阻塞进入聊天）。
  Future<void> _uploadEscrow(String passphrase, AppLockPayload payload) async {
    try {
      final api = ApiClient(payload.server);
      final escrow = KeyEscrowService(api);
      await escrow.upload(
        passphrase: passphrase,
        spaceKeyB64: payload.spaceKeyB64,
        spaceId: payload.spaceId,
        keyVersion: payload.keyVersion,
        token: payload.token ?? '',
      );
    } catch (_) {
      // 托管上传失败不阻塞：下次解锁（_syncEscrow）或 rotate 时会重试
    }
  }

  /// 完成动作：进入聊天页（create/join/offline 填充数据后统一调用；
  /// deviceId/spaceId 一律用登记后服务端返回的真实值）。
  Future<void> _finish() async {
    final kp = _keyPair;
    final enroll = _enroll;
    final sk = _spaceKey;
    final token = _sessionToken;
    if (kp == null || enroll == null || sk == null || token == null) return;
    // 名字持久化：PIN 解锁/重启后 ChatPage 恢复显示（AppLockPayload 不含名字）。
    // await 确保 profile 写入完成后再进聊天（消除 unawaited 竞态——2026-09-07
    // 老板实测：设 PIN 重启解锁后顶部条丢名字）
    await AppLockService(widget.db ?? LocalDatabase()).saveProfile(
      personName: _role == _WizardRole.create
          ? _personName.text.trim()
          : (_personNames[_chosenPerson] ?? ''),
      peerName: _role == _WizardRole.create
          ? _peerNameCtrl.text.trim()
          : (_personNames[_chosenPerson == 'personA' ? 'personB' : 'personA'] ?? ''),
      deviceName: _myDeviceName,
    );
    if (!mounted) return; // await 后守卫，避免 use_build_context_synchronously
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ChatPage(
        server: _server,
        spaceId: _spaceId.text.trim(),
        deviceId: enroll.deviceId,
        spaceKey: sk,
        keyVersion: 1,
        token: token,
        personName: _role == _WizardRole.create
            ? _personName.text.trim()
            : (_personNames[_chosenPerson] ?? ''),
        personId: enroll.personId,
        peerName: _role == _WizardRole.create
            ? _peerNameCtrl.text.trim()
            : (_personNames[_chosenPerson == 'personA' ? 'personB' : 'personA'] ?? ''),
        deviceName: _myDeviceName,
        // session 过期自动续期：复用本页 challenge-response 流程重新签发 token
        reauth: () async => (await _authenticate(kp, enroll.deviceId)).sessionToken,
      ),
    ));
  }

  // ---- 场景 A（create）：身份名字 → 口令 → PIN → 完成（设备名已自动设置，不再询问） ----

  /// 步骤 1（create）：第一个用户的名字；密钥已由 [_autoGenerateKey] 自动生成
  /// （不展示密钥信息——技术细节，小白用户不需要看）；"下一步"触发自举登记
  /// （设备名已自动设置，不再单独询问）。
  Widget _buildStepName() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitleName, l10n.wizardNameHint),
        TextField(
          controller: _personName,
          style: const TextStyle(fontSize: 20),
          decoration: InputDecoration(
            hintText: l10n.wizardNameHintInput,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
        const SizedBox(height: 20),
        _buildGenderSelector(
          selected: _myGender,
          label: l10n.wizardMyGenderLabel,
          maleLabel: l10n.wizardGenderMale,
          femaleLabel: l10n.wizardGenderFemale,
          onChanged: (g) => setState(() => _myGender = g),
        ),
        if (_role == _WizardRole.create && _bootstrapFailed) ...[
          const SizedBox(height: 12),
          Card(
            color: Colors.amber.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.wizardEnrollExists, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () => _selectRole(_WizardRole.join),
                    child: Text(l10n.wizardEnrollGoJoin),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ---- 场景 B（join）：身份名字 → 邀请码 → 口令 → PIN → 完成 ----

  /// 步骤 1（join）：你是第一个用户（创建者 personA）还是第二个（伴侣 personB）。
  /// 与 TUI 引导顺序一致：先定身份（并按需设置名字）。身份卡片**左右并排**：
  /// 左蓝（personA 天蓝）/ 右粉（personB 粉强调），与品牌 Logo/顶部通知同色系。
  Widget _buildStepIdentity() {
    final l10n = AppLocalizations.of(context)!;
    final aName = _personNames['personA'] ?? '';
    final bName = _personNames['personB'] ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitleIdentity, l10n.wizardIdentityHint),
        Row(
          children: [
            Expanded(
              child: _buildIdentityCard(
                icon: Icons.person,
                label: aName.isEmpty ? l10n.wizardIdentityCreator : aName,
                color: const Color(0xFF3BAFFD), // 左：品牌天蓝
                selected: _chosenPerson == 'personA',
                onTap: () => _selectIdentity('personA'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildIdentityCard(
                icon: Icons.group,
                label: bName.isEmpty ? l10n.wizardIdentityPartner : bName,
                color: const Color(0xFFD6529C), // 右：品牌粉
                selected: _chosenPerson == 'personB',
                onTap: () => _selectIdentity('personB'),
              ),
            ),
          ],
        ),
        if (_localError != null) _localErrorHint(_localError!),
        if (_chosenPerson == 'personB' && bName.isEmpty) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _personName,
            style: const TextStyle(fontSize: 20),
            decoration: InputDecoration(
              hintText: l10n.wizardNameHintInput,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }

  /// join 身份选择卡片：品牌色背景 + 白字图标/标签；选中加白色粗边框 + 对勾。
  Widget _buildIdentityCard({
    required IconData icon,
    required String label,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color,
      elevation: 2,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: selected ? Border.all(color: Colors.white, width: 3) : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 28),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? Colors.white : Colors.white70,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 步骤 3（join）：输入一次性邀请码（创建者 /invite 生成，24h 有效）。
  Widget _buildStepInvite() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitleInvite, l10n.wizardInviteHint),
        TextField(
          controller: _inviteCode,
          style: const TextStyle(fontSize: 20),
          decoration: InputDecoration(
            hintText: l10n.setupPageInviteHint,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
      ],
    );
  }

  /// create：首设备自举登记（免邀请码）。服务器已有空间（他人创建）时
  /// 服务端拒绝自举 → 提示改用"加入"向导。
  Future<void> _runBootstrap() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await _enrollDevice(null);
      if (!mounted) return;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _bootstrapFailed = e.code == 'INVALID_REQUEST';
        _status = AppLocalizations.of(context)!.wizardEnrollFailed('$e');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.wizardEnrollFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 设置接入口令（create=步骤2 / join=步骤3；对方凭它加入）。
  /// create 步骤 2：对方（伴侣）的名字（必填——不允许空白跳过）。
  Widget _buildStepPeerName() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitlePeerName, l10n.wizardPeerNameHint),
        TextField(
          controller: _peerNameCtrl,
          style: const TextStyle(fontSize: 20),
          decoration: InputDecoration(
            hintText: l10n.wizardPeerNameHintInput,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
        const SizedBox(height: 20),
        _buildGenderSelector(
          selected: _peerGender,
          label: l10n.wizardPeerGenderLabel,
          maleLabel: l10n.wizardGenderMale,
          femaleLabel: l10n.wizardGenderFemale,
          onChanged: (g) => setState(() => _peerGender = g),
        ),
      ],
    );
  }

  /// 性别选择：左蓝（男）/右粉（女）两个按钮，与品牌色一致；
  /// 选中者放大（AnimatedScale）+ 白粗边框，未选中半透明。
  Widget _buildGenderSelector({
    required String? selected, // 'male' / 'female'；null = 未选
    required String label,
    required String maleLabel,
    required String femaleLabel,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildGenderButton(
                label: maleLabel,
                icon: Icons.male,
                color: const Color(0xFF3BAFFD), // 左：品牌天蓝
                selected: selected == 'male',
                onTap: () => onChanged(selected == 'male' ? null : 'male'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildGenderButton(
                label: femaleLabel,
                icon: Icons.female,
                color: const Color(0xFFD6529C), // 右：品牌粉
                selected: selected == 'female',
                onTap: () => onChanged(selected == 'female' ? null : 'female'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 单个性别按钮：品牌色背景 + 白字图标/标签；选中放大 + 白粗边框，未选中半透明。
  Widget _buildGenderButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return AnimatedScale(
      scale: selected ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.35),
        elevation: selected ? 3 : 0,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: selected ? Border.all(color: Colors.white, width: 3) : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 26),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 设置接入口令（create=步骤2 / join=步骤3；对方凭它加入）。
  Widget _buildStepPassphrase() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(
          l10n.wizardTitlePassphrase,
          _role == _WizardRole.join ? l10n.wizardJoinPassphraseHint : l10n.wizardPassphraseHint,
        ),
        TextField(
          controller: _escrowPassphrase,
          style: const TextStyle(fontSize: 20),
          obscureText: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
        const SizedBox(height: 16),
        // 密保信封与口令是平行方案，可自由互切：信封页导入对端设备导出的密封
        // 密钥（首台 create 无对端设备时按需准备，随时可切回口令页）
        TextButton.icon(
          onPressed: _openEnvelopeImport,
          icon: const Icon(Icons.mail_outline, size: 18),
          label: Text(l10n.wizardSwitchToEnvelope),
        ),
      ],
    );
  }

  /// 步骤 4：设置启动锁（内嵌表单：PIN 两次确认，提交走底部"下一步"校验/跳过）。
  Widget _buildStepPin() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitlePin, l10n.wizardPinHint),
        TextField(
          controller: _pin,
          style: const TextStyle(fontSize: 20),
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: l10n.setPinDialogPinHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _confirm,
          style: const TextStyle(fontSize: 20),
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: l10n.setPinDialogConfirmHint,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_pinError != null) _localErrorHint(_pinError!),
      ],
    );
  }

  /// create：生成 Space Key（首次）+ 认证 + 设置 PIN（含口令托管上传）。
  Future<void> _runPinSetup() async {
    final kp = _keyPair;
    if (kp == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      // 1) 随机生成 Space Key（CSPRNG 32B，仅首次）
      _spaceKey ??= Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
      // 2) 认证（缓存 session；用登记后服务端分配的真实 deviceId）
      var token = _sessionToken;
      if (token == null) {
        final session = await _authenticate(kp, _enroll!.deviceId);
        token = session.sessionToken;
        _sessionToken = token;
      }
      // 3) 口令托管上传（与 PIN 无关：设锁或跳过都必须传，否则同伴无法凭口令加入）
      final pass = _escrowPassphrase.text.trim();
      if (pass.isNotEmpty) {
        final escrowPayload = AppLockPayload(
          server: _server,
          spaceId: _spaceId.text.trim(),
          deviceId: _enroll!.deviceId,
          spaceKeyB64: base64Encode(_spaceKey!),
          keyVersion: 1,
          token: token,
          escrowPassphrase: pass,
        );
        await _uploadEscrow(pass, escrowPayload);
      }
      // 4) 设置 PIN；确认"暂不设置"时跳过设锁：明文持久化配置（下次启动直接进聊天）
      if (_pinSkipped) {
        if (!mounted) return;
        await AppLockService(widget.db ?? LocalDatabase()).savePlain(AppLockPayload(
          server: _server,
          spaceId: _spaceId.text.trim(),
          deviceId: _enroll!.deviceId,
          spaceKeyB64: base64Encode(_spaceKey!),
          keyVersion: 1,
          token: token,
          escrowPassphrase: pass,
        ));
        _completeWizard();
        return;
      }
      final ok = await _setupLockAndEnter(
        server: _server,
        spaceId: _spaceId.text.trim(),
        deviceId: _enroll!.deviceId,
        spaceKeyB64: base64Encode(_spaceKey!),
        keyVersion: 1,
        token: token,
        escrowPassphrase: pass,
      );
      if (!mounted) return;
      if (ok) {
        _completeWizard();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageKeyGenFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 完成页（create/join/offline 共用）：底部"完成"按钮 → _finish 进聊天页。
  /// 向导完成：推进到完成步骤并弹出欢迎对话框（唯一「开始聊天」按钮 → 消息流页）。
  void _completeWizard() {
    setState(() {
      _step = _stepCount;
      _status = null;
    });
    // 下一帧弹窗（等 done 步骤渲染完成再盖对话框）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showWelcomeDialog();
    });
  }

  /// 完成弹窗：致欢迎词，唯一「开始聊天」按钮（点外面不关闭）→ 进入消息流页。
  Future<void> _showWelcomeDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final isCreate = _role == _WizardRole.create;
    final start = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // 只有一个按钮：开始聊天
      builder: (ctx) => AlertDialog(
        title: Text(isCreate ? l10n.welcomeDialogTitleCreate : l10n.welcomeDialogTitleJoin),
        content: Text(l10n.welcomeDialogMessage),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.welcomeDialogStart),
          ),
        ],
      ),
    );
    if (start == true && mounted) {
      unawaited(_finish()); // 进入消息流页面（fire-and-forget：await profile 写入后导航）
    }
  }

  /// 向导完成页（done 步骤）：无独立内容——欢迎对话框盖住全页，背景直接
  /// 呈现粉蓝渐变（原浅绿色块已去掉：渐变背景更贴合品牌，老板决策 2026-09-08）。
  Widget _buildStepDone() {
    return const SizedBox.shrink();
  }

  // ---- 场景 B（join）：身份名字 → 邀请码 → 口令 → PIN ----

  /// join：凭邀请码登记 → 认证 → 拉取口令密保箱 → 口令解密出 Space Key → 设置 PIN → 完成。
  /// join 邀请码页（步骤 2）「验证邀请码」：凭码登记（服务端校验，无效码抛错）
  /// ——登记成功（= 邀请码有效）才放行到口令页，错误码提示并停留本页。
  Future<bool> _verifyInviteCode() async {
    final kp = _keyPair;
    if (kp == null) return false;
    final code = _inviteCode.text.trim();
    if (code.isEmpty) {
      setState(() => _localError = AppLocalizations.of(context)!.setupPageNeedInvite);
      return false;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      if (_enroll == null) {
        await _enrollDevice(code);
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _status = AppLocalizations.of(context)!.wizardInviteWrong);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// join 口令页（步骤 3）「验证接入口令」：登记 → 认证 → fetch escrow 口令密保箱 →
  /// 用输入口令解密——口令与首台设备创建时一致（解密成功）才放行进 PIN 步骤。
  Future<bool> _verifyJoinPassphrase() async {
    final kp = _keyPair;
    if (kp == null) return false;
    final passphrase = _escrowPassphrase.text.trim();
    if (passphrase.isEmpty) {
      setState(() => _localError = AppLocalizations.of(context)!.setupPageNeedPassphrase);
      return false;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      // 1) 凭邀请码登记（码绑定 person，服务端分配真实 deviceId）
      if (_enroll == null) {
        await _enrollDevice(_inviteCode.text.trim());
      }
      final enroll = _enroll!;
      // 2) 认证（用登记后的真实 deviceId）
      final session = await _authenticate(kp, enroll.deviceId);
      _sessionToken = session.sessionToken;
      // 3) fetch 口令密保箱并用输入口令解密：口令错 → FormatException → 不通过
      final escrow = widget.escrowOverride?.call(_server) ?? KeyEscrowService(ApiClient(_server));
      final payload = await escrow.fetch(passphrase: passphrase, token: session.sessionToken);
      if (!mounted) return false;
      if (payload == null) {
        setState(() => _status = AppLocalizations.of(context)!.setupPageNoEscrow);
        return false;
      }
      _spaceKey = base64Decode(payload.spaceKeyB64);
      _spaceId.text = payload.spaceId;
      _joinKeyVersion = payload.keyVersion;
      return true;
    } on FormatException {
      if (!mounted) return false;
      setState(() => _status = AppLocalizations.of(context)!.wizardJoinPassphraseWrong);
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _status = AppLocalizations.of(context)!.setupPageEscrowFailed('$e'));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runJoinAccess() async {
    final kp = _keyPair;
    if (kp == null) return;
    // 口令已在口令页（步骤 3）验证通过（_verifyJoinPassphrase），这里仅设锁/完成
    final passphrase = _escrowPassphrase.text.trim();
    if (_pinSkipped) {
      if (!mounted) return;
      await AppLockService(widget.db ?? LocalDatabase()).savePlain(AppLockPayload(
        server: _server,
        spaceId: _spaceId.text,
        deviceId: _enroll!.deviceId,
        spaceKeyB64: base64Encode(_spaceKey!),
        keyVersion: _joinKeyVersion,
        token: _sessionToken!,
        escrowPassphrase: passphrase,
      ));
      _completeWizard();
      return;
    }
    final ok = await _setupLockAndEnter(
      server: _server,
      spaceId: _spaceId.text,
      deviceId: _enroll!.deviceId,
      spaceKeyB64: base64Encode(_spaceKey!),
      keyVersion: _joinKeyVersion,
      token: _sessionToken!,
      escrowPassphrase: passphrase,
    );
    if (!mounted) return;
    if (ok) {
      _completeWizard();
    }
  }

  // ---- 场景 C（offline）：密保信封导入 ----

  /// 步骤 1（offline）：粘贴密保信封（对方用本设备公钥密封的 Space Key）。
  /// 同时需填写一次性邀请码（非首台设备必须凭码登记后才能认证）。
  Widget _buildStepEnvelope() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitleEnvelope, l10n.setupPageEnvelopeKeyHint),
        TextField(
          controller: _envelopeKey,
          style: const TextStyle(fontSize: 18),
          maxLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
        // 邀请码已在 join 步骤 2 提供（offline 从 join 口令页切换进入时沿用
        // 已填邀请码登记），此页不再重复显示输入框
        const SizedBox(height: 16),
        // 与口令页的「改用线下密保信封导入」对称：口令/信封是平行方案可互切；
        // 切回口令页保留已输入的口令与邀请码，任一完成都进入 PIN 步骤
        TextButton.icon(
          onPressed: _switchToPassphrase,
          icon: const Icon(Icons.password, size: 18),
          label: Text(l10n.wizardSwitchToPassphrase),
        ),
      ],
    );
  }

  /// 从口令页切到密保信封页（offline 步骤 1）：记录来源角色/步骤，便于
  /// 信封页「改用线上密保口令」切回原地（create 步骤 2 / join 步骤 3）。
  /// 不用 _selectRole（它重置步骤到目标角色步骤 1 且不记来源）。
  void _openEnvelopeImport() {
    setState(() {
      _preEnvelopeRole = _role ?? _WizardRole.join; // 口令页可见时角色必已判定
      _role = _WizardRole.offline;
      _step = 1;
      _localError = null;
    });
  }

  /// 从密保信封页切回「口令」页（回到进入信封页前的角色：create 步骤 2 / join 步骤 3）。
  /// 不能用 _selectRole（它会重置 _step=1 回身份页）；直接切角色+步骤，
  /// 已输入的邀请码/口令保留，任一方案完成都进入 PIN 步骤。
  void _switchToPassphrase() {
    setState(() {
      _role = _preEnvelopeRole;
      _step = _preEnvelopeRole == _WizardRole.create ? 2 : 3;
      _status = null;
      _localError = null;
    });
  }

  /// offline 信封页（步骤 1）「验证密保信封」：登记 → 用本设备私钥解封信封——
  /// 解出合法 Space Key 才放行进 PIN 步骤；无效信封提示并停留本页。
  Future<bool> _verifyEnvelope() async {
    final kp = _keyPair;
    if (kp == null) return false;
    final envelopeRaw = _envelopeKey.text.trim();
    if (envelopeRaw.isEmpty) {
      setState(() => _localError = AppLocalizations.of(context)!.setupPagePasteEnvelope);
      return false;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      // 1) 凭邀请码登记（offline 从 join 口令页切换进入时已登记，跳过）
      if (_enroll == null) {
        await _enrollDevice(_inviteCode.text.trim());
      }
      // 2) 用本设备私钥解封 Space Key：解密失败 = 信封无效 → 不通过
      final s = await sodium();
      final spaceKey = await sealOpen(
        s,
        base64Decode(envelopeRaw),
        kp.publicKey,
        kp.privateKey,
      );
      _spaceKey = spaceKey;
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _status = AppLocalizations.of(context)!.wizardEnvelopeWrong);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// offline：信封已在信封页（步骤 1）验证解封（_verifyEnvelope），
  /// 这里仅认证/设锁/完成（Space Key 已存 _spaceKey）。
  Future<void> _runEnvelopeImport() async {
    final kp = _keyPair;
    if (kp == null) return;
    final enroll = _enroll!;
    // 认证（用登记后的真实 deviceId；信封页验证时未认证则这里补上）
    if (_sessionToken == null) {
      final session = await _authenticate(kp, enroll.deviceId);
      _sessionToken = session.sessionToken;
    }
    if (!mounted) return;
    // 设置 PIN；确认"暂不设置"时跳过设锁：明文持久化配置（下次启动直接进聊天）
    if (_pinSkipped) {
      if (!mounted) return;
      await AppLockService(widget.db ?? LocalDatabase()).savePlain(AppLockPayload(
        server: _server,
        spaceId: enroll.spaceId,
        deviceId: enroll.deviceId,
        spaceKeyB64: base64Encode(_spaceKey!),
        keyVersion: 1,
        token: _sessionToken!,
      ));
      _completeWizard();
      return;
    }
    final ok = await _setupLockAndEnter(
      server: _server,
      spaceId: enroll.spaceId,
      deviceId: enroll.deviceId,
      spaceKeyB64: base64Encode(_spaceKey!),
      keyVersion: 1,
      token: _sessionToken!,
    );
    if (!mounted) return;
    if (ok) {
      _completeWizard();
    }
  }
}
