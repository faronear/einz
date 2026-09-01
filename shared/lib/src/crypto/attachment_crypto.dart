import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sodium/sodium.dart';

import '../sodium.dart';
import 'keys.dart';

/// 附件加密（E2EE.md §6）：AttachmentKey = derive("a", attachment_id)。
///
/// AAD 绑定 space_id / attachment_id / key_version（§6.1），
/// 防止密文被跨空间、跨附件替换。
/// 返回密文、nonce、密文 SHA-256 与尺寸（元数据，供 Server 校验）。
Future<({Uint8List cipher, Uint8List nonce, String sha256, int size})> encryptAttachment({
  required Uint8List fileBytes,
  required Uint8List spaceKey,
  required String attachmentId,
  required String spaceId,
  required int keyVersion,
}) async {
  final s = await sodium();
  final attKey = await deriveSubKey(s, spaceKey, 'a', attachmentId);
  final nonce = s.randombytes.buf(s.crypto.aeadXChaCha20Poly1305IETF.nonceBytes);
  final aad = Uint8List.fromList(utf8.encode('einz-v1$spaceId$attachmentId$keyVersion'));
  final key = s.secureCopy(attKey);
  final cipher = s.crypto.aeadXChaCha20Poly1305IETF.encrypt(
    message: fileBytes,
    nonce: nonce,
    key: key,
    additionalData: aad,
  );
  key.dispose();
  // 密文 SHA-256，base64 编码（与 Server Node digest("base64") 校验一致，PROTOCOL.md §6.1）
  final sha = base64Encode(crypto.sha256.convert(cipher).bytes);
  return (cipher: cipher, nonce: nonce, sha256: sha, size: cipher.length); // 密文+MAC
}

/// 解密附件。nonce 由调用方从元数据传入。
Future<Uint8List> decryptAttachment({
  required Uint8List cipherText,
  required Uint8List nonce,
  required Uint8List spaceKey,
  required String attachmentId,
  required String spaceId,
  required int keyVersion,
}) async {
  final s = await sodium();
  final attKey = await deriveSubKey(s, spaceKey, 'a', attachmentId);
  final aad = Uint8List.fromList(utf8.encode('einz-v1$spaceId$attachmentId$keyVersion'));
  final key = s.secureCopy(attKey);
  try {
    return s.crypto.aeadXChaCha20Poly1305IETF.decrypt(
      cipherText: cipherText,
      nonce: nonce,
      key: key,
      additionalData: aad,
    );
  } on SodiumException catch (e) {
    throw FormatException('附件解密失败: ${e.originalMessage}');
  } finally {
    key.dispose();
  }
}

/// 生成附件 nonce（与密文一同存元数据）。
Future<Uint8List> generateAttachmentNonce() async {
  final s = await sodium();
  return s.randombytes.buf(s.crypto.aeadXChaCha20Poly1305IETF.nonceBytes);
}
