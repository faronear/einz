import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'l10n/app_localizations.dart';

/// 服务器固定地址（产品部署域名固定，无需用户输入）。
const String kOnlySpaceServer = 'https://only.tic.cc';

/// 向导角色（第 0 步选择）：创建新空间 / 加入现有空间 / 高级导入 sealed。
enum _WizardRole { create, join, advanced }

/// 设置页：一次性配置（生成设备身份 → 登记白名单 → 导入 Space Key → 认证）。
///
/// 与 CLI 的 init/pubkey/import/auth 流程对齐（docs/DEPLOYMENT.md §4）：
/// 1. 生成 X25519 身份密钥（私钥留在 App 内；公钥需加入服务器白名单 config.json 并重启）
/// 2. 导入 Space Key：粘贴 sealed 密封副本（base64，由对方用本公钥 seal），或直接粘贴明文 base64
/// 3. challenge-response 认证，拿到 session_token
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _deviceId = TextEditingController(text: 'dev-mobile');
  final _spaceId = TextEditingController(text: 'space-demo');
  final _sealedKey = TextEditingController();
  final _escrowPassphrase = TextEditingController();

  // 向导状态：角色分流 + 步骤索引 + 跨步骤共享数据
  _WizardRole? _role;
  int _step = 0;
  DeviceKeyPair? _keyPair;
  Uint8List? _spaceKey;
  String? _sessionToken;
  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _deviceId.dispose();
    _spaceId.dispose();
    _sealedKey.dispose();
    _escrowPassphrase.dispose();
    super.dispose();
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
          case 2: return l10n.wizardStepWhitelist;
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
    if (_role == _WizardRole.create && _step == 3 && _escrowPassphrase.text.trim().isEmpty) {
      setState(() => _status = l10n.setupPageNeedPassphrase);
      return;
    }
    if (_role == _WizardRole.join &&
        _step == 2 &&
        (_spaceId.text.trim().isEmpty || _escrowPassphrase.text.trim().isEmpty)) {
      setState(() => _status = l10n.setupPageEscrowFillAll);
      return;
    }
    if (_role == _WizardRole.advanced && _step == 2 && _sealedKey.text.trim().isEmpty) {
      setState(() => _status = l10n.setupPagePasteSealed);
      return;
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
            return _buildStepWhitelist();
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
  Future<SessionResult> _authenticate(DeviceKeyPair kp) async {
    final s = await sodium();
    final api = ApiClient(kOnlySpaceServer);
    final challenge = await api.challenge(kp.deviceId);
    final opened = await sealOpen(
      s,
      base64Decode(challenge.sealedChallenge),
      kp.publicKey,
      kp.privateKey,
    );
    return api.verify(challenge.challengeId, base64Encode(opened));
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

  /// 完成动作：进入聊天页（create/join/advanced 填充数据后统一调用）。
  void _finish() {
    final kp = _keyPair;
    final sk = _spaceKey;
    final token = _sessionToken;
    if (kp == null || sk == null || token == null) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ChatPage(
        server: kOnlySpaceServer,
        spaceId: _spaceId.text.trim(),
        deviceId: kp.deviceId,
        spaceKey: sk,
        keyVersion: 1,
        token: token,
      ),
    ));
  }

  // ---- 场景 A（create）：设备名 → 白名单 → 口令 → PIN → 分享 → 完成 ----

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

  /// 步骤 2：白名单确认（展示公钥，用户去 VPS 添加后继续）。
  Widget _buildStepWhitelist() {
    final l10n = AppLocalizations.of(context)!;
    final kp = _keyPair;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardWhitelistHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        if (kp != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                l10n.setupPageKeyInfo(kp.deviceId, kp.publicKeyB64),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
      ],
    );
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
      // 2) 认证（缓存 session）
      var token = _sessionToken;
      if (token == null) {
        final session = await _authenticate(kp);
        token = session.sessionToken;
        _sessionToken = token;
      }
      // 3) 设置 PIN（含接入口令 → 上传托管）
      final ok = await _setupLockAndEnter(
        server: kOnlySpaceServer,
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

  /// 步骤 5：二维码加入信息分享（对方扫码/复制口令接入）。
  Widget _buildStepShare() {
    final l10n = AppLocalizations.of(context)!;
    final info = JoinInfo(
      spaceId: _spaceId.text.trim(),
      passphrase: _escrowPassphrase.text.trim(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.wizardShareHint, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 12),
        Center(child: QrImageView(data: info.encode(), version: QrVersions.auto, size: 180)),
        const SizedBox(height: 12),
        SelectableText(l10n.joinDialogSpace(info.spaceId), style: const TextStyle(fontSize: 12)),
        SelectableText(l10n.joinDialogPassphrase(info.passphrase),
            style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: info.encode()));
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(l10n.joinDialogCopied)));
          },
          child: Text(l10n.joinDialogCopy),
        ),
      ],
    );
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
      ],
    );
  }

  /// 扫码加入：扫描 A 的二维码 → 自动填入空间 ID 与口令。
  Future<void> _scanJoinCode() async {
    final l10n = AppLocalizations.of(context)!;
    final info = await Navigator.of(context).push<JoinInfo>(
      MaterialPageRoute(builder: (_) => const _JoinScanPage()),
    );
    if (info == null || !mounted) return;
    _spaceId.text = info.spaceId;
    _escrowPassphrase.text = info.passphrase;
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
      final session = await _authenticate(kp);
      _sessionToken = session.sessionToken;
      final escrow = KeyEscrowService(ApiClient(kOnlySpaceServer));
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
        server: kOnlySpaceServer,
        spaceId: payload.spaceId,
        deviceId: kp.deviceId,
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
      // 1) 解封 Space Key（本设备私钥解开）
      final s = await sodium();
      final spaceKey = await sealOpen(
        s,
        base64Decode(sealedRaw),
        kp.publicKey,
        kp.privateKey,
      );
      // 2) 认证
      final session = await _authenticate(kp);
      _sessionToken = session.sessionToken;
      _spaceKey = spaceKey;
      if (!mounted) return;
      // 3) 设置 PIN → 完成步骤
      final ok = await _setupLockAndEnter(
        server: kOnlySpaceServer,
        spaceId: _spaceId.text.trim(),
        deviceId: kp.deviceId,
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
