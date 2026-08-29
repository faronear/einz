import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

import 'chat_page.dart';
import 'data/app_lock.dart';
import 'data/local_database.dart';

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
  final _server = TextEditingController(text: 'https://only.tic.cc');
  final _spaceId = TextEditingController(text: 'space-demo');
  final _sealedKey = TextEditingController();

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
      setState(() => _status = '❌ 密钥生成失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入 Space Key 并认证。
  /// sealed 粘贴框填密封副本（本设备私钥解开）；为空时提示先填（或填明文 base64）。
  Future<void> _importAndAuth() async {
    final kp = _keyPair;
    if (kp == null) {
      setState(() => _status = '⚠️ 先生成设备密钥');
      return;
    }
    final sealedRaw = _sealedKey.text.trim();
    if (sealedRaw.isEmpty) {
      setState(() => _status = '⚠️ 请粘贴密封的 Space Key 副本（base64）');
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
      final api = ApiClient(_server.text.trim());
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
        server: _server.text.trim(),
        spaceId: _spaceId.text.trim(),
        deviceId: kp.deviceId,
        spaceKeyB64: base64Encode(spaceKey),
        keyVersion: 1,
        token: session.sessionToken,
      );
      if (ok && mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => ChatPage(
            server: _server.text.trim(),
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
      setState(() => _status = '❌ 导入/认证失败: $e');
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
        ),
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OnlySpace · 设备配置')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('一次性配置', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            '1) 生成设备密钥 → 公钥加入服务器白名单（config.json）并重启\n'
            '2) 粘贴对方用你公钥密封的 Space Key 副本 → 认证',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(controller: _deviceId, decoration: const InputDecoration(labelText: '设备 ID')),
          const SizedBox(height: 12),
          TextField(controller: _server, decoration: const InputDecoration(labelText: '服务器地址')),
          const SizedBox(height: 12),
          TextField(controller: _spaceId, decoration: const InputDecoration(labelText: 'Space ID')),
          const SizedBox(height: 12),
          TextField(
            controller: _sealedKey,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '密封的 Space Key（base64）',
              hintText: '粘贴 sealed 副本（sealed-*.txt 内容）',
            ),
          ),
          const SizedBox(height: 16),
          if (_keyPair != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  '设备 ID: ${_keyPair!.deviceId}\n'
                  '公钥: ${_keyPair!.publicKeyB64}\n'
                  '（把公钥加入 config.json 后重启服务器）',
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
                  child: const Text('① 生成设备密钥'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _importAndAuth,
                  child: const Text('② 导入并认证'),
                ),
              ),
            ],
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
  late final AppLockService _lock;
  bool _stage2 = false;
  bool _busy = false;
  String? _error;
  String? _recoveryCode;

  @override
  void initState() {
    super.initState();
    _lock = AppLockService(LocalDatabase());
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _setup() async {
    final pin = _pin.text;
    if (pin.length < 4) {
      setState(() => _error = 'PIN 至少 4 位');
      return;
    }
    if (pin != _confirm.text) {
      setState(() => _error = '两次输入的 PIN 不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await _lock.setPin(pin, payload: widget.payload);
      if (!mounted) return;
      setState(() {
        _recoveryCode = code;
        _stage2 = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '设置失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_stage2 ? '保存恢复码' : '设置启动锁'),
      content: _stage2 ? _buildRecovery() : _buildPinForm(),
      actions: [
        if (!_stage2)
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('跳过')),
        if (_stage2)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('我已保存，进入聊天'),
          ),
      ],
    );
  }

  Widget _buildPinForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('每次启动需输入 PIN 才能查看消息；Space Key 将被 PIN 加密保护。'),
        const SizedBox(height: 12),
        TextField(
          controller: _pin,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'PIN（至少 4 位）', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _confirm,
          obscureText: true,
          decoration: const InputDecoration(labelText: '确认 PIN', border: OutlineInputBorder()),
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
              : const Text('设置 PIN'),
        ),
      ],
    );
  }

  Widget _buildRecovery() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('请离线保存以下恢复码（PIN 丢失时用它解锁）：', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Card(
          color: Colors.amber.shade50,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(_recoveryCode ?? '', style: const TextStyle(fontSize: 14)),
          ),
        ),
        const SizedBox(height: 8),
        const Text('恢复码与 PIN 分开保存；丢失恢复码且忘记 PIN 将无法解锁。',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
