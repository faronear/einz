import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../crypto/message_crypto.dart';

/// WS 事件帧类型（PROTOCOL.md §8）。
const String kWsTypeHello = 'hello';
const String kWsTypeMessageNew = 'message.new';
const String kWsTypeDeviceRevoked = 'device.revoked';
const String kWsTypePeerOnline = 'peer.online';
const String kWsTypePeerOffline = 'peer.offline';
const String kWsTypePassphraseRotated = 'passphrase.rotated';
const String kWsTypeProfileUpdated = 'profile.updated';
const String kWsTypeReceiptUpdated = 'receipt.updated';

/// WS 连接状态（App 据此切换轮询策略：connected → 降频兜底，断开 → 恢复高频轮询）。
enum WsStatus { stopped, connecting, connected, reconnecting }

/// WS 事件（解析后的帧）。
sealed class WsEvent {
  const WsEvent({required this.type});

  final String type;
}

/// hello：连接建立（Server 返回设备/空间信息）。
class WsHelloEvent extends WsEvent {
  const WsHelloEvent({required super.type, required this.deviceId, required this.spaceId});

  final String deviceId;
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

/// device.revoked：本设备被撤销（Server 发帧后主动断开）。
class WsDeviceRevokedEvent extends WsEvent {
  const WsDeviceRevokedEvent({required super.type, required this.deviceId});

  final String deviceId;
}

/// peer.online/peer.offline：对端设备上下线通知（App 实时更新对方在线状态）。
/// [personId] 为上下线设备所属身份：与其相同身份的设备（我自己的另一台）不算
/// "对方"，接收方须忽略（旧服务端不带该字段时为 null——按原行为处理）。
/// [onlineSince] 仅 peer.online 携带：该设备进入在线态的时刻（ms，重连不刷新），
/// 接收方据此按上线顺序排列对端的在线设备（最新上线在最前；旧服务端为 null）。
class WsPeerStatusEvent extends WsEvent {
  const WsPeerStatusEvent({
    required super.type,
    required this.deviceId,
    this.personId,
    this.onlineSince,
  });

  final String deviceId;
  final String? personId;
  final int? onlineSince;
}

/// passphrase.rotated：空间口令已被重设（客户端收到后只发通知，不弹窗）。
class WsPassphraseRotatedEvent extends WsEvent {
  const WsPassphraseRotatedEvent({required super.type, required this.deviceId});

  final String deviceId;
}

/// profile.updated：对端改名/改设备名（App/TUI 立即更新对方名称）。
class WsProfileUpdatedEvent extends WsEvent {
  const WsProfileUpdatedEvent({
    required super.type,
    required this.deviceId,
    this.personId,
    this.personName,
    this.deviceName,
  });

  final String deviceId;
  final String? personId;
  final String? personName;
  final String? deviceName;
}

/// 对方回执（已送达/已读）更新：单调高水位，按 person 一行。
class WsReceiptUpdatedEvent extends WsEvent {
  const WsReceiptUpdatedEvent({
    required super.type,
    required this.personId,
    required this.deliveredUptoSeq,
    required this.readUptoSeq,
  });

  final String personId;
  final int deliveredUptoSeq;
  final int readUptoSeq;
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

  WebSocket? _ws;
  Timer? _reconnectTimer;
  bool _stopped = true;
  int _attempt = 0;
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
    final uri = Uri.parse('$wsUrl/ws?pv=1');
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
    try {
      final frame = jsonDecode(data as String) as Map<String, dynamic>;
      final type = frame['type'] as String;
      final payload = (frame['payload'] as Map<String, dynamic>?) ?? const {};
      switch (type) {
        case kWsTypeHello:
          onEvent?.call(WsHelloEvent(
            type: type,
            deviceId: payload['device_id'] as String? ?? '',
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
        case kWsTypeDeviceRevoked:
          onEvent?.call(WsDeviceRevokedEvent(
            type: type,
            deviceId: payload['device_id'] as String? ?? '',
          ));
          break;
        case kWsTypePeerOnline:
        case kWsTypePeerOffline:
          onEvent?.call(WsPeerStatusEvent(
            type: type,
            deviceId: payload['device_id'] as String? ?? '',
            personId: payload['person_id'] as String?,
            onlineSince: payload['online_since'] as int?,
          ));
          break;
        case kWsTypePassphraseRotated:
          onEvent?.call(WsPassphraseRotatedEvent(
            type: type,
            deviceId: payload['device_id'] as String? ?? '',
          ));
          break;
        case kWsTypeProfileUpdated:
          onEvent?.call(WsProfileUpdatedEvent(
            type: type,
            deviceId: payload['device_id'] as String? ?? '',
            personId: payload['person_id'] as String?,
            personName: payload['person_name'] as String?,
            deviceName: payload['device_name'] as String?,
          ));
          break;
        case kWsTypeReceiptUpdated:
          onEvent?.call(WsReceiptUpdatedEvent(
            type: type,
            personId: payload['person_id'] as String? ?? '',
            deliveredUptoSeq: (payload['delivered_upto_seq'] as int?) ?? 0,
            readUptoSeq: (payload['read_upto_seq'] as int?) ?? 0,
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
