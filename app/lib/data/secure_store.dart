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

  /// key 前缀。默认 `einz.secure.`；桌面端 debug 脚本（package.json 的
  /// `desk-mac-run-local*`）会用 `--dart-define=einzSecurePrefix=…` 换成独立命名空间，
  /// 与 `einzDevDataDir`（SQLite/附件/缓存换个目录，见 dev_data_dir.dart）配成一对：
  /// debug 版和装机那份是同一个 app（同 bundle id、同沙盒容器），Keychain 里若不换
  /// 前缀，两边就会读写同一批条目——正式那份被覆盖等于丢密钥。
  /// ⚠ 发布脚本与 CI 绝不传这个 define（同 `docs/SERVER_SETTINGS.md` §6 的红线）。
  static const _prefix = String.fromEnvironment(
    'einzSecurePrefix',
    defaultValue: 'einz.secure.',
  );

  /// 无障碍级别选 `..._this_device`（iOS/macOS）：默认的 `unlocked` 会被
  /// **加密备份/换机恢复**带到新设备——用户换机还原备份即可读到旧消息。
  /// `this_device` 变体不随备份迁移（Apple 文档语义）。`synchronizable` 保持
  /// 默认 false（不走 iCloud Keychain 同步）。
  ///
  /// macOS 必须显式关掉**数据保护 Keychain**（`usesDataProtectionKeychain: false`，
  /// 插件默认是 true）。数据保护 Keychain 要 `keychain-access-groups` entitlement
  /// 背书，而该 entitlement 只能由 provisioning profile 授权；Developer ID 分发没有
  /// profile → 每次 SecItem* 都直接 `-34018 A required entitlement isn't present`
  /// （StartupGate 五连败 → "启动初始化失败，配置未丢失，请重试"）。
  /// **去沙盒不能解决这个问题**：无沙盒 + 无 entitlement 实测仍是 -34018；改成
  /// 老式文件型 Keychain 后同一签名下 SecItemAdd status=0（2026-09-20 实测）。
  /// 语义差异仅在 macOS 桌面端：文件型 Keychain 不支持 iCloud 同步/备份迁移，
  /// 而本应用本就 `synchronizable=false`（不走 iCloud），故此差异无实际影响。
  static final FlutterSecureStorage _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      usesDataProtectionKeychain: false,
    ),
  );

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
