import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'l10n/app_localizations.dart';

/// 服务器固定地址（产品部署域名固定，无需用户输入）。
const String kOnlySpaceServer = 'https://only.tic.cc';

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

  @override
  void dispose() {
    _deviceId.dispose();
    _spaceId.dispose();
    _sealedKey.dispose();
    _escrowPassphrase.dispose();
    super.dispose();
  }

  DeviceKeyPair? _keyPair;
  String? _status;
  bool _busy = false;

  Future<void> _generateKey() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final pair = await DeviceKeyPair.generate(deviceId: _deviceId.text.trim());
      if (!mounted) return;
      setState(() => _keyPair = pair);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageKeyGenFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入 Space Key 并认证。
  /// sealed 粘贴框填密封副本（本设备私钥解开）；为空时提示先填（或填明文 base64）。
  Future<void> _importAndAuth() async {
    final kp = _keyPair;
    if (kp == null) {
      setState(() => _status = AppLocalizations.of(context)!.setupPageGenKeyFirst);
      return;
    }
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
      final s = await sodium();
      // 1) 解封 Space Key
      final spaceKey = await sealOpen(
        s,
        base64Decode(sealedRaw),
        kp.publicKey,
        kp.privateKey,
      );

      // 2) challenge-response 认证
      final api = ApiClient(kOnlySpaceServer);
      final challenge = await api.challenge(kp.deviceId);
      final opened = await sealOpen(
        s,
        base64Decode(challenge.sealedChallenge),
        kp.publicKey,
        kp.privateKey,
      );
      final session = await api.verify(challenge.challengeId, base64Encode(opened));
      if (!mounted) return;

      // 3) 先设置启动锁（PIN 加密 Space Key 包），再进入聊天页
      final ok = await _setupLockAndEnter(
        server: kOnlySpaceServer,
        spaceId: _spaceId.text.trim(),
        deviceId: kp.deviceId,
        spaceKeyB64: base64Encode(spaceKey),
        keyVersion: 1,
        token: session.sessionToken,
      );
      if (ok && mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => ChatPage(
            server: kOnlySpaceServer,
            spaceId: _spaceId.text.trim(),
            deviceId: kp.deviceId,
            spaceKey: spaceKey,
            keyVersion: 1,
            token: session.sessionToken,
          ),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageImportFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 认证成功后设置启动锁：弹对话框输入 PIN（两次确认）→ 生成恢复码展示 → 确认后进聊天页。
  /// 返回 true 表示 PIN 已设置完成。
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

  /// 新设备凭口令接入（KEY_ESCROW.md §5）：认证 → 拉取托管包 → 口令解密
  /// 解出 Space Key → 设置 PIN → 进聊天页。无需 sealed 副本。
  Future<void> _escrowAccess() async {
    if (_keyPair == null) {
      setState(() => _status = AppLocalizations.of(context)!.setupPageEscrowGenKeyFirst);
      return;
    }
    final server = kOnlySpaceServer;
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
      final api = ApiClient(server);
      final s = await sodium();

      // 1) challenge-response 认证
      final challenge = await api.challenge(_keyPair!.deviceId);
      final opened = await sealOpen(
        s,
        base64Decode(challenge.sealedChallenge),
        _keyPair!.publicKey,
        _keyPair!.privateKey,
      );
      final session = await api.verify(challenge.challengeId, base64Encode(opened));

      // 2) 拉取托管包并口令解密
      final escrow = KeyEscrowService(api);
      final payload = await escrow.fetch(passphrase: passphrase, token: session.sessionToken);
      if (payload == null) {
        if (!mounted) return;
        setState(() => _status = AppLocalizations.of(context)!.setupPageNoEscrow);
        return;
      }
      final spaceKey = base64Decode(payload.spaceKeyB64);
      if (!mounted) return;

      // 3) 设置 PIN（含接入口令）→ 进聊天页
      final ok = await _setupLockAndEnter(
        server: server,
        spaceId: payload.spaceId,
        deviceId: _keyPair!.deviceId,
        spaceKeyB64: payload.spaceKeyB64,
        keyVersion: payload.keyVersion,
        token: session.sessionToken,
        escrowPassphrase: passphrase,
      );
      if (ok && mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => ChatPage(
            server: server,
            spaceId: payload.spaceId,
            deviceId: _keyPair!.deviceId,
            spaceKey: spaceKey,
            keyVersion: payload.keyVersion,
            token: session.sessionToken,
          ),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = AppLocalizations.of(context)!.setupPageEscrowFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.setupPageTitle)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.setupPageHeading, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            l10n.setupPageInstructions,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(controller: _deviceId, decoration: InputDecoration(labelText: l10n.setupPageDeviceIdLabel)),
          const SizedBox(height: 12),
          TextField(controller: _spaceId, decoration: InputDecoration(labelText: l10n.setupPageSpaceIdLabel)),
          const SizedBox(height: 12),
          TextField(
            controller: _sealedKey,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: l10n.setupPageSealedKeyLabel,
              hintText: l10n.setupPageSealedKeyHint,
            ),
          ),
          const SizedBox(height: 16),
          if (_keyPair != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  l10n.setupPageKeyInfo(_keyPair!.deviceId, _keyPair!.publicKeyB64),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _generateKey,
                  child: Text(l10n.setupPageGenerateKey),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _importAndAuth,
                  child: Text(l10n.setupPageImportAuth),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _escrowPassphrase,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.setupPageEscrowLabel,
              helperText: l10n.setupPageEscrowHelper,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: _busy ? null : _escrowAccess,
            child: Text(l10n.setupPageEscrowAccess),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: const TextStyle(fontSize: 13)),
          ],
        ],
      ),
    );
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
