import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:einz_shared/einz_shared.dart';

import 'local_database.dart';
import 'secure_store.dart';

/// App 启动锁（方案 B：PIN 加密密钥）。安全口径与威胁模型见 `docs/SECURITY.md`
/// §2/§4，密钥存储位置见 `docs/DATABASE.md` §4（原先指向的 docs/APP_LOCK.md 从未落地）。
///
/// - 首次设置 PIN：Argon2id 派生密钥加密"Space Key 包"（XChaCha20，复用 backup.dart），
///   密文存 drift app_state；同时用 12 词恢复码再加密一份（PIN 丢失兑底）。
/// - 每次启动：输入 PIN → 解密成功才拿到 Space Key → 进入聊天页。
/// - 防爆破：连续错误 [maxAttempts] 次 → 锁定 [lockSeconds] 秒（纯本地，Server 不参与）。
/// - 跳过 PIN：明文 Space Key 包存系统安全存储（Keychain/Keystore，SecureStore），
///   不再落 SQLite（老板 2026-09-14：消除 app_state 明文密钥）。
/// - **卸载即重置**（老板 2026-09-14 决策，见 [ensureFreshInstall]）：安全存储条目会
///   活过 App 卸载（iOS/macOS Keychain、Linux libsecret；Android/Windows 落在应用数据
///   目录里卸载即清），故全新安装时清掉上一次安装的残留，语义与设 PIN 用户一致。
class AppLockService {
  AppLockService(this.db);

  final LocalDatabase db;

  /// 明文 Space Key 包在 SecureStore 里的条目名（自动加 einz.secure. 前缀）。
  static const _securePlain = 'app_lock.plain';

  /// SecureStore 里属于本 App 的条目清单（[ensureFreshInstall] 清理用；新增条目须登记）。
  static const _secureKeys = [_securePlain];

  static const int maxAttempts = 5;
  static const int lockSeconds = 30;

  /// 锁屏码规则（老板 2026-09-11 定稿：与 CLI 一致——只允许数字，至少
  /// [pinMinLength] 位；6 位数字约 20 bit，明显强于 4 位的 13 bit）。
  /// 仅约束设置/修改；已有更短的旧 PIN 解锁不受影响。
  static const int pinMinLength = 6;

  /// 锁屏码是否只含数字（键盘为数字键盘，但可粘贴/外接键盘输入字母——需显式校验）。
  static bool isPinDigitsOnly(String pin) => RegExp(r'^\d+$').hasMatch(pin);

  static const _kPackage = 'app_lock.package';
  static const _kAttempts = 'app_lock.attempts';
  static const _kLockedUntil = 'app_lock.locked_until';
  static const _kPlain = 'app_lock.plain'; // 【遗留】旧版明文包在 app_state 的键（仅迁移读取）
  static const _kSkipped = 'app_lock.skipped'; // '1' = 用户确认暂不设锁
  static const _kProfile = 'app_lock.profile'; // JSON: {personName, peerName, deviceName}

  /// 本次安装的标记（随机 id）。**非密钥、非敏感**——它的全部意义就是"沙盒里有没有
  /// 东西"：drift 库随 App 卸载消失，安全存储条目不会，故"标记不在"= 全新安装。
  static const _kInstallId = 'app_lock.install_id';

  /// 是否已设置启动锁（有 PIN 加密的密钥包）。
  Future<bool> get isSetup async => await _get(_kPackage) != null;

  /// 本设备是否已配置（设锁或跳过均算；StartupGate 据此决定直接进聊天）。
  Future<bool> get hasConfig async =>
      await isSetup || await loadPlain() != null;

  /// 全新安装检测 + 上一次安装残留清理（老板 2026-09-14 决策：卸载即重置）。
  ///
  /// 安全存储条目会活过 App 卸载（iOS/macOS Keychain、Linux libsecret），而 drift
  /// 库不会。所以"沙盒里没有本次安装标记"≈"沙盒被清过 = 全新安装"，此时清掉上一次
  /// 安装残留的密钥条目——否则"跳过 PIN"的用户卸载重装会被直接拖进聊天，与"设了
  /// PIN"的用户（锁包在 drift，随沙盒一起消失）行为不一致。
  ///
  /// 幂等，启动流程里可重复调用。iOS"卸载 App（保留数据）"、iCloud/整机备份恢复都会
  /// 把沙盒带回来（标记仍在）→ 不会误清。跨设备泄漏另由 SecureStore 的
  /// `..._this_device` 无障碍级别兜住（条目不随备份迁移）。
  Future<void> ensureFreshInstall() async {
    if (await _get(_kInstallId) != null) return; // 同一安装：什么都不做
    await SecureStore.deleteAll(_secureKeys); // 全新安装：清残留（无残留则静默）
    await _set(_kInstallId, _newInstallId());
  }

