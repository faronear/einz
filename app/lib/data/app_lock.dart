import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:einz_shared/einz_shared.dart';

import 'local_database.dart';

/// App 启动锁（方案 B：PIN 加密密钥，docs/APP_LOCK.md）。
///
/// - 首次设置 PIN：Argon2id 派生密钥加密"Space Key 包"（XChaCha20，复用 backup.dart），
///   密文存 drift app_state；同时用 12 词恢复码再加密一份（PIN 丢失兑底）。
/// - 每次启动：输入 PIN → 解密成功才拿到 Space Key → 进入聊天页。
/// - 防爆破：连续错误 [maxAttempts] 次 → 锁定 [lockSeconds] 秒（纯本地，Server 不参与）。
class AppLockService {
  AppLockService(this.db);

  final LocalDatabase db;

  static const int maxAttempts = 5;
  static const int lockSeconds = 30;

  static const _kPackage = 'app_lock.package';
  static const _kAttempts = 'app_lock.attempts';
  static const _kLockedUntil = 'app_lock.locked_until';
  static const _kPlain = 'app_lock.plain'; // 跳过 PIN：明文 Space Key 包（仅本设备）
  static const _kSkipped = 'app_lock.skipped'; // '1' = 用户确认暂不设锁
  static const _kProfile = 'app_lock.profile'; // JSON: {personName, peerName, deviceName}

  /// 是否已设置启动锁（有 PIN 加密的密钥包）。
  Future<bool> get isSetup async => await _get(_kPackage) != null;

  /// 本设备是否已配置（设锁或跳过均算；StartupGate 据此决定直接进聊天）。
  Future<bool> get hasConfig async =>
      await isSetup || await loadPlain() != null;

  /// 明文保存 Space Key 包（跳过 PIN 场景）：无锁包但有此明文时，
  /// 下次启动直接进聊天（免打扰），直到用户在聊天页补设 PIN。
  Future<void> savePlain(AppLockPayload payload) async {
    await _set(_kPlain, jsonEncode(payload.toJson()));
    await _set(_kSkipped, '1');
  }

  /// 读取明文 Space Key 包（跳过 PIN 的无锁配置）；不存在返回 null。
  Future<AppLockPayload?> loadPlain() async {
    final raw = await _get(_kPlain);
    if (raw == null) return null;
    try {
      return AppLockPayload.fromJson(jsonDecode(raw));
    } catch (_) {
      return null; // 明文损坏视为未配置（宁可重新引导）
    }
  }

  /// 清除无锁配置（补设 PIN 成功后调用：不再保留明文副本）。
  Future<void> clearPlain() async {
    await (db.delete(db.appState)
          ..where((s) => s.key.isIn({_kPlain, _kSkipped})))
        .go();
  }

  /// 清除本地锁与密钥包（设备被撤销时调用：回到未配置状态，防止残留密钥）。
  Future<void> clear() async {
    await (db.delete(db.appState)
          ..where((s) => s.key.isIn({_kPackage, _kAttempts, _kLockedUntil, _kPlain, _kSkipped})))
        .go();
  }

  /// 修改 escrow 口令后同步本地明文配置（跳过 PIN 场景）。
  /// 设 PIN 场景（加密包）因无 PIN 可用不动锁包——由 lock_page._syncEscrow
  /// 的上传前口令验证保护，防止旧口令覆盖新托管包。
  Future<void> updateEscrowPassphrase(String passphrase) async {
    final plain = await loadPlain();
    if (plain == null) return;
    await savePlain(AppLockPayload(
      server: plain.server,
      spaceKeyB64: plain.spaceKeyB64,
      spaceId: plain.spaceId,
      deviceId: plain.deviceId,
      keyVersion: plain.keyVersion,
      token: plain.token,
      escrowPassphrase: passphrase,
    ));
  }

  /// 设置 PIN 并加密保存 Space Key 包（老板决策：不再生成 12 词恢复码）。
  /// 注意：PIN 丢失则本设备 Space Key 包无法解密（无恢复副本，纯本地）。
  Future<void> setPin(String pin, {required AppLockPayload payload}) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));
    final pkg = await encryptBackup(payload: bytes, recoveryCode: pin);

    await _set(_kPackage, jsonEncode(pkg.toJson()));
    await _set(_kAttempts, '0');
    await _set(_kLockedUntil, '0');
    await clearPlain(); // 补设 PIN 后不再保留明文副本
  }

  /// 恢复码兑底已删除（老板决策）：PIN 丢失即无法解锁本设备密钥包。
  Future<AppLockPayload> unlock(String pin) async {
    await _ensureNotLocked();
    final raw = await _get(_kPackage);
    if (raw == null) throw const AppLockException('尚未设置 PIN 锁屏密码');
    try {
      final plain = await decryptBackup(file: BackupFile.fromJson(jsonDecode(raw)), recoveryCode: pin);
      await _set(_kAttempts, '0');
      return AppLockPayload.fromJson(jsonDecode(utf8.decode(plain)));
    } on FormatException {
      await _registerFailure();
      throw const AppLockException('PIN 锁屏密码 错误');
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
  }) async {
    await _set(_kProfile, jsonEncode({
      'personName': personName,
      'peerName': peerName,
      'deviceName': deviceName,
    }));
  }

  /// 读回保存的资料（键缺失返回空串——解锁场景 ChatPage 空名时恢复）。
  Future<Map<String, String>> loadProfile() async {
    final raw = await _get(_kProfile);
    if (raw == null) return const {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {
        'personName': (m['personName'] as String?) ?? '',
        'peerName': (m['peerName'] as String?) ?? '',
        'deviceName': (m['deviceName'] as String?) ?? '',
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
    this.escrowPassphrase,
  });

  final String server;
  final String spaceKeyB64;
  final String spaceId;
  final String deviceId;
  final int keyVersion;
  final String? token;

  /// 口令托管（KEY_ESCROW.md）的接入口令：与 App 锁 PIN 区分，
  /// 同样受 PIN 加密保护；解锁/认证成功时用于自动重传托管包（rotate 后同步）。
  final String? escrowPassphrase;

  Map<String, dynamic> toJson() => {
        'server': server,
        'space_key': spaceKeyB64,
        'space_id': spaceId,
        'device_id': deviceId,
        'key_version': keyVersion,
        'token': token,
        'escrow_passphrase': escrowPassphrase,
      };

  factory AppLockPayload.fromJson(Map<String, dynamic> json) => AppLockPayload(
        server: json['server'] as String,
        spaceKeyB64: json['space_key'] as String,
        spaceId: json['space_id'] as String,
        deviceId: json['device_id'] as String,
        keyVersion: (json['key_version'] as int?) ?? 1,
        token: json['token'] as String?,
        escrowPassphrase: json['escrow_passphrase'] as String?,
      );
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
