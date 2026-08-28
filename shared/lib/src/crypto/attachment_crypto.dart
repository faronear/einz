import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../sodium.dart';
import 'keys.dart';

/// 附件加密（E2EE.md §6）：AttachmentKey = derive("a", attachment_id)。
///
/// 返回密文与本次使用的 nonce（nonce 需随附件元数据保存，供解密使用）。
Future<({Uint8List cipher, Uint8List nonce})> encryptAttachment({
  required Uint8List fileBytes,
  required Uint8List spaceKey,
  required String attachmentId,
}) async {
  final s = await sodium();
  final attKey = await deriveSubKey(s, spaceKey, 'a', attachmentId);
  final nonce = s.randombytes.buf(s.crypto.aeadXChaCha20Poly1305IETF.nonceBytes);
  final aad = Uint8List.fromList(utf8.encode('onlyspace-v1-a$attachmentId'));
  final key = s.secureCopy(attKey);
  final cipher = s.crypto.aeadXChaCha20Poly1305IETF.encrypt(
    message: fileBytes,
    nonce: nonce,
    key: key,
    additionalData: aad,
  );
  key.dispose();
  return (cipher: cipher, nonce: nonce); // 密文+MAC
}

/// 解密附件。nonce 由调用方从元数据传入。
Future<Uint8List> decryptAttachment({
  required Uint8List cipherText,
  required Uint8List nonce,
  required Uint8List spaceKey,
  required String attachmentId,
}) async {
  final s = await sodium();
  final attKey = await deriveSubKey(s, spaceKey, 'a', attachmentId);
  final aad = Uint8List.fromList(utf8.encode('onlyspace-v1-a$attachmentId'));
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
