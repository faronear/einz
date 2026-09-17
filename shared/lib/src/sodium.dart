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
  // iOS/macOS：libsodium 以静态库形式链接进 app 二进制（iOS: 本地 pod libsodium，
  // vendored xcframework + -force_load；macOS: 本地 pod libsodium-macos，
  // fat 静态库 + -force_load，见 app/macos/Libraries/libsodium-macos.podspec），
  // 符号在进程内 → 先试 DynamicLibrary.process()。
  // CLI（无静态链接）不受影响：process() 里查不到 sodium_init，回落文件路径。
  for (final lib in [DynamicLibrary.process()]) {
    if (lib.providesSymbol('sodium_init')) return lib;
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
