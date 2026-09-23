import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../sodium.dart';

/// X25519 设备凭证密钥对（E2EE.md §3）。
class EntranceKeyPair {
  EntranceKeyPair({required this.entranceId, required this.publicKey, required this.privateKey});

  final String entranceId;
  final Uint8List publicKey; // 32B
  final Uint8List privateKey; // 32B（仅本机安全存储）

  /// 生成新设备密钥对。
  static Future<EntranceKeyPair> generate({String? entranceId}) async {
    final s = await sodium();
    final kp = s.crypto.box.keyPair();
    return EntranceKeyPair(
      entranceId: entranceId ?? _randomEntranceId(s),
      publicKey: kp.publicKey,
      privateKey: kp.secretKey.extractBytes(),
    );
  }

  static String _randomEntranceId(Sodium s) {
    final bytes = s.randombytes.buf(8);
    return 'dev-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  String get publicKeyB64 => base64Encode(publicKey);
  String get privateKeyB64 => base64Encode(privateKey);
}

/// 用对方公钥"密封"一段数据（crypto_box_seal，匿名发送方加密，E2EE.md §7）。
Future<Uint8List> sealFor(Sodium s, Uint8List recipientPublicKey, Uint8List message) {
  return Future.value(s.crypto.box.seal(message: message, publicKey: recipientPublicKey));
}

/// 解开密封数据（必须拥有对应私钥）。
Future<Uint8List> sealOpen(Sodium s, Uint8List cipherText, Uint8List publicKey, Uint8List privateKey) {
  return Future.value(
    s.crypto.box.sealOpen(
      cipherText: cipherText,
      publicKey: publicKey,
      secretKey: s.secureCopy(privateKey),
    ),
  );
}

/// 派生 Message Key / Attachment Key（E2EE.md §4，keyed BLAKE2b-256）。
///
/// - 消息:   input = "m:" + message_id
/// - 附件:   input = "a:" + attachment_id
Future<Uint8List> deriveSubKey(Sodium s, Uint8List spaceKey, String namespace, String id) async {
  final input = utf8.encode('$namespace:$id');
  final key = s.secureCopy(spaceKey);
  final derived = s.crypto.genericHash(message: Uint8List.fromList(input), outLen: 32, key: key);
  key.dispose();
  return derived;
}
