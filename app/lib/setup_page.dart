import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

import 'chat_page.dart';

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

      // 3) 进入聊天页
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '❌ 导入/认证失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
