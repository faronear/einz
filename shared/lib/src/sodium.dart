import 'dart:ffi';
import 'dart:io';

import 'package:sodium/sodium.dart';

export 'package:sodium/sodium_sumo.dart' show SodiumSumoInit; // pwhash（Argon2id）需 sumo 构建

Sodium? _sodium;

/// 返回全局唯一的 [Sodium] 实例（懒加载，幂等）。
///
/// 加载策略：
/// - 优先使用环境变量 `LIBSODIUM_PATH`；
/// - macOS（Homebrew 默认路径 /opt/homebrew 与 /usr/local 都试）；
/// - Linux 常见路径；
/// - Windows 尝试 libsodium.dll。
Future<Sodium> sodium() async {
  if (_sodium != null) return _sodium!;
  _sodium = await SodiumInit.init2(loadDynamicLibrary);
  return _sodium!;
}

/// 重置（仅测试用）。
void resetSodium() {
  _sodium = null;
}

Future<DynamicLibrary> loadDynamicLibrary() async {
  // iOS：libsodium 以静态库形式链接进 app 二进制（本地 pod libsodium，
  // vendored xcframework + -force_load，见 app/ios/Libraries/libsodium.podspec），
  // 符号在进程内 → DynamicLibrary.process()。若未来改用动态 framework，改回 open('libsodium.dylib')。
  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  final candidates = <String>[
    if (Platform.environment.containsKey('LIBSODIUM_PATH'))
      Platform.environment['LIBSODIUM_PATH']!,
    if (Platform.isMacOS) ...[
      '/opt/homebrew/lib/libsodium.dylib',
      '/usr/local/lib/libsodium.dylib',
    ],
    if (Platform.isLinux) ...[
      '/usr/local/lib/libsodium.so',
      '/usr/lib/libsodium.so',
      '/lib/x86_64-linux-gnu/libsodium.so',
    ],
    if (Platform.isWindows) 'libsodium.dll',
    // 移动端：原生库由宿主 App 打包（Android jniLibs 含 4 ABI 的 libsodium.so）
    if (Platform.isAndroid) 'libsodium.so',
  ];

  Object? lastError;
  for (final path in candidates) {
    try {
      return DynamicLibrary.open(path);
    } catch (e) {
      lastError = e;
    }
  }
  throw StateError('无法加载 libsodium（尝试过: $candidates）。错误: $lastError');
}
