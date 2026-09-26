import 'dart:async';
import 'dart:math';

import 'package:einz_shared/einz_shared.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ws_realtime_service.dart';

/// ICE 服务器配置（voiceCall.zhcn.md §3）。
///
/// - STUN：打洞用，国内可达的小米公共 STUN（不用 `stun.l.google.com`，国内不可靠）。
/// - **TURN 走 `dart-define`，不写死**：跨运营商打洞失败时，部署好 coturn 后
///   `--dart-define=VOICE_TURN_URLS=turn:1.2.3.4:3478` 就能启用，不必改代码。
///   TURN 只转发 DTLS-SRTP 密文，不削弱 E2EE（方案 §3.1）。
const String kVoiceStunUrl =
    String.fromEnvironment('VOICE_STUN_URL', defaultValue: 'stun:stun.miwifi.com:3478');
const String kVoiceTurnUrls = String.fromEnvironment('VOICE_TURN_URLS');
const String kVoiceTurnUsername = String.fromEnvironment('VOICE_TURN_USERNAME');
const String kVoiceTurnCredential = String.fromEnvironment('VOICE_TURN_CREDENTIAL');

/// 通话阶段。
enum VoiceCallPhase {
  /// 空闲（无通话）。
  idle,

  /// 我已发起，等对方接听（振铃中·主叫）。
  calling,

  /// 对方打来，等我接听（振铃中·被叫）。
  ringing,

  /// 已接听，正在建立 P2P。
  connecting,

  /// 通话中。
  active,

  /// 已结束（看 [VoiceCallState.endReason] 区分怎么结束的）。
  ended,
}

/// 通话结束原因（UI 据此显示「未接 / 已拒绝 / 对方忙线 / 结束」）。
enum VoiceCallEndReason {
  /// 任一方挂断（含通话中结束）。
  hungUp,

  /// 主叫在对方接听前取消。
  canceled,

  /// 对方拒接。
  declined,

  /// 对方忙线（正在通话中）。
  busy,

  /// 振铃超时（对方没接——不做后台呼入，对方不在前台就是这个结果）。
  timeout,

  /// 连接失败（ICE 失败等）。
  failed,
}

/// 通话状态快照（UI 监听 [VoiceCallService.state]）。
class VoiceCallState {
  const VoiceCallState({
    this.phase = VoiceCallPhase.idle,
    this.isCaller = false,
    this.callId,
    this.startedAt,
    this.endReason,
    this.muted = false,
    this.speaker = true,
  });

  final VoiceCallPhase phase;
  final bool isCaller;

  /// 当前通话 id（1–64 字符，服务端只按这个转发）。
  final String? callId;

  /// 通话开始的时刻（[VoiceCallPhase.active] 起才有；UI 据此计时）。
  final DateTime? startedAt;

  final VoiceCallEndReason? endReason;

  final bool muted;

  /// 免提（接通后默认开——手持听筒贴耳的场景在 Einz 里没意义）。
  final bool speaker;

  bool get inCall =>
      phase == VoiceCallPhase.calling ||
      phase == VoiceCallPhase.ringing ||
      phase == VoiceCallPhase.connecting ||
      phase == VoiceCallPhase.active;

  VoiceCallState copyWith({
    VoiceCallPhase? phase,
    bool? isCaller,
    String? callId,
    DateTime? startedAt,
    VoiceCallEndReason? endReason,
    bool? muted,
    bool? speaker,
  }) {
    return VoiceCallState(
      phase: phase ?? this.phase,
      isCaller: isCaller ?? this.isCaller,
      callId: callId ?? this.callId,
      startedAt: startedAt ?? this.startedAt,
      endReason: endReason ?? this.endReason,
      muted: muted ?? this.muted,
      speaker: speaker ?? this.speaker,
    );
  }
}

