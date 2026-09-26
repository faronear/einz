import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../crypto/message_crypto.dart';
import 'types.dart';

/// WS 事件帧类型（PROTOCOL.md §8）。
const String kWsTypeHello = 'hello';
const String kWsTypeMessageNew = 'message.new';
const String kWsTypeEntranceRevoked = 'entrance.revoked';
const String kWsTypePeerOnline = 'peer.online';
const String kWsTypePeerOffline = 'peer.offline';
const String kWsTypePassphraseRotated = 'passphrase.rotated';
const String kWsTypeProfileUpdated = 'profile.updated';
const String kWsTypeReceiptUpdated = 'receipt.updated';

/// 语音通话信令（PROTOCOL.md §8.4）。
///
/// 服务端只做**同空间哑转发**：不解析 sdp/candidate、不落库、不进 `server_sequence`。
/// 通话状态机（振铃超时、忙线判定）全在客户端，服务端不参与——避免与断线重连纠缠。
/// 注意：服务端用的是裸字符串字面量（`server/src/ws.ts`），改名要两边一起改。
const String kWsTypeCallInvite = 'call.invite';
const String kWsTypeCallAccept = 'call.accept';
const String kWsTypeCallReject = 'call.reject';
const String kWsTypeCallHangup = 'call.hangup';
const String kWsTypeCallOffer = 'call.offer';
const String kWsTypeCallAnswer = 'call.answer';
const String kWsTypeCallIce = 'call.ice';

/// WS 连接状态（App 据此切换轮询策略：connected → 降频兜底，断开 → 恢复高频轮询）。
enum WsStatus { stopped, connecting, connected, reconnecting }

/// WS 事件（解析后的帧）。
sealed class WsEvent {
  const WsEvent({required this.type});

  final String type;
}

/// hello：连接建立（Server 返回通道/空间信息）。
class WsHelloEvent extends WsEvent {
  const WsHelloEvent({required super.type, required this.entranceId, required this.spaceId});

  final String entranceId;
  final String spaceId;
}

/// message.new：新消息广播（含 server_sequence；App 收到后增量同步即可，无需全量拉取）。
class WsMessageNewEvent extends WsEvent {
  const WsMessageNewEvent({
    required super.type,
    required this.message,
    required this.serverSequence,
  });

  final MessageEnvelope message;
  final int serverSequence;
}

/// entrance.revoked：本通道被撤销（Server 发帧后主动断开）。
class WsEntranceRevokedEvent extends WsEvent {
  const WsEntranceRevokedEvent({required super.type, required this.entranceId});

  final String entranceId;
}

/// peer.online/peer.offline：对端通道上下线通知（App 实时更新对方在线状态）。
/// [memberId] 为上下线通道所属身份：与其相同身份的通道（我自己的另一条）不算
/// "对方"，接收方须忽略（旧服务端不带该字段时为 null——按原行为处理）。
/// [onlineSince] 仅 peer.online 携带：该通道进入在线态的时刻（ms，重连不刷新），
/// 接收方据此按上线顺序排列对端的在线通道（最新上线在最前；旧服务端为 null）。
class WsPeerStatusEvent extends WsEvent {
  const WsPeerStatusEvent({
    required super.type,
    required this.entranceId,
    this.memberId,
    this.onlineSince,
  });

  final String entranceId;
  final String? memberId;
  final int? onlineSince;
}

/// passphrase.rotated：空间口令已被重设（客户端收到后只发通知，不弹窗）。
class WsPassphraseRotatedEvent extends WsEvent {
  const WsPassphraseRotatedEvent({required super.type, required this.entranceId});

  final String entranceId;
}

/// profile.updated：对端改名/改通道名（App/TUI 立即更新对方名称）。
class WsProfileUpdatedEvent extends WsEvent {
  const WsProfileUpdatedEvent({
    required super.type,
    required this.entranceId,
    this.memberId,
    this.memberName,
    this.entranceName,
  });

  final String entranceId;
  final String? memberId;
  final String? memberName;
  final String? entranceName;
}

/// 对方回执（已送达/已读）更新：单调高水位，按 member 一行。
class WsReceiptUpdatedEvent extends WsEvent {
  const WsReceiptUpdatedEvent({
    required super.type,
    required this.memberId,
    required this.deliveredUptoSeq,
    required this.readUptoSeq,
  });

  final String memberId;
  final int deliveredUptoSeq;
  final int readUptoSeq;
}

/// 通话信令事件（call.*，PROTOCOL.md §8.4）。
///
/// 服务端转发时会补 `from_entrance_id`（发起方通道 id），便于接收端判断是谁打来的、
/// 以及忽略自己另一条通道回显的帧。[sdp] / [candidate] 原样搬运，本层不解析。
class WsCallEvent extends WsEvent {
  const WsCallEvent({
    required super.type,
    required this.callId,
    this.fromEntranceId,
    this.sdp,
    this.candidate,
    this.reason,
  });

