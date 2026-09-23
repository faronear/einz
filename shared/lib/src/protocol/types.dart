/// 协议常量与类型（PROTOCOL.md）。
library;

/// 认证 / 同步相关 REST 端点（PROTOCOL.md §4）。
class Api {
  static const challenge = '/auth/challenge';
  static const verify = '/auth/verify';
  static const messages = '/messages';
  static const sync = '/sync';
  static const attachments = '/attachments';
  static const pushRegister = '/push/register';
  static const space = '/space';
  static const keyEscrow = '/key-escrow';
  // Multiverse：空间创建/加入（PROTOCOL_MULTIVERSE.md §4）
  static const spaces = '/spaces';
  static const spaceJoinPreflight = '/spaces/join/preflight';
  static const spaceJoin = '/spaces/join';
  // 消息回执（已送达/已读）单调高水位（POST 上报 / GET 回读）
  static const receipts = '/receipts';
  // 本机自助退役（PROTOCOL.md §7.3）：客户端"重置本通道"清本地数据之前调用，把自己
  // 从服务端注销（清会话/Push/待签 challenge、置 revoked），避免留下幽灵通道。
  static const entranceRetire = '/entrances/retire';
  // 补登安装级标识（多空间）：存量安装进聊天页时幂等上报一次，服务端据此把
  // 同一安装在不同空间的 entrance_id 关联起来（PROTOCOL.md §7.3）。
  static const installUid = '/entrances/install-uid';
  // 未读条数（多空间列表角标）：服务端派生——消息 + 我上报的读取水位（receipts）。
  static const messagesUnread = '/messages/unread';
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

/// 通道绑定结果（v2）：`POST /spaces` 与 `POST /spaces/join` 都直接返回这三个 id，
/// App 向导用它聚合"本次绑定拿到的身份"。
///
/// 历史：v1 时代这是 `POST /entrances/enroll` 的响应类型（`EnrollResult`）。该端点与
/// v1 邀请码已随 Multiverse 收敛删除（2026-09-15），所以它不再是"某个端点的响应"。
class EntranceBinding {
  const EntranceBinding({required this.entranceId, required this.partnerId, required this.spaceId});

  final String entranceId;
  final String partnerId;
  final String spaceId;
}

/// Multiverse：join token preflight 结果（POST /spaces/join/preflight 返回，
/// 验 token 不消费——空间公开信息供客户端确认，PROTOCOL_MULTIVERSE.md §5）。
/// Multiverse：join preflight 返回的成员身份信息（create 时预置两身份 slot；
/// join 时客户端据此展示「选择是哪一个用户」——加入者可能是第二人，也可能
/// 是第一人的其他通道，不能靠名字判别身份，老板 2026-09-10 定稿）。
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

/// Multiverse：加入结果（POST /spaces/join 返回——通道已登记、session 已签发，
/// 绑定该 Space，PROTOCOL_MULTIVERSE.md §4.1）。
class SpaceJoinResult {
  const SpaceJoinResult({
    required this.spaceId,
    required this.partnerId,
    required this.slot,
    required this.sessionToken,
    required this.entranceId,
    required this.spaceAddress,
  });

  final String spaceId;
  final String partnerId;
  final int slot;
  final String sessionToken;
  final String entranceId;
  final String spaceAddress;

  factory SpaceJoinResult.fromJson(Map<String, dynamic> json) => SpaceJoinResult(
        spaceId: json['spaceId'] as String,
        partnerId: json['partnerId'] as String,
        slot: json['slot'] as int,
        sessionToken: json['sessionToken'] as String,
        entranceId: json['entranceId'] as String,
        spaceAddress: json['spaceAddress'] as String,
      );
}

/// Multiverse：创建结果（POST /spaces 返回——创建者通道已登记、session 已签发，
/// 绑定该 Space，PROTOCOL_MULTIVERSE.md §4.1）。
class SpaceCreateResult {
  const SpaceCreateResult({
    required this.spaceId,
    required this.spaceAddress,
    required this.joinToken,
    required this.link,
    required this.expiresAt,
    required this.entranceId,
    required this.creatorPartnerId,
    required this.sessionToken,
  });

  final String spaceId;
  final String spaceAddress;
  final String joinToken;
  final String link;
  final int expiresAt;
  final String entranceId;
  final String creatorPartnerId;
  final String sessionToken;

