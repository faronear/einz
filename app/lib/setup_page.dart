import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:einz_shared/einz_shared.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/locale_settings.dart';
import 'data/server_settings.dart';
import 'l10n/app_localizations.dart';

/// 向导角色（第 0 步选择）：创建新空间 / 加入现有空间 / 线下导入密钥信封。
enum _WizardRole { create, join, offline }

/// 设置页：一次性配置（生成设备身份 → 自动登记入网 → 获得 Space Key → 设置启动锁）。
///
/// 服务器登记已全自动化（对齐 TUI/CLI 的 enroll 流程，不再需要 config.json 白名单）：
/// - create（第一个使用者）：首设备免邀请码自举登记 → 设接入口令托管 Space Key →
///   分享二维码（含 spaceId+口令+一次性邀请码，对方扫码一键加入）；
/// - join：扫码/粘贴加入信息（含邀请码）→ 凭邀请码登记 → 口令托管拉取 Space Key；
/// - offline：密钥信封导入（用对方公钥密封的 Space Key，同样先凭邀请码登记）。
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

  /// 测试注入：固定设备密钥对（golden 稳定性——名字步骤的密钥信息卡渲染公钥，
  /// 需确定性内容；生产传 null 则自动生成）。
  final DeviceKeyPair? keyPairOverride;

  /// 测试注入：替换 escrow 服务（join 口令验证；fake 可模拟口令对/错/未托管）。
  final KeyEscrowService Function(String server)? escrowOverride;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  String? _autoDeviceNameCache; // 登记用设备型号缓存（避免重复走平台通道）
  final _personName = TextEditingController(); // 首设备：第一个用户的名字
  final _spaceId = TextEditingController(); // 真实 spaceId（enroll/扫码/托管返回后填入）
  final _envelopeKey = TextEditingController();
  final _escrowPassphrase = TextEditingController();
  final _pin = TextEditingController(); // 启动锁 PIN（内嵌表单，不再弹窗）
  final _confirm = TextEditingController();
  String? _pinError; // PIN 步骤红色提示（输入框下方）
  bool _pinSkipped = false; // 用户确认"暂不设置"：跳过 setPin，仍完成前置并进下一步
  final _inviteCode = TextEditingController(); // 加入/导入设备时的一次性邀请码
  final _serverController = TextEditingController();

  // 服务器地址：默认 einz.tic.cc，探测失败时引导输入并持久化（降低小白负担）
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
  String? _status;
  bool _busy = false;

  /// 探测到的 person 名称表（服务端 /health 返回）：
  /// 空 = 服务器还没有任何用户（首设备场景）；非空 = 已有用户（后续设备场景）。
  Map<String, String> _personNames = <String, String>{};

  /// 后续设备引导中选择的身份（personA/personB；null = 首设备自举或未选）。
  String? _chosenPerson;

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
    _serverController.dispose();
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
        _serverController.text = saved;
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
      if (!mounted) return;
      setState(() {
        _probeFailed = true;
        _status = '初始化失败: $e';
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

  /// 保存用户输入的服务器地址并重新探测。
  Future<void> _saveServer() async {
    final input = _serverController.text.trim();
    if (input.isEmpty) return;
    _probeRetryTimer?.cancel(); // 用户提交新地址 → 停止自动重试循环，立即探测
    _probeRetryTimer = null;
    final probe = widget.probeServer ?? ServerSettings.probe;
    final (ok, names) = await probe(input);
    if (!mounted) return;
    setState(() {
      _server = input;
      _probeFailed = !ok;
      _personNames = names;
      if (ok && _role == null) {
        _role = names.isEmpty ? _WizardRole.create : _WizardRole.join;
        _step = 1;
      }
    });
    if (ok) {
      await ServerSettings(widget.db ?? LocalDatabase()).save(input);
    } else {
      _startProbeRetry(); // 新地址仍连不上：恢复自动重试，就绪后自动进入
    }
  }

  // 旧版四路径方法（_generateKey/_importAndAuth/_generateSpaceKeyAndAuth/
  // _escrowAccess 等）已重构为向导步骤（_buildStep* 系列，见下方各场景实现），
  // 认证/托管/二维码逻辑按步骤迁移重建。

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle(l10n)),
        actions: [
          // 全丢恢复入口常驻菜单：探测自动判定角色后依然可达
          // （密钥信封导入已移入口令页次级入口，不再放全局菜单）
          PopupMenuButton<String>(
            tooltip: l10n.wizardRoleOffline,
            onSelected: (value) {
              // 等菜单 Route 完全关闭再动作（避免 MenuRoute/DialogRoute 交叉卸载断言）
              Future<void>.delayed(const Duration(milliseconds: 300), () {
                if (!mounted) return;
                if (value == 'locale') _showLocalePicker();
                if (value == 'recover') _showRecoverDialog();
              });
            },
            itemBuilder: (context) {
              // 语言当前值：取实际生效 locale 的语言码 → 中文/English 名
              final langCode = Localizations.localeOf(context).languageCode;
              return [
                PopupMenuItem(
                  value: 'locale',
                  child: Text(l10n.wizardMenuLocale(kLocaleLabels[langCode] ?? langCode)),
                ),
                PopupMenuItem(
                  value: 'recover',
                  child: Text(l10n.wizardRecoverTitle),
                ),
              ];
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 当前服务器地址：每个页面顶部常驻显示（AppBar 标题正下方）
            Text(l10n.setupPageServerBar(_server),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            // 服务器探测失败 → 顶部引导卡片（能连时完全不显示，零打扰）
            if (_probeFailed) ...[
              Card(
                color: Colors.amber.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('⚠️ 无法连接服务器 $_server（/health 探测失败）',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _serverController,
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'https://...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy ? null : _saveServer,
                        child: const Text('保存并重试'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _buildProgressDots(),
            if (_role != null && _step > 0) ...[
              const SizedBox(height: 16),
              // 本页功能标题（AppBar 只显示所选角色名，见 _appBarTitle）
              Text(_stepTitle(l10n),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: KeyedSubtree(
                  key: ValueKey('$_role-$_step'),
                  child: SingleChildScrollView(child: _buildStep()),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_status != null) ...[
              Text(_status!, style: const TextStyle(fontSize: 13)),
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
                    child: Text(l10n.wizardBack),
                  ),
                  const Spacer(),
                  // 所有步骤显示"下一步"（create 步骤 2 的下一步触发自动自举登记），
                  // 完成页（_step == _stepCount）显示"完成"。
                  // join 步骤 1（身份选择）例外：点卡片即自动前进，无需"下一步"。
                  if (_step < _stepCount && !(_role == _WizardRole.join && _step == 1))
                    FilledButton(onPressed: _nextStep, child: Text(l10n.wizardNext))
                  else
                    FilledButton(onPressed: _finish, child: Text(l10n.wizardDone)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 向导框架 ----------

  /// 步骤总数（角色由探测自动判定：create=首设备 / join=后续设备 / offline=密钥信封）。
  int get _stepCount {
    switch (_role) {
      case _WizardRole.create:
        return 4; // name/passphrase/pin/done（设备名自动设置，输入步骤已移除）
      case _WizardRole.join:
        return 5; // identity/invite/passphrase/pin/done
      case _WizardRole.offline:
        return 3; // envelope/pin/done
      case null:
        return 1;
    }
  }

  /// 步骤标题（body 上方；AppBar 只显示所选角色名，见 _appBarTitle）。
  String _stepTitle(AppLocalizations l10n) {
    if (_role == null || _step == 0) return l10n.wizardRoleTitle;
    switch (_role!) {
      case _WizardRole.create:
        switch (_step) {
          case 1: return l10n.wizardStepName;
          case 2: return l10n.wizardStepPassphrase;
          case 3: return l10n.wizardStepPin;
          default: return l10n.wizardStepDone;
        }
      case _WizardRole.join:
        switch (_step) {
          case 1: return l10n.wizardStepIdentity;
          case 2: return l10n.wizardStepInvite;
          case 3: return l10n.wizardStepJoinPassphrase; // join 口令页：验证接入口令
          case 4: return l10n.wizardStepPin;
          default: return l10n.wizardStepDone;
        }
      case _WizardRole.offline:
        switch (_step) {
          case 1: return l10n.wizardStepEnvelope;
          case 2: return l10n.wizardStepPin;
          default: return l10n.wizardStepDone;
        }
    }
  }

  /// 页眉标题（AppBar）：固定显示所选角色名（第 0 步未选角色时显示引导语）。
  String _appBarTitle(AppLocalizations l10n) {
    if (_role == null || _step == 0) return l10n.wizardRoleTitle;
    switch (_role!) {
      case _WizardRole.create:
        return l10n.wizardAppBarCreate;
      case _WizardRole.join:
        return l10n.wizardAppBarJoin;
      case _WizardRole.offline:
        return l10n.wizardAppBarOffline;
    }
  }

  /// 进度圆点指示器。
  Widget _buildProgressDots() {
    final total = _stepCount;
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
              color: i <= _step ? Colors.indigo : Colors.grey.shade300,
            ),
          ),
      ],
    );
  }

  void _selectRole(_WizardRole role) {
    setState(() {
      _role = role;
      _step = 1;
    });
  }

  /// join 步骤 1：选择身份（personA=创建者 / personB=伴侣），点击卡片即自动进入
  /// 邀请码步骤（不再需要「下一步」按钮）；名字按需设置后留在 join 流程继续。
  void _selectIdentity(String person) {
    setState(() {
      _chosenPerson = person;
      _step = 2; // 点卡片直接进邀请码页
      _status = null;
    });
  }

  Future<void> _nextStep() async {
    final l10n = AppLocalizations.of(context)!;
    // 按步骤前置校验（每步只要求一个信息）
    if (_role == _WizardRole.join && _step == 1 && _chosenPerson == null) {
      setState(() => _status = l10n.wizardIdentityFirst);
      return;
    }
    if (_role == _WizardRole.join && _step == 2 && _inviteCode.text.trim().isEmpty) {
      setState(() => _status = l10n.setupPageNeedInvite);
      return;
    }
    // join 邀请码页（步骤 2）：邀请码必须有效（服务端登记成功）才放行——
    // 与口令页一样即时验证，不留到口令页才登记/校验
    if (_role == _WizardRole.join && _step == 2) {
      final ok = await _verifyInviteCode();
      if (!mounted) return;
      if (!ok) return;
    }
    if (_role == _WizardRole.create && _step == 2 && _escrowPassphrase.text.trim().isEmpty) {
      setState(() => _status = l10n.setupPageNeedPassphrase);
      return;
    }
    if (_role == _WizardRole.join && _step == 3 && _escrowPassphrase.text.trim().isEmpty) {
      setState(() => _status = l10n.setupPageNeedPassphrase);
      return;
    }
    // join 口令页（步骤 3）：输入口令必须与首台设备创建时一致（解密 escrow
    // 托管包成功）才放行进 PIN 步骤——错误口令/未托管提示后停留本页
    if (_role == _WizardRole.join && _step == 3) {
      final verified = await _verifyJoinPassphrase();
      if (!mounted) return;
      if (!verified) return;
    }
    if (_role == _WizardRole.offline && _step == 1) {
      if (_envelopeKey.text.trim().isEmpty) {
        setState(() => _status = l10n.setupPagePasteEnvelope);
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
    final isPinStep = (_role == _WizardRole.create && _step == 3) ||
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
    // create 步骤 1（名字）→ 自动自举登记（原设备名步骤的触发点；设备名已自动
    // 设置不再询问），成功才进口令步骤
    if (_role == _WizardRole.create && _step == 1 && _enroll == null) {
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
      // 步骤 1 即向导第一页（create=名字 / join=身份 / offline=密钥信封）；
      // 不允许退到第 0 步检测页（角色判定前的过渡页，无操作出口，会形成死胡同）
      if (_step > 1) _step--;
    });
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
            return _buildStepPassphrase();
          case 3:
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

  /// 第 0 步（角色未判定时）：显示探测状态（密钥信封导入在口令页有次级入口）。
  /// 角色由服务器探测自动判定（person 名称表空=首设备 create，非空=后续设备 join），
  /// 不再让用户手动选择。
  Widget _buildDetectAndEnvelope() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardDetectTitle,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.chatPageLocaleSwitched(kLocaleLabels[picked]!))),
    );
  }

  /// 全丢恢复：弹窗输入 escrow 口令 → 服务端凭口令重置空间（/recover，撤销
  /// 全部设备）并返回托管包 → 解出 Space Key → 本设备首设备自举 → PIN 步骤；
  /// 折叠区可选「从完整备份恢复」（归档文本 + 归档口令，本地重建密钥与历史）。
  Future<void> _showRecoverDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _RecoverDialog(
        server: _server,
        onRecovered: _applyRecovered,
        onArchiveRestored: _applyArchiveRestored,
      ),
    );
  }

  /// 归档恢复暂存的历史（「从完整备份恢复」解出；进入聊天页时经
  /// ChatPage.initialHistory 落库，messageId 幂等）。
  List<Map<String, dynamic>>? _importedHistory;

  /// 恢复成功回调：用备份解出的 Space Key 重建本设备（首设备自举登记 + 认证），
  /// 然后跳到 PIN 步骤完成设置（_runPinSetup 会复用已解出的 _spaceKey）。
  Future<void> _applyRecovered({
    required String spaceKeyB64,
    required String spaceId,
    required int keyVersion,
  }) async {
    if (!mounted) return;
    setState(() {
      _spaceKey = base64Decode(spaceKeyB64);
      _spaceId.text = spaceId;
      _role = _WizardRole.create; // 空间已被 /recover 重置 → 本设备即首设备
      _step = 3; // 直接到 PIN 步骤（create 新编号；登记/认证由本回调完成）
      _status = AppLocalizations.of(context)!.wizardRecoverEnrolling;
    });
    try {
      // 1) 首设备自举（服务端 activeCount=0 → 免邀请码）
      if (_enroll == null) {
        await _enrollDevice(null);
      }
      final kp = _keyPair;
      if (kp == null || _enroll == null) return;
      // 2) 认证（用登记后的真实 deviceId）
      final session = await _authenticate(kp, _enroll!.deviceId);
      _sessionToken = session.sessionToken;
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.wizardRecoverDone);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageKeyGenFailed('$e'));
    }
  }

  /// 归档恢复回调（对话框「从完整备份恢复」）：归档含空间密钥 + 全量历史——
  /// 历史暂存 [_importedHistory]（进入聊天页时落库），密钥身份恢复照常复用
  /// [_applyRecovered]（登记 + 认证 + 跳 PIN；需服务器可达）。
  Future<void> _applyArchiveRestored({
    required String spaceKeyB64,
    required String spaceId,
    required int keyVersion,
    required List<Map<String, dynamic>> history,
  }) async {
    _importedHistory = history;
    await _applyRecovered(
      spaceKeyB64: spaceKeyB64,
      spaceId: spaceId,
      keyVersion: keyVersion,
    );
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
            personId: _chosenPerson, // join：用户选择的身份（personA/personB）
            deviceName: await _autoDeviceName(), // 自动填设备型号（产品决定：不再询问）
          );
    if (!mounted) return;
    setState(() {
      _enroll = r;
      _spaceId.text = r.spaceId;
      _bootstrapFailed = false;
    });
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
  void _finish() {
    final kp = _keyPair;
    final enroll = _enroll;
    final sk = _spaceKey;
    final token = _sessionToken;
    if (kp == null || enroll == null || sk == null || token == null) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ChatPage(
        server: _server,
        spaceId: _spaceId.text.trim(),
        deviceId: enroll.deviceId,
        spaceKey: sk,
        keyVersion: 1,
        token: token,
        initialHistory: _importedHistory,
        // session 过期自动续期：复用本页 challenge-response 流程重新签发 token
        reauth: () async => (await _authenticate(kp, enroll.deviceId)).sessionToken,
      ),
    ));
  }

  // ---- 场景 A（create）：名字 → 口令 → PIN → 完成（设备名已自动设置，不再询问） ----

  /// 步骤 1（create）：第一个用户的名字；密钥已由 [_autoGenerateKey] 自动生成，
  /// 展示密钥信息；"下一步"触发自举登记（设备名已自动设置，不再单独询问）。
  Widget _buildStepName() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardNameHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        TextField(
          controller: _personName,
          decoration: InputDecoration(
            labelText: l10n.wizardNameLabel,
            hintText: l10n.wizardNameHintInput,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_keyPair != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.setupPageKeyGenerated,
                      style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.green)),
                  const SizedBox(height: 8),
                  SelectableText(
                    l10n.setupPageKeyInfo(_keyPair!.deviceId, _keyPair!.publicKeyB64),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
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

  // ---- 场景 B（join）：身份 → 邀请码 → 口令 → PIN → 完成 ----

  /// 步骤 1（join）：你是第一个用户（创建者 personA）还是第二个（伴侣 personB）。
  /// 与 TUI 引导顺序一致：先定身份（并按需设置名字）。
  Widget _buildStepIdentity() {
    final l10n = AppLocalizations.of(context)!;
    final aName = _personNames['personA'] ?? '';
    final bName = _personNames['personB'] ?? '尚未加入的伴侣';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardIdentityHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: Icon(Icons.person),
            title: Text('1 · ${l10n.wizardIdentityCreator}（$aName）'),
            selected: _chosenPerson == 'personA',
            onTap: () => _selectIdentity('personA'),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: Icon(Icons.group),
            title: Text('2 · ${l10n.wizardIdentityPartner}（$bName）'),
            selected: _chosenPerson == 'personB',
            onTap: () => _selectIdentity('personB'),
          ),
        ),
        if (_chosenPerson == 'personB' && bName.isEmpty) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _personName,
            decoration: InputDecoration(
              labelText: l10n.wizardNameLabel,
              hintText: l10n.wizardNameHintInput,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ],
    );
  }

  /// 步骤 3（join）：输入一次性邀请码（创建者 /invite 生成，24h 有效）。
  Widget _buildStepInvite() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardInviteHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        TextField(
          controller: _inviteCode,
          decoration: InputDecoration(
            labelText: l10n.setupPageInviteLabel,
            hintText: l10n.setupPageInviteHint,
            border: const OutlineInputBorder(),
          ),
        ),
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
      setState(() => _status = AppLocalizations.of(context)!.wizardEnrollDoneStatus);
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
  Widget _buildStepPassphrase() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_role == _WizardRole.join ? l10n.wizardJoinPassphraseHint : l10n.wizardPassphraseHint,
            style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        TextField(
          controller: _escrowPassphrase,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.setupPageEscrowLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        // 密钥信封导入与口令同属 Space Key 交换方式：仅 join（第二/三台设备）
        // 可用——信封是对端设备导出的密封密钥，首设备（create）没有对端设备，
        // 也无邀请码，故不显示此入口
        if (_role == _WizardRole.join)
          TextButton.icon(
            onPressed: () => _selectRole(_WizardRole.offline),
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
        Text(l10n.wizardPinHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        TextField(
          controller: _pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l10n.setPinDialogPinLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _confirm,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: l10n.setPinDialogConfirmLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_pinError != null) ...[
          const SizedBox(height: 8),
          Text(_pinError!,
              style: const TextStyle(color: Colors.red, fontSize: 13)),
        ],
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
          deviceId: kp.deviceId,
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
          deviceId: kp.deviceId,
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
        deviceId: kp.deviceId,
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
      _finish(); // 进入消息流页面
    }
  }

  /// 向导完成页（done 步骤）：被欢迎对话框盖住，仅作为弹窗背后的内容兜底。
  Widget _buildStepDone() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardDoneText,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.green)),
        const SizedBox(height: 8),
        Text(l10n.setupPageTitle, style: const TextStyle(fontSize: 13, color: Colors.grey)),
      ],
    );
  }

  // ---- 场景 B（join）：身份 → 邀请码 → 口令 → PIN → 完成 ----

  /// join：凭邀请码登记 → 认证 → 拉取口令托管包 → 口令解密出 Space Key → 设置 PIN → 完成。
  /// join 邀请码页（步骤 2）「验证邀请码」：凭码登记（服务端校验，无效码抛错）
  /// ——登记成功（= 邀请码有效）才放行到口令页，错误码提示并停留本页。
  Future<bool> _verifyInviteCode() async {
    final kp = _keyPair;
    if (kp == null) return false;
    final code = _inviteCode.text.trim();
    if (code.isEmpty) {
      setState(() => _status = AppLocalizations.of(context)!.setupPageNeedInvite);
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

  /// join 口令页（步骤 3）「验证接入口令」：登记 → 认证 → fetch escrow 托管包 →
  /// 用输入口令解密——口令与首台设备创建时一致（解密成功）才放行进 PIN 步骤。
  Future<bool> _verifyJoinPassphrase() async {
    final kp = _keyPair;
    if (kp == null) return false;
    final passphrase = _escrowPassphrase.text.trim();
    if (passphrase.isEmpty) {
      setState(() => _status = AppLocalizations.of(context)!.setupPageNeedPassphrase);
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
      // 3) fetch 托管包并用输入口令解密：口令错 → FormatException → 不通过
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

  // ---- 场景 C（offline）：密钥信封导入 ----

  /// 步骤 1（offline）：粘贴密钥信封（对方用本设备公钥密封的 Space Key）。
  /// 同时需填写一次性邀请码（非首台设备必须凭码登记后才能认证）。
  Widget _buildStepEnvelope() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _envelopeKey,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: l10n.setupPageEnvelopeKeyLabel,
            hintText: l10n.setupPageEnvelopeKeyHint,
            border: const OutlineInputBorder(),
          ),
        ),
        // 邀请码已在 join 步骤 2 提供（offline 从 join 口令页切换进入时沿用
        // 已填邀请码登记），此页不再重复显示输入框
        const SizedBox(height: 16),
        // 与口令页的「改用密封密钥信封导入」对称：口令/信封是平行方案可互切；
        // 切回口令页保留已输入的口令与邀请码，任一完成都进入 PIN 步骤
        TextButton.icon(
          onPressed: _switchToPassphrase,
          icon: const Icon(Icons.password, size: 18),
          label: Text(l10n.wizardSwitchToPassphrase),
        ),
      ],
    );
  }

  /// 从密钥信封页切回「验证口令」页（join 步骤 3）。
  /// 不能用 _selectRole（它会重置 _step=1 回身份页）；直接切角色+步骤，
  /// 已输入的邀请码/口令保留，任一方案完成都进入 PIN 步骤。
  void _switchToPassphrase() {
    setState(() {
      _role = _WizardRole.join;
      _step = 3; // join 口令页
      _status = null;
    });
  }

  /// offline 信封页（步骤 1）「验证密钥信封」：登记 → 用本设备私钥解封信封——
  /// 解出合法 Space Key 才放行进 PIN 步骤；无效信封提示并停留本页。
  Future<bool> _verifyEnvelope() async {
    final kp = _keyPair;
    if (kp == null) return false;
    final envelopeRaw = _envelopeKey.text.trim();
    if (envelopeRaw.isEmpty) {
      setState(() => _status = AppLocalizations.of(context)!.setupPagePasteEnvelope);
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

/// 全丢恢复弹窗：输入 escrow 口令（主路径：/recover 重置 + 托管包解密）；折叠区
/// 粘贴归档文本 + 归档口令（本地重建密钥与历史）→ 回调向导应用恢复数据。
class _RecoverDialog extends StatefulWidget {
  const _RecoverDialog({
    required this.server,
    required this.onRecovered,
    required this.onArchiveRestored,
  });

  final String server;

  /// 恢复成功回调（向导侧 _applyRecovered：登记 + 认证 + 跳 PIN 步骤）。
  final Future<void> Function({
    required String spaceKeyB64,
    required String spaceId,
    required int keyVersion,
  }) onRecovered;

  /// 归档恢复回调（向导侧 _applyArchiveRestored：暂存历史 + 复用 _applyRecovered）。
  final Future<void> Function({
    required String spaceKeyB64,
    required String spaceId,
    required int keyVersion,
    required List<Map<String, dynamic>> history,
  }) onArchiveRestored;

  @override
  State<_RecoverDialog> createState() => _RecoverDialogState();
}

class _RecoverDialogState extends State<_RecoverDialog> {
  final _passphraseCtrl = TextEditingController();
  final _archiveCtrl = TextEditingController();
  final _archivePassphraseCtrl = TextEditingController();
  bool _busy = false;
  bool _showArchive = false;
  String? _error;

  @override
  void dispose() {
    _passphraseCtrl.dispose();
    _archiveCtrl.dispose();
    _archivePassphraseCtrl.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    final l10n = AppLocalizations.of(context)!;
    final passphrase = _passphraseCtrl.text.trim();
    if (passphrase.isEmpty) {
      setState(() => _error = l10n.setupPageNeedPassphrase);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 服务端凭口令重置空间（撤销全部设备）并返回 escrow 密文包——同一口令
      // 本地解出 Space Key（纯口令闭环，与 TUI 一致；口令错 → 403，不触网解包）
      final pkg = await ApiClient(widget.server).recoverSpace(passphrase);
      if (pkg == null) {
        if (!mounted) return;
        setState(() => _error = l10n.wizardRecoverBadPassphrase);
        return;
      }
      final plain = await decryptBackup(file: pkg, recoveryCode: passphrase);
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onRecovered(
        spaceKeyB64: json['space_key'] as String,
        spaceId: json['space_id'] as String,
        keyVersion: (json['key_version'] as num?)?.toInt() ?? 1,
      );
    } on FormatException {
      if (!mounted) return;
      setState(() => _error = l10n.wizardRecoverBadPassphrase);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code == 'FORBIDDEN'
          ? l10n.wizardRecoverBadPassphrase
          : l10n.wizardRecoverFailed(e.code));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = l10n.wizardRecoverFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 归档恢复（「从完整备份恢复」折叠区）：粘贴 EINZ-BACKUP: 归档文本 +
  /// 归档口令 → 本地解密 → 校验含 history → 回调向导（_applyArchiveRestored）。
  /// 归档口令为导出时自设（与 escrow 口令无关，纯离线物）。
  Future<void> _restoreFromArchive() async {
    final l10n = AppLocalizations.of(context)!;
    final text = _archiveCtrl.text.trim();
    final passphrase = _archivePassphraseCtrl.text.trim();
    if (!text.startsWith(kBackupExportPrefix)) {
      setState(() => _error = l10n.wizardRecoverArchiveBad);
      return;
    }
    if (passphrase.isEmpty) {
      setState(() => _error = l10n.setupPageNeedPassphrase);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final b64 = text.substring(kBackupExportPrefix.length);
      final file = BackupFile.fromJson(
          jsonDecode(utf8.decode(base64Decode(b64))) as Map<String, dynamic>);
      final plain = await decryptBackup(file: file, recoveryCode: passphrase);
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final history = (json['history'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onArchiveRestored(
        spaceKeyB64: json['space_key'] as String,
        spaceId: json['space_id'] as String,
        keyVersion: (json['key_version'] as num?)?.toInt() ?? 1,
        history: history,
      );
    } on FormatException {
      if (!mounted) return;
      setState(() => _error = l10n.wizardRecoverArchiveBad);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = l10n.wizardRecoverFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.wizardRecoverTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.wizardRecoverHint,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          TextField(
            controller: _passphraseCtrl,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.wizardRecoverPassphraseLabel,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) {
              if (!_busy) _recover();
            },
          ),
          const SizedBox(height: 8),
          // 归档恢复（可选折叠）：完整备份文本 + 归档口令（导出时自设）
          TextButton(
            onPressed: () => setState(() => _showArchive = !_showArchive),
            child: Text(l10n.wizardRecoverArchiveTitle),
          ),
          if (_showArchive) ...[
            TextField(
              controller: _archiveCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l10n.wizardRecoverArchiveTextLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _archivePassphraseCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.wizardRecoverArchivePassphraseLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy ? null : _restoreFromArchive,
              child: Text(l10n.wizardRecoverArchiveStart),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.cancel)),
        FilledButton(
          onPressed: _busy ? null : _recover,
          child: Text(l10n.wizardRecoverStart),
        ),
      ],
    );
  }
}
