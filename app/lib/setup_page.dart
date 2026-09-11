import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  const SetupPage({
    super.key,
    this.db,
    this.probeServer,
    this.preflightOverride,
    this.joinOverride,
    this.createOverride,
    this.enrollOverride,
    this.createInviteOverride,
    this.authOverride,
    this.keyPairOverride,
    this.escrowOverride,
  });

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  /// 服务器探测回调（测试注入 fake 保 golden 稳定）；默认用真实 ServerSettings.probe。
  /// Multiverse：返回 (能连, 协议版本, 能力清单)——/health 不再返回 person 表，
  /// 角色改由空间入口页让用户选择。
  final Future<(bool, String, List<String>)> Function(String server)? probeServer;

  /// Multiverse join preflight 注入（测试用；默认真实 ApiClient.preflightJoin）。
  final Future<SpaceJoinPreflight> Function(String token)? preflightOverride;

  /// Multiverse join 提交注入（测试用；默认真实 ApiClient.joinSpace）。
  final Future<SpaceJoinResult> Function(String token)? joinOverride;

  /// Multiverse create 提交注入（测试用；默认真实 ApiClient.createSpace）。
  final Future<SpaceCreateResult> Function()? createOverride;

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
  String? _myGender; // create 步骤 1：我的性别（'male'/'female'，登记时随 person_name 同步服务端）
  String? _genderError; // 性别未选提醒（红字显示在选项卡下方；选中即清除）
  final _partnerNameCtrl = TextEditingController(); // create 步骤 2：伴侣（第二人）名字（必填）
  String? _partnerGender; // create 步骤 2：伴侣性别（'male'/'female'，必选）
  String? _partnerGenderError; // 伴侣性别未选提醒
  List<SpaceMemberSlot> _joinSlots = const []; // join：preflight 返回的两身份 slot（身份选择页展示）
  int? _chosenSlot; // join 步骤 2：所选身份（0=第一人/创建者，1=第二人/伴侣）
  String? _slotError; // 身份未选提醒
  final _spaceId = TextEditingController(); // 真实 spaceId（enroll/扫码/托管返回后填入）
  final _envelopeKey = TextEditingController();
  final _escrowPassphrase = TextEditingController();
  final _pin = TextEditingController(); // 启动锁 PIN（内嵌表单，不再弹窗）
  final _confirm = TextEditingController();
  String? _pinError; // PIN 步骤红色提示（输入框下方）
  bool _pinSkipped = false; // 用户确认"不设置锁屏码"：跳过 setPin，仍完成前置并进下一步
  final _inviteCode = TextEditingController(); // 加入/导入设备时的一次性邀请码
  // Multiverse join：preflight 验证通过的 token（后续步骤/最终提交用）与
  // 空间显示名（进入聊天页的对方名字）
  String _joinToken = '';
  String? _joinSpaceName;
  String? _createLink; // Multiverse create：空间邀请链接（完成页展示分享）

  // 服务器地址：默认 einz.tic.cc；探测失败由自动重试兜底（启动屏不展示输入框）
  String _server = kEinzServer;
  bool _probeFailed = false;
  bool _probeDone = false; // 探测已成功（区分"探测中"与"已就绪"——入口页显示条件）
  bool _legacyServer = false; // Multiverse：服务器协议版本不支持 spaces（旧 v1 服务器）
  Timer? _probeRetryTimer; // 探测失败后的自动重试定时器（连上即停止并自动进入）

  // 向导状态：角色分流 + 步骤索引 + 跨步骤共享数据
  _WizardRole? _role;
  int _step = 0;
  DeviceKeyPair? _keyPair;
  Uint8List? _spaceKey;
  String? _sessionToken;
  int _joinKeyVersion = 1; // join 口令验证时记录的 Space Key 版本（_verifyJoinPassphrase 填充）
  String? _status; // 后台报告的错误提示（红字，显示在底部按钮下方）
  String? _localError; // 本地校验错误提示（红字，显示在输入框下方）
  bool _busy = false;

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
  /// Multiverse：探测成功不再按 /health person 表自动判定 create/join——停留
  /// 在空间入口页由用户选择（新建空间 / 输入邀请链接加入）；旧服务器
  /// （protocol_version 非 multiverse）标记 _legacyServer 提示升级。
  /// 无法连接 → 显示输入框引导覆盖（降低小白负担）。
  Future<void> _initServer() async {
    try {
      final db = widget.db ?? LocalDatabase();
      final settings = ServerSettings(db);
      final saved = await settings.load();
      final probe = widget.probeServer ?? ServerSettings.probe;
      final (ok, pv, caps) = await probe(saved);
      if (!mounted) return;
      setState(() {
        _server = saved;
        _probeFailed = !ok;
        _probeDone = ok;
        _legacyServer = ok && !pv.contains('multiverse');
        if (ok && _role == null) {
          _step = 0; // 入口页（角色由用户选择）
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
    final (ok, pv, caps) = await probe(_server);
    if (!mounted) return;
    if (ok) {
      _probeRetryTimer?.cancel();
      _probeRetryTimer = null;
      setState(() {
        _probeFailed = false;
        _probeDone = true;
        _legacyServer = !pv.contains('multiverse');
        if (_role == null) _step = 0; // 入口页（角色由用户选择）
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
    // 探测中/失败（角色未判定）→ 品牌启动屏——全屏粉蓝渐变 + 上半部旋转 Logo
    // （无文字）；无 AppBar/菜单/服务器输入框（老板决策 2026-09-08）。
    // 探测成功但角色未选（Multiverse 入口页）不在此列——走下方 Scaffold，
    // 由 _buildStep 显示空间入口页（新建/加入选择）。
    if (_role == null && !_probeDone) return _buildSplashScreen();
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
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                // 卡片按内容自适应高度，不预先拉长（老板要求 2026-09-09）：
                                // 有后台报错时卡片仅多出一行红字，Flexible 保证内容超高时
                                // 仍可滚动而不溢出
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: SingleChildScrollView(child: _buildStep()),
                                  ),
                                  // 后台报告的错误提示（红字）固定在卡片最下方：
                                  // 白底上清晰可读（渐变背景上对比不足看不清）
                                  if (_status != null) ...[
                                    const SizedBox(height: 12),
                                    Text(
                                      _status!,
                                      style: const TextStyle(
                                        color: Colors.red,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // 底部导航：角色判定后常显（含异常退到检测页 _step==0 的兜底——
                // 此时也有"下一步"可回到步骤 1，杜绝无路可走）。
                // Multiverse join 步骤 1（token 页）也显示"下一步"——触发 preflight
                // 校验（v1 身份卡点击自动前进的例外已随身份页删除而移除）。
                if (_role != null)
                  Row(
                    children: [
                      // 第 1 页（选择页）无上一步；步骤 1（create=关于我 / join=邀请码）
                      // 起可回退——步骤 1 回到第 1 页选择页（老板 2026-09-11）；
                      // 信封页（offline 步骤 1）回退到 join 口令页（_backStep 内处理）
                      TextButton(
                        onPressed: _step >= 1 ? _backStep : null,
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
                      if (_step < _stepCount)
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
        return 6; // name/partner/passphrase/pin/done（伴侣名字/性别必填，老板 2026-09-10 定稿）
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

  /// 进度圆点指示器：共 5 点 = 第 1 页空间入口页（角色选择）+ 4 个向导内容步骤
  /// （create/join 内容步数相同；老板 2026-09-11：入口页也计为一个点，且第 2 页
  /// 可"上一步"返回选择页）。角色未选（入口页）时同样显示，仅首点亮。
  /// 信封模式（offline）是 join 流程内口令页的平行替代：进度条按 join 展示，
  /// 信封与口令处于同一位置（join 步骤 3），不缩成 2 点（老板要求 2026-09-09）。
  Widget _buildProgressDots() {
    // offline 的角色/步映射：1→3（口令位=信封位）、2→4（PIN）、3→5（完成）
    final progressStep = _role == _WizardRole.offline ? _step + 2 : _step;
    // 圆点 i 对应页面 _step == i（i=0 为入口页）：已到达（含当前）纯白，未到半透明
    const total = 5;
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
              color: i <= progressStep ? Colors.white : Colors.white54,
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
      _genderError = null;
    });
  }

  Future<void> _nextStep() async {
    final l10n = AppLocalizations.of(context)!;
    // 每轮「下一步」：先把所有红字清空，再统一检查当前页所有输入元素——名字/性别
    // 等各自独立提示（不因第一个未过就跳过其余）；本地可检测的错误 → _localError/
    // _genderError/_pinError（红字在输入框/选项卡下方）；后台/网络错误 → _status
    // （红字在按钮下方）。旧错误一律不残留（老板要求 2026-09-09）。
    setState(() {
      _localError = null;
      _genderError = null;
      _pinError = null;
      _status = null;
    });
    // ---- 本地校验：收集当前页所有失败，任一失败即停留本页 ----
    String? localError;
    String? genderError;
    var invalid = false;
    // 名字+性别页（create 步骤 1——Multiverse join 改为身份选择页，不再自填名字）
    if (_role == _WizardRole.create && _step == 1) {
      if (_personName.text.trim().isEmpty) {
        localError = l10n.wizardNameRequired;
        invalid = true;
      }
      if (_myGender == null) {
        genderError = l10n.wizardGenderRequired;
        invalid = true;
      }
    }
    // 身份选择页（join 步骤 2）：必须选择是哪一个用户（老板 2026-09-10 定稿）
    String? slotError;
    if (_role == _WizardRole.join && _step == 2) {
      if (_chosenSlot == null) {
        slotError = l10n.wizardSlotRequired;
        invalid = true;
      }
    }
    // 伴侣页（create 步骤 2）：名字与性别都必填（老板 2026-09-10 定稿——
    // create 录入两人身份，join 时按身份选择而非自填名字）
    String? partnerGenderError;
    if (_role == _WizardRole.create && _step == 2) {
      if (_partnerNameCtrl.text.trim().isEmpty) {
        localError = l10n.wizardPeerNameRequired;
        invalid = true;
      }
      if (_partnerGender == null) {
        partnerGenderError = l10n.wizardGenderRequired;
        invalid = true;
      }
    }
    if ((_role == _WizardRole.create && _step == 3) ||
        (_role == _WizardRole.join && _step == 3)) {
      if (_escrowPassphrase.text.trim().isEmpty) {
        // 两套错误提示：首设备「必须设置」/ 后续设备「验证」语气（老板要求）
        localError = _role == _WizardRole.join
            ? l10n.wizardJoinPassphraseRequired
            : l10n.setupPageNeedPassphrase;
        invalid = true;
      }
    }
    if (_role == _WizardRole.offline && _step == 1 && _envelopeKey.text.trim().isEmpty) {
      localError = l10n.setupPagePasteEnvelope;
      invalid = true;
    }
    if (invalid) {
      setState(() {
        _localError = localError;
        _genderError = genderError;
        _partnerGenderError = partnerGenderError;
        _slotError = slotError;
      });
      return;
    }
    // ---- 后台即时校验（失败停留本页；错误走 _status 红字） ----
    // Multiverse join 第一步（token 页）：token 必须有效（preflight 不消费）
    // 才放行——每次点「下一步」都按当前输入重新校验（从后面页面回退到本页后，
    // 即使输入文字被修改也会重发后台检查，老板 2026-09-11）；通过直接进下一页，
    // 不再停留显示空间确认卡片
    if (_role == _WizardRole.join && _step == 1) {
      final ok = await _verifyJoinToken();
      if (!mounted) return;
      if (!ok) return;
    }
    // join 口令页（步骤 3）：输入口令必须与首台设备创建时一致（解密 escrow
    // 口令密保箱成功）才放行进 PIN 步骤——错误口令/未托管提示后停留本页
    if (_role == _WizardRole.join && _step == 3) {
      final verified = await _verifyJoinPassphrase();
      if (!mounted) return;
      if (!verified) return;
    }
    // offline 信封页（步骤 1）「下一步」= 回到 join 口令页（步骤 3，信封入口
    // 所在位置）：信封⇄口令互切仍由页内「改用线上密保口令」承担（老板要求 2026-09-09）
    if (_role == _WizardRole.offline && _step == 1) {
      setState(() {
        _role = _preEnvelopeRole;
        _step = 3; // join 口令页
        _status = null;
        _localError = null;
      });
      return;
    }
    // PIN 步骤（create=3 / join=4 / offline=2）：底部"下一步"触发校验/跳过确认。
    // 有效 PIN → 设锁后推进；两空 → 弹窗确认"不设置锁屏码"；其余 → 输入框下方红色提示。
    final isPinStep = (_role == _WizardRole.create && _step == 4) ||
        (_role == _WizardRole.join && _step == 4) ||
        (_role == _WizardRole.offline && _step == 2);
    if (isPinStep) {
      final pin = _pin.text;
      final confirm = _confirm.text;
      if (pin.isEmpty && confirm.isEmpty) {
        // 两空：确认是否不设置锁屏码
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
    // create 步骤 3（口令页）→ 自动自举登记（登记时上传本人+伴侣名字/性别；
    // 设备名已自动设置不再询问），成功才进口令之后的 PIN 步骤
    if (_role == _WizardRole.create && _step == 3 && _enroll == null) {
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
      // 信封页（offline 步骤 1）「上一步」：回到 join 口令页（步骤 3，信封入口
      // 所在位置）——信封是口令的平行替代（同处口令位），与「下一步」回退
      // 语义一致（老板要求 2026-09-09：信封页的上一步也要能点）
      if (_role == _WizardRole.offline && _step == 1) {
        _role = _preEnvelopeRole; // 进入信封页前必为 join
        _step = 3; // join 口令页
        _localError = null;
        _status = null;
        return;
      }
      // 各角色步骤 1（create=关于我 / join=邀请码）：回到第 1 页空间入口页
      // （清空角色重新选择创建/加入；join 的 token 相关状态一并重置，避免
      // 换角色/重进后残留旧 token 直接跳过校验）
      if (_step == 1) {
        _role = null;
        _step = 0;
        _joinToken = '';
        _joinSpaceName = null;
        _joinSlots = const [];
        _chosenSlot = null;
        _slotError = null;
        _createLink = null;
        _localError = null;
        _status = null;
        return;
      }
      // 步骤 2 及以上：逐级回退（create=名字 / join=身份 / offline=密保信封）
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
    if (_role == null || _step == 0) {
      // Multiverse：探测成功后（角色未选）显示空间入口页；探测中/失败显示启动屏
      return (_probeDone && !_probeFailed) ? _buildStepEntry() : _buildDetectAndEnvelope();
    }
    switch (_role!) {
      case _WizardRole.create:
        switch (_step) {
          case 1:
            return _buildStepName();
          case 2:
            return _buildStepPartner();
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
            return _buildStepJoinToken();
          case 2:
            return _buildStepJoinIdentity();
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

  /// 空间入口页（Multiverse：探测成功且角色未选时的第一页，老板 2026-09-10
  /// 确认）：「创建秘境」/「加入秘境」左右两张卡片（2026-09-11 改左右布局）；
  /// 旧服务器（不支持 spaces）顶部显示升级提示。
  Widget _buildStepEntry() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_legacyServer)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFE8E8),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              l10n.setupEntryLegacyServer,
              style: const TextStyle(color: Color(0xFFB3261E), fontSize: 13),
            ),
          ),
        _stepHeader(l10n.setupEntryTitle, l10n.setupEntryHint),
        const SizedBox(height: 12),
        // 左右两张卡片：创建（品牌蓝 + 锤子图标）/ 加入（品牌粉 + 门图标）；
        // 创建不用加号（易与"加入"混淆，老板 2026-09-11 改为工具/建造语义图标）
        // 注意：不能用 crossAxisAlignment.stretch——入口页包在 SingleChildScrollView
        // 里（高度无界），stretch 会抛 "BoxConstraints forces an infinite height"
        // 导致卡片不渲染（2026-09-11 真机报告）；等高由 _EntryCard 固定高度保证
        Row(
          children: [
            Expanded(
              child: _EntryCard(
                icon: Icons.build_outlined,
                label: l10n.setupEntryCreate,
                backgroundColor: const Color(0xFFE3F2FD),
                accentColor: const Color(0xFF2271F7),
                onTap: () => setState(() {
                  _role = _WizardRole.create;
                  _step = 1;
                }),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _EntryCard(
                icon: Icons.door_front_door_outlined,
                label: l10n.setupEntryJoin,
                backgroundColor: const Color(0xFFFDD6ED),
                accentColor: const Color(0xFFD6529C),
                onTap: () => setState(() {
                  _role = _WizardRole.join;
                  _step = 1;
                }),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 启动屏（角色未判定时的检测页）：全屏粉蓝品牌渐变 + 上半部旋转 Logo。
  /// 无 AppBar/菜单/服务器输入框，也不显示检测/失败文字（老板要求 2026-09-09：
  /// 保持简洁优美，位置固定在屏幕上半部分）——探测失败由自动重试兜底
  /// （每 4 秒重探，就绪即自动进入向导），全程零打扰。
  Widget _buildSplashScreen() {
    return Scaffold(
      body: Container(
        // alignment 使内部 Align 撑满全屏 → 渐变 DecoratedBox 铺满整页。
        // （Scaffold body 是宽松约束，RenderProxyBox 尺寸 = child 尺寸；若不加
        // alignment，渐变容器会缩到 Column 宽度，右侧露出背景）
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
              // 上半部（约 40% 高度）：旋转 Logo——品牌展示与加载指示二合一，
              // 与 main.dart StartupGate 同尺寸同位置，开屏即定格无跳变
              const Spacer(flex: 2),
              const SpinningBrandLogo(size: 96),
              const Spacer(flex: 3),
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
    String? publicKeyB64, // 设备公钥（b64）：随锁包持久化，重启后 reauth + 弹窗展示
    String? privateKeyB64, // 设备私钥（b64）：随锁包持久化（与 Space Key 同库同策略）
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
        publicKeyB64: publicKeyB64,
        privateKeyB64: privateKeyB64,
      );
      await AppLockService(widget.db ?? LocalDatabase()).setPin(pin, payload: payload);
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _status = l10n.setPinDialogSetupFailed('$e'));
      return false;
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
    final deviceName = await _autoDeviceName(); // 设备型号（async 主体内计算，避免在 builder 闭包 await）
    // 名字持久化：PIN 解锁/重启后 ChatPage 恢复显示（AppLockPayload 不含名字）。
    // await 确保 profile 写入完成后再进聊天（消除 unawaited 竞态——2026-09-07
    // 老板实测：设 PIN 重启解锁后顶部条丢名字）
    await AppLockService(widget.db ?? LocalDatabase()).saveProfile(
      // 本人名字：join=所选身份（create 预置）；create=自填
      personName: _role == _WizardRole.join ? _joinSelectedName : _personName.text.trim(),
      // 对方名字：join=创建者名字（preflight 空间显示名）；create=伴侣名字（预置）
      peerName: _role == _WizardRole.join ? (_joinSpaceName ?? '') : _partnerNameCtrl.text.trim(),
      deviceName: deviceName,
      // 本人性别：join=所选身份性别；create=自填
      myGender: _role == _WizardRole.join ? _joinSelectedGender : (_myGender ?? ''),
      // 对方性别：无公开渠道（气泡配色回退默认）
      peerGender: '',
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
        personName: _role == _WizardRole.join ? _joinSelectedName : _personName.text.trim(),
        personId: enroll.personId,
        // 对方名字：join=创建者名字（preflight 空间显示名）；create=伴侣名字（预置）
        peerName: _role == _WizardRole.join ? (_joinSpaceName ?? '') : _partnerNameCtrl.text.trim(),
        deviceName: deviceName,
        publicKeyB64: kp.publicKeyB64,
        privateKeyB64: kp.privateKeyB64,
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
          // 开始填写即清除「名字为空」红字（不依赖再点下一步）
          onChanged: (_) {
            if (_localError != null) setState(() => _localError = null);
          },
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
          onChanged: (g) => setState(() {
            _myGender = g;
            _genderError = null; // 选中即清除未选提醒
          }),
        ),
        if (_genderError != null) _localErrorHint(_genderError!), // 性别必选：未选红字提醒
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

  /// 步骤 2（create，Multiverse）：伴侣（第二人）的名字/性别——必填（老板
  /// 2026-09-10 定稿：create 录入两人身份，join 时按身份选择而非自填名字）。
  Widget _buildStepPartner() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitlePeerName, l10n.wizardPeerNameHint),
        TextField(
          controller: _partnerNameCtrl,
          style: const TextStyle(fontSize: 20),
          onChanged: (_) {
            if (_localError != null) setState(() => _localError = null);
          },
          decoration: InputDecoration(
            hintText: l10n.wizardPeerNameHintInput,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
        const SizedBox(height: 20),
        _buildGenderSelector(
          selected: _partnerGender,
          label: l10n.wizardPeerGenderLabel,
          maleLabel: l10n.wizardGenderMale,
          femaleLabel: l10n.wizardGenderFemale,
          onChanged: (g) => setState(() {
            _partnerGender = g;
            _partnerGenderError = null; // 选中即清除未选提醒
          }),
        ),
        if (_partnerGenderError != null) _localErrorHint(_partnerGenderError!),
      ],
    );
  }

  /// 步骤 2（join，Multiverse）：选择「你是哪一个用户」——create 已录入两人
  /// 身份（preflight slots），加入者可能是第二人，也可能是第一人的其他设备，
  /// 不能靠名字判别身份，必须显式选择（老板 2026-09-10 定稿）。
  Widget _buildStepJoinIdentity() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.wizardTitleJoinIdentity, l10n.wizardJoinIdentityHint),
        if (_joinSlots.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              l10n.wizardJoinNoSlots,
              style: const TextStyle(fontSize: 14),
            ),
          )
        else
          for (final s in _joinSlots)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildSelectableCard(
                label: '${s.displayName ?? '（未命名）'}'
                    '${s.gender != null ? '（${_genderDisplay(s.gender!)}）' : ''}'
                    '${s.status == 'active' ? ' ${l10n.wizardSlotOnline}' : ''}',
                icon: s.slot == 0 ? Icons.person : Icons.person_outline,
                color: const Color(0xFF3BAFFD),
                selected: _chosenSlot == s.slot,
                alignment: Alignment.center,
                onTap: () => setState(() {
                  _chosenSlot = s.slot;
                  _slotError = null; // 选中即清除未选提醒
                }),
              ),
            ),
        if (_slotError != null) _localErrorHint(_slotError!),
      ],
    );
  }

  /// 服务端 gender 兼容中英文代码（CLI 传'男/女'、App 传'male/female'）→ 显示中文。
  String _genderDisplay(String g) =>
      (g == 'male' || g == '男') ? '男' : (g == 'female' || g == '女') ? '女' : g;

  /// join 所选身份（create 预置）的名字——本人在消息流里的显示名。
  String get _joinSelectedName {
    if (_chosenSlot == null) return '';
    for (final s in _joinSlots) {
      if (s.slot == _chosenSlot) return s.displayName ?? '';
    }
    return '';
  }

  /// join 所选身份的性别（服务端中英文 → App 'male'/'female'，气泡配色用）。
  String get _joinSelectedGender {
    if (_chosenSlot == null) return '';
    for (final s in _joinSlots) {
      if (s.slot == _chosenSlot) {
        final g = s.gender;
        if (g == null || g.isEmpty) return '';
        return (g == 'male' || g == '男')
            ? 'male'
            : (g == 'female' || g == '女')
                ? 'female'
                : g;
      }
    }
    return '';
  }

  /// 步骤 1（join，Multiverse）：输入邀请链接或 token（粘贴/扫码）。
  /// 「下一步」每次按当前输入 preflight 校验：通过直接进下一页，失败红字停留
  /// （不再显示空间确认卡片，老板 2026-09-11）。
  Widget _buildStepJoinToken() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stepHeader(l10n.setupTokenTitle, l10n.setupTokenHint),
        TextField(
          controller: _inviteCode,
          style: const TextStyle(fontSize: 20),
          // 开始填写即清除红字（不依赖再点下一步）
          onChanged: (_) {
            if (_localError != null) setState(() => _localError = null);
          },
          decoration: InputDecoration(
            hintText: l10n.setupTokenInputHint,
            border: const OutlineInputBorder(),
            // 扫码填入邀请链接/token（扫中后自动填入并自动下一步验证）
            suffixIcon: IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: l10n.setupPageScanInvite,
              onPressed: _scanInviteCode,
            ),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
      ],
    );
  }

  /// join 第一步 token 校验：POST /spaces/join/preflight（不消费 token）。
  /// 成功 → 记录 token/身份 slots（供后续步骤与最终 join 提交）并放行；失败 →
  /// 错误码映射红字（TOKEN_INVALID/EXPIRED/USED/SPACE_FULL，
  /// PROTOCOL_MULTIVERSE.md §6），停留本页。displayName 保留为进入聊天页的
  /// 对方名字（peerName，不再是确认卡片文案）。
  Future<bool> _verifyJoinToken() async {
    final raw = _inviteCode.text.trim();
    if (raw.isEmpty) {
      setState(() => _localError = AppLocalizations.of(context)!.setupTokenNeedInput);
      return false;
    }
    // 兼容完整邀请链接：https://einz.tic.cc/join/<token> → 提取 token
    final token = raw.contains('/join/') ? raw.split('/join/').last.trim() : raw;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final pre = await (widget.preflightOverride?.call(token) ??
          ApiClient(_server).preflightJoin(token));
      if (!mounted) return false;
      setState(() {
        _joinToken = token;
        _joinSpaceName = pre.displayName;
        _joinSlots = pre.slots; // 身份选择页（步骤 2）展示两身份
        _chosenSlot = null; // 换 token 后重置身份选择
        _localError = null;
      });
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      setState(() {
        _joinToken = '';
        _localError = _tokenErrorText(e.code);
      });
      return false;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _status = AppLocalizations.of(context)!.setupPageInitFailed);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 错误码 → 中文提示（PROTOCOL_MULTIVERSE.md §6 错误码表）。
  String _tokenErrorText(String code) {
    final l10n = AppLocalizations.of(context)!;
    switch (code) {
      case 'TOKEN_EXPIRED':
        return l10n.setupTokenExpired;
      case 'TOKEN_USED':
        return l10n.setupTokenUsed;
      case 'SPACE_FULL':
        return l10n.setupTokenSpaceFull;
      default:
        return l10n.setupTokenInvalid;
    }
  }

  /// 邀请码页扫码入口（老板要求 2026-09-10）：扫码后自动填入邀请码并自动
  /// 下一步（复用「下一步」的服务端校验——码无效则提示并停留本页）。
  Future<void> _scanInviteCode() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _InviteScannerPage()),
    );
    if (code == null || code.trim().isEmpty || !mounted) return;
    _inviteCode.text = code.trim();
    if (_localError != null) setState(() => _localError = null);
    await _nextStep();
  }

  /// 客户端生成 space_id（UUIDv4，协议 §3.4：space_id/space_key 由客户端生成——
  /// 口令密封包内容需含 space_id）。
  String _newSpaceId() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// create：Multiverse 创建空间（POST /spaces：创建者登记 + session + 首个
  /// join token 一并返回）。Space Key 由客户端生成，用口令加密成 sealed 包
  /// 随创建提交（服务端只存密文）；创建者可立即进聊天。
  Future<void> _runBootstrap() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final kp = _keyPair;
      if (kp == null) return;
      // 客户端生成 space_id + Space Key（协议 §3.4）
      final spaceId = _newSpaceId();
      _spaceKey ??= Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)));
      final api = ApiClient(_server);
      final passphrase = _escrowPassphrase.text.trim();
      final sealed = passphrase.isEmpty
          ? null
          : await KeyEscrowService(api).createPackage(
              passphrase: passphrase,
              spaceKeyB64: base64Encode(_spaceKey!),
              spaceId: spaceId,
              keyVersion: 1,
            );
      final created = await (widget.createOverride?.call() ??
          api.createSpace(
            spaceId: spaceId,
            displayName: _personName.text.trim(),
            gender: _myGender,
            partnerName: _partnerNameCtrl.text.trim(),
            partnerGender: _partnerGender,
            sealedSpaceKey: sealed,
            escrowPassphrase: passphrase.isEmpty ? null : passphrase,
            publicKey: kp.publicKeyB64,
            deviceName: await _autoDeviceName(),
          ));
      if (!mounted) return;
      _sessionToken = created.sessionToken;
      _enroll = EnrollResult(
        deviceId: created.deviceId,
        personId: created.creatorPersonId,
        spaceId: created.spaceId,
      );
      // 此前 create 流程漏填 _spaceId.text（仅 join/offline 填写）→ ChatPage 拿空
      // spaceId → 聊天页生成邀请码 POST /spaces//join-tokens 报 SPACE_NOT_FOUND
      // （2026-09-11 老板真机报告）；与 join 对齐补填服务端返回的 spaceId
      _spaceId.text = created.spaceId;
      _createLink = created.link; // 完成页展示空间邀请链接
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _bootstrapFailed = e.code == 'INVALID_REQUEST';
        // 空间数量上限：明确禁止提示（config.json maxSpaces——老板 2026-09-10）
        _status = e.code == 'SPACE_LIMIT_REACHED'
            ? AppLocalizations.of(context)!.wizardSpaceLimit
            : AppLocalizations.of(context)!.wizardEnrollFailed('$e');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.wizardEnrollFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 性别选择：左蓝（男）/右粉（女）两个卡片，与品牌色一致；选中者放大 +
  /// 横向扩展覆盖相邻卡（_buildCardPair），未选中压缩半透明。
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
        _buildCardPair(
          leftCard: _buildSelectableCard(
            label: maleLabel,
            icon: Icons.male,
            color: const Color(0xFF3BAFFD), // 左：品牌天蓝
            selected: selected == 'male',
            alignment: Alignment.centerLeft, // 锚左外缘：选中向右扩展覆盖粉色卡
            onTap: () => onChanged(selected == 'male' ? null : 'male'),
          ),
          rightCard: _buildSelectableCard(
            label: femaleLabel,
            icon: Icons.female,
            color: const Color(0xFFD6529C), // 右：品牌粉
            selected: selected == 'female',
            alignment: Alignment.centerRight, // 锚右外缘：选中向左扩展覆盖蓝色卡
            onTap: () => onChanged(selected == 'female' ? null : 'female'),
          ),
          leftSelected: selected == 'male',
          rightSelected: selected == 'female',
        ),
      ],
    );
  }

  /// 双卡片选择容器：两卡各占半宽（中间留 12 空隙，左右外缘与表单标签/输入框
  /// 对齐）；被选中的卡片最后绘制——选中卡片以非等比 Transform 从外缘锚点横向
  /// 扩展覆盖相邻未选中卡片（性别选择与身份选择共用）。
  Widget _buildCardPair({
    required Widget leftCard,
    required Widget rightCard,
    required bool leftSelected,
    required bool rightSelected,
  }) {
    return SizedBox(
      height: 92, // 卡片增高：容纳放大后的名字（20 号）+ 头像图标，防内容溢出（老板要求字号放大）
      child: LayoutBuilder(
        builder: (context, c) {
          final half = (c.maxWidth - 12) / 2; // 两卡各占半宽，中间留 12 空隙
          Widget slot(Widget child, bool left) => Positioned(
                left: left ? 0 : half + 12,
                width: half,
                top: 0,
                bottom: 0,
                child: child,
              );
          // 被选中的最后绘制：横向扩展时压在相邻未选中卡片之上
          final children = leftSelected
              ? [slot(rightCard, false), slot(leftCard, true)]
              : [slot(leftCard, true), slot(rightCard, false)];
          return Stack(clipBehavior: Clip.none, children: children);
        },
      ),
    );
  }

  /// 可选中卡片：品牌色背景 + 白字图标/标签；选中放大 + 横向扩展（锚点在外侧，
  /// 覆盖相邻未选中卡片）+ 阴影；未选中压缩半透明；切换时大小/颜色/阴影渐变。
  Widget _buildSelectableCard({
    required String label,
    required IconData icon,
    required Color color,
    required bool selected,
    required Alignment alignment, // 缩放锚点：靠外侧边，选中时向相邻卡片扩展
    required VoidCallback onTap,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: selected ? 1 : 0),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOutCubic,
      // 未选中（t=0）→ 选中（t=1）整体渐变：大小（0.9 → 纵向 1.15 + 横向 1.35）、
      // 颜色（半透明 → 不透明）、阴影（0 → 4）同步缓动；锚点在外侧覆盖相邻卡片
      builder: (context, t, _) => Transform(
        alignment: alignment,
        transform: Matrix4.diagonal3Values(
          0.9 + 0.45 * t,
          0.9 + 0.25 * t,
          1,
        ),
        child: Material(
          color: Color.lerp(color.withValues(alpha: 0.35), color, t),
          elevation: 4 * t,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              alignment: Alignment.center, // 卡片撑满槽位后内容垂直居中
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14), // 无描边（老板：白边累赘），选中靠阴影+放大区分
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 26),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20, // 名字字号放大（老板要求：放大再放大）
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
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
        // 标题行右侧：密保信封⇄口令互切图标（老板要求 2026-09-10，替代原下方
        // 文字链接；仅后续设备 join 适用——首台设备无对端可导出密封信封）
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 两套标题：首设备「设置密保口令」/ 后续设备「验证密保口令」（老板要求）
            Expanded(
              child: _stepHeader(
                _role == _WizardRole.join
                    ? l10n.wizardJoinPassphraseTitle
                    : l10n.wizardTitlePassphrase,
                _role == _WizardRole.join
                    ? l10n.wizardJoinPassphraseHint
                    : l10n.wizardPassphraseHint,
              ),
            ),
            if (_role == _WizardRole.join)
              _DogEarSwitch(
                icon: Icons.mail_outline,
                tooltip: l10n.wizardSwitchToEnvelope,
                onTap: _openEnvelopeImport,
              ),
          ],
        ),
        TextField(
          controller: _escrowPassphrase,
          style: const TextStyle(fontSize: 20),
          obscureText: true,
          // 开始填写即清除「口令为空」红字（不依赖再点下一步）
          onChanged: (_) {
            if (_localError != null) setState(() => _localError = null);
          },
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
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
          // 开始填写即清除 PIN 红字（不依赖再点下一步）
          onChanged: (_) {
            if (_pinError != null) setState(() => _pinError = null);
          },
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
          // 开始填写即清除 PIN 红字（不依赖再点下一步）
          onChanged: (_) {
            if (_pinError != null) setState(() => _pinError = null);
          },
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
      // 3) 口令（Multiverse：sealed 包已随 POST /spaces 提交，无需再上传托管；
      // 口令仅用于 AppLockPayload 持久化）
      final pass = _escrowPassphrase.text.trim();
      // 4) 设置 PIN；确认"不设置锁屏码"时跳过设锁：明文持久化配置（下次启动直接进聊天）
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
          publicKeyB64: kp.publicKeyB64,
          privateKeyB64: kp.privateKeyB64,
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
        publicKeyB64: kp.publicKeyB64,
        privateKeyB64: kp.privateKeyB64,
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.welcomeDialogMessage),
            // Multiverse：create 完成后展示空间邀请链接（分享给伴侣加入）
            if (isCreate && _createLink != null) ...[
              const SizedBox(height: 12),
              Text(
                l10n.setupCreateShareTitle,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _createLink!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF2271F7)),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: l10n.setupCreateCopy,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _createLink!));
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(l10n.setupCreateCopied),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
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

  /// join 口令页（步骤 3）「验证接入口令」：join 提交（POST /spaces/join——
  /// 设备登记 + session 签发）→ 口令 escrow 取 Space Key，口令与首台设备创建时
  /// 一致（解密成功）才放行进 PIN 步骤。
  Future<bool> _verifyJoinPassphrase() async {
    final kp = _keyPair;
    if (kp == null) return false;
    final passphrase = _escrowPassphrase.text.trim();
    if (passphrase.isEmpty) {
      setState(() => _localError = AppLocalizations.of(context)!.wizardJoinPassphraseRequired);
      return false;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      // Multiverse：join 提交（POST /spaces/join——设备登记 + session 签发，
      // 绑定该 Space；token 已在第一步 preflight 验证，此处真正消费）
      final api = ApiClient(_server);
      final join = await (widget.joinOverride?.call(_joinToken) ??
          api.joinSpace(
            token: _joinToken,
            publicKey: kp.publicKeyB64,
            partnerSlot: _chosenSlot, // 身份选择（0=第一人/创建者，1=第二人/伴侣）
            deviceName: await _autoDeviceName(),
          ));
      if (!mounted) return false;
      _sessionToken = join.sessionToken;
      _enroll = EnrollResult(
        deviceId: join.deviceId,
        personId: join.personId,
        spaceId: join.spaceId,
      );
      // 口令取 Space Key（POST /spaces/{id}/key-escrow——口令正确才返回；
      // escrowOverride 可注入 fake，与 v1 fetch 同边界）
      final file = await (widget.escrowOverride?.call(_server) ?? KeyEscrowService(api))
          .fetchSpaceEscrow(join.spaceId, passphrase);
      if (!mounted) return false;
      if (file == null) {
        setState(() => _status = AppLocalizations.of(context)!.setupPageNoEscrow);
        return false;
      }
      final payload = await (widget.escrowOverride?.call(_server) ?? KeyEscrowService(api))
          .openPackage(passphrase: passphrase, file: file);
      if (!mounted) return false;
      _spaceKey = base64Decode(payload.spaceKeyB64);
      _spaceId.text = join.spaceId;
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
        publicKeyB64: kp.publicKeyB64,
        privateKeyB64: kp.privateKeyB64,
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
      publicKeyB64: kp.publicKeyB64,
      privateKeyB64: kp.privateKeyB64,
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
        // 标题行右侧：密保信封⇄口令互切图标（老板要求 2026-09-10，替代原下方
        // 文字链接；切回口令页保留已输入的口令与邀请码，任一完成都进入 PIN 步骤）
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _stepHeader(
                  l10n.wizardTitleEnvelope, l10n.setupPageEnvelopeKeyHint),
            ),
            _DogEarSwitch(
              icon: Icons.password,
              tooltip: l10n.wizardSwitchToPassphrase,
              onTap: _switchToPassphrase,
            ),
          ],
        ),
        TextField(
          controller: _envelopeKey,
          style: const TextStyle(fontSize: 18),
          maxLines: 3,
          // 开始填写即清除「信封为空」红字（不依赖再点下一步）
          onChanged: (_) {
            if (_localError != null) setState(() => _localError = null);
          },
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
        ),
        if (_localError != null) _localErrorHint(_localError!),
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

  /// offline：信封导入路径——认证/设锁/完成（Space Key 已存 _spaceKey）。
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
    // 设置 PIN；确认"不设置锁屏码"时跳过设锁：明文持久化配置（下次启动直接进聊天）
    if (_pinSkipped) {
      if (!mounted) return;
      await AppLockService(widget.db ?? LocalDatabase()).savePlain(AppLockPayload(
        server: _server,
        spaceId: enroll.spaceId,
        deviceId: enroll.deviceId,
        spaceKeyB64: base64Encode(_spaceKey!),
        keyVersion: 1,
        token: _sessionToken!,
        publicKeyB64: kp.publicKeyB64,
        privateKeyB64: kp.privateKeyB64,
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
      publicKeyB64: kp.publicKeyB64,
      privateKeyB64: kp.privateKeyB64,
    );
    if (!mounted) return;
    if (ok) {
      _completeWizard();
    }
  }
}

