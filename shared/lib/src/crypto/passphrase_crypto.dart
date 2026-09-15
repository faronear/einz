/// 通用口令加解密基础库（与任何业务功能无关）。
///
/// 机制：BackupKey = Argon2id(口令, salt)（crypto_pwhash，E2EE.md §4.3）
/// → XChaCha20-Poly1305 加密，信封 {format, salt, nonce, ciphertext}。
///
/// 使用方（互不依赖，都只依赖本库）：
/// - 口令密保箱（key_escrow.dart）：Space Key 包托管在 Server；
/// - 加密备份（backup.dart）：恢复码加密的离线导出；
/// - App 启动锁（app 锁包）：PIN 加密 Space Key 包。
///
/// ⚠️ [kPassphraseFormat] 与 [kPassphraseExportPrefix] 是线上一致性凭据
/// （Server 密保箱里存的就是该格式密文）——**值一个字符都不能变**。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import '../sodium.dart';

/// 口令加密信封格式标识（历史名 einz-backup-v1：escrow 密保箱与备份归档共用同一信封格式）。
const String kPassphraseFormat = 'einz-backup-v1';

/// 口令加密文本前缀：`EINZ-BACKUP:` + base64(信封 JSON)。用于两类口令加密
/// 载体：① escrow 口令密保箱（Space Key 包，纯口令恢复用）；② 加密备份
/// 归档文本（Space Key + 全量聊天历史）。
const String kPassphraseExportPrefix = 'EINZ-BACKUP:';

/// SodiumSumo 单例（pwhash/Argon2id 只在 sumo 构建中提供）。
///
/// 必须缓存：`SodiumSumoInit.init2` 每次都会重新 dlopen + 初始化库（`hashPassphrase`
/// 每次调用都会走到这里，代价是几十 ms 级的白工）。`sodium.dart` 的 `sodium()`
/// 本来就是缓存的，这里与之对齐（2026-09-15 评审）。
SodiumSumo? _sumoInstance;
Future<SodiumSumo> _sumo() async =>
    _sumoInstance ??= await SodiumSumoInit.init2(loadDynamicLibrary);

/// 重置缓存的 SodiumSumo 实例（仅测试用，与 `sodium.dart` 的 `resetSodium()` 对应）。
void resetSodiumSumo() {
  _sumoInstance = null;
}

/// 派生口令密钥（E2EE.md §4.3 / §10.1）：Argon2id(passphrase, salt) → 32B。
///
/// [passphrase] 是通用的人类可输入口令——按调用方语义不同，实际传入
/// 12 词恢复码（加密备份）、锁屏码 PIN（App 启动锁）或密保口令（口令密保箱）。
Future<Uint8List> derivePassphraseKey({
  required String passphrase,
  required Uint8List salt,
}) async {
  final s = await _sumo();
  final key = s.crypto.pwhash.call(
    outLen: 32,
    password: Int8List.fromList(utf8.encode(passphrase)),
    salt: salt,
    opsLimit: s.crypto.pwhash.opsLimitModerate,
    memLimit: s.crypto.pwhash.memLimitModerate,
    alg: CryptoPwhashAlgorithm.argon2id13,
  );
  final bytes = key.extractBytes();
  key.dispose();
  return bytes;
}

/// 生成随机 salt（crypto_pwhash_SALTBYTES = 16B）。
Future<Uint8List> generatePassphraseSalt() async {
  final s = await _sumo();
  return s.randombytes.buf(s.crypto.pwhash.saltBytes);
}

/// 口令加密信封（{format, salt, nonce, ciphertext}）。
class PassphraseEnvelope {
  PassphraseEnvelope({
    required this.salt,
    required this.nonce,
    required this.ciphertext,
  });

  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List ciphertext;

  Map<String, dynamic> toJson() => {
        'format': kPassphraseFormat,
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
        'ciphertext': base64Encode(ciphertext),
      };

  factory PassphraseEnvelope.fromJson(Map<String, dynamic> json) {
    if (json['format'] != kPassphraseFormat) {
      throw FormatException('口令加密信封格式不兼容: ${json['format']}');
    }
    return PassphraseEnvelope(
      salt: base64Decode(json['salt'] as String),
      nonce: base64Decode(json['nonce'] as String),
      ciphertext: base64Decode(json['ciphertext'] as String),
    );
  }
}

/// 口令加密（payload = 任意字节，如 JSON 序列化的密钥包）。
///
/// 内部生成随机 salt → 派生密钥 → 加密；salt 随信封保存，解密时复用。
Future<PassphraseEnvelope> encryptWithPassphrase({
  required Uint8List payload,
  required String passphrase,
}) async {
  final s = await _sumo();
  final salt = await generatePassphraseSalt();
  final key = await derivePassphraseKey(passphrase: passphrase, salt: salt);
  final nonce = s.randombytes.buf(s.crypto.aeadXChaCha20Poly1305IETF.nonceBytes);
  final aad = Uint8List.fromList(utf8.encode(kPassphraseFormat));
  final secureKey = s.secureCopy(key);
  final cipher = s.crypto.aeadXChaCha20Poly1305IETF.encrypt(
    message: payload,
    nonce: nonce,
    key: secureKey,
    additionalData: aad,
  );
  secureKey.dispose();
  return PassphraseEnvelope(
    salt: salt,
    nonce: nonce,
    ciphertext: cipher,
  );
}

/// 口令解密（口令错误 / 数据损坏会抛 [FormatException]）。
Future<Uint8List> decryptWithPassphrase({
  required PassphraseEnvelope envelope,
  required String passphrase,
}) async {
  // 与加密路径同一个实例（SodiumSumo 是 Sodium 的超集）：此前这里用 sodium()、
  // 加密路径用 _sumo()，两条路径不一致（2026-09-15 评审，纯一致性瑕疵）。
  final s = await _sumo();
  final key = await derivePassphraseKey(passphrase: passphrase, salt: envelope.salt);
  final aad = Uint8List.fromList(utf8.encode(kPassphraseFormat));
  final secureKey = s.secureCopy(key);
  try {
    return s.crypto.aeadXChaCha20Poly1305IETF.decrypt(
      cipherText: envelope.ciphertext,
      nonce: envelope.nonce,
      key: secureKey,
      additionalData: aad,
    );
  } on SodiumException catch (e) {
    throw FormatException('口令解密失败（口令错误或数据损坏）: ${e.originalMessage}');
  } finally {
    secureKey.dispose();
  }
}
