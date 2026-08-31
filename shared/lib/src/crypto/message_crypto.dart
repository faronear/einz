import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../sodium.dart';
import 'keys.dart';

/// 消息密文信封（E2EE.md §5.1 / PROTOCOL.md §5）。
class MessageEnvelope {
  MessageEnvelope({
    required this.v,
    required this.type,
    required this.keyVersion,
    required this.messageId,
    required this.senderDeviceId,
    this.senderPersonId,
    required this.nonce,
    required this.ciphertext,
    this.serverSequence,
    this.createdAt,
  });

  final int v;
  final String type;
  final int keyVersion;
  final String messageId;
  final String senderDeviceId;
  final String? senderPersonId; // 发送者归属 person（"自己/对方"判断维度，旧消息可能缺失）
  final String nonce; // base64(24B)
  final String ciphertext; // base64(密文+MAC)
  final int? serverSequence; // Server 分配（同步响应中携带）
  final int? createdAt; // Server 时间（同步响应中携带）

  Map<String, dynamic> toJson() => {
        'v': v,
        'type': type,
        'key_version': keyVersion,
        'message_id': messageId,
        'sender_device_id': senderDeviceId,
        if (senderPersonId != null) 'sender_person_id': senderPersonId,
        'nonce': nonce,
        'ciphertext': ciphertext,
        if (serverSequence != null) 'server_sequence': serverSequence,
        if (createdAt != null) 'created_at': createdAt,
      };

  factory MessageEnvelope.fromJson(Map<String, dynamic> json) => MessageEnvelope(
        v: json['v'] as int,
        type: json['type'] as String,
        keyVersion: json['key_version'] as int,
        messageId: json['message_id'] as String,
        senderDeviceId: json['sender_device_id'] as String,
        senderPersonId: json['sender_person_id'] as String?,
        nonce: json['nonce'] as String,
        ciphertext: json['ciphertext'] as String,
        serverSequence: json['server_sequence'] as int?,
        createdAt: json['created_at'] as int?,
      );
}

/// 构造 AAD（E2EE.md §5.2）："onlyspace-v1" ‖ space_id ‖ message_id ‖ sender ‖ type ‖ key_version
Uint8List _buildAad(String spaceId, MessageEnvelope env) {
  final aad = 'onlyspace-v1$spaceId${env.messageId}${env.senderDeviceId}${env.type}${env.keyVersion}';
  return Uint8List.fromList(utf8.encode(aad));
}

/// 加密一条消息（本地完成，Server 只见密文）。
Future<MessageEnvelope> encryptMessage({
  required String plaintext,
  required Uint8List spaceKey,
  required String spaceId,
  required String senderDeviceId,
  String? senderPersonId,
  required String messageId,
  String type = 'text',
  int keyVersion = 1,
}) async {
  final s = await sodium();
  final messageKey = await deriveSubKey(s, spaceKey, 'm', messageId);
  final nonce = s.randombytes.buf(s.crypto.aeadXChaCha20Poly1305IETF.nonceBytes);
  final env = MessageEnvelope(
    v: 1,
    type: type,
    keyVersion: keyVersion,
    messageId: messageId,
    senderDeviceId: senderDeviceId,
    senderPersonId: senderPersonId,
    nonce: base64Encode(nonce),
    ciphertext: '',
  );
  final aad = _buildAad(spaceId, env);
  final key = s.secureCopy(messageKey);
  final cipher = s.crypto.aeadXChaCha20Poly1305IETF.encrypt(
    message: Uint8List.fromList(utf8.encode(plaintext)),
    nonce: nonce,
    key: key,
    additionalData: aad,
  );
  key.dispose();
  return MessageEnvelope(
    v: 1,
    type: type,
    keyVersion: keyVersion,
    messageId: messageId,
    senderDeviceId: senderDeviceId,
    senderPersonId: senderPersonId,
    nonce: env.nonce,
    ciphertext: base64Encode(cipher),
  );
}

/// 解密一条消息（失败抛 [FormatException]）。
/// 注意：密钥由调用方按 env.keyVersion 从密钥归档中选择（E2EE.md §9.2），
/// AAD 使用 env 携带的 key_version，本函数不再接收冗余的 keyVersion 参数。
Future<String> decryptMessage({
  required MessageEnvelope env,
  required Uint8List spaceKey,
  required String spaceId,
}) async {
  final s = await sodium();
  final messageKey = await deriveSubKey(s, spaceKey, 'm', env.messageId);
  final aad = _buildAad(spaceId, env);
  final key = s.secureCopy(messageKey);
  try {
    final plain = s.crypto.aeadXChaCha20Poly1305IETF.decrypt(
      cipherText: base64Decode(env.ciphertext),
      nonce: base64Decode(env.nonce),
      key: key,
      additionalData: aad,
    );
    return utf8.decode(plain);
  } on SodiumException catch (e) {
    throw FormatException('消息解密失败（AAD/密钥/密文不匹配）: ${e.originalMessage}');
  } finally {
    key.dispose();
  }
}
