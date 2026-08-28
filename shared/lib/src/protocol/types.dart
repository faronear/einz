/// 协议常量与类型（PROTOCOL.md）。
library;

/// 协议版本。
const int kProtocolVersion = 1;

/// 消息类型。
const Set<String> kMessageTypes = {'text', 'image', 'video', 'voice', 'system'};

/// 认证 / 同步相关 REST 端点（PROTOCOL.md §4）。
class Api {
  static const challenge = '/auth/challenge';
  static const verify = '/auth/verify';
  static const messages = '/messages';
  static const sync = '/sync';
  static const attachments = '/attachments';
  static const devices = '/devices';
  static const pushRegister = '/push/register';
  static const space = '/space';
}

/// 认证挑战结果。
class ChallengeResult {
  ChallengeResult({required this.challengeId, required this.sealedChallenge, required this.expiresIn});

  final String challengeId;
  final String sealedChallenge;
  final int expiresIn;

  factory ChallengeResult.fromJson(Map<String, dynamic> json) => ChallengeResult(
        challengeId: json['challenge_id'] as String,
        sealedChallenge: json['sealed_challenge'] as String,
        expiresIn: json['expires_in'] as int,
      );
}

/// 会话结果。
class SessionResult {
  SessionResult({required this.sessionToken, required this.spaceId, required this.expiresIn});

  final String sessionToken;
  final String spaceId;
  final int expiresIn;

  factory SessionResult.fromJson(Map<String, dynamic> json) => SessionResult(
        sessionToken: json['session_token'] as String,
        spaceId: json['space_id'] as String,
        expiresIn: json['expires_in'] as int,
      );
}

/// 上传消息的返回。
class PostMessageResult {
  PostMessageResult({required this.messageId, required this.serverSequence, required this.createdAt});

  final String messageId;
  final int serverSequence;
  final int createdAt;

  factory PostMessageResult.fromJson(Map<String, dynamic> json) => PostMessageResult(
        messageId: json['message_id'] as String,
        serverSequence: json['server_sequence'] as int,
        createdAt: json['created_at'] as int,
      );
}

/// 服务端错误（PROTOCOL.md §9）。
class ApiException implements Exception {
  ApiException(this.code, this.message, [this.httpStatus = 0]);

  final String code;
  final String message;
  final int httpStatus;

  @override
  String toString() => 'ApiException($code): $message';
}