/// 邀请码扫码页：全屏相机预览，识别到二维码即返回其内容（自动填入与自动
/// 下一步由调用方 [_SetupPageState._scanInviteCode] 完成）。识别后立即关闭，
/// 未识别到时右上角 ✕ 取消返回。
class _InviteScannerPage extends StatefulWidget {
  const _InviteScannerPage();

  @override
  State<_InviteScannerPage> createState() => _InviteScannerPageState();
}

class _InviteScannerPageState extends State<_InviteScannerPage> {
  bool _resolved = false; // 防抖：连续帧重复识别只回传一次

  void _onDetect(BarcodeCapture capture) {
    if (_resolved) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) {
        _resolved = true;
        Navigator.of(context).pop(value.trim());
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.setupPageScanInvite),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(onDetect: _onDetect),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l10n.setupPageScannerHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// 表单右上角「折角切换块」（老板要求 2026-09-10）：右上角斜切（狗耳朵折角），
/// 折角背后露出品牌粉——类似登录页手机/邮件登录互换、二维码/输入框登录互换的
/// 切换样式，比纯图标更生动。
class _DogEarSwitch extends StatelessWidget {
  const _DogEarSwitch({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  static const double _cut = 14; // 折角斜切边长（等腰直角三角形）

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            children: [
              // 折角背面：斜切三角形区域露出品牌粉（折角翻起效果）
              const Positioned.fill(child: ColoredBox(color: Color(0xFFD6529C))),
              // 主体矩形：右上角斜切，白底细描边 + 切换图标居中
              Positioned.fill(
                child: ClipPath(
                  clipper: const _DogEarClipper(_cut),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0xFFE9D5E0)),
                    ),
                    child: Icon(icon, size: 22, color: const Color(0xFF33415A)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右上角斜切（狗耳朵/折角）路径：右上角切掉边长 [cut] 的等腰直角三角形。
class _DogEarClipper extends CustomClipper<Path> {
  const _DogEarClipper(this.cut);

  final double cut;

  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width - cut, 0)
      ..lineTo(size.width, cut)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(_DogEarClipper oldClipper) => oldClipper.cut != cut;
}

/// 空间入口页的选择卡片：大图标 + 名称，点按选择「创建秘境 / 加入秘境」。
/// 浅色品牌底 + 品牌色图标/文字，两张卡片左右并排（老板 2026-09-11）。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.accentColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          height: 132,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 44, color: accentColor),
                const SizedBox(height: 12),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: accentColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
