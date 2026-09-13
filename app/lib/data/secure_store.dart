import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 密钥安全存储封装（iOS Keychain / Android Keystore / 桌面等价物）。
///
/// - 承载不落 SQLite 的敏感材料：Space Key 包、token、设备密钥对等（DATABASE.md §4）
/// - 所有 key 统一 `einz.secure.` 前缀，避免与其他应用数据混淆；
///   deleteAll 只清理本前缀，不误伤 Keychain 里其他条目
/// - 单例持有，进程内复用同一份平台配置
class SecureStore {
  SecureStore._();

  static const _prefix = 'einz.secure.';

  static final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static String _key(String name) => '$_prefix$name';

  /// 读取；不存在或平台不可用返回 null（调用方按"未配置"处理）。
  static Future<String?> read(String name) async {
    try {
      return await _storage.read(key: _key(name));
    } on UnsupportedError {
      return null; // 测试环境 / 未支持平台：视为无密钥
    }
  }

  /// 写入（value 为 null 等价删除）。
  static Future<void> write(String name, String? value) async {
    await _storage.write(key: _key(name), value: value);
  }

  /// 删除单个条目（不存在时静默）。
  static Future<void> delete(String name) async {
    await _storage.delete(key: _key(name));
  }

  /// 批量删除：只删 `einz.secure.` 前缀下的条目（Keychain deleteAll 是全局的，
  /// 不能直接用——逐 key 删除以保证范围收敛）。
  static Future<void> deleteAll(Iterable<String> names) async {
    for (final name in names) {
      await delete(name);
    }
  }

  /// 检查条目是否存在。
  static Future<bool> contains(String name) async {
    if (kIsWeb) return (await read(name)) != null;
    return _storage.containsKey(key: _key(name));
  }
}
