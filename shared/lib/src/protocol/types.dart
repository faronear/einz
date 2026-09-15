/// 协议常量与类型（PROTOCOL.md）。
library;

/// 协议版本。
const int kProtocolVersion = 1;

/// 消息类型。
const Set<String> kMessageTypes = {'text', 'image', 'video', 'voice', 'audio', 'file', 'system'};

/// 认证 / 同步相关 REST 端点（PROTOCOL.md §4）。
class Api {
  static const challenge = '/auth/challenge';
  static const verify = '/auth/verify';
  static const messages = '/messages';
  static const sync = '/sync';
  static const attachments = '/attachments';
  static const devicesEnroll = '/devices/enroll';
  static const invites = '/invites';
  static const pushRegister = '/push/register';
  static const space = '/space';
  static const keyEscrow = '/key-escrow';
  // Multiverse：空间创建/加入（PROTOCOL_MULTIVERSE.md §4）
  static const spaces = '/spaces';
  static const spaceJoinPreflight = '/spaces/join/preflight';
  static const spaceJoin = '/spaces/join';
  static const spaceLookup = '/spaces/lookup';
  // 消息回执（已送达/已读）单调高水位（POST 上报 / GET 回读）
  static const receipts = '/receipts';
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

/// 动态登记结果（POST /devices/enroll 返回）：登记后设备已在白名单生效。
class EnrollResult {
  const EnrollResult({required this.deviceId, required this.personId, required this.spaceId});

  final String deviceId;
  final String personId;
  final String spaceId;

  factory EnrollResult.fromJson(Map<String, dynamic> json) => EnrollResult(
        deviceId: json['device_id'] as String,
        personId: json['person_id'] as String,
        spaceId: json['space_id'] as String,
      );
}

/// Multiverse：join token preflight 结果（POST /spaces/join/preflight 返回，
/// 验 token 不消费——空间公开信息供客户端确认，PROTOCOL_MULTIVERSE.md §5）。
/// Multiverse：join preflight 返回的成员身份信息（create 时预置两身份 slot；
/// join 时客户端据此展示「选择是哪一个用户」——加入者可能是第二人，也可能
/// 是第一人的其他设备，不能靠名字判别身份，老板 2026-09-10 定稿）。
class SpaceMemberSlot {
  const SpaceMemberSlot({
    required this.slot,
    required this.displayName,
    required this.gender,
    required this.status,
  });

  final int slot;
  final String? displayName;
  final String? gender;
  final String status;

  factory SpaceMemberSlot.fromJson(Map<String, dynamic> json) => SpaceMemberSlot(
        slot: json['slot'] as int,
        displayName: json['displayName'] as String?,
        gender: json['gender'] as String?,
        status: json['status'] as String,
      );
}

class SpaceJoinPreflight {
  const SpaceJoinPreflight({
    required this.spaceId,
    required this.displayName,
    required this.status,
    required this.memberCount,
    required this.slots,
  });

  final String spaceId;
  final String? displayName;
  final String status;
  final int memberCount;
  final List<SpaceMemberSlot> slots;

