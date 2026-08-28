import 'package:flutter/material.dart';

import 'package:onlyspace_shared/onlyspace_shared.dart';

/// OnlySpace 移动端入口。
///
/// Phase 0 骨架：验证 app 工程已接入 shared 核心包（crypto / protocol / sync），
/// 首屏提供"生成设备密钥"自检，密钥展示复用 shared 的 [DeviceKeyPair]。
/// 安全存储（Keychain/Keystore）与消息界面见 projectPlan Phase 1/3。
void main() {
  runApp(const OnlySpaceApp());
}

class OnlySpaceApp extends StatelessWidget {
  const OnlySpaceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OnlySpace',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const DeviceSetupPage(),
    );
  }
}

/// 设备设置页：生成设备身份密钥（接入 shared 核心包的自检入口）。
class DeviceSetupPage extends StatefulWidget {
  const DeviceSetupPage({super.key});

  @override
  State<DeviceSetupPage> createState() => _DeviceSetupPageState();
}

class _DeviceSetupPageState extends State<DeviceSetupPage> {
  DeviceKeyPair? _keyPair;
  String? _error;
  bool _busy = false;

  Future<void> _generateDeviceKey() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 首次调用会加载 libsodium（shared 的 loadDynamicLibrary 策略）
      final pair = await DeviceKeyPair.generate(deviceId: 'dev-mobile');
      if (!mounted) return; // P3 修复：异步间隙后组件可能已销毁，避免 setState-after-dispose
      setState(() => _keyPair = pair);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'libsodium 加载或密钥生成失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OnlySpace')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '两个人的私密聊天与共享私人空间',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Phase 0 骨架：shared 核心包（crypto / protocol / sync）已接入',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            if (_keyPair != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('设备 ID: ${_keyPair!.deviceId}'),
                      const SizedBox(height: 8),
                      SelectableText('公钥: ${_keyPair!.publicKeyB64}'),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!),
                ),
              ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _generateDeviceKey,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('生成设备密钥'),
            ),
          ],
        ),
      ),
    );
  }
}
