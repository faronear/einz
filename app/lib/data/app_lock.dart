import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:onlyspace_shared/onlyspace_shared.dart';

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
  static const _kRecovery = 'app_lock.recovery';
  static const _kAttempts = 'app_lock.attempts';
  static const _kLockedUntil = 'app_lock.locked_until';

  /// 是否已设置启动锁。
  Future<bool> get isSetup async => await _get(_kPackage) != null;

  /// 设置 PIN 并加密保存 Space Key 包；返回 12 词恢复码（用户需离线保存）。
  Future<String> setPin(String pin, {required AppLockPayload payload}) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));
    final pkg = await encryptBackup(payload: bytes, recoveryCode: pin);

    // 恢复码兑底：同一 payload 用恢复码再加密一份
    final recoveryCode = await generateRecoveryCode();
    final recPkg = await encryptBackup(payload: bytes, recoveryCode: recoveryCode);

    await _set(_kPackage, jsonEncode(pkg.toJson()));
    await _set(_kRecovery, jsonEncode(recPkg.toJson()));
    await _set(_kAttempts, '0');
    await _set(_kLockedUntil, '0');
    return recoveryCode;
  }

  /// 用 PIN 解锁：解密 Space Key 包；PIN 错误抛 [AppLockException]，锁定中抛 [AppLockLockedException]。
  Future<AppLockPayload> unlock(String pin) async {
    await _ensureNotLocked();
    final raw = await _get(_kPackage);
    if (raw == null) throw const AppLockException('尚未设置启动锁');
    try {
      final plain = await decryptBackup(file: BackupFile.fromJson(jsonDecode(raw)), recoveryCode: pin);
      await _set(_kAttempts, '0');
      return AppLockPayload.fromJson(jsonDecode(utf8.decode(plain)));
    } on FormatException {
      await _registerFailure();
      throw const AppLockException('PIN 错误');
    }
  }

  /// 恢复码兑底：PIN 丢失时用 12 词恢复码解密（E2EE.md §10）。
  Future<AppLockPayload> unlockWithRecovery(String recoveryCode) async {
    final raw = await _get(_kRecovery);
    if (raw == null) throw const AppLockException('无恢复副本');
    try {
      final plain = await decryptBackup(file: BackupFile.fromJson(jsonDecode(raw)), recoveryCode: recoveryCode);
      await _set(_kAttempts, '0');
      await _set(_kLockedUntil, '0');
      return AppLockPayload.fromJson(jsonDecode(utf8.decode(plain)));
    } on FormatException {
      throw const AppLockException('恢复码错误');
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
  });

  final String server;
  final String spaceKeyB64;
  final String spaceId;
  final String deviceId;
  final int keyVersion;
  final String? token;

  Map<String, dynamic> toJson() => {
        'server': server,
        'space_key': spaceKeyB64,
        'space_id': spaceId,
        'device_id': deviceId,
        'key_version': keyVersion,
        'token': token,
      };

  factory AppLockPayload.fromJson(Map<String, dynamic> json) => AppLockPayload(
        server: json['server'] as String,
        spaceKeyB64: json['space_key'] as String,
        spaceId: json['space_id'] as String,
        deviceId: json['device_id'] as String,
        keyVersion: (json['key_version'] as int?) ?? 1,
        token: json['token'] as String?,
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