  final String callId;

  /// 帧的发起方通道（S→C 才有；C→S 时为空）。
  final String? fromEntranceId;

  /// offer / answer 的 SDP 全文。
  final String? sdp;

  /// ICE 候选（RTCIceCandidate.toMap() 的形状）。
  final Map<String, dynamic>? candidate;

  /// reject 的原因：`declined`（拒接）/ `busy`（忙线）。
  final String? reason;
}

/// WS 实时客户端：连接 / 事件回调 / 自动重连（指数退避，上限 30s）。
///
/// - [server] 传 http(s) 基址（https://einz.tic.cc），内部转换为 ws(s)://
/// - 凭证走握手头 `Authorization: Bearer <session_token>`，**不放 URL**（PROTOCOL.md §8.1）
/// - [stop] 之前持续重连；状态经 [onStatus] 回调（App 据此切换轮询策略）
/// - [onUnauthorized]：服务器以 4401 关闭（session 过期）时调用——CLI/App 在此
///   重新认证并 [updateToken]，随后立即重连；未提供则按普通断线退避重连
class WsClient {
  WsClient({
    required this.server,
    required String token,
    this.onEvent,
    this.onStatus,
    this.onUnauthorized,
  }) : _token = token;

  final String server;
  String _token;

  /// 事件回调（message.new 等）。
  final void Function(WsEvent event)? onEvent;

  /// 连接状态回调。
  final void Function(WsStatus status)? onStatus;

  /// 401（session 过期）续期回调：返回后立即用新 token 重连。
  final Future<void> Function()? onUnauthorized;

  String get token => _token;

  /// 更新连接 token（重新认证后调用，供下一次重连使用）。
  void updateToken(String newToken) {
    _token = newToken;
  }

  /// 发一个帧（通话信令用；此前本类只有 `listen` 没有发送能力）。
  ///
  /// 未连接时静默丢弃——通话信令是"尽力而为"，丢了由上层状态机（超时/挂断）兜底，
  /// 不需要在这里抛错打断 UI。
  void send(String type, Map<String, dynamic> payload) {
    final ws = _ws;
    if (ws == null) return;
    ws.add(jsonEncode(<String, dynamic>{
      'id': ++_frameId,
      'type': type,
      'payload': payload,
    }));
  }

  WebSocket? _ws;
  Timer? _reconnectTimer;
  bool _stopped = true;
  int _attempt = 0;
  /// 连续"4401 → 续期 → 仍被 4401"的次数（连上就清零，见 [_connect]）。
  int _unauthorizedStreak = 0;
  /// 发出去的帧序号（PROTOCOL.md §8.2 的 `id`；只用于日志/排障，非请求-响应配对）。
  int _frameId = 0;
  WsStatus _status = WsStatus.stopped;

  WsStatus get status => _status;

  /// 建立连接（失败自动重连，直到 [stop]）。
  void start() {
    _stopped = false;
    _connect();
  }

