import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:einz_shared/einz_shared.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'data/server_settings.dart';
import 'l10n/app_localizations.dart';

/// 向导角色（第 0 步选择）：创建新空间 / 加入现有空间 / 高级导入 sealed。
enum _WizardRole { create, join, advanced }

/// 设置页：一次性配置（生成设备身份 → 自动登记入网 → 获得 Space Key → 设置启动锁）。
///
/// 服务器登记已全自动化（对齐 TUI/CLI 的 enroll 流程，不再需要 config.json 白名单）：
/// - create（第一个使用者）：首设备免邀请码自举登记 → 设接入口令托管 Space Key →
///   分享二维码（含 spaceId+口令+一次性邀请码，对方扫码一键加入）；
/// - join：扫码/粘贴加入信息（含邀请码）→ 凭邀请码登记 → 口令托管拉取 Space Key；
/// - advanced：sealed 密封副本导入（同样先凭邀请码登记）。
/// 认证统一在登记之后进行（challenge 要求设备已入网），deviceId/spaceId 用登记返回值。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, this.db, this.probeServer, this.enrollOverride, this.createInviteOverride});

  /// 测试注入用；默认新建（生产路径）。
  final LocalDatabase? db;

  /// 服务器探测回调（测试注入 fake 保 golden 稳定）；默认用真实 ServerSettings.probe。
  final Future<bool> Function(String server)? probeServer;

  /// 测试注入：登记设备（生产走真实 ApiClient.enrollDevice；注入后不发起网络请求）。
  final Future<EnrollResult> Function(String? inviteCode)? enrollOverride;

  /// 测试注入：生成邀请码（生产走真实 ApiClient.createInvite）。
  final Future<InviteResult> Function(String personId)? createInviteOverride;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _deviceId = TextEditingController(text: 'dev-mobile');
  final _spaceId = TextEditingController(); // 真实 spaceId（enroll/扫码/托管返回后填入）
  final _sealedKey = TextEditingController();
  final _escrowPassphrase = TextEditingController();
  final _inviteCode = TextEditingController(); // 加入/导入设备时的一次性邀请码
  final _serverController = TextEditingController();

  // 服务器地址：默认 einz.tic.cc，探测失败时引导输入并持久化（降低小白负担）
  String _server = kEinzServer;
  bool _probeFailed = false;

  // 向导状态：角色分流 + 步骤索引 + 跨步骤共享数据
  _WizardRole? _role;
  int _step = 0;
  DeviceKeyPair? _keyPair;
  Uint8List? _spaceKey;
  String? _sessionToken;
  String? _status;
  bool _busy = false;

  /// 设备登记结果（服务端分配的真实 deviceId/personId/spaceId）。
  /// 认证（challenge）与进聊天页一律用它，不用本地临时 deviceId。
  EnrollResult? _enroll;

  /// create 分享页生成的对方（personB）邀请码。
  String? _partnerInvite;

  /// create 自举失败（服务器已有空间设备）时为 true → 展示改用"加入"的引导。
  bool _bootstrapFailed = false;

  @override
  void dispose() {
    _deviceId.dispose();
    _spaceId.dispose();
    _sealedKey.dispose();
    _escrowPassphrase.dispose();
    _inviteCode.dispose();
    _serverController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _initServer();
  }

  /// 服务器地址初始化：读持久化值（无则默认 einz.tic.cc）→ 快速探测。
  /// 能连 → 零打扰（不显示任何 UI）；无法连接 → 显示输入框引导覆盖（降低小白负担）。
  Future<void> _initServer() async {
    try {
      final db = widget.db ?? LocalDatabase();
      final settings = ServerSettings(db);
      final saved = await settings.load();
      final probe = widget.probeServer ?? ServerSettings.probe;
      final ok = await probe(saved);
      if (!mounted) return;
      setState(() {
        _server = saved;
        _probeFailed = !ok;
        _serverController.text = saved;
      });
    } catch (_) {
      // 测试环境无 path_provider/数据库实现 → 跳过探测（保持默认服务器，零打扰）
    }
  }

  /// 保存用户输入的服务器地址并重新探测。
  Future<void> _saveServer() async {
    final input = _serverController.text.trim();
    if (input.isEmpty) return;
    final probe = widget.probeServer ?? ServerSettings.probe;
    final ok = await probe(input);
    if (!mounted) return;
    setState(() {
      _server = input;
      _probeFailed = !ok;
    });
    if (ok) {
      await ServerSettings(widget.db ?? LocalDatabase()).save(input);
    }
  }

  // 旧版四路径方法（_generateKey/_importAndAuth/_generateSpaceKeyAndAuth/
  // _escrowAccess 等）已重构为向导步骤（_buildStep* 系列，见下方各场景实现），
  // 认证/托管/二维码逻辑按步骤迁移重建。

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(_appBarTitle(l10n))),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            if (_role != null && _step > 0)
              Row(
                children: [
                  TextButton(onPressed: _backStep, child: Text(l10n.wizardBack)),
                  const Spacer(),
                  if (_step < _stepCount - 1)
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

  /// 步骤总数（按角色：create=7 / join=5 / advanced=5；未选角色=1）。
  int get _stepCount {
    switch (_role) {
      case _WizardRole.create:
        return 7; // role/device/whitelist/passphrase/pin/share/done
      case _WizardRole.join:
        return 5; // role/device/join/pin/done
      case _WizardRole.advanced:
        return 5; // role/device/sealed/pin/done
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
          case 1: return l10n.wizardStepDevice;
          case 2: return l10n.wizardStepEnroll;
          case 3: return l10n.wizardStepPassphrase;
          case 4: return l10n.wizardStepPin;
          case 5: return l10n.wizardStepShare;
          default: return l10n.wizardStepDone;
        }
      case _WizardRole.join:
        switch (_step) {
          case 1: return l10n.wizardStepDevice;
          case 2: return l10n.wizardStepJoin;
          case 3: return l10n.wizardStepPin;
          default: return l10n.wizardStepDone;
        }
      case _WizardRole.advanced:
        switch (_step) {
          case 1: return l10n.wizardStepDevice;
          case 2: return l10n.wizardStepSealed;
          case 3: return l10n.wizardStepPin;
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
      case _WizardRole.advanced:
        return l10n.wizardAppBarAdvanced;
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

  void _nextStep() {
    final l10n = AppLocalizations.of(context)!;
    // 按步骤前置校验（每步只要求一个信息）
    if (_step == 1 && _keyPair == null) {
      setState(() => _status = l10n.setupPageGenKeyFirst);
      return;
    }
    if (_role == _WizardRole.create && _step == 2 && _enroll == null) {
      setState(() => _status = l10n.wizardEnrollFirst);
      return;
    }
    if (_role == _WizardRole.create && _step == 3 && _escrowPassphrase.text.trim().isEmpty) {
      setState(() => _status = l10n.setupPageNeedPassphrase);
      return;
    }
    if (_role == _WizardRole.join &&
        _step == 2 &&
        (_spaceId.text.trim().isEmpty ||
            _escrowPassphrase.text.trim().isEmpty ||
            _inviteCode.text.trim().isEmpty)) {
      setState(() => _status = l10n.setupPageEscrowFillAll);
      return;
    }
    if (_role == _WizardRole.advanced && _step == 2) {
      if (_sealedKey.text.trim().isEmpty) {
        setState(() => _status = l10n.setupPagePasteSealed);
        return;
      }
      if (_inviteCode.text.trim().isEmpty) {
        setState(() => _status = l10n.setupPageNeedInvite);
        return;
      }
    }
    setState(() {
      if (_step < _stepCount - 1) _step++;
    });
  }

  void _backStep() {
    setState(() {
      if (_step > 0) _step--;
    });
  }

  /// 按角色+步骤分发到对应步骤页。
  Widget _buildStep() {
    if (_role == null || _step == 0) return _buildChooseRole();
    switch (_role!) {
      case _WizardRole.create:
        switch (_step) {
          case 1:
            return _buildStepDevice();
          case 2:
            return _buildStepEnroll();
          case 3:
            return _buildStepPassphrase();
          case 4:
            return _buildStepPin();
          case 5:
            return _buildStepShare();
          default:
            return _buildStepDone();
        }
      case _WizardRole.join:
        switch (_step) {
          case 1:
            return _buildStepDevice();
          case 2:
            return _buildStepJoin();
          case 3:
            return _buildStepPin();
          default:
            return _buildStepDone();
        }
      case _WizardRole.advanced:
        switch (_step) {
          case 1:
            return _buildStepDevice();
          case 2:
            return _buildStepSealed();
          case 3:
            return _buildStepPin();
          default:
            return _buildStepDone();
        }
    }
  }

  /// 第 0 步：角色选择（创建 / 加入 / 高级折叠）。
  Widget _buildChooseRole() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardRoleTitle,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _roleCard(l10n.wizardRoleCreate, Icons.add_circle_outline, _WizardRole.create),
        const SizedBox(height: 8),
        _roleCard(l10n.wizardRoleJoin, Icons.qr_code_scanner, _WizardRole.join),
        const SizedBox(height: 8),
        ExpansionTile(
          title: Text(l10n.wizardRoleAdvanced, style: const TextStyle(fontSize: 14)),
          children: [
            _roleCard(l10n.wizardRoleAdvanced, Icons.key, _WizardRole.advanced),
          ],
        ),
      ],
    );
  }

  Widget _roleCard(String text, IconData icon, _WizardRole role) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(text),
        onTap: () => _selectRole(role),
      ),
    );
  }

  // ---- 辅助：认证 / PIN 设置 / 进聊天页 ----

  /// challenge-response 认证，返回 session（PROTOCOL.md §4）。
  /// [enrolledDeviceId] 用登记后服务端分配的真实 id（challenge 要求设备已入网）。
  Future<SessionResult> _authenticate(DeviceKeyPair kp, String enrolledDeviceId) async {
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

  /// 登记设备：create=首设备免邀请码自举；join/advanced=凭一次性邀请码。
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
            deviceName: _deviceId.text.trim(),
          );
    if (!mounted) return;
    setState(() {
      _enroll = r;
      _spaceId.text = r.spaceId;
      _bootstrapFailed = false;
    });
  }

  /// 设置启动锁对话框（PIN 两次确认 → 恢复码展示）→ 返回是否完成。
  Future<bool> _setupLockAndEnter({
    required String server,
    required String spaceId,
    required String deviceId,
    required String spaceKeyB64,
    required int keyVersion,
    required String token,
    String? escrowPassphrase,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SetPinDialog(
        payload: AppLockPayload(
          server: server,
          spaceId: spaceId,
          deviceId: deviceId,
          spaceKeyB64: spaceKeyB64,
          keyVersion: keyVersion,
          token: token,
          escrowPassphrase: escrowPassphrase,
        ),
      ),
    );
    return ok ?? false;
  }

  /// 完成动作：进入聊天页（create/join/advanced 填充数据后统一调用；
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
        // session 过期自动续期：复用本页 challenge-response 流程重新签发 token
        reauth: () async => (await _authenticate(kp, enroll.deviceId)).sessionToken,
      ),
    ));
  }

  // ---- 场景 A（create）：设备名 → 登记（自动自举）→ 口令 → PIN → 分享 → 完成 ----

  /// 步骤 1：设备名称 + 生成设备密钥（生成结果在本页明确反馈）。
  Widget _buildStepDevice() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _deviceId,
          decoration: InputDecoration(
            labelText: l10n.setupPageDeviceIdLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _generateKeyPair,
          child: Text(l10n.setupPageGenerateKey),
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
      ],
    );
  }

  Future<void> _generateKeyPair() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final pair = await DeviceKeyPair.generate(deviceId: _deviceId.text.trim());
      if (!mounted) return;
      setState(() {
        _keyPair = pair;
        _status = AppLocalizations.of(context)!.setupPageKeyGenerated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageKeyGenFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 步骤 2（create）：登记设备（全自动，替代旧版手动加 config.json 白名单）。
  Widget _buildStepEnroll() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardEnrollHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _runBootstrap,
          child: Text(l10n.wizardEnrollAction),
        ),
        if (_enroll != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                l10n.wizardEnrollDone(_enroll!.deviceId, _enroll!.spaceId),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
        if (_bootstrapFailed) ...[
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

  /// 步骤 3：设置接入口令（对方凭它加入）。
  Widget _buildStepPassphrase() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardPassphraseHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        TextField(
          controller: _escrowPassphrase,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.setupPageEscrowLabel,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  /// 步骤 4：设置 PIN（按角色分发：create 生成密钥 / join 凭口令接入 / advanced sealed 导入）。
  Widget _buildStepPin() {
    final l10n = AppLocalizations.of(context)!;
    final isCreate = _role == _WizardRole.create;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardPinHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy
              ? null
              : (isCreate
                  ? _runPinSetup
                  : (_role == _WizardRole.join ? _runJoinAccess : _runSealedImport)),
          child: Text(l10n.setPinDialogSetPin),
        ),
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
      // 3) 设置 PIN（含接入口令 → 上传托管）
      final ok = await _setupLockAndEnter(
        server: _server,
        spaceId: _spaceId.text.trim(),
        deviceId: kp.deviceId,
        spaceKeyB64: base64Encode(_spaceKey!),
        keyVersion: 1,
        token: token,
        escrowPassphrase: _escrowPassphrase.text.trim(),
      );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _step = 5;
          _status = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageKeyGenFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 步骤 5（create）：分享加入信息——二维码/文本含 spaceId + 口令 +
  /// 一次性邀请码（先点按钮生成邀请码，再展示二维码；对方扫码即一键加入）。
  Widget _buildStepShare() {
    final l10n = AppLocalizations.of(context)!;
    final enroll = _enroll;
    final code = _partnerInvite;
    if (code == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.wizardShareHint, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _generatePartnerInvite,
            child: Text(l10n.wizardShareGenInvite),
          ),
        ],
      );
    }
    final info = JoinInfo(
      spaceId: enroll?.spaceId ?? _spaceId.text.trim(),
      passphrase: _escrowPassphrase.text.trim(),
      inviteCode: code,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardShareHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        Center(child: QrImageView(data: info.encode(), version: QrVersions.auto, size: 180)),
        const SizedBox(height: 12),
        SelectableText('${l10n.setupPageInviteLabel}: $code',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        SelectableText(l10n.joinDialogSpace(info.spaceId), style: const TextStyle(fontSize: 12)),
        SelectableText(l10n.joinDialogPassphrase(info.passphrase),
            style: const TextStyle(fontSize: 12)),
        Text(l10n.wizardShareInviteNote,
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            FilledButton.tonal(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: info.encode()));
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(l10n.joinDialogCopied)));
              },
              child: Text(l10n.joinDialogCopy),
            ),
            TextButton(
              onPressed: _busy ? null : _generatePartnerInvite,
              child: Text(l10n.wizardShareRegenerate),
            ),
          ],
        ),
      ],
    );
  }

  /// create：为对方（personB）生成一次性邀请码（POST /invites，需已认证 token）。
  Future<void> _generatePartnerInvite() async {
    final kp = _keyPair;
    final enroll = _enroll;
    if (kp == null || enroll == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final InviteResult r;
      if (widget.createInviteOverride != null) {
        r = await widget.createInviteOverride!('personB');
      } else {
        var token = _sessionToken;
        if (token == null) {
          final s = await _authenticate(kp, enroll.deviceId);
          token = s.sessionToken;
          _sessionToken = token;
        }
        r = await ApiClient(_server).createInvite(token: token, personId: 'personB');
      }
      if (!mounted) return;
      setState(() => _partnerInvite = r.inviteCode);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.httpStatus == 401 && _sessionToken != null) {
        _sessionToken = null; // token 过期：重新认证后再试一次
        await _generatePartnerInvite();
        return;
      }
      setState(() => _status = AppLocalizations.of(context)!.wizardShareInviteFailed('$e'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.wizardShareInviteFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 完成页（create/join/advanced 共用）：底部"完成"按钮 → _finish 进聊天页。
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

  // ---- 场景 B（join）：扫码/口令加入 ----

  /// 步骤 2（join）：扫码或粘贴加入信息（自动填入空间 ID 与口令）。
  Widget _buildStepJoin() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardJoinHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: _busy ? null : _scanJoinCode,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_scanner),
              const SizedBox(width: 8),
              Text(l10n.scanJoinTitle),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _spaceId,
          decoration: InputDecoration(
            labelText: l10n.setupPageSpaceIdLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _escrowPassphrase,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.setupPageEscrowLabel,
            border: const OutlineInputBorder(),
          ),
        ),
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

  /// 扫码加入：扫描 A 的二维码 → 自动填入空间 ID、口令与邀请码。
  Future<void> _scanJoinCode() async {
    final l10n = AppLocalizations.of(context)!;
    final info = await Navigator.of(context).push<JoinInfo>(
      MaterialPageRoute(builder: (_) => const _JoinScanPage()),
    );
    if (info == null || !mounted) return;
    _spaceId.text = info.spaceId;
    _escrowPassphrase.text = info.passphrase;
    _inviteCode.text = info.inviteCode ?? '';
    setState(() => _status = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.scanJoinFound)));
  }

  /// join：认证 → 拉取口令托管包 → 口令解密出 Space Key → 设置 PIN → 完成步骤。
  Future<void> _runJoinAccess() async {
    final kp = _keyPair;
    if (kp == null) return;
    final spaceId = _spaceId.text.trim();
    final passphrase = _escrowPassphrase.text.trim();
    if (spaceId.isEmpty || passphrase.isEmpty) {
      setState(() => _status = AppLocalizations.of(context)!.setupPageEscrowFillAll);
      return;
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
      final escrow = KeyEscrowService(ApiClient(_server));
      final payload = await escrow.fetch(passphrase: passphrase, token: session.sessionToken);
      if (payload == null) {
        if (!mounted) return;
        setState(() => _status = AppLocalizations.of(context)!.setupPageNoEscrow);
        return;
      }
      _spaceKey = base64Decode(payload.spaceKeyB64);
      _spaceId.text = payload.spaceId;
      if (!mounted) return;
      final ok = await _setupLockAndEnter(
        server: _server,
        spaceId: payload.spaceId,
        deviceId: enroll.deviceId,
        spaceKeyB64: payload.spaceKeyB64,
        keyVersion: payload.keyVersion,
        token: session.sessionToken,
        escrowPassphrase: passphrase,
      );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _step = 4;
          _status = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageEscrowFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- 场景 C（advanced）：sealed 导入 ----

  /// 步骤 2（advanced）：粘贴 sealed 密钥副本（对方用本设备公钥密封）。
  /// 同时需填写一次性邀请码（非首台设备必须凭码登记后才能认证）。
  Widget _buildStepSealed() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _sealedKey,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: l10n.setupPageSealedKeyLabel,
            hintText: l10n.setupPageSealedKeyHint,
            border: const OutlineInputBorder(),
          ),
        ),
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

  /// advanced：解封 sealed Space Key → 认证 → 设置 PIN → 完成步骤。
  Future<void> _runSealedImport() async {
    final kp = _keyPair;
    if (kp == null) return;
    final sealedRaw = _sealedKey.text.trim();
    if (sealedRaw.isEmpty) {
      setState(() => _status = AppLocalizations.of(context)!.setupPagePasteSealed);
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      // 0) 凭邀请码登记（第二台及以上设备必须；码绑定 person）
      if (_enroll == null) {
        await _enrollDevice(_inviteCode.text.trim());
      }
      final enroll = _enroll!;
      // 1) 解封 Space Key（本设备私钥解开）
      final s = await sodium();
      final spaceKey = await sealOpen(
        s,
        base64Decode(sealedRaw),
        kp.publicKey,
        kp.privateKey,
      );
      // 2) 认证（用登记后的真实 deviceId）
      final session = await _authenticate(kp, enroll.deviceId);
      _sessionToken = session.sessionToken;
      _spaceKey = spaceKey;
      if (!mounted) return;
      // 3) 设置 PIN → 完成步骤
      final ok = await _setupLockAndEnter(
        server: _server,
        spaceId: enroll.spaceId,
        deviceId: enroll.deviceId,
        spaceKeyB64: base64Encode(spaceKey),
        keyVersion: 1,
        token: session.sessionToken,
      );
      if (!mounted) return;
      if (ok) {
        setState(() {
          _step = 4;
          _status = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageImportFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// 设置启动锁对话框（两段式）：
/// 阶段 1：输入 PIN（两次确认）→ AppLockService.setPin 加密 Space Key 包；
/// 阶段 2：展示 12 词恢复码（PIN 丢失兑底），确认已保存后关闭并进入聊天页。
class SetPinDialog extends StatefulWidget {
  const SetPinDialog({super.key, required this.payload});

  final AppLockPayload payload;

  @override
  State<SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<SetPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  final _escrowPassphrase = TextEditingController();
  late final AppLockService _lock;
  bool _stage2 = false;
  bool _busy = false;
  String? _error;
  String? _recoveryCode;
  String? _escrowStatus;

  @override
  void initState() {
    super.initState();
    _lock = AppLockService(LocalDatabase());
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    _escrowPassphrase.dispose();
    super.dispose();
  }

  Future<void> _setup() async {
    final pin = _pin.text;
    if (pin.length < 4) {
      setState(() => _error = AppLocalizations.of(context)!.setPinDialogPinTooShort);
      return;
    }
    if (pin != _confirm.text) {
      setState(() => _error = AppLocalizations.of(context)!.setPinDialogPinMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final escrowPass = _escrowPassphrase.text.trim();
      // 接入口令（与 App 锁 PIN 区分，KEY_ESCROW.md）：非空则一并加密保存
      final payload = AppLockPayload(
        server: widget.payload.server,
        spaceId: widget.payload.spaceId,
        deviceId: widget.payload.deviceId,
        spaceKeyB64: widget.payload.spaceKeyB64,
        keyVersion: widget.payload.keyVersion,
        token: widget.payload.token,
        escrowPassphrase: escrowPass.isEmpty ? null : escrowPass,
      );
      final code = await _lock.setPin(pin, payload: payload);
      if (escrowPass.isNotEmpty) {
        await _uploadEscrow(escrowPass, payload);
      }
      if (!mounted) return;
      setState(() {
        _recoveryCode = code;
        _stage2 = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = AppLocalizations.of(context)!.setPinDialogSetupFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 口令加密 Space Key 包并上传托管（Server 只存密文；失败不阻塞进入聊天）。
  Future<void> _uploadEscrow(String passphrase, AppLockPayload payload) async {
    final l10n = AppLocalizations.of(context)!; // await 前取，避免跨 async gap 用 context
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
      _escrowStatus = l10n.setPinDialogEscrowUploaded;
    } catch (e) {
      _escrowStatus = l10n.setPinDialogEscrowUploadFailed('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(_stage2 ? l10n.setPinDialogRecoveryTitle : l10n.setPinDialogTitle),
      content: _stage2 ? _buildRecovery() : _buildPinForm(),
      actions: [
        if (!_stage2)
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.skip)),
        if (_stage2)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.setPinDialogEnterChat),
          ),
      ],
    );
  }

  Widget _buildPinForm() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.setPinDialogIntro),
        const SizedBox(height: 12),
        TextField(
          controller: _pin,
          obscureText: true,
          decoration: InputDecoration(labelText: l10n.setPinDialogPinLabel, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _confirm,
          obscureText: true,
          decoration: InputDecoration(labelText: l10n.setPinDialogConfirmLabel, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _escrowPassphrase,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.setPinDialogEscrowLabel,
            helperText: l10n.setPinDialogEscrowHelper,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _setup,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.setPinDialogSetPin),
        ),
      ],
    );
  }

  Widget _buildRecovery() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.setPinDialogRecoveryIntro, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Card(
          color: Colors.amber.shade50,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(_recoveryCode ?? '', style: const TextStyle(fontSize: 14)),
          ),
        ),
        if (_escrowStatus != null) ...[
          const SizedBox(height: 8),
          Text(_escrowStatus!, style: const TextStyle(fontSize: 12)),
        ],
        const SizedBox(height: 8),
        Text(l10n.setPinDialogRecoveryWarning,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

/// 扫码加入页（B 端）：MobileScanner 懒构造——进入页面才实例化
/// （widget 测试不进入此页，不触碰原生相机通道）。
class _JoinScanPage extends StatefulWidget {
  const _JoinScanPage();

  @override
  State<_JoinScanPage> createState() => _JoinScanPageState();
}

class _JoinScanPageState extends State<_JoinScanPage> {
  late final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      final info = JoinInfo.decode(raw);
      if (info != null) {
        _handled = true;
        Navigator.of(context).pop(info);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.scanJoinTitle)),
      body: Column(
        children: [
          Expanded(child: MobileScanner(controller: _controller, onDetect: _onDetect)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(l10n.scanJoinHint, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