  factory SpaceJoinPreflight.fromJson(Map<String, dynamic> json) =>
      SpaceJoinPreflight(
        spaceId: json['spaceId'] as String,
        displayName: json['displayName'] as String?,
        status: json['status'] as String,
        memberCount: json['memberCount'] as int,
        slots: (json['slots'] as List<dynamic>? ?? const [])
            .map((e) => SpaceMemberSlot.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Multiverse：加入结果（POST /spaces/join 返回——设备已登记、session 已签发，
/// 绑定该 Space，PROTOCOL_MULTIVERSE.md §4.1）。
class SpaceJoinResult {
  const SpaceJoinResult({
    required this.spaceId,
    required this.personId,
    required this.partnerSlot,
    required this.sessionToken,
    required this.deviceId,
    required this.spaceAddress,
  });

  final String spaceId;
  final String personId;
  final int partnerSlot;
  final String sessionToken;
  final String deviceId;
  final String spaceAddress;

  factory SpaceJoinResult.fromJson(Map<String, dynamic> json) => SpaceJoinResult(
        spaceId: json['spaceId'] as String,
        personId: json['personId'] as String,
        partnerSlot: json['partnerSlot'] as int,
        sessionToken: json['sessionToken'] as String,
        deviceId: json['deviceId'] as String,
        spaceAddress: json['spaceAddress'] as String,
      );
}

/// Multiverse：创建结果（POST /spaces 返回——创建者设备已登记、session 已签发，
/// 绑定该 Space，PROTOCOL_MULTIVERSE.md §4.1）。
class SpaceCreateResult {
  const SpaceCreateResult({
    required this.spaceId,
    required this.spaceAddress,
    required this.joinToken,
    required this.link,
    required this.expiresAt,
    required this.deviceId,
    required this.creatorPersonId,
    required this.sessionToken,
  });

  final String spaceId;
  final String spaceAddress;
  final String joinToken;
  final String link;
  final int expiresAt;
  final String deviceId;
  final String creatorPersonId;
  final String sessionToken;

  factory SpaceCreateResult.fromJson(Map<String, dynamic> json) =>
      SpaceCreateResult(
        spaceId: json['spaceId'] as String,
        spaceAddress: json['spaceAddress'] as String,
        joinToken: json['joinToken'] as String,
        link: json['link'] as String,
        expiresAt: json['expiresAt'] as int,
        deviceId: json['deviceId'] as String,
        creatorPersonId: json['creatorPersonId'] as String,
        sessionToken: json['sessionToken'] as String,
      );
}

/// 邀请码生成结果（POST /invites 返回，创建者调用）。
/// Multiverse：POST /spaces/{id}/join-tokens 生成的绑定新设备的邀请（24h 一次性）。
class JoinTokenResult {
  const JoinTokenResult({
    required this.joinToken,
    required this.link,
    required this.expiresAt,
  });

  final String joinToken;
  final String link;
  final int expiresAt;

  factory JoinTokenResult.fromJson(Map<String, dynamic> json) => JoinTokenResult(
        joinToken: json['joinToken'] as String,
        link: json['link'] as String,
        expiresAt: json['expiresAt'] as int,
      );
}

class InviteResult {
  const InviteResult({required this.inviteCode, required this.personId, required this.expiresAt});

  final String inviteCode;
  final String personId;
  final int expiresAt;

  factory InviteResult.fromJson(Map<String, dynamic> json) => InviteResult(
        inviteCode: json['invite_code'] as String,
        personId: json['person_id'] as String,
        expiresAt: json['expires_at'] as int,
      );
}

/// 空间设备信息（GET /space 返回）：device_id → person_id 映射，
/// 用于判断消息是否"同一个人"发送（多设备凭证语义，PROTOCOL.md §7.3）。
class SpaceDevice {
  const SpaceDevice({
    required this.deviceId,
    required this.personId,
    required this.status,
    this.lastSeen,
  });

  final String deviceId;
  final String personId;
  final String status;
  final int? lastSeen;

  factory SpaceDevice.fromJson(Map<String, dynamic> json) => SpaceDevice(
        deviceId: json['device_id'] as String,
        personId: json['person_id'] as String,
        status: json['status'] as String,
        lastSeen: json['last_seen'] as int?,
      );
}

/// 空间信息（GET /space 响应）。
class SpaceResult {
  const SpaceResult({
    required this.spaceId,
    required this.devices,
    this.personNames = const {},
    this.personGenders = const {},
  });

  final String spaceId;
  final List<SpaceDevice> devices;

  /// person_id → person_name（创建者/邀请时设置，显示层用）。
  final Map<String, String> personNames;

  /// person_id → gender（male/female，显示层用）。
  final Map<String, String> personGenders;

  factory SpaceResult.fromJson(Map<String, dynamic> json) => SpaceResult(
        spaceId: json['space_id'] as String,
        devices: (json['devices'] as List)
            .map((d) => SpaceDevice.fromJson(d as Map<String, dynamic>))
            .toList(),
        personNames: (json['person_names'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        personGenders: (json['person_genders'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
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

/// 消息回执（已送达/已读）单调高水位，按 (space, person) 一行。
///
/// 语义：我的消息 seq=S 已送达 ⟺ 对方 `deliveredUptoSeq ≥ S`；已读 ⟺
/// `readUptoSeq ≥ S`。按 person 记 → "该 person 至少一台设备已收到/已读"
/// （不保证其所有设备）。回执只前进，且 `deliveredUptoSeq ≥ readUptoSeq`。
class ReceiptRow {
  ReceiptRow({
    required this.personId,
    required this.deliveredUptoSeq,
    required this.readUptoSeq,
    required this.updatedAt,
  });

  final String personId;
  final int deliveredUptoSeq;
  final int readUptoSeq;
  final int updatedAt;

  factory ReceiptRow.fromJson(Map<String, dynamic> json) => ReceiptRow(
        personId: json['person_id'] as String,
        deliveredUptoSeq: (json['delivered_upto_seq'] as int?) ?? 0,
        readUptoSeq: (json['read_upto_seq'] as int?) ?? 0,
        updatedAt: (json['updated_at'] as int?) ?? 0,
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