  /// 停止并关闭连接（取消重连）。
  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    await _ws?.close();
    _ws = null;
    _setStatus(WsStatus.stopped);
  }

  void _setStatus(WsStatus s) {
    _status = s;
    onStatus?.call(s);
  }

  void _connect() {
    if (_stopped) return;
    _setStatus(_attempt == 0 ? WsStatus.connecting : WsStatus.reconnecting);
    final wsUrl = server.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
    // 凭证走握手头，**不放 URL query**（2026-09-15 评审 H4）：URL 会进反代
    // access log / 代理缓存 / 浏览器历史，session token 不该落在这些地方。
    final uri = Uri.parse('$wsUrl/ws?pv=$kProtocolVersion');
    WebSocket.connect(
      uri.toString(),
      headers: {'Authorization': 'Bearer $_token'},
    ).then((ws) {
      if (_stopped) {
        ws.close();
        return;
      }
      _ws = ws;
      _attempt = 0;
      // 注意：这里**不能**清零 _unauthorizedStreak —— 服务端是先完成 WS 握手、
      // 再 4401 关掉（握手成功 ≠ 被接受）。清零放在 [_handleFrame]（真收到帧）。
      _setStatus(WsStatus.connected);
      ws.listen(
        _handleFrame,
        onDone: () => _onClosed(ws),
        onError: (_) => _scheduleReconnect(),
      );
    }).catchError((_) {
      _scheduleReconnect();
    });
  }

  /// 连接关闭：4401（session 过期）→ 续期后立即重连；其他 → 退避重连。
  Future<void> _onClosed(WebSocket ws) async {
    if (_stopped) return;
    // 旧连接的 onDone 迟到（已重连、甚至已换新连接后旧 socket 才收尾）→ 忽略：
    // 否则会白触发一次退避重连，多开一条连接（2026-09-15 评审）。
    if (ws != _ws) return;
    _ws = null;
    if (ws.closeCode == 4401 && onUnauthorized != null) {
      try {
        final before = _token;
        await onUnauthorized!(); // 重新认证并 updateToken
        if (_stopped) return;
        if (_token == before) {
          // 续期**没有真的换到新 token**（上层忘了 updateToken，或服务端照样拒）→
          // 立即重连只会拿同一个坏 token 再被 4401 关掉，构成**零延迟死循环**。
          // 2026-09-22 实测：App 侧就是这样把 POST /auth/challenge 打成
          // 429 RATE_LIMITED，进而连累同 IP 的邀请加入（也被限流）。
          // 这里兜底：token 没变就走退避，不让循环失控。
          _scheduleReconnect();
          return;
        }
        // 即便拿到了新 token，也要防"服务端照样拒"这一类：连续几次仍被 4401，
        // 说明不是单纯的会话过期（通道不在册 / 服务端不认本通道），立刻重连会变成
        // 打服务端的循环（每轮一次 POST /auth/challenge，很快触发限流）。
        if (++_unauthorizedStreak >= 3) {
          _scheduleReconnect();
          return;
        }
        _attempt = 0;
        _setStatus(WsStatus.reconnecting);
        _connect(); // 用新 token 立即重连
        return;
      } catch (_) {
        // 续期失败：走普通退避重连
      }
    }
    _scheduleReconnect();
  }

  void _handleFrame(dynamic data) {
    // 收到帧 = 服务端真的接受了这条连接 → 续期链路是好的，清零 4401 连续计数
    _unauthorizedStreak = 0;
    try {
      final frame = jsonDecode(data as String) as Map<String, dynamic>;
      final type = frame['type'] as String;
      final payload = (frame['payload'] as Map<String, dynamic>?) ?? const {};
      switch (type) {
        case kWsTypeHello:
          onEvent?.call(WsHelloEvent(
            type: type,
            entranceId: payload['entrance_id'] as String? ?? '',
            spaceId: payload['space_id'] as String? ?? '',
          ));
          break;
        case kWsTypeMessageNew:
          onEvent?.call(WsMessageNewEvent(
            type: type,
            message: MessageEnvelope.fromJson(payload['message'] as Map<String, dynamic>),
            serverSequence: payload['server_sequence'] as int,
          ));
          break;
        case kWsTypeEntranceRevoked:
          onEvent?.call(WsEntranceRevokedEvent(
            type: type,
            entranceId: payload['entrance_id'] as String? ?? '',
          ));
          break;
        case kWsTypePeerOnline:
        case kWsTypePeerOffline:
          onEvent?.call(WsPeerStatusEvent(
            type: type,
            entranceId: payload['entrance_id'] as String? ?? '',
            memberId: payload['member_id'] as String?,
            onlineSince: payload['online_since'] as int?,
          ));
          break;
        case kWsTypePassphraseRotated:
          onEvent?.call(WsPassphraseRotatedEvent(
            type: type,
            entranceId: payload['entrance_id'] as String? ?? '',
          ));
          break;
        case kWsTypeProfileUpdated:
          onEvent?.call(WsProfileUpdatedEvent(
            type: type,
            entranceId: payload['entrance_id'] as String? ?? '',
            memberId: payload['member_id'] as String?,
            memberName: payload['member_name'] as String?,
            entranceName: payload['entrance_name'] as String?,
          ));
          break;
        case kWsTypeReceiptUpdated:
          onEvent?.call(WsReceiptUpdatedEvent(
            type: type,
            memberId: payload['member_id'] as String? ?? '',
            deliveredUptoSeq: (payload['delivered_upto_seq'] as int?) ?? 0,
            readUptoSeq: (payload['read_upto_seq'] as int?) ?? 0,
          ));
          break;
        case kWsTypeCallInvite:
        case kWsTypeCallAccept:
        case kWsTypeCallReject:
        case kWsTypeCallHangup:
        case kWsTypeCallOffer:
        case kWsTypeCallAnswer:
        case kWsTypeCallIce:
          onEvent?.call(WsCallEvent(
            type: type,
            callId: payload['call_id'] as String? ?? '',
            fromEntranceId: payload['from_entrance_id'] as String?,
            sdp: payload['sdp'] as String?,
            candidate: (payload['candidate'] as Map<String, dynamic>?),
            reason: payload['reason'] as String?,
          ));
          break;
      }
    } catch (_) {
      // 未知/损坏帧忽略（协议向前兼容）
    }
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _attempt++;
    // 指数退避：1/2/4/8/16/30s（上限 30s）
    final delay = const [1, 2, 4, 8, 16, 30][(_attempt - 1).clamp(0, 5)];
    _setStatus(WsStatus.reconnecting);
    _reconnectTimer = Timer(Duration(seconds: delay), _connect);
  }
}