  /// 随机安装标记（16 字节 hex）。只用于判定"沙盒是否为空"，无密码学用途。
  static String _newInstallId() {
    final r = Random.secure();
    return List.generate(
        16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 明文保存 Space Key 包（跳过 PIN 场景）：无锁包但有此明文时，
  /// 下次启动直接进聊天（免打扰），直到用户在聊天页补设 PIN。
  /// 存系统安全存储（Keychain/Keystore），SQLite 不再保留明文副本。
  Future<void> savePlain(AppLockPayload payload) async {
    await SecureStore.write(_securePlain, jsonEncode(payload.toJson()));
    await _set(_kSkipped, '1');
    await _deletePlainFromDb(); // 兼容：清掉旧版本可能残留的明文副本
  }

  /// 读取明文 Space Key 包（跳过 PIN 的无锁配置）；不存在返回 null。
  ///
  /// 兼容旧版：包还在 app_state（明文落 SQLite）时自动迁移到 SecureStore，
  /// 并删除 app_state 里的明文副本；迁移失败视为未配置（宁可重新引导）。
  Future<AppLockPayload?> loadPlain() async {
    final raw = await SecureStore.read(_securePlain) ?? await _get(_kPlain);
    if (raw == null) return null;
    try {
      final payload = AppLockPayload.fromJson(jsonDecode(raw));
      if (await _get(_kPlain) != null) {
        await SecureStore.write(_securePlain, raw);
        await _deletePlainFromDb();
      }
      return payload;
    } catch (_) {
      return null; // 明文损坏视为未配置（宁可重新引导）
    }
  }

  /// 清除无锁配置（补设 PIN 成功后调用：不再保留明文副本）。
  Future<void> clearPlain() async {
    await SecureStore.delete(_securePlain);
    await _deletePlainFromDb();
    await (db.delete(db.appState)..where((s) => s.key.equals(_kSkipped))).go();
  }

  /// 清除本地锁与密钥包（设备被撤销时调用：回到未配置状态，防止残留密钥）。
  Future<void> clear() async {
    await SecureStore.delete(_securePlain);
    await (db.delete(db.appState)
          ..where((s) => s.key.isIn({_kPackage, _kAttempts, _kLockedUntil, _kPlain, _kSkipped})))
        .go();
  }

  /// 删除 app_state 里的旧版明文包（迁移/清理用）。
  Future<void> _deletePlainFromDb() async {
    await (db.delete(db.appState)..where((s) => s.key.equals(_kPlain))).go();
  }

  /// 取消启动锁（"设为空"）：删除加密包，保留明文配置（Space Key 仍可进聊天）。
  Future<void> clearPackage() async {
    await (db.delete(db.appState)
          ..where((s) => s.key.equals(_kPackage)))
        .go();
  }

  /// 设置 PIN 并加密保存 Space Key 包（老板决策：不再生成 12 词恢复码）。
  /// 注意：PIN 丢失则本设备 Space Key 包无法解密（无恢复副本，纯本地）。
  Future<void> setPin(String pin, {required AppLockPayload payload}) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));
    final pkg = await encryptWithPassphrase(payload: bytes, passphrase: pin);

