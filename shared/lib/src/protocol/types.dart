/// 协议常量与类型（PROTOCOL.md）。
library;

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
  // 消息回执（已送达/已读）单调高水位（POST 上报 / GET 回读）
  static const receipts = '/receipts';
  // 本机自助退役（PROTOCOL.md §7.3）：客户端"重置设备"清本地数据之前调用，把自己
  // 从服务端注销（清会话/Push/待签 challenge、置 revoked），避免留下幽灵设备。
  static const deviceRetire = '/devices/retire';
  // 补登安装级设备标识（多空间）：存量设备进聊天页时幂等上报一次，服务端据此把
  // 同一物理设备在不同空间的 device_id 关联起来（PROTOCOL.md §7.3）。
  static const deviceUid = '/devices/uid';
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

/// 设备绑定结果（v2）：`POST /spaces` 与 `POST /spaces/join` 都直接返回这三个 id，
/// App 向导用它聚合"本次绑定拿到的身份"。
///
/// 历史：v1 时代这是 `POST /devices/enroll` 的响应类型（`EnrollResult`）。该端点与
/// v1 邀请码已随 Multiverse 收敛删除（2026-09-15），所以它不再是"某个端点的响应"。
class DeviceBinding {
  const DeviceBinding({required this.deviceId, required this.personId, required this.spaceId});

  final String deviceId;
  final String personId;
  final String spaceId;
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

/// 空间公开信息 + 两身份 slot（**不含空间名**：spaces.display_name 已删，
/// 2026-09-16——join 方需要的"对方是谁"由 slots 里的身份名提供）。
class SpaceJoinPreflight {
  const SpaceJoinPreflight({
    required this.spaceId,
    required this.status,
    required this.memberCount,
    required this.slots,
  });

  final String spaceId;
  final String status;
  final int memberCount;
  final List<SpaceMemberSlot> slots;

  factory SpaceJoinPreflight.fromJson(Map<String, dynamic> json) =>
      SpaceJoinPreflight(
        spaceId: json['spaceId'] as String,
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
    this.personSlots = const {},
  });

  final String spaceId;
  final List<SpaceDevice> devices;

  /// person_id → person_name（创建者/邀请时设置，显示层用）。
  final Map<String, String> personNames;

  /// person_id → gender（male/female，显示层用）。
  final Map<String, String> personGenders;

  /// person_id → partner_slot（0=第一人/创建者，1=第二人/伴侣；
  /// 同性别气泡配色区分「第二个人」用，老服务端无此键时为空表）。
  final Map<String, int> personSlots;

  factory SpaceResult.fromJson(Map<String, dynamic> json) => SpaceResult(
        spaceId: json['space_id'] as String,
        devices: (json['devices'] as List)
            .map((d) => SpaceDevice.fromJson(d as Map<String, dynamic>))
            .toList(),
        personNames: (json['person_names'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        personGenders: (json['person_genders'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        personSlots: (json['person_slots'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as int)),
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
///
/// 错误码语义（客户端**只应**按下述处理，2026-09-16）：
/// - `DEVICE_REVOKED`（403）：本设备被**明确撤销**（涉嫌被盗用）——唯一授权客户端
///   清空本地数据的错误码；
/// - `FORBIDDEN`（403）：设备**未登记**（最常见原因是服务端库被清空/重置，属运维失误）
///   ——只警告，绝不清空本地数据，允许继续查看本地消息（`device.revoked` 帧同理是明确撤销）。
class ApiException implements Exception {
  ApiException(this.code, this.message, [this.httpStatus = 0]);

  final String code;
  final String message;
  final int httpStatus;

  @override
  String toString() => 'ApiException($code): $message';
}
