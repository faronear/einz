import 'dart:convert';
import 'dart:typed_data';

import '../protocol/api_client.dart';
import '../sodium.dart';
import 'backup.dart';

/// 口令托管密钥（KEY_ESCROW.md §4）。
///
/// Space Key 用"口令"（Argon2id）派生密钥加密成密文包后托管到 Server——
/// Server 存的是被口令加密的密钥，没有口令解不开；口令只留在客户端/用户脑中。
/// 复用 backup.dart 的密码学机制（deriveBackupKey + XChaCha20-Poly1305），零新增密码学。
class KeyEscrowService {
  KeyEscrowService(this.api);

  final ApiClient api;

  /// 用口令加密 Space Key 包（`{space_key, space_id, key_version}`）。
  Future<BackupFile> createPackage({
    required String passphrase,
    required String spaceKeyB64,
    required String spaceId,
    required int keyVersion,
  }) {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'space_key': spaceKeyB64,
      'space_id': spaceId,
      'key_version': keyVersion,
    })));
    return encryptBackup(payload: payload, recoveryCode: passphrase);
  }

  /// 用口令解出 Space Key 包；口令错误抛 [FormatException]。
  Future<EscrowPayload> openPackage({
    required String passphrase,
    required BackupFile file,
  }) async {
    final plain = await decryptBackup(file: file, recoveryCode: passphrase);
    final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
    return EscrowPayload(
      spaceKeyB64: json['space_key'] as String,
      spaceId: json['space_id'] as String,
      keyVersion: (json['key_version'] as int?) ?? 1,
    );
  }

  /// 一键：口令加密 + 上传托管（附口令 argon2id 哈希，供服务端 /recover 恢复校验）。
  Future<void> upload({
    required String passphrase,
    required String spaceKeyB64,
    required String spaceId,
    required int keyVersion,
    required String token,
  }) async {
    final pkg = await createPackage(passphrase: passphrase, spaceKeyB64: spaceKeyB64, spaceId: spaceId, keyVersion: keyVersion);
    final hash = await hashPassphrase(passphrase);
    await api.uploadKeyEscrow(pkg, token, passphraseHash: hash);
  }

  /// 口令 argon2id 哈希字符串（crypto_pwhash_str，自含盐）。
  /// 仅用于服务端"口令是否匹配"验证，不用于任何密钥派生。
  /// （sodium ≥2.3.1：pwhash 相关移入 crypto.pwhash 子对象，str 生成密码哈希串）
  Future<String> hashPassphrase(String passphrase) async {
    final s = await SodiumSumoInit.init2(loadDynamicLibrary);
    return s.crypto.pwhash.str(
      password: passphrase,
      opsLimit: s.crypto.pwhash.opsLimitModerate,
      memLimit: s.crypto.pwhash.memLimitModerate,
    );
  }

  /// 一键：拉取 + 口令解密；未托管或无口令错误时：
  /// - 未托管（Server 无包）返回 null；
  /// - 口令错误抛 [FormatException]。
  Future<EscrowPayload?> fetch({
    required String passphrase,
    required String token,
  }) async {
    final snap = await api.getKeyEscrow(token);
    final file = snap.file;
    if (file == null) return null;
    return openPackage(passphrase: passphrase, file: file);
  }

  /// 清除托管包。
  Future<void> remove(String token) => api.deleteKeyEscrow(token);
}

/// 从口令托管包解出的 Space Key 信息。
class EscrowPayload {
  const EscrowPayload({
    required this.spaceKeyB64,
    required this.spaceId,
    required this.keyVersion,
  });

  final String spaceKeyB64;
  final String spaceId;
  final int keyVersion;
}