/// 语音通话服务：状态机 + WebRTC + 走 WS 的信令（PROTOCOL.md §8.4）。
///
/// 边界（方案已拍板）：**只做前台通话**——不做后台呼入、不接推送。
/// 对方 App 不在前台时，发起方会一直振铃到超时（[VoiceCallEndReason.timeout]），
/// UI 必须把这说清楚，别让人以为功能坏了。
///
/// 通话状态机**全在客户端**：服务端只哑转发，振铃超时/忙线判定都在这里。
class VoiceCallService {
  VoiceCallService({required this.ws});

  final WsRealtimeService ws;

  /// 通话状态（UI 监听）。
  final ValueNotifier<VoiceCallState> state = ValueNotifier(const VoiceCallState());

  /// 通话结束回调（UI 据此写通话记录、弹提示）。
  void Function(VoiceCallEndReason reason, bool wasCaller, Duration? duration)? onEnded;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _remoteOfferSdp; // 被叫：接听前先存着对方的 offer
  final List<Map<String, dynamic>> _pendingIce = []; // pc 还没建好时先攒着
  Timer? _ringTimer;
  Timer? _connectTimer;

  static const Duration _ringTimeout = Duration(seconds: 60);

  /// 接通阶段（已接听、正在打洞）的超时。
  ///
  /// 没有它，ICE 打不通时会**永远停在「正在接通…」**——用户以为卡死，其实是在
  /// 干等一个永远不会来的 connected（跨运营商无 TURN 时就是这样）。
  static const Duration _connectTimeout = Duration(seconds: 30);

  // ─────────────────────────── 对外动作 ───────────────────────────

  /// 发起通话。对方不在前台就是振铃到超时。
  Future<void> invite() async {
    if (state.value.phase != VoiceCallPhase.idle) return;
    final callId = _newCallId();
    _isCaller = true;
    _emit(state.value.copyWith(phase: VoiceCallPhase.calling, isCaller: true, callId: callId));
    _send(kWsTypeCallInvite, callId);
    _startRingTimer();
    try {
      await _ensureMic();
      final pc = await _createPc();
      for (final track in _localStream!.getAudioTracks()) {
        await pc.addTrack(track, _localStream!);
      }
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _send(kWsTypeCallOffer, callId, extra: <String, dynamic>{'sdp': offer.sdp});
    } catch (e) {
      _end(VoiceCallEndReason.failed);
    }
  }

  /// 接听（被叫）。
  Future<void> accept() async {
    final s = state.value;
    if (s.phase != VoiceCallPhase.ringing || s.callId == null) return;
    _ringTimer?.cancel();
    final callId = s.callId!;
    _emit(s.copyWith(phase: VoiceCallPhase.connecting));
    _startConnectTimer();
    _send(kWsTypeCallAccept, callId);
    try {
      await _ensureMic();
      final pc = await _createPc();
      final offer = _remoteOfferSdp;
      if (offer != null) {
        await pc.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
      }
      for (final track in _localStream!.getAudioTracks()) {
        await pc.addTrack(track, _localStream!);
      }
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _send(kWsTypeCallAnswer, callId, extra: <String, dynamic>{'sdp': answer.sdp});
      await _flushIce();
    } catch (e) {
      _end(VoiceCallEndReason.failed);
    }
  }

  /// 拒接（被叫）。[reason] 一般传 `busy`（忙线）或 `declined`（不想接）。
  void reject({String reason = 'declined'}) {
    final s = state.value;
    if (s.phase != VoiceCallPhase.ringing || s.callId == null) return;
    _send(kWsTypeCallReject, s.callId!, extra: <String, dynamic>{'reason': reason});
    _end(reason == 'busy' ? VoiceCallEndReason.busy : VoiceCallEndReason.declined);
  }

  /// 挂断（通话中）或取消（振铃中的主叫）。
  void hangUp() {
    final s = state.value;
    if (!s.inCall) return;
    if (s.callId != null) _send(kWsTypeCallHangup, s.callId!);
    _end(s.phase == VoiceCallPhase.calling
        ? VoiceCallEndReason.canceled
        : VoiceCallEndReason.hungUp);
  }

