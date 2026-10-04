/// 协议常量与类型（PROTOCOL.md）。
library;

/// wire 协议版本（PROTOCOL.md §1）：REST 用请求头 `X-Protocol-Version`，
/// WS 用握手 query `?pv=`。改了**任何** wire 契约（字段名 / 路径 / WS 事件名 /
/// 错误码）都必须 bump。
///
/// - `1` = device→entrance / person→member 全量改名**之前**的旧 wire；
/// - `2` = 该次改名之后的 wire（`sender_device_id`→`sender_entrance_id`、
///   `person_id`→`member_id`、WS 帧 `device.revoked`→`entrance.revoked`、
///   错误码 `DEVICE_REVOKED`→`ENTRANCE_REVOKED`、`/devices/*`→`/entrances/*` 等，
///   见 docs/GLOSSARY.md「wire 字段改名」）；
/// - `3` = 群聊一期（2026-10-03，aimemo/groupChatDesign.md）：create 删
///   `peer_name`/`peer_gender`（不再预置伴侣）、**create 新增 `mode`（duo|group，
///   创建时定死、永不改变——2026-10-04 取消升格）**、join slot 显式语义（不带
///   slot = 新身份 / 带 slot = 加通道，需 channel token）、join 请求新增
///   `member_name`/`member_gender`、join-tokens 请求新增 `purpose`、
///   preflight 响应新增 `mode`/`purpose`/`inviterName`、WS 新增
///   `member.joined` 帧。无老客户端兼容（一次性升级）。
///
/// REST（ApiClient）与 WS（ws_client）共用这一份，别再各写一个字面量。
/// 服务端对应 `server/src/protocolVersion.ts`（改动请两端同步）。
const String kProtocolVersion = '3';

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
  // 邮件通知（PROTOCOL.md §7.5）：没进应用商店 → 没有后台推送，给离线的对方发一封
  // 摘要信把他拉回来。PUT 设置（并发确认信）／GET 查状态／DELETE 撤掉。
  static const notifyEmail = '/notify/email';
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

/// 邮件通知状态（`GET` / `PUT` /notify/email，PROTOCOL.md §7.5）。
///
/// [state] 是服务端的四种状态之一：
/// - `none`：没设置过；
/// - `pending`：已发出确认信，等收件人点链接（**此时还不会收到任何提醒**）；
/// - `verified`：生效中；
/// - `inactive`：已退订或曾硬退信。
///
/// 提醒邮件的正文语言由 [lang] 决定（`zh` / `en`，PUT 时随邮箱一起上报）——
/// 服务端无从知道收件人读哪种语言，只能由客户端（知道界面语言）顺手告诉它。
class NotifyEmailStatus {
  NotifyEmailStatus({
    this.email,
    required this.state,
    this.verificationSent = false,
  });

  /// 已设置的提醒邮箱（`none` 时为 null）。
  final String? email;
  final String state;
  /// 本次 PUT 是否真的投出了确认信（老地址已验证过时不需要重发）。
  final bool verificationSent;

  factory NotifyEmailStatus.fromJson(Map<String, dynamic> json) => NotifyEmailStatus(
        email: json['email'] as String?,
        state: (json['state'] as String?) ?? 'none',
        verificationSent: (json['verification_sent'] as bool?) ?? false,
      );

  bool get isNone => state == 'none';
  /// 已点过确认链接、真的会收到提醒。
  bool get isVerified => state == 'verified';
  /// 填了但还没确认（Pending）——这一档必须让用户看见，否则他会以为已经开了。
  bool get isPending => state == 'pending';
}

/// 通道绑定结果（v2）：`POST /spaces` 与 `POST /spaces/join` 都直接返回这三个 id，
/// App 向导用它聚合"本次绑定拿到的身份"。
///
/// 历史：v1 时代这是 `POST /entrances/enroll` 的响应类型（`EnrollResult`）。该端点与
/// v1 邀请码已随 Multiverse 收敛删除（2026-09-15），所以它不再是"某个端点的响应"。
class EntranceBinding {
  const EntranceBinding({required this.entranceId, required this.memberId, required this.spaceId});