    await _set(_kPackage, jsonEncode(pkg.toJson()));
    await _set(_kAttempts, '0');
    await _set(_kLockedUntil, '0');
    await clearPlain(); // 补设 PIN 后不再保留明文副本
  }

  /// 恢复码兑底已删除（老板决策）：PIN 丢失即无法解锁本设备密钥包。
  Future<AppLockPayload> unlock(String pin) async {
    await _ensureNotLocked();
    final raw = await _get(_kPackage);
    if (raw == null) throw const AppLockException('尚未设置锁屏码');
    try {
      final plain = await decryptWithPassphrase(envelope: PassphraseEnvelope.fromJson(jsonDecode(raw)), passphrase: pin);
      await _set(_kAttempts, '0');
      return AppLockPayload.fromJson(jsonDecode(utf8.decode(plain)));
    } on FormatException {
      await _registerFailure();
      throw const AppLockException('锁屏码 错误');
    }
  }

  /// 剩余锁定秒数（0 = 未锁定）。
  Future<int> get remainingLockSeconds async {
    final until = int.tryParse(await _get(_kLockedUntil) ?? '0') ?? 0;
    final remain = until - DateTime.now().millisecondsSinceEpoch;
    return remain > 0 ? (remain / 1000).ceil() : 0;
  }

  Future<void> _ensureNotLocked() async {
    final remain = await remainingLockSeconds;
    if (remain > 0) throw AppLockLockedException('尝试次数过多，请 $remain 秒后再试', remain);
  }

  Future<void> _registerFailure() async {
    final n = (int.tryParse(await _get(_kAttempts) ?? '0') ?? 0) + 1;
    if (n >= maxAttempts) {
      await _set(_kLockedUntil, '${DateTime.now().millisecondsSinceEpoch + lockSeconds * 1000}');
      await _set(_kAttempts, '0');
    } else {
      await _set(_kAttempts, '$n');
    }
  }

  Future<String?> _get(String key) async {
    final row = await (db.select(db.appState)..where((s) => s.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _set(String key, String value) async {
    await (db.into(db.appState)).insertOnConflictUpdate(
      AppStateCompanion.insert(key: key, value: value),
    );
  }

  /// 用户资料（名字）持久化：向导完成时保存，PIN 解锁/重启后 ChatPage 恢复显示。
  /// （名字不在 AppLockPayload 里——解锁构造 ChatPage 时无法获得，故单独存。）
  Future<void> saveProfile({
    required String personName,
    required String peerName,
    required String deviceName,
    String myGender = '', // 本人性别（male/female；个人资料弹窗图标展示用）
    String peerGender = '', // 对方性别（male/female；消息气泡配色用）
    int? mySlot, // 本人身份槽位（0=第一人/创建者，1=第二人；同性别气泡青色用）
    int? peerSlot, // 对方身份槽位（同上；对方气泡配色判定用）
  }) async {
    await _set(_kProfile, jsonEncode({
      'personName': personName,
      'peerName': peerName,
      'deviceName': deviceName,
      'myGender': myGender,
      'peerGender': peerGender,
      'mySlot': mySlot,
      'peerSlot': peerSlot,
    }));
  }

  /// 读回保存的资料（键缺失返回空串——解锁场景 ChatPage 空名时恢复）。
  Future<Map<String, Object?>> loadProfile() async {
    final raw = await _get(_kProfile);
    if (raw == null) return const {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {
        'personName': (m['personName'] as String?) ?? '',
        'peerName': (m['peerName'] as String?) ?? '',
        'deviceName': (m['deviceName'] as String?) ?? '',
        'myGender': (m['myGender'] as String?) ?? '',
        'peerGender': (m['peerGender'] as String?) ?? '',
        'mySlot': (m['mySlot'] as num?)?.toInt(),
        'peerSlot': (m['peerSlot'] as num?)?.toInt(),
      };
    } catch (_) {
      return const {};
    }
  }
}

/// 被 PIN/恢复码加密保护的 Space Key 包（解密成功后进入聊天所需的一切）。
class AppLockPayload {
  const AppLockPayload({
    required this.server,
    required this.spaceKeyB64,
    required this.spaceId,
    required this.deviceId,
    this.keyVersion = 1,
    this.token,
    this.escrowUpdatedAt,
    this.publicKeyB64,
    this.privateKeyB64,
  });

  final String server;
  final String spaceKeyB64;
  final String spaceId;
  final String deviceId;
  final int keyVersion;
  final String? token;

  /// 本端已知的服务端口令更新时间（ms）：上线时与服务器对比，
  /// 服务器更新 = 离线期间口令被重设（应弹窗重新验证）。
  final int? escrowUpdatedAt;

  /// 设备 X25519 密钥对（b64）：随锁包持久化——重启后 challenge-response
  /// 重新认证（reauth）需用私钥签名；「我的设备」弹窗展示公钥。旧包无此字段。
  final String? publicKeyB64;
  final String? privateKeyB64;

  Map<String, dynamic> toJson() => {
        'server': server,
        'space_key': spaceKeyB64,
        'space_id': spaceId,
        'device_id': deviceId,
        'key_version': keyVersion,
        'token': token,
        'escrow_updated_at': escrowUpdatedAt,
        'device_public_key': publicKeyB64,
        'device_private_key': privateKeyB64,
      };

  factory AppLockPayload.fromJson(Map<String, dynamic> json) => AppLockPayload(
        server: json['server'] as String,
        spaceKeyB64: json['space_key'] as String,
        spaceId: json['space_id'] as String,
        deviceId: json['device_id'] as String,
        keyVersion: (json['key_version'] as int?) ?? 1,
        token: json['token'] as String?,
        escrowUpdatedAt: json['escrow_updated_at'] as int?,
        publicKeyB64: json['device_public_key'] as String?,
        privateKeyB64: json['device_private_key'] as String?,
      );
}

/// 用锁包里的设备密钥对完成 challenge-response 重新认证（重启后 reauth 用：
/// 会话过期 401/4401 时自动续期）。锁包无密钥对（旧包）时抛 [StateError]。
Future<String> reauthFromPayload(AppLockPayload payload) async {
  final pub = payload.publicKeyB64;
  final priv = payload.privateKeyB64;
  if (pub == null || priv == null || pub.isEmpty || priv.isEmpty) {
    throw StateError('锁包无设备密钥对');
  }
  final s = await sodium();
  final api = ApiClient(payload.server);
  final challenge = await api.challenge(payload.deviceId);
  final opened = await sealOpen(
    s,
    base64Decode(challenge.sealedChallenge),
    base64Decode(pub),
    base64Decode(priv),
  );
  return (await api.verify(challenge.challengeId, base64Encode(opened))).sessionToken;
}

class AppLockException implements Exception {
  const AppLockException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppLockLockedException extends AppLockException {
  const AppLockLockedException(super.message, this.remainingSeconds);
  final int remainingSeconds;
}