  /// 切换静音。
  void toggleMute() {
    final stream = _localStream;
    if (stream == null) return;
    final next = !state.value.muted;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !next;
    }
    _emit(state.value.copyWith(muted: next));
  }

  /// 切换免提。
  Future<void> toggleSpeaker() async {
    final next = !state.value.speaker;
    try {
      await Helper.setSpeakerphoneOn(next);
    } catch (_) {
      // 桌面端不支持，忽略
    }
    _emit(state.value.copyWith(speaker: next));
  }

  /// 处理服务端转发来的通话信令（由页面把 [WsCallEvent] 转进来）。
  Future<void> handleRemote(WsCallEvent event) async {
    final callId = event.callId;
    final s = state.value;
    switch (event.type) {
      case kWsTypeCallInvite:
        if (s.phase != VoiceCallPhase.idle) {
          // 已经在通话中 → 回一个忙线，让对方立刻知道而不是干等超时
          _send(kWsTypeCallReject, callId, extra: <String, dynamic>{'reason': 'busy'});
          return;
        }
        _isCaller = false;
        _remoteOfferSdp = null;
        _pendingIce.clear();
        _emit(const VoiceCallState().copyWith(
          phase: VoiceCallPhase.ringing,
          isCaller: false,
          callId: callId,
        ));
        _startRingTimer(); // 一直不接 = 未接来电
        break;
      case kWsTypeCallAccept:
        if (s.phase == VoiceCallPhase.calling && s.callId == callId) {
          _ringTimer?.cancel();
          _emit(s.copyWith(phase: VoiceCallPhase.connecting));
          _startConnectTimer();
        }
        break;
      case kWsTypeCallReject:
        if (s.callId == callId) {
          _end(event.reason == 'busy' ? VoiceCallEndReason.busy : VoiceCallEndReason.declined);
        }
        break;
      case kWsTypeCallHangup:
        if (s.callId == callId) {
          _end(s.phase == VoiceCallPhase.ringing || s.phase == VoiceCallPhase.calling
              ? VoiceCallEndReason.canceled
              : VoiceCallEndReason.hungUp);
        }
        break;
      case kWsTypeCallOffer:
        if (s.callId == callId && s.phase == VoiceCallPhase.ringing) {
          _remoteOfferSdp = event.sdp;
        }
        break;
      case kWsTypeCallAnswer:
        if (s.callId == callId && _pc != null && event.sdp != null) {
          try {
            await _pc!.setRemoteDescription(RTCSessionDescription(event.sdp!, 'answer'));
            await _flushIce();
          } catch (_) {
            _end(VoiceCallEndReason.failed);
          }
        }
        break;
      case kWsTypeCallIce:
        if (s.callId != callId) break;
        final candidate = event.candidate;
        if (candidate == null) break;
        if (_pc == null) {
          _pendingIce.add(candidate);
        } else {
          await _addIce(candidate);
        }
        break;
    }
  }

  /// 彻底清理（页面销毁时调用）。
  Future<void> dispose() async {
    _ringTimer?.cancel();
    _connectTimer?.cancel();
    await _teardown();
    state.dispose();
  }

  // ─────────────────────────── 内部 ───────────────────────────

  bool _isCaller = false;

  void _emit(VoiceCallState next) => state.value = next;

  String _newCallId() {
    final rnd = Random.secure();
    final suffix = List<int>.generate(6, (_) => rnd.nextInt(16)).map((n) => n.toRadixString(16)).join();
    return 'c${DateTime.now().millisecondsSinceEpoch}$suffix';
  }

  void _send(String type, String callId, {Map<String, dynamic>? extra}) {
    ws.sendCall(type, <String, dynamic>{'call_id': callId, ...?extra});
  }

  void _startRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = Timer(_ringTimeout, () => _end(VoiceCallEndReason.timeout));
  }

  /// 开始计时"接通"阶段：超时就判定连接失败（不让它无限转圈）。
  void _startConnectTimer() {
    _connectTimer?.cancel();
    _connectTimer = Timer(_connectTimeout, () {
      final s = state.value;
      if (s.phase == VoiceCallPhase.connecting) _end(VoiceCallEndReason.failed);
    });
  }

  Future<void> _ensureMic() async {
    if (_localStream != null) return;
    _localStream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': false,
    });
  }

  /// 建连接。接通后**重设一次音频会话**——Phase A 真机实测：iOS 上不重设会出现
  /// 「connected 但没声音」，音频会话可能被别的 App 抢走。
  Future<RTCPeerConnection> _createPc() async {
    final pc = await createPeerConnection(<String, dynamic>{'iceServers': _iceServers()});
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      final id = state.value.callId;
      if (id == null) return;
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      _send(kWsTypeCallIce, id, extra: <String, dynamic>{'candidate': candidate.toMap()});
    };
    pc.onConnectionState = (connState) async {
      final s = state.value;
      if (connState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (s.phase != VoiceCallPhase.active) {
          await _activateAudioRoute();
          _emit(s.copyWith(phase: VoiceCallPhase.active, startedAt: DateTime.now()));
        }
      } else if (connState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        if (s.inCall) _end(VoiceCallEndReason.failed);
      }
    };
    return pc;
  }

  Future<void> _activateAudioRoute() async {
    // 通话期间常亮：息屏会让 iOS 挂起 App，直接把通话断掉（Phase A 4G 那次就踩过）
    unawaited(WakelockPlus.enable().catchError((_) => null));
    try {
      await Helper.ensureAudioSession();
      await Helper.setSpeakerphoneOn(state.value.speaker);
    } catch (_) {
      // 桌面端没有音频会话 API，忽略
    }
  }

  Future<void> _addIce(Map<String, dynamic> candidate) async {
    try {
      await _pc?.addCandidate(RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        candidate['sdpMLineIndex'] as int?,
      ));
    } catch (_) {
      // 单个候选无效不影响整体（别的候选可能还能用）
    }
  }

  Future<void> _flushIce() async {
    final pending = List<Map<String, dynamic>>.from(_pendingIce);
    _pendingIce.clear();
    for (final c in pending) {
      await _addIce(c);
    }
  }

  List<Map<String, dynamic>> _iceServers() {
    final servers = <Map<String, dynamic>>[
      <String, dynamic>{'urls': kVoiceStunUrl},
    ];
    final turn = kVoiceTurnUrls.trim();
    if (turn.isNotEmpty) {
      final urls = turn.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      if (urls.isNotEmpty) {
        servers.add(<String, dynamic>{
          'urls': urls,
          'username': kVoiceTurnUsername,
          'credential': kVoiceTurnCredential,
        });
      }
    }
    return servers;
  }

  void _end(VoiceCallEndReason reason) {
    final s = state.value;
    if (s.phase == VoiceCallPhase.idle) return;
    _ringTimer?.cancel();
    _connectTimer?.cancel();
    final duration = s.startedAt == null ? null : DateTime.now().difference(s.startedAt!);
    _emit(s.copyWith(phase: VoiceCallPhase.ended, endReason: reason));
    unawaited(WakelockPlus.disable().catchError((_) => null));
    unawaited(_teardown());
    onEnded?.call(reason, _isCaller, duration);
  }

  /// 回到 idle（UI 收完结束提示后调用，避免一直停在 ended）。
  void reset() {
    _ringTimer?.cancel();
    _connectTimer?.cancel();
    _emit(const VoiceCallState());
  }

  Future<void> _teardown() async {
    try {
      await _pc?.close();
      await _pc?.dispose();
    } catch (_) {}
    try {
      await _localStream?.dispose();
    } catch (_) {}
    _pc = null;
    _localStream = null;
    _remoteOfferSdp = null;
    _pendingIce.clear();
  }
}