  final String entranceId;
  final String memberId;
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

/// 空间公开信息 + 成员 slot 列表（**不含空间名**：spaces.display_name 已删，
/// 2026-09-16）。2026-10-03/04 新增 [mode]/[purpose]/[inviterName]/[targetName]：
/// 客户端按 [purpose] 分流加入向导（invite=新身份、自己填名字 / attach=进已有
/// 身份、名字早就有），不再展示身份选择页。
class SpaceJoinPreflight {
  const SpaceJoinPreflight({
    required this.spaceId,
    required this.status,
    required this.memberCount,
    required this.slots,
    this.mode = 'duo',
    this.purpose = 'attach',
    this.inviterName,
    this.targetName,
    this.targetIsIssuer = false,
  });

  final String spaceId;
  final String status;
  final int memberCount;
  final List<SpaceMemberSlot> slots;
  /// 空间模式：'duo' | 'group'（旧服务端缺省回 duo）。
  final String mode;
  /// token 类型（2026-10-04 收敛）：
  /// - `invite` = 开**新身份**（新成员，向导里自己填名字）
  /// - `attach` = 进**已有身份**（我在新设备接入 / 帮别人找回身份）
  /// 旧服务端/老 token 缺省回 attach（安全侧：不会误开新身份）。
  final String purpose;
  /// 签发者显示名——invite 显示"XX 邀请你"，attach 显示"XX 的链接"。
  /// 无名成员空间为 null。
  final String? inviterName;
  /// attach 时"要进入的那个身份"的显示名（invite 恒为 null）——向导据此显示
  /// 「回到 <名字> 的身份」并跳过填名字（那是同一个身份，名字已经有了）。
  final String? targetName;
  /// attach 的目标是不是**签发者自己**（true = "我在另一台设备接入"，
  /// false = "别人帮我找回"）。不能靠名字比字符串——同名成员是允许的。
  final bool targetIsIssuer;

  factory SpaceJoinPreflight.fromJson(Map<String, dynamic> json) =>
      SpaceJoinPreflight(
        spaceId: json['spaceId'] as String,
        status: json['status'] as String,
        memberCount: json['memberCount'] as int,
        mode: (json['mode'] as String?) ?? 'duo',
        purpose: (json['purpose'] as String?) ?? 'attach',
        inviterName: json['inviterName'] as String?,
        targetName: json['targetName'] as String?,
        targetIsIssuer: (json['targetIsIssuer'] as bool?) ?? false,
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
    required this.memberId,
    required this.slot,
    required this.sessionToken,
    required this.entranceId,
    required this.spaceAddress,
  });

  final String spaceId;
  final String memberId;
  final int slot;
  final String sessionToken;
  final String entranceId;
  final String spaceAddress;

  factory SpaceJoinResult.fromJson(Map<String, dynamic> json) => SpaceJoinResult(
        spaceId: json['spaceId'] as String,
        memberId: json['memberId'] as String,
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
    required this.creatorMemberId,
    required this.sessionToken,
  });

  final String spaceId;
  final String spaceAddress;
  final String joinToken;
  final String link;
  final int expiresAt;
  final String entranceId;
  final String creatorMemberId;
  final String sessionToken;

  factory SpaceCreateResult.fromJson(Map<String, dynamic> json) =>
      SpaceCreateResult(
        spaceId: json['spaceId'] as String,
        spaceAddress: json['spaceAddress'] as String,
        joinToken: json['joinToken'] as String,
        link: json['link'] as String,
        expiresAt: json['expiresAt'] as int,
        entranceId: json['entranceId'] as String,
        creatorMemberId: json['creatorMemberId'] as String,
        sessionToken: json['sessionToken'] as String,
      );
}

