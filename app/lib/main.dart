import 'package:flutter/material.dart';

import 'data/app_lock.dart';
import 'data/local_database.dart';
import 'lock_page.dart';
import 'setup_page.dart';

/// OnlySpace 移动端入口。
///
/// 启动流程：检查是否已设置启动锁 → 已设置进锁屏页（PIN 解密 Space Key 包），
/// 未设置进一次性配置页（认证后设置 PIN）。
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
      home: const StartupGate(),
    );
  }
}

/// 启动门：读取本地锁状态决定首屏（锁屏页 or 设置页）。
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  bool? _locked;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final lock = AppLockService(LocalDatabase());
    final hasLock = await lock.isSetup;
    if (!mounted) return;
    setState(() => _locked = hasLock);
  }

  @override
  Widget build(BuildContext context) {
    if (_locked == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _locked! ? const LockPage() : const SetupPage();
  }
}


