import 'package:flutter/material.dart';

import 'setup_page.dart';

/// OnlySpace 移动端入口。
///
/// Phase 3：设置页（一次性配置/认证）→ 聊天页（发送/同步）。
/// 安全存储（Keychain/Keystore）见 projectPlan 后续阶段。
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
      home: const SetupPage(),
    );
  }
}