/// 开通码生成结果（创建者调用）：POST /spaces/{id}/join-tokens 生成的、绑定一条新通道的
/// 一次性授权（24h 内一次性有效）。
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

/// 空间通道信息（GET /space 返回）：entrance_id → member_id 映射，
/// 用于判断消息是否"同一个人"发送（多通道凭证语义，PROTOCOL.md §7.3）。
class SpaceEntrance {
  const SpaceEntrance({
    required this.entranceId,
    required this.memberId,
    required this.status,
    this.lastSeen,
  });

  final String entranceId;
  final String memberId;
  final String status;
  final int? lastSeen;

  factory SpaceEntrance.fromJson(Map<String, dynamic> json) => SpaceEntrance(
        entranceId: json['entrance_id'] as String,
        memberId: json['member_id'] as String,
        status: json['status'] as String,
        lastSeen: json['last_seen'] as int?,
      );
}

/// 空间信息（GET /space 响应）。
class SpaceResult {
  const SpaceResult({
    required this.spaceId,
    required this.entrances,
    this.memberNames = const {},
    this.memberGenders = const {},
    this.memberSlots = const {},
    this.mode = 'duo',
    this.maxMembers = 0,
  });

  final String spaceId;
  final List<SpaceEntrance> entrances;

  /// member_id → member_name（创建者/邀请时设置，显示层用）。
  final Map<String, String> memberNames;

  /// member_id → gender（male/female，显示层用）。
  final Map<String, String> memberGenders;

  /// member_id → slot（小整数槽位：新身份 join 分配最小空槽，duo 恒 0/1；
  /// 同性别气泡配色区分「第二个人」用，老服务端无此键时为空表）。
  ///
  /// 群聊一期附带用途：**键集合就是本空间全部成员**（含未设置名字的成员——
  /// memberNames 只收有名字的），客户端列成员名单请以这里为准。
  final Map<String, int> memberSlots;

  /// 空间模式（群聊一期 2026-10-03）：'duo' = 二人私密空间（上限 2、通话可用）；
  /// 'group' = 群空间（上限 [maxMembers]、通话禁用）。旧服务端缺省回 'duo'。
  final String mode;

  /// 本服务器单空间成员上限（serverConfig.json 的 maxMembersPerSpace；0=不限）。
  /// **只对 group 生效**（duo 恒 2，与这个值无关）。客户端据此在满员时隐藏邀请
  /// 入口、在成员弹层里写明"最多 N 人"。
  final int maxMembers;

  factory SpaceResult.fromJson(Map<String, dynamic> json) => SpaceResult(
        spaceId: json['space_id'] as String,
        entrances: (json['entrances'] as List)
            .map((d) => SpaceEntrance.fromJson(d as Map<String, dynamic>))
            .toList(),
        memberNames: (json['member_names'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        memberGenders: (json['member_genders'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        memberSlots: (json['member_slots'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as int)),
        mode: (json['mode'] as String?) ?? 'duo',
        maxMembers: (json['max_members'] as num?)?.toInt() ?? 0,
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

/// 消息回执（已送达/已读）单调高水位，按 (space, member) 一行。
///
/// 语义：我的消息 seq=S 已送达 ⟺ 对方 `deliveredUptoSeq ≥ S`；已读 ⟺
/// `readUptoSeq ≥ S`。按 member 记 → "该 member 至少一条通道已收到/已读"
/// （不保证其所有通道）。回执只前进，且 `deliveredUptoSeq ≥ readUptoSeq`。
class ReceiptRow {
  ReceiptRow({
    required this.memberId,
    required this.deliveredUptoSeq,
    required this.readUptoSeq,
    required this.updatedAt,
  });

  final String memberId;
  final int deliveredUptoSeq;
  final int readUptoSeq;
  final int updatedAt;

  factory ReceiptRow.fromJson(Map<String, dynamic> json) => ReceiptRow(
        memberId: json['member_id'] as String,
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
