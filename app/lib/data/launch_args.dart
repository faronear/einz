import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 启动参数桥的通道名（原生侧见 macos/Runner/MainFlutterWindow.swift）。
const String kLaunchArgsChannel = 'einz.launch.args';

/// 读取进程启动参数。
///
/// macOS 经 `open -a Einz --args --server …` 启动时，Flutter 的
/// `Platform.executableArguments` 收不到参数（macOS embedder 不转发给 Dart
/// 侧），故走原生桥读 `ProcessInfo.processInfo.arguments`（原生侧已去掉首元素
/// 的执行文件路径）。其他桌面端直接用 `Platform.executableArguments`。
///
/// 调用方须先 `WidgetsFlutterBinding.ensureInitialized()`：平台通道依赖
/// services 绑定，未初始化时 invokeMethod 会抛错。
Future<List<String>> readLaunchArgs() async {
  if (Platform.isMacOS) {
    try {
      final result = await const MethodChannel(kLaunchArgsChannel)
          .invokeMethod<List<dynamic>>('get');
      if (result != null) return result.cast<String>();
    } catch (e) {
      // 桥读不到就退回 dart 侧，不让启动失败。这里必须留日志：曾因静默吞异常，
      // 导致 --server 两种启动方式都无效且极难定位。
      debugPrint('[launch] 启动参数桥读取失败，退回 Platform.executableArguments: $e');
    }
  }
  return Platform.executableArguments;
}

/// 从启动参数里解析 `--server` 的地址；未提供、缺值或空值一律返回 null。
///
/// 支持 `--server <地址>` 与 `--server=<地址>` 两种写法；重复出现时最后一个生效
/// （后写覆盖前写，与命令行惯例一致）。
String? parseServerArg(List<String> args) {
  String? server;
  for (int i = 0; i < args.length; i++) {
    final a = args[i];
    String? value;
    if (a == '--server') {
      if (i + 1 < args.length) value = args[i + 1];
    } else if (a.startsWith('--server=')) {
      value = a.substring('--server='.length);
    }
    if (value != null && value.isNotEmpty) server = value; // 空值等同未提供
  }
  return server;
}