  factory SpaceCreateResult.fromJson(Map<String, dynamic> json) =>
      SpaceCreateResult(
        spaceId: json['spaceId'] as String,
        spaceAddress: json['spaceAddress'] as String,
        joinToken: json['joinToken'] as String,
        link: json['link'] as String,
        expiresAt: json['expiresAt'] as int,
        entranceId: json['entranceId'] as String,
        creatorPartnerId: json['creatorPartnerId'] as String,
        sessionToken: json['sessionToken'] as String,
      );
}

/// 邀请码生成结果（POST /invites 返回，创建者调用）。
/// Multiverse：POST /spaces/{id}/join-tokens 生成的绑定新通道的邀请（24h 一次性）。
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

/// 空间通道信息（GET /space 返回）：entrance_id → partner_id 映射，
/// 用于判断消息是否"同一个人"发送（多通道凭证语义，PROTOCOL.md §7.3）。
class SpaceEntrance {
  const SpaceEntrance({
    required this.entranceId,
    required this.partnerId,
    required this.status,
    this.lastSeen,
  });

  final String entranceId;
  final String partnerId;
  final String status;
  final int? lastSeen;

  factory SpaceEntrance.fromJson(Map<String, dynamic> json) => SpaceEntrance(
        entranceId: json['entrance_id'] as String,
        partnerId: json['partner_id'] as String,
        status: json['status'] as String,
        lastSeen: json['last_seen'] as int?,
      );
}

/// 空间信息（GET /space 响应）。
class SpaceResult {
  const SpaceResult({
    required this.spaceId,
    required this.entrances,
    this.partnerNames = const {},
    this.partnerGenders = const {},
    this.partnerSlots = const {},
  });

  final String spaceId;
  final List<SpaceEntrance> entrances;

  /// partner_id → partner_name（创建者/邀请时设置，显示层用）。
  final Map<String, String> partnerNames;

  /// partner_id → gender（male/female，显示层用）。
  final Map<String, String> partnerGenders;

  /// partner_id → slot（0=第一人/创建者，1=第二人/伴侣；
  /// 同性别气泡配色区分「第二个人」用，老服务端无此键时为空表）。
  final Map<String, int> partnerSlots;

  factory SpaceResult.fromJson(Map<String, dynamic> json) => SpaceResult(
        spaceId: json['space_id'] as String,
        entrances: (json['entrances'] as List)
            .map((d) => SpaceEntrance.fromJson(d as Map<String, dynamic>))
            .toList(),
        partnerNames: (json['partner_names'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        partnerGenders: (json['partner_genders'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        partnerSlots: (json['partner_slots'] as Map<String, dynamic>? ?? {})
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

/// 消息回执（已送达/已读）单调高水位，按 (space, partner) 一行。
///
/// 语义：我的消息 seq=S 已送达 ⟺ 对方 `deliveredUptoSeq ≥ S`；已读 ⟺
/// `readUptoSeq ≥ S`。按 partner 记 → "该 partner 至少一条通道已收到/已读"
/// （不保证其所有通道）。回执只前进，且 `deliveredUptoSeq ≥ readUptoSeq`。
class ReceiptRow {
  ReceiptRow({
    required this.partnerId,
    required this.deliveredUptoSeq,
    required this.readUptoSeq,
    required this.updatedAt,
  });

  final String partnerId;
  final int deliveredUptoSeq;
  final int readUptoSeq;
  final int updatedAt;

  factory ReceiptRow.fromJson(Map<String, dynamic> json) => ReceiptRow(
        partnerId: json['partner_id'] as String,
        deliveredUptoSeq: (json['delivered_upto_seq'] as int?) ?? 0,
        readUptoSeq: (json['read_upto_seq'] as int?) ?? 0,
        updatedAt: (json['updated_at'] as int?) ?? 0,
      );
}

/// 服务端错误（PROTOCOL.md §9）。
///
/// 错误码语义（客户端**只应**按下述处理，2026-09-16）：
/// - `ENTRANCE_REVOKED`（403）：本通道被**明确撤销**（涉嫌被盗用）——唯一授权客户端
///   清空本地数据的错误码；
/// - `FORBIDDEN`（403）：通道**未登记**（最常见原因是服务端库被清空/重置，属运维失误）
///   ——只警告，绝不清空本地数据，允许继续查看本地消息（`entrance.revoked` 帧同理是明确撤销）。
class ApiException implements Exception {
  ApiException(this.code, this.message, [this.httpStatus = 0]);

  final String code;
  final String message;
  final int httpStatus;

  @override
  String toString() => 'ApiException($code): $message';
}
